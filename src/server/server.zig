const std = @import("std");
const Atomic = std.atomic.Value;

const main = @import("main");
const chunk = main.chunk;
const network = main.network;
const Connection = network.Connection;
const ConnectionManager = network.ConnectionManager;
const InventoryId = main.items.Inventory.InventoryId;
const utils = main.utils;
const vec = main.vec;
const Vec2i = vec.Vec2i;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;
const BinaryReader = main.utils.BinaryReader;
const BinaryWriter = main.utils.BinaryWriter;
const Blueprint = main.blueprint.Blueprint;
const Mask = main.blueprint.Mask;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const CircularBufferQueue = main.utils.CircularBufferQueue;
const sync = main.sync;

pub const BlockUpdateSystem = @import("BlockUpdateSystem.zig");
pub const world_zig = @import("world.zig");
pub const ServerWorld = world_zig.ServerWorld;
pub const terrain = @import("terrain/terrain.zig");
pub const Entity = @import("Entity.zig");
pub const SimulationChunk = @import("SimulationChunk.zig");
pub const stdin_handler = @import("stdin_handler.zig");
pub const storage = @import("storage.zig");
pub const permission = @import("permission.zig");

pub const command = @import("command.zig");
pub const WeatherMap = @import("WeatherMap.zig");

pub const WorldEditData = struct {
	const maxWorldEditHistoryCapacity: u32 = 1024;

	selectionPosition1: ?Vec3i = null,
	selectionPosition2: ?Vec3i = null,
	clipboard: ?Blueprint = null,
	undoHistory: History,
	redoHistory: History,
	mask: ?Mask = null,

	const History = struct {
		changes: CircularBufferQueue(Value),

		const Value = struct {
			blueprint: Blueprint,
			position: Vec3i,
			message: []const u8,

			pub fn init(blueprint: Blueprint, position: Vec3i, message: []const u8) Value {
				return .{.blueprint = blueprint, .position = position, .message = main.globalAllocator.dupe(u8, message)};
			}
			pub fn deinit(self: Value) void {
				main.globalAllocator.free(self.message);
				self.blueprint.deinit(main.globalAllocator);
			}
			pub fn selection(self: Value) Blueprint.Selection {
				return .initFromExtent(self.position, self.blueprint.extent());
			}
		};
		pub fn init() History {
			return .{.changes = .init(main.globalAllocator, maxWorldEditHistoryCapacity)};
		}
		pub fn deinit(self: *History) void {
			self.clear();
			self.changes.deinit();
		}
		pub fn clear(self: *History) void {
			while (self.changes.popFront()) |item| item.deinit();
		}
		pub fn push(self: *History, value: Value) void {
			if (self.changes.reachedCapacity()) {
				if (self.changes.popFront()) |oldValue| oldValue.deinit();
			}

			self.changes.pushBack(value);
		}
		pub fn pop(self: *History) ?Value {
			return self.changes.popBack();
		}
	};
	pub fn init() WorldEditData {
		return .{.undoHistory = History.init(), .redoHistory = History.init()};
	}
	pub fn deinit(self: *WorldEditData) void {
		if (self.clipboard != null) {
			self.clipboard.?.deinit(main.globalAllocator);
		}
		self.undoHistory.deinit();
		self.redoHistory.deinit();
		if (self.mask) |mask| {
			mask.deinit(main.globalAllocator);
		}
	}
};

pub const PlayerIndex = usize;

