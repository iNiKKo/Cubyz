const std = @import("std");

const main = @import("main");
const blocks = @import("blocks.zig");
const chunk = @import("chunk.zig");
const ServerChunk = chunk.ServerChunk;
const game = @import("game.zig");
const World = game.World;
const ServerWorld = main.server.ServerWorld;
const graphics = @import("graphics.zig");
const items = @import("items.zig");
const ItemStack = items.ItemStack;
const ZonElement = main.ZonElement;
const physics = main.physics;
const random = @import("random.zig");
const settings = @import("settings.zig");
const utils = @import("utils.zig");
const vec = @import("vec.zig");
const Mat4f = vec.Mat4f;
const Vec2f = vec.Vec2f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;
const Vec4f = vec.Vec4f;
const BinaryReader = main.utils.BinaryReader;
const BinaryWriter = main.utils.BinaryWriter;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

const c = @import("c");

const ItemDrop = struct { // MARK: ItemDrop
	pos: Vec3d,
	vel: Vec3d,
	rot: Vec3f,
	onGround: bool = false,
	itemStack: ItemStack,
	despawnTime: i32,
	pickupCooldown: i32,

	reverseIndex: u16,
};

pub const ItemDropNetworkData = struct {
	index: u16,
	pos: Vec3d,
	vel: Vec3d,
};

