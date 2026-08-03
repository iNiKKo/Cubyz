const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const physics = main.physics;
const random = main.random;
const vec = main.vec;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const Mob = main.server.Mob;
const ServerWorld = main.server.ServerWorld;

const maxCapacity = 4096;

const terminalVelocity = 40.0;
const gravity = physics.baseGravity;

const wanderSpeed = 2.5;
const fleeSpeed = 5.5;
const fleeRadius = 6.0;
const fleeRadiusSqr = fleeRadius*fleeRadius;
const turnSpeed = 4.0; // radians/second
const facingTolerance = 0.6; // radians; must be roughly facing a direction before walking toward it
const jumpHeight = 1.25; // matches the player's jump height
const jumpCooldownDuration = 0.5; // seconds between jumps
const stuckJumpDelay = 0.25; // seconds of barely moving forward while trying to walk before jumping
const stuckDistanceThreshold = 0.1; // total horizontal distance covered below this over stuckJumpDelay counts as "stuck"
const tameFeedRadius = 3.0;
const attractRadius = 8.0; // untamed mobs notice a crouching player holding an apple within this range
const attractRadiusSqr = attractRadius*attractRadius;
const followStopRadius = 2.5; // tamed mobs stop walking once this close to their tamer
const followStopRadiusSqr = followStopRadius*followStopRadius;
const tameHerdRadius = 16.0;
const tameHerdRadiusSqr = tameHerdRadius*tameHerdRadius;
const shelterSearchRadius = 10; // blocks, horizontal search range for tree cover
const shelterSearchCooldownDuration = 3.0; // seconds between re-searching for cover if none was found
const shelterArriveRadius = 1.2;
const shelterArriveRadiusSqr = shelterArriveRadius*shelterArriveRadius;
const shelterOverheadScanHeight = 6; // blocks scanned upward when checking for leaf cover

allocator: NeverFailingAllocator,

list: std.MultiArrayList(Mob) = .{},

indices: [maxCapacity]u16 = undefined,

emptyMutex: main.utils.Mutex = .{},
isEmpty: std.bit_set.ArrayBitSet(usize, maxCapacity) = .initFull(),

/// Chunk positions (wx,wy,wz of the chunk that generated a spawn) already used to spawn
/// a mob this session. Guards against re-running the mob-spawn generator producing a
/// duplicate if a chunk is regenerated (e.g. evicted from cache) before it's ever saved
/// to disk — spawn() is otherwise called from arbitrary chunk-generation worker threads,
/// so this set is protected by emptyMutex alongside the slot-allocation bitset.
spawnedChunks: std.AutoHashMapUnmanaged(main.chunk.ChunkPosition, void) = .{},

changeQueue: main.utils.ConcurrentQueue(union(enum) {add: struct {u16, Mob}, remove: u16}) = undefined,

world: *ServerWorld,

size: u32 = 0,

pub fn init(self: *@This(), allocator: NeverFailingAllocator, world: *ServerWorld) void {
	self.* = .{
		.allocator = allocator,
		.world = world,
		.changeQueue = .init(allocator, 16),
	};
	self.list.resize(self.allocator.allocator, maxCapacity) catch unreachable;
}

pub fn deinit(self: *@This()) void {
	self.processChanges();
	self.changeQueue.deinit();
	self.list.deinit(self.allocator.allocator);
	self.spawnedChunks.deinit(self.allocator.allocator);
}

fn hitBoxFor(mobType: Mob.MobType) physics.collision.Box {
	const modelIndex = main.entityModel.getById(mobType.modelId()) orelse main.entityModel.default();
	const height: f64 = @floatCast(modelIndex.get().height);
	const halfHeight = height*0.5;
	const halfWidth = height*0.3;
	return .{.min = .{-halfWidth, -halfWidth, -halfHeight}, .max = .{halfWidth, halfWidth, halfHeight}};
}