pub const User = struct {
	const maxSimulationDistance = 8;
	const simulationSize = 2*maxSimulationDistance;
	const simulationMask = simulationSize - 1;
	const playerCommandPermissions = .{
		"/command/avatar",
		"/command/help",
		"/command/afk",
		"/command/back",
		"/command/home",
		"/command/players",
		"/command/playtime",
		"/command/spawn",
		"/command/tpa",
		"/command/tpaccept",
	};
	conn: *Connection = undefined,
	innerPlayer: Entity = .{},
	timeDifference: utils.TimeDifference = .{},
	interpolation: utils.GenericInterpolation(3) = undefined,
	lastTime: i16 = undefined,
	lastSaveTime: std.Io.Timestamp = .fromNanoseconds(0),
	name: []const u8 = "",
	renderDistance: u16 = undefined,
	clientUpdatePos: Vec3i = .{0, 0, 0},
	receivedFirstEntityData: bool = false,
	isLocal: bool = false,
	id: main.entity.Entity = .noValue,

	heldItem: main.items.Item = .null,
	heldLightTransform: main.vec.Vec4f = .{ 0.0, 0.12, 0.0, -90.0 },
	heldToolRotationYZ: main.vec.Vec2f = .{ 0.0, 0.0 },
	heldToolScale: f32 = 1.0,
	heldMiningSwing: f32 = -1.0,
	tpaRequestFrom: ?PlayerIndex = null,
	isAfk: bool = false,

	loadedChunks: [simulationSize][simulationSize][simulationSize]*SimulationChunk = undefined,
	lastRenderDistance: u16 = 0,
	lastPos: Vec3i = @splat(0),
	gamemode: std.atomic.Value(main.game.Gamemode) = .init(.creative),
	spawnPos: ?Vec3d = null,
	worldEditData: WorldEditData = undefined,

	playerIndex: PlayerIndex = undefined,

	jobQueue: main.utils.ConcurrentMaxHeap(main.utils.ThreadPool.Task) = undefined,
	jobQueueScheduled: bool = false,
	jobQueueLastUpdate: struct { position: Vec3i, time: std.Io.Timestamp, alreadyInUpdate: bool = false } = .{.position = @splat(0), .time = .{.nanoseconds = 0}},

	lastSentBiomeId: u32 = 0xffffffff,
	lastSentRainIntensity: f32 = -1,
	lastSentWeatherGridMillis: i64 = 0,
	lastLightningCheckMillis: i64 = 0,
	hungerExhaustion: f32 = 0,
	healingTime: f32 = 0,
	lastSentHunger: f32 = -1,
	lastSentSaturation: f32 = -1,
	lastSentHealth: f32 = -1,

	newKeyString: ?[]const u8 = null,
	key: network.authentication.PublicKey = undefined,
	legacyKey: ?network.authentication.PublicKey = null,

	inventoryClientToServerIdMap: std.AutoHashMap(InventoryId, InventoryId) = undefined,
	inventory: ?InventoryId = null,
	handInventory: ?InventoryId = null,

	connected: Atomic(bool) = .init(true),
	connectQueued: Atomic(bool) = .init(false),
	state: State = .awaitingKeyVerification,

	mutex: main.utils.Mutex = .{},

	inventoryCommands: main.List([]const u8) = .empty,

	pub const State = enum { awaitingKeyVerification, connectedVerified, awaitingReloadVerified };

	pub fn player(self: *User) *Entity {
		return &self.innerPlayer;
	}

	pub fn init(manager: *ConnectionManager, ipPort: []const u8) !*User {
		const self = main.globalAllocator.create(User);
		errdefer main.globalAllocator.destroy(self);
		self.* = .{};
		self.conn = try Connection.init(manager, ipPort, self);
		self.@"continue"();
		network.protocols.handShake.serverSide(self.conn);
		return self;
	}
	pub fn @"continue"(self: *User) void {

		self.* = .{
			.conn = self.conn,
			.name = self.name,
			.newKeyString = self.newKeyString,
			.playerIndex = self.playerIndex,
			.state = self.state,

			.inventoryClientToServerIdMap = .init(main.globalAllocator.allocator),
			.worldEditData = .init(),
			.jobQueue = .init(main.globalAllocator),
		};
	}
	fn privateDeinit(self: *User) void {
		self.conn.deinit();
		main.globalAllocator.free(self.name);
		if (self.newKeyString) |str| main.globalAllocator.free(str);
		main.globalAllocator.destroy(self);
	}
	pub fn deferredPauseAndDeinit(self: *User) void {
		self.conn.disconnect();
		if (self.inventory != null) {
			world.?.savePlayer(self) catch |err| {
				std.log.err("Failed to save player: {s}", .{@errorName(err)});
				return;
			};
		}

		main.heap.GarbageCollection.deferredFree(.{.ptr = self, .freeFunction = main.meta.castFunctionSelfToAnyopaque(privateDeinit)});
		main.heap.GarbageCollection.deferredFree(.{.ptr = self, .freeFunction = main.meta.castFunctionSelfToAnyopaque(pause)});
	}
	pub fn pause(self: *User) void {
		self.state = switch (self.state) {
			.awaitingKeyVerification => .awaitingKeyVerification,
			.connectedVerified => .awaitingReloadVerified,
			.awaitingReloadVerified => .awaitingReloadVerified,
		};

		self.clearJobQueue();

		main.items.Inventory.server.disconnectUser(self);
		std.debug.assert(self.inventoryClientToServerIdMap.count() == 0);
		self.inventoryClientToServerIdMap.deinit();

		if (self.inventory != null) {
			world.?.savePlayer(self) catch |err| {
				std.log.err("Failed to save player: {s}", .{@errorName(err)});
				return;
			};

			main.items.Inventory.server.destroyExternallyManagedInventory(self.inventory.?);
			main.items.Inventory.server.destroyExternallyManagedInventory(self.handInventory.?);
		}

		self.worldEditData.deinit();
		self.heldItem.deinit();

		if (self.player().id != .noValue) {
			self.player().deinit(.server);
		}

		self.unloadOldChunk(.{0, 0, 0}, 0);
		for (self.inventoryCommands.items) |commandData| {
			main.globalAllocator.free(commandData);
		}
		self.inventoryCommands.deinit(main.globalAllocator);

		self.jobQueue.deinit();
	}

	pub fn identifyFromKeysAndName(self: *User, name: []const u8, keys: main.ZonElement) !void {
		std.debug.assert(self.name.len == 0);
		self.name = main.globalAllocator.dupe(u8, name);
		{
			const keyBase64 = keys.get([]const u8, @tagName(main.settings.launchConfig.preferredAuthenticationAlgorithm)) orelse return error.PublicKeyNotPresent;
			self.key = try .initFromBase64(keyBase64, main.settings.launchConfig.preferredAuthenticationAlgorithm);
			self.newKeyString = main.globalAllocator.print("{s}:{s}", .{@tagName(main.settings.launchConfig.preferredAuthenticationAlgorithm), keyBase64});
		}
		var foundKey: bool = false;
		for (std.meta.fieldNames(main.network.authentication.KeyTypeEnum)) |keyTypeName| {
			const keyBase64 = keys.get([]const u8, keyTypeName) orelse continue;
			const keyWithType = main.stackAllocator.print("{s}:{s}", .{keyTypeName, keyBase64});
			defer main.stackAllocator.free(keyWithType);
			self.playerIndex = world.?.playerDatabase.get(keyWithType) orelse continue;
			foundKey = true;
			const keyType = std.meta.stringToEnum(main.network.authentication.KeyTypeEnum, keyTypeName).?;
			if (keyType == self.key) break;
			self.legacyKey = try .initFromBase64(keyBase64, keyType);
			break;
		}
		if (!foundKey) {
			if (world.?.playerDatabase.size == 0) {
				std.log.info("Here", .{});
				self.playerIndex = world.?.localPlayerIndex;
			} else {
				const nameEntry = main.stackAllocator.print("name:{s}", .{name});
				defer main.stackAllocator.free(nameEntry);
				self.playerIndex = world.?.playerDatabase.get(nameEntry) orelse world.?.nextPlayerIndex.fetchAdd(1, .monotonic);
			}
		}
	}

	pub fn identifyAsLocal(self: *User, name: []const u8) !void {
		std.debug.assert(self.name.len == 0);
		self.name = main.globalAllocator.dupe(u8, name);

		if (world.?.settings.testingMode and !self.isLocal) {
			self.playerIndex = world.?.nextPlayerIndex.fetchAdd(1, .monotonic);
			std.log.info("Assigned temporary testing player index {d} to {s}", .{self.playerIndex, name});
		} else {
			self.playerIndex = world.?.localPlayerIndex;
		}
	}

	pub fn verifySignatures(self: *User, reader: *BinaryReader) !void {
		try self.key.verifySignature(reader, self.conn.secureChannel.verificationDataForClientSignature.items);
		if (self.legacyKey) |key| {
			try key.verifySignature(reader, self.conn.secureChannel.verificationDataForClientSignature.items);
		}
	}

	var freeId: u32 = 0;
	pub fn initPlayer(self: *User) void {
		self.id = @enumFromInt(freeId);
		freeId += 1;

		world.?.loadPlayer(self) catch {
			std.log.err("Error while loading player data of {s}. Discarding data.", .{self.name});
		};
		if (main.entity.components.@"cubyz:model".server.get(self.id) == null) {
			if (main.entityModel.playerEntityModels.items.len != 0) {
				const defaultModel = main.entityModel.playerEntityModels.items[main.random.nextIntBounded(u32, &main.seed, @intCast(main.entityModel.playerEntityModels.items.len))];
				main.entity.components.@"cubyz:model".server.put(self.id, .{.entityModel = defaultModel});
			}
		}
		if (main.entity.components.@"cubyz:bag".server.get(self.id) == null) {
			main.entity.components.@"cubyz:bag".server.loadEmpty(self.id);
		}
		if (main.entity.components.@"cubyz:permissions".server.get(self.id) == null) {
			main.entity.components.@"cubyz:permissions".server.loadEmpty(self.id);
		}
		inline for (playerCommandPermissions) |permissionPath| main.entity.components.@"cubyz:permissions".server.addPermission(self.id, .white, permissionPath);
		if (self.isLocal) {
			main.entity.components.@"cubyz:permissions".server.addPermission(self.id, .white, "/");
		}

		self.interpolation.init(@ptrCast(&self.player().pos), @ptrCast(&self.player().vel));
		self.loadUnloadChunks();

		main.entity.components.@"cubyz:player".server.load(self.id, @truncate(self.playerIndex));
	}

	fn simArrIndex(x: i32) usize {
		return @intCast(x >> chunk.chunkShift & simulationMask);
	}

	fn unloadOldChunk(self: *User, newPos: Vec3i, newRenderDistance: u16) void {
		const lastBoxStart = (self.lastPos -% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const lastBoxEnd = (self.lastPos +% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxStart = (newPos -% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxEnd = (newPos +% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));

		var x: i32 = lastBoxStart[0];
		while (x != lastBoxEnd[0]) : (x +%= chunk.chunkSize) {
			const inXDistance = x -% newBoxStart[0] >= 0 and x -% newBoxEnd[0] < 0;
			var y: i32 = lastBoxStart[1];
			while (y != lastBoxEnd[1]) : (y +%= chunk.chunkSize) {
				const inYDistance = y -% newBoxStart[1] >= 0 and y -% newBoxEnd[1] < 0;
				var z: i32 = lastBoxStart[2];
				while (z != lastBoxEnd[2]) : (z +%= chunk.chunkSize) {
					const inZDistance = z -% newBoxStart[2] >= 0 and z -% newBoxEnd[2] < 0;
					if (!inXDistance or !inYDistance or !inZDistance) {
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)].decreaseRefCount();
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)] = undefined;
					}
				}
			}
		}
	}

	fn loadNewChunk(self: *User, newPos: Vec3i, newRenderDistance: u16) void {
		const lastBoxStart = (self.lastPos -% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const lastBoxEnd = (self.lastPos +% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxStart = (newPos -% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxEnd = (newPos +% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));

		var x: i32 = newBoxStart[0];
		while (x != newBoxEnd[0]) : (x +%= chunk.chunkSize) {
			const inXDistance = x -% lastBoxStart[0] >= 0 and x -% lastBoxEnd[0] < 0;
			var y: i32 = newBoxStart[1];
			while (y != newBoxEnd[1]) : (y +%= chunk.chunkSize) {
				const inYDistance = y -% lastBoxStart[1] >= 0 and y -% lastBoxEnd[1] < 0;
				var z: i32 = newBoxStart[2];
				while (z != newBoxEnd[2]) : (z +%= chunk.chunkSize) {
					const inZDistance = z -% lastBoxStart[2] >= 0 and z -% lastBoxEnd[2] < 0;
					if (!inXDistance or !inYDistance or !inZDistance) {
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)] = world_zig.ChunkManager.getOrGenerateSimulationChunkAndIncreaseRefCount(.{.wx = x, .wy = y, .wz = z, .voxelSize = 1}, self.player().pos);
					}
				}
			}
		}
	}

	fn loadUnloadChunks(self: *User) void {
		const newPos: Vec3i = @as(Vec3i, @trunc(self.player().pos)) +% @as(Vec3i, @splat(chunk.chunkSize/2)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newRenderDistance = main.settings.simulationDistance;
		if (@reduce(.Or, newPos != self.lastPos) or newRenderDistance != self.lastRenderDistance) {
			self.unloadOldChunk(newPos, newRenderDistance);
			self.loadNewChunk(newPos, newRenderDistance);
			self.lastRenderDistance = newRenderDistance;
			self.lastPos = newPos;
		}
	}

	pub fn getTaskFromJobQueue(self: *User) ?struct { main.utils.ThreadPool.Task, enum { hasMoreTasks, empty } } {
		self.mutex.lock();
		defer self.mutex.unlock();
		if (vec.lengthSquare(@as(@Vector(3, i64), self.jobQueueLastUpdate.position -% self.lastPos)) > 32*32) {
			const startTime = main.timestamp();
			if (self.jobQueueLastUpdate.time.durationTo(startTime).toMilliseconds() > 100 and !self.jobQueueLastUpdate.alreadyInUpdate) {
				const ResortTaskTask = struct {
					const vtable = utils.ThreadPool.VTable{
						.getPriority = &getPriority,
						.isStillNeeded = &isStillNeeded,
						.run = main.meta.castFunctionSelfToAnyopaque(run),
						.clean = main.meta.castFunctionSelfToAnyopaque(clean),
						.taskType = .taskPriorityUpdate,
					};

					pub fn getPriority(_: *anyopaque) f32 {
						unreachable;
					}

					pub fn isStillNeeded(_: *anyopaque) bool {
						return true;
					}

					pub fn run(user: *User) void {
						var newTasks: main.List(main.utils.ThreadPool.Task) = .initCapacity(main.stackAllocator, user.jobQueue.size);
						defer newTasks.deinit(main.stackAllocator);
						while (user.jobQueue.extractAny()) |_task| {
							var task = _task;
							if (!task.vtable.isStillNeeded(task.self)) {
								task.vtable.clean(task.self);
								continue;
							}
							task.cachedPriority = task.vtable.getPriority(task.self);
							newTasks.append(main.stackAllocator, task);
						}
						user.jobQueue.addMany(newTasks.items);
						user.mutex.lock();
						defer user.mutex.unlock();
						user.jobQueueLastUpdate = .{
							.position = user.lastPos,
							.time = main.timestamp(),
						};
					}

					pub fn clean(_: *anyopaque) void {
						unreachable;
					}
				};

				self.jobQueueLastUpdate.alreadyInUpdate = true;
				return .{
					.{
						.cachedPriority = undefined,
						.vtable = &ResortTaskTask.vtable,
						.self = self,
					},
					.hasMoreTasks,
				};
			}
		}
		if (self.isNetworkQueueFull()) {
			self.jobQueueScheduled = false;
			return null;
		}
		const task = self.jobQueue.extractMax() orelse {
			self.jobQueueScheduled = false;
			return null;
		};
		if (self.jobQueue.size == 0) {
			self.jobQueueScheduled = false;
			return .{task, .empty};
		} else {
			return .{task, .hasMoreTasks};
		}
	}

	pub fn addTask(self: *User, task: *anyopaque, vtable: *const main.utils.ThreadPool.VTable) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		self.jobQueue.add(.{
			.cachedPriority = vtable.getPriority(task),
			.vtable = vtable,
			.self = task,
		});
	}

	pub fn clearJobQueue(self: *User) void {
		while (self.jobQueue.extractAny()) |task| {
			task.vtable.clean(task.self);
		}
	}

	fn isNetworkQueueFull(self: *User) bool {
		const estimatedQueueBytes: usize = @intFromFloat(self.conn.bandwidthEstimateInBytesPerRtt * 4.0);
		const queueLimit = std.math.clamp(estimatedQueueBytes, 16*1024, 900000);
		return self.conn.secureChannel.super.sendBuffer.buffer.len > queueLimit;
	}

	fn scheduleJobQueue(self: *User) void {
		self.mutex.assertLocked();
		if (self.jobQueueScheduled) return;
		if (self.jobQueue.size == 0) return;
		if (self.isNetworkQueueFull()) return;
		self.jobQueueScheduled = true;
		main.threadPool.addPlayer(self);
	}

	pub fn update(self: *User) void {
		self.mutex.lock();
		self.scheduleJobQueue();
		const commands = self.inventoryCommands;
		defer commands.deinit(main.globalAllocator);
		self.inventoryCommands = .empty;
		self.mutex.unlock();

		for (commands.items) |commandData| {
			defer main.globalAllocator.free(commandData);
			var reader: BinaryReader = .init(commandData);
			main.sync.server.executeUserCommand(self, &reader) catch |err| {
				if (err == error.InventoryNotFound) {
					main.network.protocols.inventory.sendFailure(self.conn);
				} else {
					std.log.err("Got error while executing user command: {s}. Disconnecting.", .{@errorName(err)});
					std.log.debug("Command data: {any}", .{commandData});
					self.conn.disconnect();
				}
			};
		}

		self.mutex.lock();
		defer self.mutex.unlock();
		var time = @as(i16, @truncate(main.timestamp().toMilliseconds())) -% main.settings.entityLookback;
		time -%= self.timeDifference.difference.load(.monotonic);
		self.interpolation.update(time, self.lastTime);
		self.lastTime = time;

		const saveTime = main.timestamp();
		if (self.lastSaveTime.durationTo(saveTime).toSeconds() > 5) {
			world.?.savePlayer(self) catch |err| {
				std.log.err("Failed to save player {s}: {s}", .{self.name, @errorName(err)});
			};
			self.lastSaveTime = saveTime;
		}

		self.loadUnloadChunks();
	}

	pub fn receiveCommand(self: *User, commandData: []const u8) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		self.inventoryCommands.append(main.globalAllocator, main.globalAllocator.dupe(u8, commandData));
	}

	pub fn receiveData(self: *User, reader: *BinaryReader) !void {
		self.mutex.lock();
		defer self.mutex.unlock();
		const position: [3]f64 = try reader.readVec(Vec3d);
		const velocity: [3]f64 = try reader.readVec(Vec3d);
		const rotation: [3]f32 = try reader.readVec(Vec3f);
		if (self.isAfk and (vec.lengthSquare(position - self.player().pos) > 0.01*0.01 or velocity[0]*velocity[0] + velocity[1]*velocity[1] + velocity[2]*velocity[2] > 0.05*0.05)) {
			self.isAfk = false;
			main.server.sendMessage("{s}§#00ff00 is no longer AFK", .{self.name});
		}
		self.player().rot = rotation;
		const time = try reader.readInt(i16);
		self.timeDifference.addDataPoint(time);
		self.interpolation.updatePosition(&position, &velocity, time);
	}

	pub fn sendMessage(self: *User, comptime fmt: []const u8, args: anytype) void {
		const msg = main.stackAllocator.print(fmt, args);
		defer main.stackAllocator.free(msg);
		self.sendRawMessage(msg);
	}
	pub fn sendRawMessage(self: *User, msg: []const u8) void {
		main.network.protocols.chat.send(self.conn, msg);
	}
	pub fn teleport(self: *User, position: Vec3d, saveBackPosition: bool) void {
		if (saveBackPosition) self.player().backPosition = self.player().pos;
		self.player().pos = position;
		self.player().vel = @splat(0);
		self.interpolation.init(@ptrCast(&self.player().pos), @ptrCast(&self.player().vel));
		main.network.protocols.genericUpdate.sendTPCoordinates(self.conn, position);
	}

	pub fn getRespawnPos(user: *User) Vec3d {
		if (user.player().respawnHome) |index| {
			if (user.player().homePositions[index]) |position| return position;
		}
		return user.spawnPos orelse @floatFromInt(main.server.world.?.spawn);
	}
	pub fn getSpawnPos(user: *User) Vec3d {
		user.player().backPosition = user.player().pos;
		return user.getRespawnPos();
	}

	pub fn format(user: User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
		try writer.print("{s}@{d}", .{user.name, user.playerIndex});
	}
};