pub const ItemDropManager = struct { // MARK: ItemDropManager
	/// Half the side length of all item entities hitboxes as a cube.
	pub const radius: f64 = 0.1;
	/// Side length of all item entities hitboxes as a cube.
	pub const diameter: f64 = 2*radius;

	pub const pickupRange: f64 = 1.0;

	const terminalVelocity = 40.0;
	const gravity = 9.81;

	const maxCapacity = 65536;

	allocator: NeverFailingAllocator,

	list: std.MultiArrayList(ItemDrop),

	indices: [maxCapacity]u16 = undefined,

	emptyMutex: main.utils.Mutex = .{},
	isEmpty: std.bit_set.ArrayBitSet(usize, maxCapacity),

	changeQueue: main.utils.ConcurrentQueue(union(enum) { add: struct { u16, ItemDrop }, remove: u16 }),

	world: ?*ServerWorld,

	size: u32 = 0,

	pub fn init(self: *ItemDropManager, allocator: NeverFailingAllocator, world: ?*ServerWorld) void {
		self.* = ItemDropManager{
			.allocator = allocator,
			.list = std.MultiArrayList(ItemDrop){},
			.isEmpty = .initFull(),
			.changeQueue = .init(allocator, 16),
			.world = world,
		};
		self.list.resize(self.allocator.allocator, maxCapacity) catch unreachable;
	}

	pub fn deinit(self: *ItemDropManager) void {
		self.processChanges();
		self.changeQueue.deinit();
		for (self.indices[0..self.size]) |i| {
			self.list.items(.itemStack)[i].item.deinit();
		}
		self.list.deinit(self.allocator.allocator);
	}

	pub fn loadFrom(self: *ItemDropManager, zon: ZonElement) void {
		const zonArray = zon.getChild("array");
		for (zonArray.toSlice()) |elem| {
			self.addFromZon(elem);
		}
	}

	pub fn loadFromBytes(self: *ItemDropManager, reader: *main.utils.BinaryReader) !void {
		const version = try reader.readInt(u8);
		if (version != 0) return error.UnsupportedVersion;
		var i: u16 = 0;
		while (reader.remaining.len != 0) : (i += 1) {
			try self.addFromBytes(reader, i);
		}
	}

	pub fn storeToBytes(self: *ItemDropManager, writer: *main.utils.BinaryWriter) void {
		const version = 0;
		writer.writeInt(u8, version);
		for (self.indices[0..self.size]) |i| {
			storeSingleToBytes(writer, self.list.get(i));
		}
	}

	fn addFromBytes(self: *ItemDropManager, reader: *main.utils.BinaryReader, i: u16) !void {
		const despawnTime = try reader.readInt(i32);
		const pos = try reader.readVec(Vec3d);
		const vel = try reader.readVec(Vec3d);
		const itemStack = try items.ItemStack.fromBytes(reader);
		self.addWithIndex(i, pos, vel, random.nextFloatVector(3, &main.seed)*@as(Vec3f, @splat(2*std.math.pi)), itemStack, despawnTime, 0);
	}

	fn storeSingleToBytes(writer: *main.utils.BinaryWriter, itemdrop: ItemDrop) void {
		writer.writeInt(i32, itemdrop.despawnTime);
		writer.writeVec(Vec3d, itemdrop.pos);
		writer.writeVec(Vec3d, itemdrop.vel);
		itemdrop.itemStack.toBytes(writer);
	}

	fn addFromZon(self: *ItemDropManager, zon: ZonElement) void {
		const item = items.Item.init(zon) catch |err| {
			const msg = zon.toStringEfficient(main.stackAllocator, "");
			defer main.stackAllocator.free(msg);
			std.log.err("Ignoring invalid item drop {s} which caused {s}", .{msg, @errorName(err)});
			return;
		};
		const properties = .{
			zon.get(Vec3d, "pos") orelse .{0, 0, 0},
			zon.get(Vec3d, "vel") orelse .{0, 0, 0},
			random.nextFloatVector(3, &main.seed)*@as(Vec3f, @splat(2*std.math.pi)),
			items.ItemStack{.item = item, .amount = zon.get(u16, "amount") orelse 1},
			zon.get(i32, "despawnTime") orelse 60,
			0,
		};
		if (zon.get(u16, "i")) |i| {
			@call(.auto, addWithIndex, .{self, i} ++ properties);
		} else {
			@call(.auto, add, .{self} ++ properties);
		}
	}

	pub fn getPositionAndVelocityData(self: *ItemDropManager, allocator: NeverFailingAllocator) []ItemDropNetworkData {
		const result = allocator.alloc(ItemDropNetworkData, self.size);
		for (self.indices[0..self.size], result) |i, *res| {
			res.* = .{
				.index = i,
				.pos = self.list.items(.pos)[i],
				.vel = self.list.items(.vel)[i],
			};
		}
		return result;
	}

	pub fn getInitialList(self: *ItemDropManager, allocator: NeverFailingAllocator) ZonElement {
		self.processChanges(); // Make sure all the items from the queue are included.
		var list = ZonElement.initArray(allocator);
		var ii: u32 = 0;
		while (ii < self.size) : (ii += 1) {
			const i = self.indices[ii];
			list.array.append(self.storeSingle(allocator, i));
		}
		return list;
	}

	fn storeDrop(allocator: NeverFailingAllocator, itemDrop: ItemDrop, i: u16) ZonElement {
		const obj = ZonElement.initObject(allocator);
		obj.put("i", i);
		obj.put("pos", itemDrop.pos);
		obj.put("vel", itemDrop.vel);
		itemDrop.itemStack.storeToZon(allocator, obj);
		obj.put("despawnTime", itemDrop.despawnTime);
		return obj;
	}

	fn storeSingle(self: *ItemDropManager, allocator: NeverFailingAllocator, i: u16) ZonElement {
		return storeDrop(allocator, self.list.get(i), i);
	}

	pub fn store(self: *ItemDropManager, allocator: NeverFailingAllocator) ZonElement {
		const zonArray = ZonElement.initArray(allocator);
		for (self.indices[0..self.size]) |i| {
			const item = self.storeSingle(allocator, i);
			zonArray.array.append(item);
		}
		const zon = ZonElement.initObject(allocator);
		zon.put("array", zonArray);
		return zon;
	}

	pub fn update(self: *ItemDropManager, deltaTime: f32) void {
		std.debug.assert(self.world != null);
		self.processChanges();
		const pos = self.list.items(.pos);
		const vel = self.list.items(.vel);
		const onGround = self.list.items(.onGround);
		const pickupCooldown = self.list.items(.pickupCooldown);
		const despawnTime = self.list.items(.despawnTime);
		var ii: u32 = 0;
		while (ii < self.size) {
			const i = self.indices[ii];
			if (self.world.?.getSimulationChunkAndIncreaseRefCount(@trunc(pos[i][0]), @trunc(pos[i][1]), @trunc(pos[i][2]))) |simChunk| {
				defer simChunk.decreaseRefCount();
				if (simChunk.getChunk() != null) {
					// Check collision with blocks:
					updateEnt(&pos[i], &vel[i], &onGround[i], deltaTime);
				}
			}
			pickupCooldown[i] -= 1;
			despawnTime[i] -= 1;
			if (despawnTime[i] < 0) {
				self.directRemove(i);
			} else {
				ii += 1;
			}
		}
	}

	pub fn add(self: *ItemDropManager, pos: Vec3d, vel: Vec3d, rot: Vec3f, itemStack: ItemStack, despawnTime: i32, pickupCooldown: i32) void {
		self.emptyMutex.lock();
		const i: u16 = @intCast(self.isEmpty.findFirstSet() orelse {
			self.emptyMutex.unlock();
			std.log.err("Item drop capacitiy limit reached. Failed to add itemStack: {}×{s}", .{itemStack.amount, itemStack.item.id() orelse return});
			itemStack.item.deinit();
			return;
		});
		self.isEmpty.unset(i);
		const drop = ItemDrop{
			.pos = pos,
			.vel = vel,
			.rot = rot,
			.itemStack = itemStack,
			.despawnTime = despawnTime,
			.pickupCooldown = pickupCooldown,
			.reverseIndex = undefined,
		};
		if (self.world != null) {
			const list = ZonElement.initArray(main.stackAllocator);
			defer list.deinit(main.stackAllocator);
			list.array.append(.null);
			list.array.append(storeDrop(main.stackAllocator, drop, i));
			const updateData = list.toStringEfficient(main.stackAllocator, &.{});
			defer main.stackAllocator.free(updateData);

			const userList = main.server.getUserList(main.stackAllocator);
			defer main.stackAllocator.free(userList);
			for (userList) |user| {
				main.network.protocols.entity.send(user.conn, updateData);
			}
		}

		self.emptyMutex.unlock();
		self.changeQueue.pushBack(.{.add = .{i, drop}});
	}

	fn addWithIndex(self: *ItemDropManager, i: u16, pos: Vec3d, vel: Vec3d, rot: Vec3f, itemStack: ItemStack, despawnTime: i32, pickupCooldown: i32) void {
		self.emptyMutex.lock();
		std.debug.assert(self.isEmpty.isSet(i));
		self.isEmpty.unset(i);
		const drop = ItemDrop{
			.pos = pos,
			.vel = vel,
			.rot = rot,
			.itemStack = itemStack,
			.despawnTime = despawnTime,
			.pickupCooldown = pickupCooldown,
			.reverseIndex = undefined,
		};
		if (self.world != null) {
			const list = ZonElement.initArray(main.stackAllocator);
			defer list.deinit(main.stackAllocator);
			list.array.append(.null);
			list.array.append(storeDrop(main.stackAllocator, drop, i));
			const updateData = list.toStringEfficient(main.stackAllocator, &.{});
			defer main.stackAllocator.free(updateData);

			const userList = main.server.getUserList(main.stackAllocator);
			defer main.stackAllocator.free(userList);
			for (userList) |user| {
				main.network.protocols.entity.send(user.conn, updateData);
			}
		}

		self.emptyMutex.unlock();
		self.changeQueue.pushBack(.{.add = .{i, drop}});
	}

	fn processChanges(self: *ItemDropManager) void {
		while (self.changeQueue.popFront()) |data| {
			switch (data) {
				.add => |addData| {
					self.internalAdd(addData[0], addData[1]);
				},
				.remove => |index| {
					self.internalRemove(index);
				},
			}
		}
	}

	fn internalAdd(self: *ItemDropManager, i: u16, drop_: ItemDrop) void {
		var drop = drop_;
		if (self.world == null) {
			ClientItemDropManager.clientSideInternalAdd(self, i, drop);
		}
		drop.reverseIndex = @intCast(self.size);
		self.list.set(i, drop);
		self.indices[self.size] = i;
		self.size += 1;
	}

	fn internalRemove(self: *ItemDropManager, i: u16) void {
		self.size -= 1;
		const ii = self.list.items(.reverseIndex)[i];
		self.list.items(.itemStack)[i].deinit();
		self.list.items(.itemStack)[i] = .{};
		self.indices[ii] = self.indices[self.size];
		self.list.items(.reverseIndex)[self.indices[self.size]] = ii;
	}

	fn directRemove(self: *ItemDropManager, i: u16) void {
		std.debug.assert(self.world != null);
		self.emptyMutex.lock();
		self.isEmpty.set(i);

		const list = ZonElement.initArray(main.stackAllocator);
		defer list.deinit(main.stackAllocator);
		list.array.append(.null);
		list.array.append(.{.int = i});
		const updateData = list.toStringEfficient(main.stackAllocator, &.{});
		defer main.stackAllocator.free(updateData);

		const userList = main.server.getUserList(main.stackAllocator);
		defer main.stackAllocator.free(userList);
		for (userList) |user| {
			main.network.protocols.entity.send(user.conn, updateData);
		}

		self.emptyMutex.unlock();
		self.internalRemove(i);
	}

	fn updateEnt(pos: *Vec3d, vel: *Vec3d, onGround: *bool, deltaTime: f64) void {
		const hitBox = physics.collision.Box{.min = @splat(-radius), .max = @splat(radius)};
		var volumeProperties: physics.collision.VolumeProperties = undefined;
		physics.calculateVolumeProperties(.server, &volumeProperties, pos.*, hitBox, terminalVelocity);

		var friction: physics.FrictionState = undefined;
		physics.calculateFriction(.server, &volumeProperties, &friction, pos.*, hitBox, onGround.*);
		var motion = physics.calculateMotion(.server, deltaTime, friction, volumeProperties, physics.playerDensity, pos.*, vel, @splat(0.0), gravity, 0.0);

		var stepAmount: f64 = 0.0;
		stepAmount = physics.calculateWallCollision(.server, &motion, pos, vel, onGround, friction, hitBox, 0.1, null, false);

		_ = physics.calculateVerticalCollision(.server, deltaTime, pos, vel, null, onGround, hitBox, motion, 1.0);
	}

	pub fn checkEntity(self: *ItemDropManager, user: *main.server.User) void {
		var ii: u32 = 0;
		while (ii < self.size) {
			const i = self.indices[ii];
			if (self.list.items(.pickupCooldown)[i] > 0) {
				ii += 1;
				continue;
			}
			const hitbox = main.game.Player.outerBoundingBox;
			const min = user.player().pos + hitbox.min;
			const max = user.player().pos + hitbox.max;
			const itemPos = self.list.items(.pos)[i];
			const dist = @max(min - itemPos, itemPos - max);
			if (@reduce(.Max, dist) < radius + pickupRange) {
				const itemStack = &self.list.items(.itemStack)[i];
				main.items.Inventory.server.tryCollectingToPlayerInventory(user, itemStack);
				if (itemStack.amount == 0) {
					self.directRemove(i);
					continue;
				}
			}
			ii += 1;
		}
	}
};