/// Safe to call from any thread (e.g. chunk generation workers). The actual
/// list mutation is deferred to processChanges(), which only ever runs on
/// the thread that owns the ServerWorld tick (see update()).
///
/// `spawningChunk` identifies the chunk whose generation triggered this spawn; if that
/// chunk was already used to spawn a mob this session (e.g. it got regenerated after
/// being evicted from cache but before ever being saved to disk, so the generator ran
/// again), the spawn is silently skipped to avoid duplicating the same mob.
pub fn spawn(self: *@This(), pos: Vec3d, mobType: Mob.MobType, spawningChunk: main.chunk.ChunkPosition) void {
	self.emptyMutex.lock();
	const alreadySpawned = self.spawnedChunks.fetchPut(self.allocator.allocator, spawningChunk, {}) catch unreachable;
	if (alreadySpawned != null) {
		self.emptyMutex.unlock();
		return;
	}
	const i: u16 = @intCast(self.isEmpty.findFirstSet() orelse {
		self.emptyMutex.unlock();
		std.log.err("Mob capacity limit reached. Failed to spawn {s}", .{mobType.modelId()});
		return;
	});
	self.isEmpty.unset(i);
	self.emptyMutex.unlock();

	const id = main.entity.allocateEntityId();
	// Seed from the entity id (globally unique) rather than position: two mobs spawned at
	// the same or nearby rounded position (initSeed3D truncates to whole blocks) would
	// otherwise get identical/correlated RNG state and move in perfect lockstep forever.
	var mob = Mob{
		.id = id,
		.mobType = mobType,
		.pos = pos,
		.health = mobType.maxHealth(),
		.randState = random.initSeed2D(self.world.settings.seed, .{@bitCast(@intFromEnum(id)), 0}),
	};
	pickWanderDirection(&mob);

	const modelIndex = main.entityModel.getById(mobType.modelId()) orelse main.entityModel.default();
	main.entity.components.@"cubyz:model".server.put(id, .{.entityModel = modelIndex});

	self.broadcastAdd(mob);
	self.changeQueue.pushBack(.{.add = .{i, mob}});
}

const saveVersion = 2;

/// Only safe to call before the server starts accepting connections (world init).
pub fn loadFromBytes(self: *@This(), reader: *main.utils.BinaryReader) !void {
	const version = try reader.readInt(u8);
	if (version != saveVersion) return error.UnsupportedVersion;
	while (reader.remaining.len != 0) {
		const mob = try Mob.fromBytes(reader);
		if (self.size >= maxCapacity) break;
		const i: u16 = @intCast(self.isEmpty.findFirstSet() orelse break);
		self.isEmpty.unset(i);

		main.entity.reserveEntityId(mob.id);
		const modelIndex = main.entityModel.getById(mob.mobType.modelId()) orelse main.entityModel.default();
		main.entity.components.@"cubyz:model".server.put(mob.id, .{.entityModel = modelIndex});

		self.list.set(i, mob);
		self.indices[self.size] = i;
		self.size += 1;
	}
}

/// Only safe to call while nothing else can mutate the mob list concurrently (world deinit).
pub fn storeToBytes(self: *@This(), writer: *main.utils.BinaryWriter) void {
	self.processChanges();
	writer.writeInt(u8, saveVersion);
	for (self.indices[0..self.size]) |i| {
		self.list.get(i).toBytes(writer);
	}
}

pub fn despawn(self: *@This(), index: u32) void {
	const i = self.indices[index];
	const id = self.list.items(.id)[i];
	self.despawnStorageIndex(i, id);
}

fn despawnStorageIndex(self: *@This(), i: u16, id: main.entity.Entity) void {
	main.entity.server.removeAllComponents(id);

	self.emptyMutex.lock();
	self.isEmpty.set(i);
	self.emptyMutex.unlock();

	self.broadcastRemove(id);
	self.changeQueue.pushBack(.{.remove = i});
}