pub const updatesPerSec: u32 = 20;
const updateTime: std.Io.Duration = .fromNanoseconds(1000000000/20);

pub var world: ?*ServerWorld = null;
var userMutex: main.utils.Mutex = .{};
var users: main.ListManaged(*User) = undefined;
var userDeinitList: main.utils.ConcurrentQueue(*User) = undefined;
var userConnectList: main.utils.ConcurrentQueue(*User) = undefined;

pub var connectionManager: *ConnectionManager = undefined;

pub var running: std.atomic.Value(bool) = .init(false);
var restart: bool = true;

var lastTime: std.Io.Timestamp = undefined;

pub var thread: ?std.Thread = null;

fn init(name: []const u8, singlePlayerPort: ?u16, mode: ServerWorld.Mode) void {
	main.heap.allocators.createWorldArena();
	std.debug.assert(world == null);
	command.init();
	users = .init(main.globalAllocator);
	lastTime = main.timestamp();

	main.entity.server.init();
	main.items.Inventory.server.init();
	main.sync.server.init();

	world = ServerWorld.init(name, mode) catch |err| {
		std.log.err("Failed to create world: {s}", .{@errorName(err)});
		@panic("Can't create world.");
	};

	world.?.generate() catch |err| {
		std.log.err("Failed to generate world: {s}", .{@errorName(err)});
		@panic("Can't generate world.");
	};

	connectionManager.@"continue"() catch |err| {
		std.log.err("Couldn't create thread: {s}", .{@errorName(err)});
		@panic("Could not open Server.");
	};
	if (singlePlayerPort) |port| blk: {
		const ipString = main.stackAllocator.print("127.0.0.1:{}", .{port});
		defer main.stackAllocator.free(ipString);
		const user = User.init(connectionManager, ipString) catch |err| {
			std.log.err("Cannot create singleplayer user {s}", .{@errorName(err)});
			break :blk;
		};
		user.isLocal = true;
	}
}