pub const ClientItemDropManager = struct { // MARK: ClientItemDropManager
	const maxf64Capacity = ItemDropManager.maxCapacity*@sizeOf(Vec3d)/@sizeOf(f64);

	super: ItemDropManager,

	lastTime: i16,

	timeDifference: utils.TimeDifference = .{},

	interpolation: utils.GenericInterpolation(maxf64Capacity) align(64) = undefined,

	var instance: ?*ClientItemDropManager = null;

	var mutex: main.utils.Mutex = .{};

	pub fn init(self: *ClientItemDropManager, allocator: NeverFailingAllocator) void {
		std.debug.assert(instance == null); // Only one instance allowed.
		instance = self;
		self.* = .{
			.super = undefined,
			.lastTime = @as(i16, @truncate(main.timestamp().toMilliseconds())) -% settings.entityLookback,
		};
		self.super.init(allocator, null);
		self.interpolation.init(
			@ptrCast(self.super.list.items(.pos).ptr),
			@ptrCast(self.super.list.items(.vel).ptr),
		);
	}

	pub fn deinit(self: *ClientItemDropManager) void {
		std.debug.assert(instance != null); // Double deinit.
		self.super.deinit();
		instance = null;
	}

	pub fn readPosition(self: *ClientItemDropManager, time: i16, itemData: []ItemDropNetworkData) void {
		self.timeDifference.addDataPoint(time);
		var pos: [ItemDropManager.maxCapacity]Vec3d = undefined;
		var vel: [ItemDropManager.maxCapacity]Vec3d = undefined;
		for (itemData) |data| {
			pos[data.index] = data.pos;
			vel[data.index] = data.vel;
		}
		mutex.lock();
		defer mutex.unlock();
		self.interpolation.updatePosition(@ptrCast(&pos), @ptrCast(&vel), time); // TODO: Only update the ones we actually changed.
	}

	pub fn updateInterpolationData(self: *ClientItemDropManager) void {
		self.super.processChanges();
		var time = @as(i16, @truncate(main.timestamp().toMilliseconds())) -% settings.entityLookback;
		time -%= self.timeDifference.difference.load(.monotonic);
		{
			mutex.lock();
			defer mutex.unlock();
			self.interpolation.updateIndexed(time, self.lastTime, self.super.indices[0..self.super.size], 4);
		}
		self.lastTime = time;
	}

	fn clientSideInternalAdd(_: *ItemDropManager, i: u16, drop: ItemDrop) void {
		mutex.lock();
		defer mutex.unlock();
		for (&instance.?.interpolation.lastVel) |*lastVel| {
			@as(*align(8) [ItemDropManager.maxCapacity]Vec3d, @ptrCast(lastVel))[i] = Vec3d{0, 0, 0};
		}
		for (&instance.?.interpolation.lastPos) |*lastPos| {
			@as(*align(8) [ItemDropManager.maxCapacity]Vec3d, @ptrCast(lastPos))[i] = drop.pos;
		}
	}

	pub fn remove(self: *ClientItemDropManager, i: u16) void {
		self.super.emptyMutex.lock();
		self.super.isEmpty.set(i);
		self.super.emptyMutex.unlock();
		self.super.changeQueue.pushBack(.{.remove = i});
	}

	pub fn loadFrom(self: *ClientItemDropManager, zon: ZonElement) void {
		self.super.loadFrom(zon);
	}

	pub fn addFromZon(self: *ClientItemDropManager, zon: ZonElement) void {
		self.super.addFromZon(zon);
	}
};

pub fn getItemEmittedLight(item: main.items.Item) Vec3f {
	if (item == .baseItem) {
		if (item.baseItem.block()) |blockType| {
			const l = (blocks.Block{.typ = blockType, .data = 0}).light();
			if (l != 0) {
				return Vec3f{
					@floatFromInt(l >> 16 & 255),
					@floatFromInt(l >> 8 & 255),
					@floatFromInt(l & 255),
				} / @as(Vec3f, @splat(255.0));
			}
		}
	}
	return @splat(0);
}