/// Applies damage to the mob with the given id. On death, despawns it and drops its item.
/// Returns false if no mob with that id is currently alive.
pub fn damage(self: *@This(), targetId: main.entity.Entity, amount: f32) bool {
	self.processChanges();

	const ids = self.list.items(.id);
	var target: ?u16 = null;
	for (self.indices[0..self.size]) |i| {
		if (ids[i] == targetId) {
			target = i;
			break;
		}
	}
	const i = target orelse return false;

	var mob = self.list.get(i);
	mob.health -= amount;
	if (mob.health <= 0) {
		self.despawnStorageIndex(i, mob.id);

		const dropItemId = mob.mobType.dropItemId();
		if (main.items.BaseItemIndex.fromId(dropItemId)) |baseItem| {
			const stack = main.items.ItemStack{.item = .{.baseItem = baseItem}, .amount = 1};
			self.world.drop(stack, mob.pos, .{0, 0, 1}, 2.0);
		} else {
			std.log.err("Unknown drop item id {s} for mob type", .{dropItemId});
		}
	} else {
		self.list.set(i, mob);
		self.broadcastAdd(mob);
	}
	return true;
}

fn processChanges(self: *@This()) void {
	while (self.changeQueue.popFront()) |data| {
		switch (data) {
			.add => |addData| {
				const i, const mob = addData;
				self.list.set(i, mob);
				self.indices[self.size] = i;
				self.size += 1;
			},
			.remove => |i| {
				var ii: u32 = 0;
				while (ii < self.size) : (ii += 1) {
					if (self.indices[ii] == i) {
						self.size -= 1;
						self.indices[ii] = self.indices[self.size];
						break;
					}
				}
			},
		}
	}
}

fn broadcastAdd(_: *@This(), mob: Mob) void {
	const list = ZonElement.initArray(main.stackAllocator);
	defer list.deinit(main.stackAllocator);
	list.array.append(mob.save(main.stackAllocator));
	list.array.append(.null);
	const updateData = list.toStringEfficient(main.stackAllocator, &.{});
	defer main.stackAllocator.free(updateData);

	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		main.network.protocols.entity.send(user.conn, updateData);
	}
}

fn broadcastRemove(_: *@This(), id: main.entity.Entity) void {
	const list = ZonElement.initArray(main.stackAllocator);
	defer list.deinit(main.stackAllocator);
	list.array.append(.{.int = @intFromEnum(id)});
	list.array.append(.null);
	const updateData = list.toStringEfficient(main.stackAllocator, &.{});
	defer main.stackAllocator.free(updateData);

	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		main.network.protocols.entity.send(user.conn, updateData);
	}
}

/// Appends each live mob's zon representation into `zonArray` (which the caller owns
/// and is responsible for freeing). Does not build or own any intermediate container.
pub fn appendInitialList(self: *@This(), allocator: NeverFailingAllocator, zonArray: ZonElement) void {
	self.processChanges();
	var ii: u32 = 0;
	while (ii < self.size) : (ii += 1) {
		const i = self.indices[ii];
		zonArray.array.append(self.list.get(i).save(allocator));
	}
}

pub fn getPositionAndVelocityData(self: *@This(), allocator: NeverFailingAllocator) []main.entity.EntityNetworkData {
	const result = allocator.alloc(main.entity.EntityNetworkData, self.size);
	for (self.indices[0..self.size], result) |i, *res| {
		res.* = .{
			.id = self.list.items(.id)[i],
			.pos = self.list.items(.pos)[i],
			.vel = self.list.items(.vel)[i],
			.rot = self.list.items(.rot)[i],
		};
	}
	return result;
}