fn deinit() void {
	connectionManager.pause();
	main.threadPool.pause();
	defer main.threadPool.@"continue"();

	main.threadPool.unschedulePlayers();

	users.clearAndFree();

	while (userDeinitList.popFront()) |user| {
		user.pause();
		user.privateDeinit();
	}

	if (world) |_world| {
		_world.deinit();
	}
	world = null;

	main.sync.server.deinit();
	main.items.Inventory.server.deinit();
	main.entity.server.deinit();
	WeatherMap.deinit();

	command.deinit();

	main.heap.allocators.destroyWorldArena();
}

pub fn getUserList(allocator: main.heap.NeverFailingAllocator) []*User {
	userMutex.lock();
	defer userMutex.unlock();
	return allocator.dupe(*User, users.items);
}

fn getInitialEntityList(allocator: main.heap.NeverFailingAllocator) []const u8 {

	var initialList: []const u8 = undefined;
	const list = main.ZonElement.initArray(main.stackAllocator);
	defer list.deinit(main.stackAllocator);
	list.array.append(.null);
	const itemDropList = world.?.itemDropManager.getInitialList(main.stackAllocator);
	list.array.appendSlice(itemDropList.array.items);
	itemDropList.array.items.len = 0;
	itemDropList.deinit(main.stackAllocator);
	initialList = list.toStringEfficient(allocator, &.{});
	return initialList;
}