// Going to handle item animations and other things like - bobbing, interpolation, movement reactions
pub const ItemDisplayManager = struct { // MARK: ItemDisplayManager
	pub var showItem: bool = true;
	var cameraFollow: Vec3f = @splat(0);
	var cameraFollowVel: Vec3f = @splat(0);
	const damping: Vec3f = @splat(130);

	pub var handLightPositionRelative: Vec3f = @splat(0);
	pub var handLightColor: Vec3f = @splat(0);
	/// A dropped torch must not replace another dropped torch just because the player walks closer
	/// to it. Keep a small, sorted set of the most relevant lights for the GPU instead. Four covers
	/// ordinary torch use while keeping the per-fragment work bounded. Beyond this limit the weakest
	/// lights are intentionally omitted rather than causing a sudden nearest-light swap.
	pub const maxDropLights = 8;
	const maxDropLightClusters = 32;
	const dropLightClusterRadius: f32 = 4.0;
	pub var dropLightPositionsRelative: [maxDropLights]Vec3f = @splat(@splat(0));
	pub var dropLightColors: [maxDropLights]Vec3f = @splat(@splat(0));
	/// F5 exposes these so dynamic-light pressure is visible while testing worlds with many torches.
	pub var droppedLightSourceCount: u32 = 0;
	pub var droppedLightClusterCount: u32 = 0;
	pub var activeDropLightCount: u32 = 0;
	const DropLightCluster = struct {
		position: Vec3f,
		color: Vec3f,
		weight: f32,
		sources: u16,
	};
	pub var handLightRadius: f32 = 12.0;
	/// Live developer controls for procedural-tool attachment. Kept out of persistent graphics
	/// settings because they are temporary model-tuning values, but replicated through heldLight.
	pub var heldToolOffset: Vec3f = .{0.0, 0.25, 0.10};
	pub var heldToolRotation: Vec3f = .{-110.0, 0.0, 90.0};
	pub var heldToolScale: f32 = 1.60;
	const maxReplicatedPlayers = 1024;
	pub const HeldLightTransform = Vec4f;
	const defaultHeldLightTransform = HeldLightTransform{ 0.0, 0.12, 0.0, -90.0 };
	const RemoteHeldItem = struct { item: items.Item = .null, transform: HeldLightTransform = defaultHeldLightTransform, toolRotationYZ: Vec2f = .{0.0, 0.0}, toolScale: f32 = 1.0 };
	var remoteHeldItems: [maxReplicatedPlayers]RemoteHeldItem = @splat(.{});
	const HeldItemIdentity = union(enum) { none: void, base: items.BaseItemIndex, procedural: *items.ProceduralItem };
	var lastSentHeldItem: HeldItemIdentity = .{ .none = {} };
	var lastSentHeldLightTransform: HeldLightTransform = defaultHeldLightTransform;
	var lastSentHeldToolRotationYZ: Vec2f = .{0.0, 0.0};
	var lastSentHeldToolScale: f32 = 1.0;
	var sentInitialHeldLight: bool = false;

	pub fn setRemoteHeldItem(entityId: main.entity.Entity, item: items.Item, transform: HeldLightTransform, toolRotationYZ: Vec2f, toolScale: f32) void {
		const id = @intFromEnum(entityId);
		if (id >= maxReplicatedPlayers) {
			item.deinit();
			return;
		}
		remoteHeldItems[id].item.deinit();
		remoteHeldItems[id] = .{ .item = item, .transform = transform, .toolRotationYZ = toolRotationYZ, .toolScale = toolScale };
	}
	pub fn remoteHeldItem(entityId: main.entity.Entity) ?items.Item {
		const id = @intFromEnum(entityId);
		if (id >= maxReplicatedPlayers) return null;
		const item = remoteHeldItems[id].item;
		return if (item == .null) null else item;
	}
	pub fn remoteHeldLight(entityId: main.entity.Entity) ?u16 {
		const item = remoteHeldItem(entityId) orelse return null;
		if (item != .baseItem) return null;
		const blockType = item.baseItem.block() orelse return null;
		return if ((blocks.Block{ .typ = blockType, .data = 0 }).light() != 0) blockType else null;
	}
	pub fn remoteHeldLightTransform(entityId: main.entity.Entity) HeldLightTransform {
		const id = @intFromEnum(entityId);
		return if (id < maxReplicatedPlayers) remoteHeldItems[id].transform else defaultHeldLightTransform;
	}
	pub fn remoteHeldToolRotationYZ(entityId: main.entity.Entity) Vec2f {
		const id = @intFromEnum(entityId);
		return if (id < maxReplicatedPlayers) remoteHeldItems[id].toolRotationYZ else .{0.0, 0.0};
	}
	pub fn remoteHeldToolScale(entityId: main.entity.Entity) f32 {
		const id = @intFromEnum(entityId);
		return if (id < maxReplicatedPlayers) remoteHeldItems[id].toolScale else 1.0;
	}
	/// Remote held procedural items are deserialized per client and owned by this cache. Release them
	/// when leaving a world and at renderer shutdown so a remote player holding a tool cannot leak its
	/// ProceduralItem allocation.
	pub fn clearRemoteHeldItems() void {
		for (&remoteHeldItems) |*held| {
			held.item.deinit();
			held.* = .{};
		}
		lastSentHeldItem = .{ .none = {} };
		lastSentHeldLightTransform = defaultHeldLightTransform;
		lastSentHeldToolRotationYZ = .{0.0, 0.0};
		lastSentHeldToolScale = 1.0;
		sentInitialHeldLight = false;
	}
	pub const RemoteLight = struct { positionRelative: Vec3f = @splat(0), color: Vec3f = @splat(0) };
	/// Keep the dynamic-light budget bounded. The closest remote lantern is the one that can visibly
	/// affect this client, while every avatar still renders its own held light model.
	pub fn closestRemoteLight(playerPos: Vec3d) RemoteLight {
		var result: RemoteLight = .{};
		var bestDistance = std.math.inf(f32);
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		for (main.client.entity_manager.entities.items()) |ent| {
			if (ent.id == game.Player.id) continue;
			const blockType = remoteHeldLight(ent.id) orelse continue;
			const rel: Vec3f = @floatCast(ent.getRenderPosition() - playerPos + Vec3d{0.35, 0.0, 0.1});
			const distance = vec.lengthSquare(rel);
			if (distance >= bestDistance) continue;
			const light = (blocks.Block{ .typ = blockType, .data = 0 }).light();
			bestDistance = distance;
			result.positionRelative = rel;
			result.color = Vec3f{ @floatFromInt(light >> 16 & 255), @floatFromInt(light >> 8 & 255), @floatFromInt(light & 255) } / @as(Vec3f, @splat(255.0));
		}
		return result;
	}

	pub fn update(deltaTime: f64) void {
		if (deltaTime == 0) return;
		const dt: f32 = @floatCast(deltaTime);

		var playerVel: Vec3f = .{@floatCast((game.Player.super.vel[2]*0.009 + game.Player.eye.vel[2]*0.0075)), 0, 0};
		playerVel = vec.clampMag(playerVel, 0.32);

		const n1: Vec3f = cameraFollowVel - (cameraFollow - playerVel)*damping*damping*@as(Vec3f, @splat(dt));
		const n2: Vec3f = @as(Vec3f, @splat(1)) + damping*@as(Vec3f, @splat(dt));
		cameraFollowVel = n1/(n2*n2);

		cameraFollow += cameraFollowVel*@as(Vec3f, @splat(dt));

		updateHandLight();
	}

	fn updateHandLight() void {
		handLightColor = @splat(0);
		dropLightPositionsRelative = @splat(@splat(0));
		dropLightColors = @splat(@splat(0));
		droppedLightSourceCount = 0;
		droppedLightClusterCount = 0;
		activeDropLightCount = 0;

		const item = game.Player.inventory.getItem(game.Player.selectedSlot);
		// The held state is replicated for every block item; only its emitted-light colour remains
		// conditional below. This lets other players see ordinary building blocks in a hand too.
		var heldItemIdentity: HeldItemIdentity = .{ .none = {} };
		if (item == .baseItem) {
			const baseItem = item.baseItem;
			heldItemIdentity = .{ .base = baseItem };
			if (baseItem.block()) |blockType| {
				const light = (blocks.Block{.typ = blockType, .data = 0}).light();
				if (light != 0) {
					handLightColor = Vec3f{
						@floatFromInt(light >> 16 & 255),
						@floatFromInt(light >> 8 & 255),
						@floatFromInt(light & 255),
					} / @as(Vec3f, @splat(255.0));
					const pos = Vec3f{0.4, 0.55, -0.32};
					const invViewRotation = game.camera.viewMatrix.transpose();
					handLightPositionRelative = vec.xyz(invViewRotation.mulVec(Vec4f{pos[0], pos[1], pos[2], 1}));
				}
			}
		} else if (item == .proceduralItem) {
			heldItemIdentity = .{ .procedural = item.proceduralItem };
		}
		if (game.world) |world| {
			const isTool = item == .proceduralItem;
			const transform: HeldLightTransform = if (isTool) .{ heldToolOffset[0], heldToolOffset[1], heldToolOffset[2], heldToolRotation[0] } else defaultHeldLightTransform;
			const toolRotationYZ: Vec2f = if (isTool) .{ heldToolRotation[1], heldToolRotation[2] } else .{0.0, 0.0};
			const toolScale: f32 = if (isTool) heldToolScale else 1.0;
			if (!sentInitialHeldLight or !std.meta.eql(heldItemIdentity, lastSentHeldItem) or !std.meta.eql(transform, lastSentHeldLightTransform) or !std.meta.eql(toolRotationYZ, lastSentHeldToolRotationYZ) or toolScale != lastSentHeldToolScale) {
				main.network.protocols.heldLight.send(world.conn, item, transform, toolRotationYZ, toolScale);
				lastSentHeldItem = heldItemIdentity;
				lastSentHeldLightTransform = transform;
				lastSentHeldToolRotationYZ = toolRotationYZ;
				lastSentHeldToolScale = toolScale;
				sentInitialHeldLight = true;
			}
		} else {
			sentInitialHeldLight = false;
		}

		var clusters: [maxDropLightClusters]DropLightCluster = undefined;
		var clusterCount: usize = 0;
		var dropStrengths: [maxDropLights]f32 = @splat(0);

		if (game.world) |world| {
			const itemDrops = &world.itemDrops.super;
			const playerPos = game.Player.getPosBlocking();
			for (0..itemDrops.size) |i| {
				const dropStack = itemDrops.list.items(.itemStack)[i];
				if (dropStack.item == .baseItem) {
					const baseItem = dropStack.item.baseItem;
					if (baseItem.block()) |blockType| {
						const light = (blocks.Block{.typ = blockType, .data = 0}).light();
						if (light != 0) {
							const dPos = itemDrops.list.items(.pos)[i];
							const relPos = Vec3f{
								@floatCast(dPos[0] - playerPos[0]),
								@floatCast(dPos[1] - playerPos[1]),
								@floatCast(dPos[2] - playerPos[2]),
							};
							const distToPlayer = vec.length(relPos);
							if (distToPlayer < 48.0) {
								droppedLightSourceCount += 1;
								const col = Vec3f{
									@floatFromInt(light >> 16 & 255),
									@floatFromInt(light >> 8 & 255),
									@floatFromInt(light & 255),
								} / @as(Vec3f, @splat(255.0));
								const str = @max(@max(col[0], col[1]), col[2]) / (1.0 + distToPlayer * 0.05);
								// Nearby torches form one soft cluster. Its position is weighted by the
								// visible contribution, so a pair within four blocks behaves like one
								// stronger light rather than consuming two GPU slots.
								var match: ?usize = null;
								var bestClusterDistance = dropLightClusterRadius * dropLightClusterRadius;
								for (clusters[0..clusterCount], 0..) |cluster, clusterIndex| {
									const clusterDistance = vec.lengthSquare(relPos - cluster.position);
									if (clusterDistance <= bestClusterDistance) {
										bestClusterDistance = clusterDistance;
										match = clusterIndex;
									}
								}
								if (match) |clusterIndex| {
									const oldWeight = clusters[clusterIndex].weight;
									const newWeight = oldWeight + str;
									clusters[clusterIndex].position = (clusters[clusterIndex].position * @as(Vec3f, @splat(oldWeight)) + relPos * @as(Vec3f, @splat(str))) / @as(Vec3f, @splat(newWeight));
									clusters[clusterIndex].color += col;
									clusters[clusterIndex].weight = newWeight;
									clusters[clusterIndex].sources +|= 1;
								} else if (clusterCount < maxDropLightClusters) {
									clusters[clusterCount] = .{ .position = relPos, .color = col, .weight = str, .sources = 1 };
									clusterCount += 1;
								}
							}
						}
					}
				}
			}
		}
		droppedLightClusterCount = @intCast(clusterCount);
		// Select the most visible clusters for the fixed GPU budget. This preserves a bounded
		// fragment cost even when a player drops hundreds of torches in one place.
		for (clusters[0..clusterCount]) |cluster| {
			for (0..maxDropLights) |slot| {
				if (cluster.weight <= dropStrengths[slot]) continue;
				var move: usize = maxDropLights - 1;
				while (move > slot) : (move -= 1) {
					dropStrengths[move] = dropStrengths[move - 1];
					dropLightPositionsRelative[move] = dropLightPositionsRelative[move - 1];
					dropLightColors[move] = dropLightColors[move - 1];
				}
				dropStrengths[slot] = cluster.weight;
				dropLightPositionsRelative[slot] = cluster.position;
				dropLightColors[slot] = cluster.color;
				break;
			}
		}
		for (dropStrengths) |strength| {
			if (strength > 0) activeDropLightCount += 1;
		}
	}
};