/// Tames the mob with the given id, plus any nearby untamed mob of the same type
/// (its "herd"), so they stop fleeing from `playerIndex` (the player's persistent
/// PlayerIndex, stable across reconnects/restarts, not their ephemeral entity id).
/// `playerPos` is used to enforce a server-side feed-reach limit, independent of
/// the client's raycast. Returns false if no mob with that id is alive and in reach.
pub fn feed(self: *@This(), targetId: main.entity.Entity, playerIndex: usize, playerPos: Vec3d) bool {
	self.processChanges();

	const ids = self.list.items(.id);
	const pos = self.list.items(.pos);
	const mobType = self.list.items(.mobType);
	const tamedBy = self.list.items(.tamedBy);

	var targetIndex: ?u16 = null;
	for (self.indices[0..self.size]) |i| {
		if (ids[i] == targetId) {
			targetIndex = i;
			break;
		}
	}
	const target = targetIndex orelse return false;
	if (vec.lengthSquare(pos[target] - playerPos) > tameFeedRadius*tameFeedRadius) return false;

	tamedBy[target] = playerIndex;
	self.broadcastAdd(self.list.get(target));

	for (self.indices[0..self.size]) |i| {
		if (i == target) continue;
		if (mobType[i] != mobType[target]) continue;
		if (tamedBy[i] != Mob.noTamer) continue;
		if (vec.lengthSquare(pos[i] - pos[target]) > tameHerdRadiusSqr) continue;
		tamedBy[i] = playerIndex;
		self.broadcastAdd(self.list.get(i));
	}
	return true;
}

fn pickWanderDirection(mob: *Mob) void {
	const angle = random.nextFloat(&mob.randState)*2*std.math.pi;
	mob.wanderDir = .{@cos(angle), @sin(angle), 0};
	mob.state = .wander;
	mob.stateTimer = 4 + random.nextFloat(&mob.randState)*5;
}

fn pickPause(mob: *Mob) void {
	mob.state = .pause;
	mob.stateTimer = 1 + random.nextFloat(&mob.randState)*2;
}

fn isHoldingApple(user: *main.server.User) bool {
	return std.mem.eql(u8, user.selectedItemId, "cubyz:apple");
}

fn isRainingAt(world: *ServerWorld, pos: Vec3d) bool {
	const wx: i32 = @intFromFloat(@floor(pos[0]));
	const wy: i32 = @intFromFloat(@floor(pos[1]));
	const wz: i32 = @intFromFloat(@floor(pos[2]));
	const biome = world.getBiome(wx, wy, wz);
	const nowMillis = main.timestamp().toMilliseconds();
	const weather = main.server.WeatherMap.sample(world.settings.seed, biome, wx, wy, nowMillis);
	return weather.kind == .rain and weather.precipitation > 0.05;
}

fn isLeafBlock(block: main.blocks.Block) bool {
	if (block.typ == 0) return false;
	return std.mem.startsWith(u8, block.id(), "cubyz:leaves/");
}

/// Checks for leaf cover directly above (x, y), scanning up to shelterOverheadScanHeight blocks.
fn hasCoverAt(world: *ServerWorld, wx: i32, wy: i32, wzStart: i32) bool {
	var wz = wzStart;
	const top = wzStart + shelterOverheadScanHeight;
	while (wz < top) : (wz += 1) {
		const block = world.getBlock(wx, wy, wz) orelse continue;
		if (isLeafBlock(block)) return true;
	}
	return false;
}

/// Scans outward in a small ring around the mob for the nearest tree canopy.
/// Expensive relative to the rest of the AI tick, so callers should throttle this.
fn findNearbyTreeCover(world: *ServerWorld, pos: Vec3d) ?Vec3d {
	const originX: i32 = @intFromFloat(@floor(pos[0]));
	const originY: i32 = @intFromFloat(@floor(pos[1]));
	const originZ: i32 = @intFromFloat(@floor(pos[2]));

	var bestDistSqr: i32 = std.math.maxInt(i32);
	var best: ?Vec3d = null;

	var dx: i32 = -shelterSearchRadius;
	while (dx <= shelterSearchRadius) : (dx += 1) {
		var dy: i32 = -shelterSearchRadius;
		while (dy <= shelterSearchRadius) : (dy += 1) {
			const distSqr = dx*dx + dy*dy;
			if (distSqr > shelterSearchRadius*shelterSearchRadius or distSqr >= bestDistSqr) continue;
			const wx = originX + dx;
			const wy = originY + dy;
			if (!hasCoverAt(world, wx, wy, originZ)) continue;
			bestDistSqr = distSqr;
			best = Vec3d{@floatFromInt(wx), @floatFromInt(wy), pos[2]} + Vec3d{0.5, 0.5, 0};
		}
	}
	return best;
}