fn updateSurvivalNeeds(user: *User) void {
	const player = user.player();
	if (user.gamemode.raw == .survival) {
		const horizontalSpeed = @sqrt(player.vel[0]*player.vel[0] + player.vel[1]*player.vel[1]);
		const hungerInterval: f32 = if (horizontalSpeed >= 6.0 and @abs(player.vel[2]) >= 0.5) 30.0 else if (horizontalSpeed >= 6.0) 60.0 else 180.0;
		user.hungerExhaustion += 1.0/(hungerInterval*@as(f32, @floatFromInt(updatesPerSec)));
		while (user.hungerExhaustion >= 1.0) {
			user.hungerExhaustion -= 1.0;
			player.hunger = @max(0, player.hunger - 1);
		}

		if (player.health < player.maxHealth and player.energy >= player.maxEnergy and player.hunger >= 1.5) {
			user.healingTime += 1.0/@as(f32, @floatFromInt(updatesPerSec));
			if (user.healingTime >= 1.5) {
				user.healingTime = 0;
				player.health = @min(player.maxHealth, player.health + 1.5);
				player.hunger = @max(0, player.hunger - 1.5);
			}
		} else {
			user.healingTime = 0;
		}
	}

	if (player.hunger != user.lastSentHunger or player.energy != user.lastSentSaturation or player.health != user.lastSentHealth) {
		user.lastSentHunger = player.hunger;
		user.lastSentSaturation = player.energy;
		user.lastSentHealth = player.health;
		main.network.protocols.genericUpdate.sendNeeds(user.conn, player.health, player.hunger, player.energy);
	}
}