pub const ItemDropRenderer = struct { // MARK: ItemDropRenderer
	var itemPipeline: graphics.Pipeline = undefined;
	var itemUniforms: struct {
		modelMatrix: c_int,
		ambientLight: c_int,
		modelIndex: c_int,
		block: c_int,
		reflectionMapSize: c_int,
		contrast: c_int,
		glDepthRange: c_int,
	} = undefined;

	var itemModelSSBO: graphics.SSBO = undefined;
	var modelData: main.ListManaged(u32) = undefined;
	var freeSlots: main.ListManaged(*ItemVoxelModel) = undefined;

	const ItemVoxelModel = struct {
		index: u31 = undefined,
		len: u31 = undefined,
		item: items.Item,
		/// Inventory icons are normally flat; a held block must instead use its placed-block mesh.
		forceBlockModel: bool = false,

		fn getSlot(len: u31) u31 {
			for (freeSlots.items, 0..) |potentialSlot, i| {
				if (len == potentialSlot.len) {
					_ = freeSlots.swapRemove(i);
					const result = potentialSlot.index;
					main.globalAllocator.destroy(potentialSlot);
					return result;
				}
			}
			const result: u31 = @intCast(modelData.items.len);
			modelData.resize(result + len);
			return result;
		}

		fn init(template: ItemVoxelModel) *ItemVoxelModel {
			const self = main.globalAllocator.create(ItemVoxelModel);
			self.* = ItemVoxelModel{
				.item = template.item,
				.forceBlockModel = template.forceBlockModel,
			};
			if (self.item == .baseItem and self.item.baseItem.block() != null and (self.forceBlockModel or self.item.baseItem.image().imageData.ptr == graphics.Image.defaultImage.imageData.ptr)) {
				// Find sizes and free index:
				var block = blocks.Block{.typ = self.item.baseItem.block().?, .data = 0};
				block.data = block.mode().naturalStandard;
				const model = blocks.meshes.model(block).model();
				var data: main.ListManaged(u32) = .init(main.stackAllocator);
				defer data.deinit();
				for (model.internalQuads) |quad| {
					const textureIndex = blocks.meshes.textureIndex(block, quad.quadInfo().textureSlot);
					data.append(@as(u32, @intFromEnum(quad)) << 16 | textureIndex); // modelAndTexture
					data.append(0); // offsetByNormal
				}
				for (model.neighborFacingQuads) |list| {
					for (list) |quad| {
						const textureIndex = blocks.meshes.textureIndex(block, quad.quadInfo().textureSlot);
						data.append(@as(u32, @intFromEnum(quad)) << 16 | textureIndex); // modelAndTexture
						data.append(1); // offsetByNormal
					}
				}
				self.len = @intCast(data.items.len);
				self.index = getSlot(self.len);
				@memcpy(modelData.items[self.index..][0..self.len], data.items);
			} else {
				// Find sizes and free index:
				const img = self.item.getImage();
				const size = Vec3i{img.width, 1, img.height};
				self.len = @intCast(3 + @reduce(.Mul, size));
				self.index = getSlot(self.len);
				var dataSection: []u32 = undefined;
				dataSection = modelData.items[self.index..][0..self.len];
				dataSection[0] = @intCast(size[0]);
				dataSection[1] = @intCast(size[1]);
				dataSection[2] = @intCast(size[2]);
				var i: u32 = 3;
				var z: u32 = 0;
				while (z < 1) : (z += 1) {
					var x: u32 = 0;
					while (x < img.width) : (x += 1) {
						var y: u32 = 0;
						while (y < img.height) : (y += 1) {
							dataSection[i] = img.getRGB(x, y).toArgb();
							i += 1;
						}
					}
				}
			}
			itemModelSSBO.bufferData(u32, modelData.items);
			return self;
		}

		fn deinit(self: *ItemVoxelModel) void {
			freeSlots.append(self);
		}

		pub fn equals(self: ItemVoxelModel, other: ?*ItemVoxelModel) bool {
			if (other == null) return false;
			return self.forceBlockModel == other.?.forceBlockModel and std.meta.eql(self.item, other.?.item);
		}

		pub fn hashCode(self: ItemVoxelModel) u32 {
			return self.item.hashCode();
		}
	};

	pub fn init() void {
		itemPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/item_drop.vert",
			"assets/cubyz/shaders/item_drop.frag",
			"",
			&itemUniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{},
			.{.depthTest = true},
			.{.attachments = &.{.noBlending}},
		);
		itemModelSSBO = .init();
		itemModelSSBO.bufferData(i32, &[3]i32{1, 1, 1});
		itemModelSSBO.bind(2);

		modelData = .init(main.globalAllocator);
		freeSlots = .init(main.globalAllocator);
	}

	pub fn deinit() void {
		itemPipeline.deinit();
		itemModelSSBO.deinit();
		modelData.deinit();
		voxelModels.clear();
		for (freeSlots.items) |freeSlot| {
			main.globalAllocator.destroy(freeSlot);
		}
		freeSlots.deinit();
		ItemDisplayManager.clearRemoteHeldItems();
	}

	var voxelModels: utils.Cache(ItemVoxelModel, 32, 32, ItemVoxelModel.deinit) = .{};

	fn getModel(item: items.Item) *ItemVoxelModel {
		const compareObject = ItemVoxelModel{.item = item};
		return voxelModels.findOrCreate(compareObject, ItemVoxelModel.init, null);
	}
	fn getBlockModel(item: items.Item) *ItemVoxelModel {
		const compareObject = ItemVoxelModel{ .item = item, .forceBlockModel = true };
		return voxelModels.findOrCreate(compareObject, ItemVoxelModel.init, null);
	}

	fn bindCommonUniforms(ambientLight: Vec3f) void {
		itemPipeline.bind(null);
		c.glUniform1f(itemUniforms.reflectionMapSize, main.renderer.reflectionCubeMapSize);
		c.glUniform3fv(itemUniforms.ambientLight, 1, @ptrCast(&ambientLight));
		c.glUniform1f(itemUniforms.contrast, 0.12);
		var depthRange: [2]f32 = undefined;
		c.glGetFloatv(c.GL_DEPTH_RANGE, &depthRange);
		c.glUniform2fv(itemUniforms.glDepthRange, 1, &depthRange);
	}

	fn bindLightUniform(light: [6]u8, ambientLight: Vec3f, emittedLight: Vec3f) void {
		const sunLight: Vec3f = ambientLight*@as(Vec3f, @floatFromInt(Vec3i{light[0], light[1], light[2]}))/@as(Vec3f, @splat(255));
		const blockLight: Vec3f = @as(Vec3f, @floatFromInt(Vec3i{light[3], light[4], light[5]}))/@as(Vec3f, @splat(255));
		const env = @sqrt(sunLight*sunLight + blockLight*blockLight);
		const finalLight = @max(env, emittedLight * @as(Vec3f, @splat(0.85)));
		c.glUniform3fv(itemUniforms.ambientLight, 1, @ptrCast(&@min(finalLight, @as(Vec3f, @splat(1)))));
	}

	fn bindModelUniforms(modelIndex: u31, blockType: u16) void {
		c.glUniform1i(itemUniforms.modelIndex, modelIndex);
		c.glUniform1i(itemUniforms.block, blockType);
	}

	fn drawItem(vertices: u31, modelMatrix: Mat4f) void {
		c.glUniformMatrix4fv(itemUniforms.modelMatrix, 1, c.GL_TRUE, @ptrCast(&modelMatrix));
		main.renderer.chunk_meshing.vao.bind();
		c.glDrawElements(c.GL_TRIANGLES, vertices, c.GL_UNSIGNED_INT, null);
	}

	pub fn renderItemDrops(ambientLight: Vec3f, playerPos: Vec3d) void {
		game.world.?.itemDrops.updateInterpolationData();

		bindCommonUniforms(ambientLight);
		const itemDrops = &game.world.?.itemDrops.super;
		for (itemDrops.indices[0..itemDrops.size]) |i| {
			const item = itemDrops.list.items(.itemStack)[i].item;
			if (item != .null) {
				var pos = itemDrops.list.items(.pos)[i];
				const rot = itemDrops.list.items(.rot)[i];
				const blockPos: Vec3i = @floor(pos);
				const light: [6]u8 = main.renderer.mesh_storage.getLight(blockPos[0], blockPos[1], blockPos[2]) orelse @splat(0);
				bindLightUniform(light, ambientLight, getItemEmittedLight(item));
				pos -= playerPos;

				const model = getModel(item);
				var vertices: u31 = 36;

				var scale: f32 = 0.3;
				var blockType: u16 = 0;
				if (item == .baseItem and item.baseItem.block() != null and item.baseItem.image().imageData.ptr == graphics.Image.defaultImage.imageData.ptr) {
					blockType = item.baseItem.block().?;
					vertices = model.len/2*6;
				} else {
					scale = 0.5;
				}
				bindModelUniforms(model.index, blockType);

				var modelMatrix = Mat4f.translation(@floatCast(pos));
				modelMatrix = modelMatrix.mul(Mat4f.rotationX(-rot[0]));
				modelMatrix = modelMatrix.mul(Mat4f.rotationY(-rot[1]));
				modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-rot[2]));
				modelMatrix = modelMatrix.mul(Mat4f.scale(@splat(scale)));
				modelMatrix = modelMatrix.mul(Mat4f.translation(@splat(-0.5)));
				drawItem(vertices, modelMatrix);
			}
		}
	}

	/// Render the selected item a remote player is carrying. This uses the same voxel-item mesh path
	/// as dropped/first-person items, so procedural tools retain their generated artwork while
	/// torches and lanterns keep their authored placed-block geometry.
	pub fn renderRemoteHeldLights(ambientLight: Vec3f, playerPos: Vec3d) void {
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		bindCommonUniforms(ambientLight);
		for (main.client.entity_manager.entities.items()) |ent| {
			if (ent.id == game.Player.id) continue;
			const item = ItemDisplayManager.remoteHeldItem(ent.id) orelse continue;
			const baseItem = if (item == .baseItem) item.baseItem else null;
			const blockType = if (baseItem) |candidate| candidate.block() else null;
			const emittedLight = getItemEmittedLight(item);
			// Crafted/terrain blocks whose item falls back to the block texture read best as a small
			// 3D held block. Ores/gems supply a dedicated inventory icon, so preserve that flat item
			// silhouette instead of turning the ore's host-stone block into a cube in the hand. Lights
			// are an explicit exception: torch/lantern geometry must stay 3D even with custom icons.
			const useBlockModel = if (baseItem) |candidate| blockType != null and (emittedLight[0] != 0 or emittedLight[1] != 0 or emittedLight[2] != 0 or candidate.image().imageData.ptr == graphics.Image.defaultImage.imageData.ptr) else false;
			const model = if (useBlockModel) getBlockModel(item) else getModel(item);
			const vertices: u31 = if (useBlockModel) model.len/2*6 else 36;
			bindModelUniforms(model.index, if (useBlockModel) blockType.? else 0);
			const blockPos: Vec3i = @floor(ent.pos);
			const light: [6]u8 = main.renderer.mesh_storage.getLight(blockPos[0], blockPos[1], blockPos[2]) orelse @splat(0);
			bindLightUniform(light, ambientLight, getItemEmittedLight(item));
			const position: Vec3f = @floatCast(ent.getRenderPosition() - playerPos);
			const modelComponent = main.entity.components.@"cubyz:model".client.get(ent.id);
			const entityModel = if (modelComponent) |component| component.entityModel.get() else null;
			// Entity-model origins are half a model-height above the player position. Use the same
			// origin transform as modelRenderer, then append the authored RightItem node. Every bundled
			// player model supplies this attachment; the fallback remains useful for custom models.
			var modelMatrix = Mat4f.translation(position + Vec3f{ 0, 0, if (entityModel) |avatarModel| -avatarModel.height/2 else 0 });
			modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-ent.rot[2]));
			if (modelComponent) |component| {
				if (component.entityModel.get().nodeIndexMap.get("RightItem")) |nodeId| {
					modelMatrix = modelMatrix.mul(component.matrices[nodeId].transpose());
				} else {
					modelMatrix = modelMatrix.mul(Mat4f.translation(Vec3f{ -0.34, 0, 0.05 }));
				}
			} else {
				modelMatrix = modelMatrix.mul(Mat4f.translation(Vec3f{ -0.34, 0, 0.05 }));
			}
			const isLantern = blockType == blocks.getTypeById("cubyz:lantern/coal") or blockType == blocks.getTypeById("cubyz:lantern/sulfur");
			if (isLantern) {
				// Lantern models are upright with the handle on top. Leave them upright and lower the
				// body from RightItem so the handle appears gripped and the lantern dangles below.
				modelMatrix = modelMatrix.mul(Mat4f.translation(Vec3f{ 0.0, 0.04, -0.12 }));
				modelMatrix = modelMatrix.mul(Mat4f.rotationZ(@as(f32, std.math.pi / 2.0)));
			} else {
				// Torch/ordinary block items use the tuned forward-hand transform.
			const transform = ItemDisplayManager.remoteHeldLightTransform(ent.id);
			modelMatrix = modelMatrix.mul(Mat4f.translation(Vec3f{ transform[0], transform[1], transform[2] }));
			modelMatrix = modelMatrix.mul(Mat4f.rotationX(std.math.degreesToRadians(transform[3])));
			if (item == .proceduralItem) {
				const toolRotationYZ = ItemDisplayManager.remoteHeldToolRotationYZ(ent.id);
				modelMatrix = modelMatrix.mul(Mat4f.rotationY(std.math.degreesToRadians(toolRotationYZ[0])));
				modelMatrix = modelMatrix.mul(Mat4f.rotationZ(std.math.degreesToRadians(toolRotationYZ[1])));
				modelMatrix = modelMatrix.mul(Mat4f.scale(@splat(ItemDisplayManager.remoteHeldToolScale(ent.id))));
			}
			}
			// Full blocks are deliberately half the light/item scale; otherwise a held stone/dirt
			// cube obscures too much of the avatar. Flat ore/gem icons and custom light models retain
			// their readable item scale.
			const heldScale: f32 = if (useBlockModel and emittedLight[0] == 0 and emittedLight[1] == 0 and emittedLight[2] == 0) 0.154 else 0.308;
			modelMatrix = modelMatrix.mul(Mat4f.scale(@splat(heldScale)));
			modelMatrix = modelMatrix.mul(Mat4f.translation(@splat(-0.5)));
			drawItem(vertices, modelMatrix);
		}
	}

	inline fn getIndex(x: u8, y: u8, z: u8) u32 {
		return (z*4) + (y*2) + (x);
	}

	inline fn blendColors(a: [6]f32, b: [6]f32, t: f32) [6]f32 {
		var result: [6]f32 = .{0, 0, 0, 0, 0, 0};
		inline for (0..6) |i| {
			result[i] = std.math.lerp(a[i], b[i], t);
		}
		return result;
	}

	pub fn renderDisplayItems(ambientLight: Vec3f, playerPos: Vec3d) void {
		if (!ItemDisplayManager.showItem) return;

		const displayItemUbo = graphics.frame_uniforms.StaticUbo.init(.{
			.projectionMatrix = Mat4f.perspective(std.math.degreesToRadians(65), @as(f32, @floatFromInt(main.renderer.lastWidth))/@as(f32, @floatFromInt(main.renderer.lastHeight)), 0.01, 3).toGl(),
			.viewMatrix = Mat4f.identity().toGl(),
			.playerPositionInteger = @splat(0),
			.playerPositionFraction = @splat(0),
		});
		defer displayItemUbo.deinit();
		displayItemUbo.bind();
		defer displayItemUbo.unbind();
		bindCommonUniforms(ambientLight);

		const item = game.Player.inventory.getItem(game.Player.selectedSlot);
		if (item != .null) {
			var pos: Vec3d = Vec3d{0, 0, 0};
			const rot: Vec3f = ItemDisplayManager.cameraFollow;

			const lightPos = @as(Vec3d, @floatCast(playerPos)) - @as(Vec3f, @splat(0.5));
			const blockPos: Vec3i = @floor(lightPos);
			const localBlockPos: Vec3f = @floatCast(lightPos - @as(Vec3d, @floatFromInt(blockPos)));

			var samples: [8][6]f32 = @splat(@splat(0));
			inline for (0..2) |z| {
				inline for (0..2) |y| {
					inline for (0..2) |x| {
						const light: [6]u8 = main.renderer.mesh_storage.getLight(
							blockPos[0] +% @as(i32, @intCast(x)),
							blockPos[1] +% @as(i32, @intCast(y)),
							blockPos[2] +% @as(i32, @intCast(z)),
						) orelse @splat(0);

						inline for (0..6) |i| {
							samples[getIndex(x, y, z)][i] = @as(f32, @floatFromInt(light[i]));
						}
					}
				}
			}

			inline for (0..2) |y| {
				inline for (0..2) |x| {
					samples[getIndex(x, y, 0)] = blendColors(samples[getIndex(x, y, 0)], samples[getIndex(x, y, 1)], localBlockPos[2]);
				}
			}

			inline for (0..2) |x| {
				samples[getIndex(x, 0, 0)] = blendColors(samples[getIndex(x, 0, 0)], samples[getIndex(x, 1, 0)], localBlockPos[1]);
			}

			var result: [6]u8 = .{0, 0, 0, 0, 0, 0};
			inline for (0..6) |i| {
				const val = std.math.lerp(samples[getIndex(0, 0, 0)][i], samples[getIndex(1, 0, 0)][i], localBlockPos[0]);
				result[i] = @floor(val);
			}

			bindLightUniform(result, ambientLight, getItemEmittedLight(item));

			const model = getModel(item);
			var vertices: u31 = 36;

			const isBlock: bool = item == .baseItem and item.baseItem.block() != null and item.baseItem.image().imageData.ptr == graphics.Image.defaultImage.imageData.ptr;
			var scale: f32 = 0;
			var blockType: u16 = 0;
			if (isBlock) {
				blockType = item.baseItem.block().?;
				vertices = model.len/2*6;
				scale = 0.3;
				pos = Vec3d{0.4, 0.55, -0.32};
			} else {
				scale = 0.57;
				pos = Vec3d{0.4, 0.65, -0.3};
			}
			bindModelUniforms(model.index, blockType);

			var modelMatrix = Mat4f.rotationZ(-rot[2]);
			modelMatrix = modelMatrix.mul(Mat4f.rotationY(-rot[1]));
			modelMatrix = modelMatrix.mul(Mat4f.rotationX(-rot[0]));
			modelMatrix = modelMatrix.mul(Mat4f.translation(@floatCast(pos)));
			if (!isBlock) {
				if (item == .proceduralItem) {
					modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-std.math.pi*0.47));
					modelMatrix = modelMatrix.mul(Mat4f.rotationY(std.math.pi*0.25));
				} else {
					modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-std.math.pi*0.45));
				}
			} else {
				modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-std.math.pi*0.2));
			}
			modelMatrix = modelMatrix.mul(Mat4f.scale(@splat(scale)));
			modelMatrix = modelMatrix.mul(Mat4f.translation(@splat(-0.5)));
			drawItem(vertices, modelMatrix);
		}
	}
};