/// Finds the nearest player that should be treated as a flee threat: crouching players
/// are sneaking and ignored, and the specific player who tamed this mob is trusted.
fn nearestThreateningPlayerDistanceSqr(mob: *const Mob) struct {distSqr: f64, dir: Vec3d} {
	var best: f64 = std.math.inf(f64);
	var bestDir: Vec3d = .{0, 0, 0};
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (user.crouching) continue;
		if (mob.tamedBy != Mob.noTamer and user.playerIndex == mob.tamedBy) continue;
		const delta = mob.pos - user.player().pos;
		const distSqr = vec.lengthSquare(delta);
		if (distSqr < best) {
			best = distSqr;
			bestDir = delta;
		}
	}
	return .{.distSqr = best, .dir = bestDir};
}

const AttractiveTarget = struct {distSqr: f64, dir: Vec3d, isTamer: bool};

/// Finds the nearest crouching player holding an apple within attractRadius (untamed mobs
/// are drawn to whoever's trying to feed them), or the mob's tamer if they're holding an
/// apple (tamed mobs follow their tamer regardless of crouching).
fn nearestAttractivePlayerDistanceSqr(mob: *const Mob) ?AttractiveTarget {
	var best: ?AttractiveTarget = null;
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		const isTamer = mob.tamedBy != Mob.noTamer and user.playerIndex == mob.tamedBy;
		if (!isTamer and !user.crouching) continue;
		if (!isHoldingApple(user)) continue;
		const delta = mob.pos - user.player().pos;
		const distSqr = vec.lengthSquare(delta);
		if (!isTamer and distSqr >= attractRadiusSqr) continue;
		if (best == null or distSqr < best.?.distSqr) {
			best = .{.distSqr = distSqr, .dir = delta, .isTamer = isTamer};
		}
	}
	return best;
}

const DesiredMovement = struct {dir: Vec3f, speed: f32};

const highPriorityStates = [_]Mob.AiState{.flee, .attract, .follow};

fn isHighPriorityState(state: Mob.AiState) bool {
	for (highPriorityStates) |s| {
		if (s == state) return true;
	}
	return false;
}