fn update() void {
	world.?.update();
	main.entity.server.update();
	stdin_handler.update();

	while (userConnectList.popFront()) |user| {
		if (user.connected.load(.monotonic)) connectInternal(user);
	}

	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		user.update();
		updateSurvivalNeeds(user);
	}

	const itemData = world.?.itemDropManager.getPositionAndVelocityData(main.stackAllocator);
	defer main.stackAllocator.free(itemData);

	var entityData: main.ListManaged(main.entity.EntityNetworkData) = .init(main.stackAllocator);
	defer entityData.deinit();

	for (userList) |user| {
		const id = user.id;
		entityData.append(.{
			.id = id,
			.pos = user.player().pos,
			.vel = user.player().vel,
			.rot = user.player().rot,
		});
	}
	for (userList) |user| {
		main.network.protocols.entityPosition.send(user.conn, user.player().pos, entityData.items, itemData);
	}

	for (userList) |user| {
		const pos = @as(Vec3i, @trunc(user.player().pos));
		const biomeId = world.?.getBiome(pos[0], pos[1], pos[2]).paletteId;
		if (biomeId != user.lastSentBiomeId) {
			user.lastSentBiomeId = biomeId;
			main.network.protocols.genericUpdate.sendBiome(user.conn, biomeId);
		}

		const biome = world.?.getBiome(pos[0], pos[1], pos[2]);
		const nowMillis = main.timestamp().toMilliseconds();
		const weather = WeatherMap.sample(world.?.settings.seed, biome, pos[0], pos[1], nowMillis);
		if (nowMillis - user.lastLightningCheckMillis >= 4000) {
			user.lastLightningCheckMillis = nowMillis;
			if (weather.kind == .rain and weather.cloudCover >= 0.80 and weather.precipitation >= 0.65) {
				var lightningSeed = main.random.initSeed2D(world.?.settings.seed ^ @as(u64, @bitCast(@divFloor(nowMillis, 4000))), .{pos[0] >> 6, pos[1] >> 6});
				const intensity = std.math.clamp((weather.precipitation - 0.65)*2.0, 0.25, 1.0);
				if (main.random.nextFloat(&lightningSeed) < 0.08 + intensity*0.16) {
					const strikePosition = Vec3d{
						@as(f64, @floatFromInt(pos[0])) + @as(f64, main.random.nextFloatSigned(&lightningSeed))*160.0,
						@as(f64, @floatFromInt(pos[1])) + @as(f64, main.random.nextFloatSigned(&lightningSeed))*160.0,
						main.game.weatherCloudBaseHeight,
					};
					for (userList) |other| {
						const otherPosition = other.player().pos;
						const deltaX = otherPosition[0] - strikePosition[0];
						const deltaY = otherPosition[1] - strikePosition[1];
						if (deltaX*deltaX + deltaY*deltaY <= 512.0*512.0) {
							main.network.protocols.genericUpdate.sendLightning(other.conn, strikePosition, intensity);
						}
					}
				}
			}
		}

		const rainIntensity = if (weather.kind == .rain) weather.precipitation else 0.0;
		if (@abs(rainIntensity - user.lastSentRainIntensity) >= 0.02) {
			user.lastSentRainIntensity = rainIntensity;
			main.network.protocols.genericUpdate.sendRainIntensity(user.conn, rainIntensity);
		}

		if (nowMillis - user.lastSentWeatherGridMillis >= 200) {
			user.lastSentWeatherGridMillis = nowMillis;
			const centerCell = Vec2i{
				@divFloor(pos[0], main.game.WeatherGrid.cell_size),
				@divFloor(pos[1], main.game.WeatherGrid.cell_size),
			};
			const half: i32 = @intCast(main.game.WeatherGrid.dimension/2);
			const originCell = centerCell - @as(Vec2i, @splat(half));
			var cells: [main.game.WeatherGrid.cell_count]main.game.WeatherGrid.Cell = undefined;
			const gridWind = weather.wind;
			for (0..main.game.WeatherGrid.dimension) |gy| {
				for (0..main.game.WeatherGrid.dimension) |gx| {
					const cellPos = originCell + Vec2i{@intCast(gx), @intCast(gy)};
					const sampleX = cellPos[0]*main.game.WeatherGrid.cell_size + @divTrunc(main.game.WeatherGrid.cell_size, 2);
					const sampleY = cellPos[1]*main.game.WeatherGrid.cell_size + @divTrunc(main.game.WeatherGrid.cell_size, 2);
					const cellBiome = world.?.getBiomeAndSeed(sampleX, sampleY, pos[2]).biome;
					const cellWeather = WeatherMap.sampleWithWind(world.?.settings.seed, cellBiome, sampleX, sampleY, nowMillis, gridWind);
					cells[gy*main.game.WeatherGrid.dimension + gx] = .{
						.cloud_cover = @intFromFloat(std.math.clamp(cellWeather.cloudCover, 0.0, 1.0)*255.0),
						.precipitation = @intFromFloat(std.math.clamp(cellWeather.precipitation, 0.0, 1.0)*255.0),
						.dust = @intFromFloat(std.math.clamp(cellWeather.dust, 0.0, 1.0)*255.0),
						.kind = @intFromEnum(cellWeather.kind),
					};
				}
			}
			main.network.protocols.genericUpdate.sendWeatherGrid(user.conn, originCell, gridWind, nowMillis, cells);
		}
	}

	while (userDeinitList.popFront()) |user| {
		user.deferredPauseAndDeinit();
	}
}

pub fn startFromNewThread(name: []const u8, port: ?u16, mode: ServerWorld.Mode) void {
	main.initThreadLocals();
	defer main.deinitThreadLocals();
	startFromExistingThread(name, port, mode);
}

pub fn startFromExistingThread(name: []const u8, port: ?u16, mode: ServerWorld.Mode) void {
	std.debug.assert(!running.load(.monotonic));

	const worldName: []const u8 = main.globalAllocator.dupe(u8, name);
	defer main.globalAllocator.free(worldName);

	connectionManager = ConnectionManager.init(main.settings.defaultPort, .{.allowNewConnections = mode == .multiplayer}) catch |err| {
		std.log.err("Couldn't create socket: {s}", .{@errorName(err)});
		@panic("Could not open Server.");
	};
	userDeinitList = .init(main.globalAllocator, 16);
	userConnectList = .init(main.globalAllocator, 16);

	defer {
		connectionManager.deinit();
		connectionManager = undefined;

		while (userDeinitList.popFront()) |user| {
			user.privateDeinit();
		}

		userDeinitList.deinit();
		userConnectList.deinit();
	}

	restart = true;
	while (restart) {
		restart = false;

		init(worldName, port, mode);
		defer deinit();

		running.store(true, .release);
		while (running.load(.monotonic)) {
			main.heap.GarbageCollection.syncPoint();
			const newTime = main.timestamp();
			if (lastTime.durationTo(newTime).nanoseconds < updateTime.nanoseconds) {
				main.io.sleep(newTime.durationTo(lastTime.addDuration(updateTime)), .awake) catch {};
				lastTime = lastTime.addDuration(updateTime);
			} else {
				std.log.warn("The server is lagging behind by {d:.1} ms", .{@as(f32, @floatFromInt(newTime.nanoseconds -% lastTime.nanoseconds -% updateTime.nanoseconds))/1000000.0});
				lastTime = newTime;
			}
			update();
		}
	}
}