/// Returns the desired horizontal travel direction (unit vector, or zero if not moving) and speed.
fn tickAi(world: *ServerWorld, mob: *Mob, deltaTime: f32) DesiredMovement {
	const nearest = nearestThreateningPlayerDistanceSqr(mob);

	if (mob.state != .flee and nearest.distSqr < fleeRadiusSqr) {
		mob.state = .flee;
		mob.stateTimer = 2 + random.nextFloat(&mob.randState)*2;
	} else if (mob.state != .flee) {
		if (nearestAttractivePlayerDistanceSqr(mob)) |attractive| {
			mob.state = if (attractive.isTamer) .follow else .attract;
		} else if (mob.state == .attract or mob.state == .follow) {
			pickPause(mob);
		}
	}

	if (!isHighPriorityState(mob.state)) {
		const raining = isRainingAt(world, mob.pos);
		if (raining and mob.state != .shelter) {
			mob.state = .shelter;
			mob.shelterSearchCooldown = 0;
		} else if (!raining and mob.state == .shelter) {
			pickPause(mob);
		}
	}

	mob.stateTimer -= deltaTime;
	if (mob.shelterSearchCooldown > 0) mob.shelterSearchCooldown -= deltaTime;

	switch (mob.state) {
		.flee => {
			if (mob.stateTimer <= 0 or nearest.distSqr >= fleeRadiusSqr*4) {
				pickPause(mob);
				return .{.dir = .{0, 0, 0}, .speed = 0};
			}
			var dir: Vec3f = @floatCast(nearest.dir);
			const len = vec.length(dir);
			if (len > 0.001) dir /= @splat(len) else dir = mob.wanderDir;
			return .{.dir = dir, .speed = fleeSpeed};
		},
		.attract => {
			const attractive = nearestAttractivePlayerDistanceSqr(mob) orelse {
				pickPause(mob);
				return .{.dir = .{0, 0, 0}, .speed = 0};
			};
			// Just face them; standing still lets the player walk up to feed it.
			var dir: Vec3f = @floatCast(-attractive.dir);
			const len = vec.length(dir);
			if (len > 0.001) dir /= @splat(len);
			return .{.dir = dir, .speed = 0};
		},
		.follow => {
			const attractive = nearestAttractivePlayerDistanceSqr(mob) orelse {
				pickPause(mob);
				return .{.dir = .{0, 0, 0}, .speed = 0};
			};
			var dir: Vec3f = @floatCast(-attractive.dir);
			const len = vec.length(dir);
			if (attractive.distSqr <= followStopRadiusSqr) {
				// Close enough: stop walking but keep facing them.
				if (len > 0.001) dir /= @splat(len);
				return .{.dir = dir, .speed = 0};
			}
			if (len > 0.001) dir /= @splat(len) else dir = mob.wanderDir;
			return .{.dir = dir, .speed = wanderSpeed};
		},
		.wander => {
			if (mob.stateTimer <= 0) {
				pickPause(mob);
				return .{.dir = .{0, 0, 0}, .speed = 0};
			}
			return .{.dir = mob.wanderDir, .speed = wanderSpeed};
		},
		.pause => {
			if (mob.stateTimer <= 0) {
				pickWanderDirection(mob);
			}
			return .{.dir = .{0, 0, 0}, .speed = 0};
		},
		.shelter => {
			const alreadyUnderCover = hasCoverAt(world, @intFromFloat(@floor(mob.pos[0])), @intFromFloat(@floor(mob.pos[1])), @intFromFloat(@floor(mob.pos[2])));
			if (alreadyUnderCover) return .{.dir = .{0, 0, 0}, .speed = 0};

			if (mob.shelterSearchCooldown <= 0) {
				mob.shelterSearchCooldown = shelterSearchCooldownDuration;
				if (findNearbyTreeCover(world, mob.pos)) |target| {
					mob.shelterTarget = target;
				} else {
					// No cover in range; just wander normally until the next search attempt.
					return .{.dir = mob.wanderDir, .speed = wanderSpeed};
				}
			}

			const delta = mob.shelterTarget - mob.pos;
			const distSqr = vec.lengthSquare(Vec3d{delta[0], delta[1], 0});
			if (distSqr <= shelterArriveRadiusSqr) return .{.dir = .{0, 0, 0}, .speed = 0};

			var dir: Vec3f = @floatCast(delta);
			dir[2] = 0;
			const len = vec.length(dir);
			if (len > 0.001) dir /= @splat(len) else dir = mob.wanderDir;
			return .{.dir = dir, .speed = wanderSpeed};
		},
	}
}

fn yawFromDirection(dir: Vec3f) f32 {
	return std.math.atan2(dir[0], dir[1]);
}

fn directionFromYaw(yaw: f32) Vec3f {
	return .{@sin(yaw), @cos(yaw), 0};
}

fn angleDifference(target: f32, current: f32) f32 {
	var diff = @mod(target - current + std.math.pi, 2*std.math.pi) - std.math.pi;
	if (diff < -std.math.pi) diff += 2*std.math.pi;
	return diff;
}

/// Turns mob.rot[2] toward the desired direction and returns the desired horizontal
/// walking speed, only once roughly facing that direction (so it turns on the spot
/// instead of gliding sideways). Zero when idle, turning sharply, or paused.
fn steerTowards(mob: *Mob, desired: DesiredMovement, deltaTime: f32) f32 {
	if (vec.lengthSquare(desired.dir) < 0.001) return 0;

	const targetYaw = yawFromDirection(desired.dir);
	const diff = angleDifference(targetYaw, mob.rot[2]);
	const maxTurn = turnSpeed*deltaTime;
	mob.rot[2] += std.math.clamp(diff, -maxTurn, maxTurn);

	if (desired.speed == 0 or @abs(diff) > facingTolerance) return 0;
	return desired.speed;
}

fn updateEnt(mob: *Mob, hitBox: physics.collision.Box, walkSpeed: f32, deltaTime: f64) void {
	var volumeProperties: physics.collision.VolumeProperties = undefined;
	physics.calculateVolumeProperties(.server, &volumeProperties, mob.pos, hitBox, terminalVelocity);

	var friction: physics.FrictionState = undefined;
	physics.calculateFriction(.server, &volumeProperties, &friction, mob.pos, hitBox, mob.onGround);

	// Match the player's movement model: acceleration is desiredSpeed*frictionCoefficient,
	// so velocity converges to desiredSpeed instead of crawling at a fraction of it.
	const facing = directionFromYaw(mob.rot[2]);
	const inputAcc = facing*@as(Vec3f, @splat(walkSpeed*friction.mobile));

	// Jump if we're trying to walk but net horizontal progress over the last
	// stuckJumpDelay seconds is tiny (blocked by a ledge/step), rather than relying
	// on instantaneous velocity, which can noisily bounce near zero right after a
	// wall collision even when the mob is about to resolve the block on its own.
	const dt: f32 = @floatCast(deltaTime);
	if (mob.jumpCooldown > 0) mob.jumpCooldown -= dt;
	var doJump = false;
	if (walkSpeed > 0 and mob.onGround) {
		mob.stuckTimer += dt;
		if (mob.stuckTimer >= stuckJumpDelay) {
			const horizontalTravel = vec.length(Vec3f{@floatCast(mob.pos[0] - mob.stuckAnchorPos[0]), @floatCast(mob.pos[1] - mob.stuckAnchorPos[1]), 0});
			if (horizontalTravel < stuckDistanceThreshold and mob.jumpCooldown <= 0 and physics.collision.collides(.server, .z, 1.0, mob.pos, hitBox) == null) {
				doJump = true;
				mob.jumpCooldown = jumpCooldownDuration;
			}
			mob.stuckTimer = 0;
			mob.stuckAnchorPos = mob.pos;
		}
	} else {
		mob.stuckTimer = 0;
		mob.stuckAnchorPos = mob.pos;
	}

	var motion = physics.calculateMotion(.server, deltaTime, friction, volumeProperties, physics.playerDensity, mob.pos, &mob.vel, inputAcc, gravity, if (doJump) jumpHeight else 0.0);

	_ = physics.calculateWallCollision(.server, &motion, &mob.pos, &mob.vel, &mob.onGround, friction, hitBox, 0.6, null, false);
	_ = physics.calculateVerticalCollision(.server, deltaTime, &mob.pos, &mob.vel, null, &mob.onGround, hitBox, motion, 0.0);
}

pub fn update(self: *@This(), deltaTime: f32) void {
	self.processChanges();

	const pos = self.list.items(.pos);
	const mobType = self.list.items(.mobType);
	var ii: u32 = 0;
	while (ii < self.size) {
		const i = self.indices[ii];
		if (self.world.getSimulationChunkAndIncreaseRefCount(@trunc(pos[i][0]), @trunc(pos[i][1]), @trunc(pos[i][2]))) |simChunk| {
			defer simChunk.decreaseRefCount();
			if (simChunk.getChunk() != null) {
				var mob = self.list.get(i);
				const oldState = mob.state;
				const desired = tickAi(self.world, &mob, deltaTime);
				const walkSpeed = steerTowards(&mob, desired, deltaTime);
				updateEnt(&mob, hitBoxFor(mobType[i]), walkSpeed, deltaTime);
				self.list.set(i, mob);
				if (mob.state != oldState) self.broadcastAdd(mob);
			}
		}
		ii += 1;
	}
}