pub const StopType = enum { stop, restart };
pub fn stop(_restart: StopType) void {
	if (_restart == .restart) {
		restart = true;
	}
	running.store(false, .release);
}

pub fn disconnect(user: *User) void {
	if (!user.connected.load(.monotonic)) return;
	removePlayer(user);
	userDeinitList.pushBack(user);
	user.connected.store(false, .monotonic);
}

pub fn removePlayer(user: *User) void {
	if (!user.connected.load(.monotonic)) return;

	const foundUser = blk: {
		userMutex.lock();
		defer userMutex.unlock();
		for (users.items, 0..) |other, i| {
			if (other == user) {
				_ = users.swapRemove(i);
				break :blk true;
			}
		}
		break :blk false;
	};
	if (!foundUser) return;

	sendMessage("{s}§#ffff00 left", .{user.name});

	const zonArray = main.ZonElement.initArray(main.stackAllocator);
	defer zonArray.deinit(main.stackAllocator);
	zonArray.array.append(.{.int = @intFromEnum(user.id)});
	const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
	defer main.stackAllocator.free(data);
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |other| {
		main.network.protocols.entity.send(other.conn, data);
	}
}

pub fn connect(user: *User) void {
	if (user.connectQueued.swap(true, .acq_rel)) return;
	userConnectList.pushBack(user);
}

pub fn connectInternal(user: *User) void {
	user.initPlayer();
	main.network.protocols.handShake.sendServerPlayerData(user.conn);
	user.conn.handShakeState.store(.complete, .monotonic);

	const heldLightUsers = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(heldLightUsers);
	for (heldLightUsers) |other| {
		if (other.id != .noValue) main.network.protocols.heldLight.sendTo(user.conn, other.id, other.heldItem, other.heldLightTransform, other.heldToolRotationYZ, other.heldToolScale, other.heldMiningSwing);
	}

	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);

	if (!world.?.settings.testingMode) {
		for (userList) |other| {
			if (other.playerIndex == user.playerIndex) {
				user.conn.disconnect();
				return;
			}
		}
	}

	{
		const zonArray = main.ZonElement.initArray(main.stackAllocator);
		defer zonArray.deinit(main.stackAllocator);

		const entityZon = user.player().save(main.stackAllocator, .playerNearby);
		zonArray.array.append(entityZon);
		const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
		defer main.stackAllocator.free(data);
		for (userList) |other| {
			main.network.protocols.entity.send(other.conn, data);
		}
	}
	{
		const zonArray = main.ZonElement.initArray(main.stackAllocator);
		defer zonArray.deinit(main.stackAllocator);
		for (userList) |other| {
			const entityZon = other.player().save(main.stackAllocator, .playerNearby);
			zonArray.array.append(entityZon);
		}
		const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
		defer main.stackAllocator.free(data);
		if (user.connected.load(.monotonic)) main.network.protocols.entity.send(user.conn, data);
	}
	const initialList = getInitialEntityList(main.stackAllocator);
	main.network.protocols.entity.send(user.conn, initialList);
	main.stackAllocator.free(initialList);
	sendMessage("{s}§#ffff00 joined", .{user.name});

	userMutex.lock();
	users.append(user);
	userMutex.unlock();
}

pub fn messageFrom(msg: []const u8, source: *User) void {
	if (source.player().prefix) |prefix| {
		sendMessage("[{s}§#ffffff] {s}§#ffffff > {s}", .{prefix, source.name, msg});
	} else {
		sendMessage("[{s}§#ffffff] {s}", .{source.name, msg});
	}
}

fn sendRawMessage(msg: []const u8) void {
	chatMutex.lock();
	defer chatMutex.unlock();
	main.log.chat("{s}", .{msg});
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		user.sendRawMessage(msg);
	}
}

var chatMutex: main.utils.Mutex = .{};
pub fn sendMessage(comptime fmt: []const u8, args: anytype) void {
	const msg = main.stackAllocator.print(fmt, args);
	defer main.stackAllocator.free(msg);
	sendRawMessage(msg);
}

pub fn getUserByIndex(index: PlayerIndex) ?*User {
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (user.playerIndex == index) {
			return user;
		}
	}
	return null;
}
