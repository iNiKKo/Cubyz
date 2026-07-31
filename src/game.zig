const std = @import("std");
const Atomic = std.atomic.Value;

const main = @import("main");
const assets = @import("assets.zig");
const itemdrop = @import("itemdrop.zig");
const ClientItemDropManager = itemdrop.ClientItemDropManager;
const items = @import("items.zig");
const ClientInventory = items.Inventory.ClientInventory;
const ZonElement = main.ZonElement;
const network = @import("network.zig");
const particles = @import("particles.zig");
const Connection = network.Connection;
const ConnectionManager = network.ConnectionManager;
const vec = @import("vec.zig");
const Vec2f = vec.Vec2f;
const Vec2i = vec.Vec2i;
const Vec3i = vec.Vec3i;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const Vec3d = vec.Vec3d;
const Mat4f = vec.Mat4f;
const graphics = @import("graphics.zig");
const Fog = graphics.Fog;
const renderer = @import("renderer.zig");
const settings = @import("settings.zig");
const Block = main.blocks.Block;
const physics = main.physics;
const KeyBoard = main.KeyBoard;

pub const camera = struct { // MARK: camera
	pub var rotation: Vec3f = Vec3f{0, 0, 0};
	pub var direction: Vec3f = Vec3f{0, 0, 0};
	pub var viewMatrix: Mat4f = Mat4f.identity();
	pub fn moveRotation(mouseX: f32, mouseY: f32) void {
		// Mouse movement along the y-axis rotates the image along the x-axis.
		rotation[0] += mouseY;
		const bound = std.math.pi/2.0 - 0.001;
		rotation[0] = std.math.clamp(rotation[0], -bound, bound);
		// Mouse movement along the x-axis rotates the image along the z-axis.
		rotation[2] += mouseX;
	}

	pub fn updateViewMatrix() void {
		direction = vec.rotateZ(vec.rotateX(Vec3f{0, 1, 0}, -rotation[0]), -rotation[2]);
		viewMatrix = Mat4f.identity().mul(Mat4f.rotationX(rotation[0])).mul(Mat4f.rotationZ(rotation[2]));
	}
};

pub const Gamemode = enum(u8) { survival = 0, creative = 1 };

pub const DamageType = enum(u8) {
	heal = 0, // For when you are adding health
	kill = 1,
	fall = 2,
	heat = 3,
	spiky = 4,

	pub fn sendMessage(self: DamageType, name: []const u8) void {
		switch (self) {
			.heal => main.server.sendMessage("{s}§#ffffff was healed", .{name}),
			.kill => main.server.sendMessage("{s}§#ffffff was killed", .{name}),
			.fall => main.server.sendMessage("{s}§#ffffff died of fall damage", .{name}),
			.heat => main.server.sendMessage("{s}§#ffffff burned to death", .{name}),
			.spiky => main.server.sendMessage("{s}§#ffffff experienced death by 1000 needles", .{name}),
		}
	}
};

pub const Player = struct { // MARK: Player
	pub const EyeData = struct {
		pos: Vec3d = .{0, 0, 0},
		vel: Vec3d = .{0, 0, 0},
		coyote: f64 = 0.0,
		step: @Vector(3, bool) = .{false, false, false},
		box: physics.collision.Box = .{
			.min = -Vec3d{standingBoundingBoxExtent[0]*0.2, standingBoundingBoxExtent[1]*0.2, 0.6},
			.max = Vec3d{standingBoundingBoxExtent[0]*0.2, standingBoundingBoxExtent[1]*0.2, 0.9 - 0.05},
		},
		desiredPos: Vec3d = .{0, 0, 1.7 - standingBoundingBoxExtent[2]},
	};
	pub var super: main.server.Entity = .{};
	pub var eye: EyeData = .{};
	pub var crouching: bool = false;
	pub var id: main.entity.Entity = .noValue;
	pub var gamemode: Atomic(Gamemode) = .init(.creative);
	pub var isFlying: Atomic(bool) = .init(false);
	pub var isGhost: Atomic(bool) = .init(false);
	pub var hyperSpeed: Atomic(bool) = .init(false);
	pub var mutex: main.utils.Mutex = .{};
	pub const inventorySize = 32;
	pub var inventory: ClientInventory = undefined;
	pub var selectedSlot: u32 = 0;
	pub const defaultBlockDamage: f32 = 1;

	pub var selectionPosition1: ?Vec3i = null;
	pub var selectionPosition2: ?Vec3i = null;

	pub var friction: physics.FrictionState = .{.current = 0, .mobile = 0};
	pub var volumeProperties: physics.collision.VolumeProperties = .{.density = 0, .maxDensity = 0, .mobileFriction = 0, .terminalVelocity = 0};

	pub var onGround: bool = false;
	pub var jumpCooldown: f64 = 0;
	pub var jumpCoyote: f64 = 0;
	pub const jumpCooldownConstant = 0.3;
	pub const jumpCoyoteTimeConstant = 0.100;

	pub const standingBoundingBoxExtent: Vec3d = .{0.3, 0.3, 0.9};
	pub const crouchingBoundingBoxExtent: Vec3d = .{0.3, 0.3, 0.725};
	pub var crouchPerc: f32 = 0;

	pub var outerBoundingBoxExtent: Vec3d = standingBoundingBoxExtent;
	pub var outerBoundingBox: physics.collision.Box = .{
		.min = -standingBoundingBoxExtent,
		.max = standingBoundingBoxExtent,
	};
	pub const jumpHeight = 1.25;

	fn loadFrom(zon: ZonElement) !void {
		try super.loadFrom(id, zon, .client);
	}

	pub fn setPosBlocking(newPos: Vec3d) void {
		mutex.lock();
		defer mutex.unlock();
		super.pos = newPos;
	}

	pub fn getPosBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return super.pos;
	}

	pub fn getVelBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return super.vel;
	}

	pub fn getEyePosBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return eye.pos + super.pos + eye.desiredPos;
	}

	pub fn getEyeVelBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return eye.vel;
	}

	pub fn getEyeCoyoteBlocking() f64 {
		mutex.lock();
		defer mutex.unlock();
		return eye.coyote;
	}

	pub fn getJumpCoyoteBlocking() f64 {
		mutex.lock();
		defer mutex.unlock();
		return jumpCoyote;
	}

	pub fn setGamemode(newGamemode: Gamemode) void {
		gamemode.store(newGamemode, .monotonic);

		if (newGamemode != .creative) {
			isFlying.store(false, .monotonic);
			isGhost.store(false, .monotonic);
			hyperSpeed.store(false, .monotonic);
		}
	}

	pub fn isCreative() bool {
		return gamemode.load(.monotonic) == .creative;
	}

	pub fn isActuallyFlying() bool {
		return isFlying.load(.monotonic) and !isGhost.load(.monotonic);
	}

	pub fn steppingHeight() Vec3d {
		if (onGround) {
			return .{0, 0, 0.6};
		} else {
			return .{0, 0, 0.08};
		}
	}

	pub fn placeBlock(mods: main.Window.Key.Modifiers) void {
		if (main.renderer.MeshSelection.selectedBlockPos) |blockPos| blk: {
			const mesh = main.renderer.mesh_storage.getMesh(.initFromWorldPos(blockPos, 1)) orelse break :blk;
			const block = mesh.chunk.getBlock(blockPos[0] - mesh.pos.wx, blockPos[1] - mesh.pos.wy, blockPos[2] - mesh.pos.wz);
			const onInteract = block.onInteract();
			if (!mods.shift) {
				if (onInteract.run(.{.blockPos = blockPos, .block = block, .chunk = mesh.chunk}) == .handled) return;
			}
		}

		inventory.placeBlock(selectedSlot);
	}

	pub fn kill(spawnPos: Vec3d) void {
		Player.super.pos = spawnPos;
		Player.super.vel = .{0, 0, 0};

		Player.super.health = Player.super.maxHealth;
		Player.super.energy = Player.super.maxEnergy;

		Player.eye = .{};
		Player.jumpCoyote = 0;
	}

	pub fn dropFromHand(mods: main.Window.Key.Modifiers) void {
		if (mods.shift) {
			inventory.dropStack(selectedSlot);
		} else {
			inventory.dropOne(selectedSlot);
		}
	}

	pub fn breakBlock(deltaTime: f64) void {
		inventory.breakBlock(selectedSlot, deltaTime);
	}

	pub fn acquireSelectedBlock() void {
		if (main.renderer.MeshSelection.selectedBlockPos) |selectedPos| {
			const block = main.renderer.mesh_storage.getBlockFromRenderThread(selectedPos[0], selectedPos[1], selectedPos[2]) orelse return;

			const item: items.Item = for (0..items.itemListSize) |idx| {
				const baseItem: main.items.BaseItemIndex = @enumFromInt(idx);
				if (baseItem.block() == block.typ) {
					break .{.baseItem = baseItem};
				}
			} else return;

			// Check if there is already a slot with that item type
			for (0..12) |slotIdx| {
				if (std.meta.eql(inventory.getItem(slotIdx), item)) {
					if (isCreative()) {
						inventory.fillFromCreative(@intCast(slotIdx), item);
					}
					selectedSlot = @intCast(slotIdx);
					return;
				}
			}

			if (isCreative()) {
				const targetSlot = blk: {
					if (inventory.getItem(selectedSlot) == .null) break :blk selectedSlot;
					// Look for an empty slot
					for (0..12) |slotIdx| {
						if (inventory.getItem(slotIdx) == .null) {
							break :blk slotIdx;
						}
					}
					break :blk selectedSlot;
				};

				inventory.fillFromCreative(@intCast(targetSlot), item);
				selectedSlot = @intCast(targetSlot);
			}
		}
	}
};

/// Server-authoritative weather sampled over nearby world cells. Rendering will interpolate/sample this
/// map rather than treating the player's own precipitation as the state of the whole sky.
pub const WeatherGrid = struct {
	pub const dimension: usize = 5;
	pub const cell_count: usize = dimension*dimension;
	pub const cell_size: i32 = 512;
	pub const Cell = struct {
		cloud_cover: u8 = 0,
		precipitation: u8 = 0,
		dust: u8 = 0,
		kind: u8 = 0,
	};
	pub const Sample = struct {
		cloud_cover: f32 = 0,
		precipitation: f32 = 0,
		dust: f32 = 0,
		kind: u8 = 0,
	};
	pub const Snapshot = struct {
		origin_cell: Vec2i = .{0, 0},
		wind: Vec2f = .{0, 0},
		cells: [cell_count]Cell = [_]Cell{.{}} ** cell_count,
		revision: u64 = 0,
		time_millis: i64 = 0,
	};

	mutex: main.utils.Mutex = .{},
	origin_cell: Vec2i = .{0, 0},
	wind: Vec2f = .{0, 0},
	cells: [cell_count]Cell = [_]Cell{.{}} ** cell_count,
	revision: u64 = 0,
	time_millis: i64 = 0,

	pub fn update(self: *WeatherGrid, origin_cell: Vec2i, wind: Vec2f, time_millis: i64, cells: [cell_count]Cell) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		self.origin_cell = origin_cell;
		self.wind = wind;
		self.cells = cells;
		self.revision +%= 1;
		self.time_millis = time_millis;
	}

	pub fn snapshot(self: *WeatherGrid) Snapshot {
		self.mutex.lock();
		defer self.mutex.unlock();
		return .{.origin_cell = self.origin_cell, .wind = self.wind, .cells = self.cells, .revision = self.revision, .time_millis = self.time_millis};
	}

	/// Returns the server-authoritative weather at this world position. Outside the most recent snapshot
	/// is deliberately clear: renderers must not invent a second client-only weather pattern at the edge.
	pub fn sampleAt(self: *WeatherGrid, wx: f64, wy: f64) Sample {
		return sampleSnapshot(self.snapshot(), wx, wy);
	}

	pub fn sampleSnapshot(weather_snapshot: Snapshot, wx: f64, wy: f64) Sample {
		const cell_x: i32 = @intFromFloat(@floor(wx/@as(f64, @floatFromInt(cell_size))));
		const cell_y: i32 = @intFromFloat(@floor(wy/@as(f64, @floatFromInt(cell_size))));
		const rel_x = cell_x - weather_snapshot.origin_cell[0];
		const rel_y = cell_y - weather_snapshot.origin_cell[1];
		if (rel_x < 0 or rel_x >= dimension or rel_y < 0 or rel_y >= dimension) return .{};
		const cell = weather_snapshot.cells[@as(usize, @intCast(rel_y))*dimension + @as(usize, @intCast(rel_x))];
		return .{
			.cloud_cover = @as(f32, @floatFromInt(cell.cloud_cover))/255.0,
			.precipitation = @as(f32, @floatFromInt(cell.precipitation))/255.0,
			.dust = @as(f32, @floatFromInt(cell.dust))/255.0,
			.kind = cell.kind,
		};
	}
};

/// Weather precipitation and its local atmosphere live below the low storm deck. Keep this shared with
/// the rain renderer so climbing/flying above the deck never leaves rain, haze, storm dimming, or
/// disabled god rays active in otherwise clear air.
pub const weatherCloudBaseHeight: f64 = 448.0;

/// Smooth only the last few blocks below the cloud base, then fully disable local weather above it.
/// The short fade avoids a one-frame fog/light pop when crossing the deck in flight.
pub fn weatherExposureAtAltitude(z: f64) f32 {
	return std.math.clamp(@as(f32, @floatCast((weatherCloudBaseHeight - z)/8.0)), 0.0, 1.0);
}

/// Weather is an outdoor effect. The propagated sunlight field is present in open air (including at
/// night, because it represents sky exposure rather than the current time-of-day brightness) but falls
/// away under solid roofs and into caves. Requiring a strong local sky-light value prevents miners from
/// receiving rain, storm fog, dim daylight, or other surface weather merely because their X/Y lies in a
/// rainy weather cell.
pub fn weatherExposureAtPosition(pos: Vec3d) f32 {
	const altitudeExposure = weatherExposureAtAltitude(pos[2]);
	if (altitudeExposure <= 0.0) return 0.0;
	const x: i32 = @intFromFloat(@floor(pos[0]));
	const y: i32 = @intFromFloat(@floor(pos[1]));
	const z: i32 = @intFromFloat(@floor(pos[2]));
	const light = renderer.mesh_storage.getLight(x, y, z) orelse return 0.0;
	const skyLight: u8 = @max(light[0], @max(light[1], light[2]));
	// A brief fade at cave mouths avoids a hard fog wall, while normal shaded terrain and foliage remain
	// weather-exposed. Direct outdoor sky light is 255.
	const skyExposure = std.math.clamp((@as(f32, @floatFromInt(skyLight)) - 96.0)/128.0, 0.0, 1.0);
	return altitudeExposure*skyExposure;
}

pub const World = struct { // MARK: World
	conn: *Connection,
	manager: *ConnectionManager,
	name: []const u8,
	milliTime: i64,
	gameTime: Atomic(i64) = .init(0),
	dayTime: DayTime = .{},
	connected: bool = true,
	paused: bool = true,
	blockPalette: *assets.Palette = undefined,
	itemPalette: *assets.Palette = undefined,
	proceduralItemPalette: *assets.Palette = undefined,
	biomePalette: *assets.Palette = undefined,
	entityModelPalette: *assets.Palette = undefined,
	entityComponentPalette: *assets.Palette = undefined,
	itemDrops: ClientItemDropManager = undefined,
	playerBiome: Atomic(*const main.server.terrain.biomes.Biome) = undefined,
	/// Last rain-intensity value ([0, 1]) received from the server for the biome patch the player currently
	/// occupies. Written by network/protocols.zig's genericUpdate.clientReceive whenever the server-side
	/// eased value (see server/WeatherMap.zig) moves enough to resend. DayTime.rainIntensity (below) is
	/// what actually gets read by rendering — it eases toward this target every frame client-side too, the
	/// same double-smoothing "server eases, client also eases toward whatever it last heard" pattern
	/// already used for playerBiome's fog color, so sparse network updates never look like a step either.
	rainIntensityTarget: Atomic(f32) = .init(0),
	weatherGrid: WeatherGrid = .{},

	shouldRestart: std.atomic.Value(bool) = .init(false),
	shouldReload: bool = false,

	fn connect(self: *World) !ZonElement {
		main.heap.allocators.createWorldArena();
		errdefer main.heap.allocators.destroyWorldArena();

		self.conn.handShakeState.store(if (self.shouldReload) .reload else .start, .monotonic);

		self.* = .{
			.conn = self.conn,
			.manager = self.manager,
			.name = "client",
			.milliTime = main.timestamp().toMilliseconds(),
		};

		errdefer self.conn.deinit();

		self.itemDrops.init(main.globalAllocator);
		errdefer self.itemDrops.deinit();

		return try network.protocols.handShake.clientSide(self.conn, settings.playerName);
	}

	pub fn init(self: *World, ip: []const u8, manager: *ConnectionManager) !ZonElement {
		self.conn = try Connection.init(manager, ip, null);
		self.manager = manager;
		return try self.connect();
	}

	pub fn @"continue"(self: *World) !void {
		try self.finishHandshake(try self.connect());
	}

	pub fn deinit(self: *World) void {
		main.server.stop(.stop);

		if (main.server.thread) |serverThread| {
			serverThread.join();
			main.server.thread = null;
		}

		self.conn.deinit();

		self.connected = false;
		self.pause();
		self.manager.deinit();
	}
	pub fn pause(self: *World) void {
		main.threadPool.pause();
		defer main.threadPool.@"continue"();
		defer main.threadPool.updateTaskPriority();

		self.paused = true;

		// TODO: Close all world related guis.
		main.gui.inventory.deinit();
		main.gui.deinit();
		main.gui.init();
		main.itemdrop.ItemDisplayManager.clearRemoteHeldItems();
		Player.inventory.deinit(main.globalAllocator);
		main.sync.client.reset();

		Player.super.deinit(.client);
		main.entity.client.clear();
		self.itemDrops.deinit();
		self.blockPalette.deinit();
		self.itemPalette.deinit();
		self.proceduralItemPalette.deinit();
		self.biomePalette.deinit();
		self.entityComponentPalette.deinit();
		self.entityModelPalette.deinit();
		renderer.mesh_storage.deinit();
		renderer.mesh_storage.init();
		assets.unloadAssets();
		main.heap.allocators.destroyWorldArena();
	}

	pub fn finishHandshake(self: *World, zon: ZonElement) !void {
		self.conn.manager.world = self;
		main.game.world = self;
		errdefer main.heap.allocators.destroyWorldArena();
		errdefer self.conn.deinit();
		errdefer self.itemDrops.deinit();

		// TODO: Consider using a per-world allocator.
		self.blockPalette = try assets.Palette.init(main.globalAllocator, zon.getChild("blockPalette"), "cubyz:air");
		errdefer self.blockPalette.deinit();
		self.biomePalette = try assets.Palette.init(main.globalAllocator, zon.getChild("biomePalette"), null);
		errdefer self.biomePalette.deinit();
		self.itemPalette = try assets.Palette.init(main.globalAllocator, zon.getChild("itemPalette"), null);
		errdefer self.itemPalette.deinit();
		self.proceduralItemPalette = try assets.Palette.init(main.globalAllocator, zon.getChild("toolPalette"), null);
		errdefer self.proceduralItemPalette.deinit();
		self.entityModelPalette = try assets.Palette.init(main.globalAllocator, zon.getChild("entityModelPalette"), "cubyz:missing");
		errdefer self.entityModelPalette.deinit();
		self.entityComponentPalette = try assets.Palette.init(main.globalAllocator, zon.getChild("entityComponentPalette"), null);
		errdefer self.entityComponentPalette.deinit();

		const path = main.stackAllocator.print("{s}/serverAssets", .{main.files.cubyzDirStr()});
		defer main.stackAllocator.free(path);
		try assets.loadWorldAssets(path, self.blockPalette, self.itemPalette, self.proceduralItemPalette, self.biomePalette, self.entityModelPalette, self.entityComponentPalette);
		Player.id = @enumFromInt(zon.get(u32, "player_id") orelse @intFromEnum(main.entity.Entity.noValue));
		Player.inventory = ClientInventory.init(main.globalAllocator, Player.inventorySize, .serverShared, .{.playerInventory = Player.id}, .{});
		Player.setGamemode(std.enums.fromInt(Gamemode, zon.get(u8, "gamemode") orelse return error.Invalid) orelse return error.Invalid);
		self.playerBiome = .init(main.server.terrain.biomes.getPlaceholderBiome());
		main.audio.setMusic(self.playerBiome.raw.preferredMusic);

		main.Window.setMouseGrabbed(true);
		main.blocks.meshes.generateTextureArray();
		main.particles.ParticleManager.generateTextureArray();
		main.models.uploadModels();
		main.entityModel.loadModelsAndTexture();

		try Player.loadFrom(zon.getChild("player"));
		main.network.protocols.handShake.signalLoadedAssets();

		self.paused = false;
	}

	pub fn update(self: *World, deltaTime: f64) void {
		const newTime: i64 = main.timestamp().toMilliseconds();
		while (self.milliTime +% 100 -% newTime < 0) {
			self.milliTime +%= 100;
			var curTime = self.gameTime.load(.monotonic);
			while (self.gameTime.cmpxchgWeak(curTime, curTime +% 1, .monotonic, .monotonic)) |actualTime| {
				curTime = actualTime;
			}
		}
		network.protocols.playerPosition.send(self.conn, Player.getPosBlocking(), Player.getVelBlocking(), @intCast(newTime & 65535));
		self.dayTime.update(deltaTime);
	}

	pub const DayTime = struct { // MARK: DayTime
		const dayCycleLength = 12000; // Length of one in-game day in 100ms. Midnight is at DAY_CYCLE/2. Sunrise and sunset each take about 1/16 of the day. Currently set to 20 minutes
		const minimumAmbientLight: f32 = 0.1;
		pub const nightStart = dayCycleLength/4 + dayCycleLength/16;
		pub const dayStart = dayCycleLength/2 + dayCycleLength/4 + dayCycleLength/16;

		biomeFog: Fog = Fog{.skyColor = .{0.8, 0.8, 1}, .fogColor = .{0.8, 0.8, 1}, .density = 1.0/15.0/128.0, .fogLower = 100, .fogHigher = 1000},
		fog: Fog = Fog{.skyColor = .{0.8, 0.8, 1}, .fogColor = .{0.8, 0.8, 1}, .density = 1.0/15.0/128.0, .fogLower = 100, .fogHigher = 1000},
		/// Rendered rain intensity ([0, 1]), eased every frame toward World.rainIntensityTarget (see that
		/// field's doc comment) — read by renderer/clouds.zig and renderer/rain.zig.
		rainIntensity: f32 = 0,
		/// Smoothed local rain/snow/dust visibility loss, [0, 1]. Kept separate from precipitation
		/// so weather packets can update at a low rate without fog or daylight stepping.
		weatherVisibility: f32 = 0,
		/// Horizontal weather-fog scale in blocks. Rain deliberately reaches farther than snow; both values
		/// are eased so crossing a weather-cell boundary cannot make the visibility wall jump.
		weatherFogRange: f32 = 96,
		/// Weather needs its own colour memory as well as its smoothed density. Rebuilding the tint from
		/// the clear biome every frame made the horizon snap from storm haze to sky blue on crossing a
		/// weather-cell boundary, even while `weatherVisibility` was still visibly fading out.
		weatherHazeColor: Vec3f = .{0.58, 0.65, 0.74},
		weatherSkyHazeColor: Vec3f = .{0.58, 0.65, 0.74},
		ambientLight: f32 = 0,
		dayTime: i64 = 0,
		/// How far (0-1) between `dayTime`'s current tick and the next, in real time — `dayTime` itself
		/// only advances once every 100ms (see World.update()'s tick loop), so anything sampling it
		/// directly holds a stale value for ~6 frames at 60fps and then jumps. getDayProgress() blends
		/// this fraction in so the sun sweeps continuously instead.
		dayTimeFraction: f32 = 0,

		pub fn getDayProgress(self: *DayTime) f32 {
			return (@as(f32, @floatFromInt(self.dayTime)) + self.dayTimeFraction)/@as(f32, @floatFromInt(dayCycleLength));
		}

		/// Direction pointing from the world toward the sun. Matches the rotation used by the star field
		/// in Skybox.render() so the sun/moon stay visually consistent with the sky: zenith (+Z) at noon
		/// (progress 0), nadir (-Z) at midnight (progress 0.5).
		pub fn getSunDirection(self: *DayTime) Vec3f {
			return vec.rotateX(Vec3f{0, 0, 1}, 2*std.math.pi*self.getDayProgress());
		}

		/// True (unclamped) direction of whichever celestial body is currently above the horizon — same
		/// body selection as getShadowLightDirection(), but without its elevation clamp. Use this wherever
		/// something needs to visually track the sun/moon's *real* position (e.g. god rays converging on
		/// its actual screen position, or fading in lockstep with Skybox's own billboard/horizonFade)
		/// rather than the shading-stabilized direction — getShadowLightDirection()'s clamp intentionally
		/// makes shading disagree with the true position near the horizon, which is exactly wrong for
		/// anything trying to visually follow the sun/moon itself.
		pub fn getVisibleCelestialDirection(self: *DayTime) Vec3f {
			const sunDir = self.getSunDirection();
			return if (sunDir[2] >= 0) sunDir else -sunDir;
		}

		/// Direction of whichever celestial body (sun or moon) is currently above the horizon, for use
		/// as the shadow-casting light direction. Falls back to the sun direction when both are below
		/// the horizon (shouldn't normally happen, but keeps the result well-defined).
		pub fn getShadowLightDirection(self: *DayTime) Vec3f {
			var dir = self.getVisibleCelestialDirection();
			// Clamp light elevation to a minimum of 0.35 (~20.5 degrees) to keep light projections
			// stable and prevent infinite shadow stretching at sunset/sunrise. This also caps how long a
			// caster's shadow can get: shadow length is roughly height/tan(elevation), so 0.35 caps that
			// ratio at ~2.7x the caster's height (0.18, the previous value, allowed ~5.5x — a tall tree
			// could throw a shadow that stretched for tens of blocks at low sun).
			dir[2] = @max(dir[2], 0.35);
			return vec.normalize(dir);
		}

		/// Whether getShadowLightDirection() is currently returning the sun's direction rather than the
		/// moon's. Needed anywhere that treats sun-light and moonlight differently (color, intensity) —
		/// checking getShadowLightDirection()[2] >= 0 does *not* work for this, since both the sun's and
		/// the moon's direction satisfy that whenever *they* are the one currently active/above horizon.
		pub fn isSunlight(self: *DayTime) bool {
			return self.getSunDirection()[2] >= 0;
		}

		/// [0,1] weight: 1.0 = full normal shadow/god-ray strength, 0.0 = faded to a neutral, near-flat
		/// state right at the sun/moon crossing (dayProgress 0.25 = sunset, 0.75 = sunrise). Verified
		/// numerically that getVisibleCelestialDirection()'s `sunDir[2] >= 0` selection flips the active
		/// light's direction by a full 180 degrees in a single frame at exactly this crossing — with no
		/// mitigation, that reads as shadows/god-rays instantly snapping to a new direction instead of
		/// sweeping. Rather than rendering both bodies' shadows simultaneously and cross-fading them (a
		/// bigger change requiring two full CSM render passes to share this project's compute/indirect-
		/// draw GPU buffers within one frame — the same category of shared-GL-state risk that caused the
		/// MSAA shadow-rebind bug earlier this project), this fades shadow/god-ray *strength* down to
		/// near-zero right at the crossing and back up afterward: the direction still flips instantly
		/// underneath, but it does so while shadows are barely visible, hiding the snap inside a brief,
		/// deliberate fade rather than showing it as a hard pop.
		///
		/// Mirrors getSkyColorFactor()/updateAmbientLight()'s windowed-ramp technique, but measures
		/// distance from the CROSSING itself (dayProgress 0.25/0.75), not from midnight (dayCycleLength/2)
		/// like those two — they center on midnight because that's their day/night plateau's center; here
		/// the crossing is what needs softening, not the plateau.
		pub fn getShadowTransitionFade(self: *DayTime) f32 {
			const progress = self.getDayProgress();
			const distFromDawn = @abs(progress - 0.25);
			const distFromDusk = @abs(progress - 0.75);
			const distFromCrossing = @min(distFromDawn, distFromDusk);
			const windowWidth: f32 = 1.0/24.0; // ~1/24 of a full day/night cycle on each side of the crossing.
			if (distFromCrossing >= windowWidth) return 1.0;
			const t = distFromCrossing/windowWidth; // 0 at the crossing itself, 1 at the window edge.
			return t*t*(3.0 - 2.0*t); // smoothstep: eases toward 1.0, zero derivative at both ends.
		}

		pub fn getStarOpacity(self: *DayTime) f32 {
			const dayTime = @abs(self.dayTime - dayCycleLength/2);
			if (dayTime < dayCycleLength/4 - dayCycleLength/16) {
				return 1;
			}
			if (dayTime > dayCycleLength/4 + dayCycleLength/16) {
				return 0;
			}

			return 1 - @as(f32, @floatFromInt(dayTime - (dayCycleLength/4 - dayCycleLength/16)))/@as(f32, @floatFromInt(dayCycleLength/8));
		}

		fn updateAmbientLight(self: *DayTime) void {
			const dayTime = @abs(self.dayTime - dayCycleLength/2);
			if (dayTime < dayCycleLength/4 - dayCycleLength/16) {
				self.ambientLight = 0.1;
				return;
			}
			if (dayTime > dayCycleLength/4 + dayCycleLength/16) {
				self.ambientLight = 1;
				return;
			}

			self.ambientLight = minimumAmbientLight + (1 - minimumAmbientLight)*@as(f32, @floatFromInt(dayTime - (dayCycleLength/4 - dayCycleLength/16)))/@as(f32, @floatFromInt(dayCycleLength/8));
		}

		fn updateTimeOfDay(self: *DayTime) void {
			self.dayTime = @intCast(@mod(world.?.gameTime.load(.monotonic), dayCycleLength));
			// Real time elapsed since the last 100ms tick boundary World.update() advanced past, as a
			// 0-1 fraction of the next tick — see dayTimeFraction's doc comment for why this matters.
			const newTime: i64 = main.timestamp().toMilliseconds();
			const millisSinceTick: f32 = @floatFromInt(newTime -% world.?.milliTime);
			self.dayTimeFraction = std.math.clamp(millisSinceTick/100.0, 0.0, 1.0);
		}

		fn getSkyColorFactor(self: *DayTime) Vec3f {
			const dayTime = @abs(self.dayTime - dayCycleLength/2);
			if (dayTime < dayCycleLength/4 - dayCycleLength/16) {
				return @splat(0);
			}
			if (dayTime > dayCycleLength/4 + dayCycleLength/16) {
				return @splat(1);
			}
			var skyColorFactor: Vec3f = undefined;
			// b:
			if (dayTime > dayCycleLength/4) {
				skyColorFactor[2] = @as(f32, @floatFromInt(dayTime - dayCycleLength/4))/@as(f32, @floatFromInt(dayCycleLength/16));
			} else {
				skyColorFactor[2] = 0;
			}
			// g:
			if (dayTime > dayCycleLength/4 + dayCycleLength/32) {
				skyColorFactor[1] = 1;
			} else if (dayTime > dayCycleLength/4 - dayCycleLength/32) {
				skyColorFactor[1] = 1 - @as(f32, @floatFromInt(dayCycleLength/4 + dayCycleLength/32 - dayTime))/@as(f32, @floatFromInt(dayCycleLength/16));
			} else {
				skyColorFactor[1] = 0;
			}
			// r:
			if (dayTime > dayCycleLength/4) {
				skyColorFactor[0] = 1;
			} else {
				skyColorFactor[0] = 1 - @as(f32, @floatFromInt(dayCycleLength/4 - dayTime))/@as(f32, @floatFromInt(dayCycleLength/16));
			}

			return skyColorFactor;
		}

		pub fn update(self: *DayTime, deltaTime: f64) void {
			self.updateTimeOfDay();
			const biome = world.?.playerBiome.load(.monotonic);

			const t = 1 - @as(f32, @floatCast(@exp(-2*deltaTime)));

			self.biomeFog.fogColor += (biome.fogColor - self.biomeFog.fogColor)*@as(Vec3f, @splat(t));
			self.biomeFog.skyColor += (biome.skyColor - self.biomeFog.skyColor)*@as(Vec3f, @splat(t));
			self.biomeFog.density += (biome.fogDensity - self.biomeFog.density)*t;
			self.biomeFog.fogLower += (biome.fogLower - self.biomeFog.fogLower)*t;
			self.biomeFog.fogHigher += (biome.fogHigher - self.biomeFog.fogHigher)*t;

			const rainIntensityTarget = world.?.rainIntensityTarget.load(.monotonic);
			self.rainIntensity += (rainIntensityTarget - self.rainIntensity)*t;

			const skyColorFactor = self.getSkyColorFactor();
			self.updateAmbientLight();

			self.fog.fogColor = self.biomeFog.fogColor*skyColorFactor;
			self.fog.skyColor = self.biomeFog.skyColor*skyColorFactor;
			self.fog.density = self.biomeFog.density;
			self.fog.fogLower = self.biomeFog.fogLower;
			self.fog.fogHigher = self.biomeFog.fogHigher;
			const clearFogColor = self.fog.fogColor;
			const clearSkyColor = self.fog.skyColor;

			// Sandstorm visibility is local to the same server weather cell that emits dust particles.
			// It must not tint/fog a player standing in a neighbouring clear biome.
			const playerPos = Player.getPosBlocking();
			const localWeather = world.?.weatherGrid.sampleAt(playerPos[0], playerPos[1]);
			// Local cells still retain their server weather above the cloud deck so players below can see
			// the same storm, but this camera is in clear air: weather particles are already altitude-gated
			// in rain.zig, and its fog/dimming counterpart must use the identical gate here.
			const weatherExposure = weatherExposureAtPosition(playerPos);
			const dust = localWeather.dust*weatherExposure;
			const precipitationVisibility = if (localWeather.kind == 1 or localWeather.kind == 2) localWeather.precipitation*weatherExposure else 0.0;
			// WeatherMap commonly produces gentle rain in the 0.05-0.15 range. A linear response made
			// that visually indistinguishable from clear weather, so use a square-root perceptual curve:
			// light rain gains a readable haze while full storms still remain substantially stronger.
			const visibilityTarget = @sqrt(@max(precipitationVisibility, dust));
			self.weatherVisibility += (visibilityTarget - self.weatherVisibility)*t;
			// Deliberately distinct atmosphere palettes. These targets are smoothed independently of
			// the local cell, so walking out of a storm carries its haze into clear air and dissolves it
			// naturally instead of immediately replacing it with the clear-sky colour.
			const weatherHazeTarget: Vec3f = switch (localWeather.kind) {
				1 => .{0.34, 0.43, 0.56}, // rain: cool blue-grey
				2 => .{0.84, 0.89, 0.96}, // snow: pale, neutral-white haze
				3 => .{0.76, 0.52, 0.25}, // dust: warm yellow-orange sand
				else => clearFogColor,
			};
			const weatherSkyHazeTarget: Vec3f = switch (localWeather.kind) {
				1 => .{0.40, 0.50, 0.64},
				2 => .{0.88, 0.93, 0.98},
				3 => .{0.78, 0.56, 0.30},
				else => clearSkyColor,
			};
			const hazeT = 1 - @as(f32, @floatCast(@exp(-1.35*deltaTime)));
			self.weatherHazeColor += (weatherHazeTarget - self.weatherHazeColor)*@as(Vec3f, @splat(hazeT));
			self.weatherSkyHazeColor += (weatherSkyHazeTarget - self.weatherSkyHazeColor)*@as(Vec3f, @splat(hazeT));
			const weatherFogRangeTarget: f32 = switch (localWeather.kind) {
				1 => 96, // rain: preserve more mid-distance visibility than snow.
				2 => 64, // snow: retain the denser, closer white-out requested by the player.
				3 => 56, // dust: sandstorms remain the most locally obscuring weather.
				else => 96,
			};
			self.weatherFogRange += (weatherFogRangeTarget - self.weatherFogRange)*t;
			if (self.weatherVisibility > 0.01) {
				const hazeStrength = std.math.clamp(self.weatherVisibility * 0.92, 0.0, 0.82);
				self.fog.fogColor += (self.weatherHazeColor - self.fog.fogColor)*@as(Vec3f, @splat(hazeStrength));
				self.fog.skyColor += (self.weatherSkyHazeColor - self.fog.skyColor)*@as(Vec3f, @splat(hazeStrength * 0.72));
				// Strong weather hides distant terrain through ordinary depth fog, not an abrupt circular
				// wall. Fog density rises while its upper distance contracts, both eased above.
				self.fog.density *= std.math.lerp(1.0, 30.0, self.weatherVisibility);
				// Dense precipitation removes most direct daylight even at noon. Renderer shadow settings may
				// boost ambient slightly afterward, so this target deliberately leaves a stronger storm dim.
				self.ambientLight *= std.math.lerp(1.0, 0.42, self.weatherVisibility);
			}
		}
	};
};
pub var testWorld: World = undefined; // TODO:
pub var world: ?*World = null;

pub var projectionMatrix: Mat4f = Mat4f.identity();

var nextBlockPlaceTime: ?std.Io.Timestamp = null;
var nextBlockBreakTime: ?std.Io.Timestamp = null;

pub fn pressPlace(mods: main.Window.Key.Modifiers) void {
	const time = main.timestamp();
	nextBlockPlaceTime = time.addDuration(main.settings.updateRepeatDelay);
	Player.placeBlock(mods);
}

pub fn releasePlace(_: main.Window.Key.Modifiers) void {
	nextBlockPlaceTime = null;
}

pub fn pressBreak(_: main.Window.Key.Modifiers) void {
	const time = main.timestamp();
	nextBlockBreakTime = time.addDuration(main.settings.updateRepeatDelay);
	Player.breakBlock(0);
}

pub fn releaseBreak(_: main.Window.Key.Modifiers) void {
	nextBlockBreakTime = null;
}

pub fn pressAcquireSelectedBlock(_: main.Window.Key.Modifiers) void {
	Player.acquireSelectedBlock();
}

pub fn flyToggle(_: main.Window.Key.Modifiers) void {
	if (!Player.isCreative()) return;

	const newIsFlying = !Player.isActuallyFlying();

	Player.isFlying.store(newIsFlying, .monotonic);
	Player.isGhost.store(false, .monotonic);
}

pub fn ghostToggle(_: main.Window.Key.Modifiers) void {
	if (!Player.isCreative()) return;

	const newIsGhost = !Player.isGhost.load(.monotonic);

	Player.isGhost.store(newIsGhost, .monotonic);
	Player.isFlying.store(newIsGhost, .monotonic);
}

pub fn hyperSpeedToggle(_: main.Window.Key.Modifiers) void {
	if (!Player.isCreative()) return;

	Player.hyperSpeed.store(!Player.hyperSpeed.load(.monotonic), .monotonic);
}

pub fn getBlockWithSide(comptime side: main.sync.Side, x: i32, y: i32, z: i32) ?Block {
	if (side == .client) {
		return main.renderer.mesh_storage.getBlockFromRenderThread(x, y, z);
	} else {
		return main.server.world.?.getBlock(x, y, z);
	}
}

pub fn update(deltaTime: f64) void { // MARK: update()
	if (world.?.shouldRestart.load(.acquire)) {
		restart();
	}

	physics.calculateVolumeProperties(.client, &Player.volumeProperties, Player.super.pos, Player.outerBoundingBox, physics.playerAirTerminalVelocity);
	if (Player.isFlying.load(.monotonic)) {
		Player.friction = .{.current = 20, .mobile = 20};
	} else {
		physics.calculateFriction(.client, &Player.volumeProperties, &Player.friction, Player.super.pos, Player.outerBoundingBox, Player.onGround);
	}
	var acc = Vec3d{0, 0, 0};
	const speedMultiplier: f32 = if (Player.hyperSpeed.load(.monotonic)) 4.0 else 1.0;

	const density = if (Player.isFlying.load(.monotonic)) 0.0 else Player.volumeProperties.density;
	const maxDensity = if (Player.isFlying.load(.monotonic)) 0.0 else Player.volumeProperties.maxDensity;

	var jumping = false;
	Player.jumpCooldown -= deltaTime;
	// At equillibrium we want to have dv/dt = a - λv = 0 → a = λ*v
	const fricMul = speedMultiplier*Player.friction.mobile;

	const horizontalForward = vec.rotateZ(Vec3d{0, 1, 0}, -camera.rotation[2]);
	const forward = vec.normalize(std.math.lerp(horizontalForward, camera.direction, @as(Vec3d, @splat(density/@max(1.0, maxDensity)))));
	const right = Vec3d{-horizontalForward[1], horizontalForward[0], 0};
	var movementDir: Vec3d = .{0, 0, 0};

	if (main.Window.grabbed) {
		const walkingSpeed: f64 = if (Player.crouching) 2.5 else 4.5;
		var movementSpeed: f64 = walkingSpeed*@min(1, vec.length(Vec2f{
			@max(KeyBoard.key("forward").value, KeyBoard.key("backward").value),
			@max(KeyBoard.key("left").value, KeyBoard.key("right").value),
		}));
		if (KeyBoard.key("forward").value > 0.0) {
			if (KeyBoard.key("sprint").pressed and !Player.crouching) {
				if (Player.isGhost.load(.monotonic)) {
					movementSpeed = @max(movementSpeed, 128*KeyBoard.key("forward").value);
					movementDir += forward*@as(Vec3d, @splat(128*KeyBoard.key("forward").value));
				} else if (Player.isFlying.load(.monotonic)) {
					movementSpeed = @max(movementSpeed, 32*KeyBoard.key("forward").value);
					movementDir += forward*@as(Vec3d, @splat(32*KeyBoard.key("forward").value));
				} else {
					movementSpeed = @max(movementSpeed, 8*KeyBoard.key("forward").value);
					movementDir += forward*@as(Vec3d, @splat(8*KeyBoard.key("forward").value));
				}
			} else {
				movementDir += forward*@as(Vec3d, @splat(walkingSpeed*KeyBoard.key("forward").value));
			}
		}
		if (KeyBoard.key("backward").value > 0.0) {
			movementDir += forward*@as(Vec3d, @splat(-walkingSpeed*KeyBoard.key("backward").value));
		}
		if (KeyBoard.key("left").value > 0.0) {
			movementDir += right*@as(Vec3d, @splat(walkingSpeed*KeyBoard.key("left").value));
		}
		if (KeyBoard.key("right").value > 0.0) {
			movementDir += right*@as(Vec3d, @splat(-walkingSpeed*KeyBoard.key("right").value));
		}
		if (KeyBoard.key("jump").pressed) {
			if (Player.isFlying.load(.monotonic)) {
				if (KeyBoard.key("sprint").pressed) {
					if (Player.isGhost.load(.monotonic)) {
						movementSpeed = @max(movementSpeed, 60);
						movementDir[2] += 60;
					} else {
						movementSpeed = @max(movementSpeed, 25);
						movementDir[2] += 25;
					}
				} else {
					movementSpeed = @max(movementSpeed, 5.5);
					movementDir[2] += 5.5;
				}
			} else if ((Player.onGround or Player.jumpCoyote > 0.0) and Player.jumpCooldown <= 0) {
				jumping = true;
				Player.jumpCooldown = Player.jumpCooldownConstant;
				if (!Player.onGround) {
					Player.eye.coyote = 0;
				}
				Player.jumpCoyote = 0;
			} else if (!KeyBoard.key("fall").pressed) {
				movementSpeed = @max(movementSpeed, walkingSpeed);
				movementDir[2] += walkingSpeed;
			}
		} else {
			Player.jumpCooldown = 0;
		}
		if (KeyBoard.key("fall").pressed) {
			if (Player.isFlying.load(.monotonic)) {
				if (KeyBoard.key("sprint").pressed) {
					if (Player.isGhost.load(.monotonic)) {
						movementSpeed = @max(movementSpeed, 60);
						movementDir[2] -= 60;
					} else {
						movementSpeed = @max(movementSpeed, 25);
						movementDir[2] -= 25;
					}
				} else {
					movementSpeed = @max(movementSpeed, 5.5);
					movementDir[2] -= 5.5;
				}
			} else if (!KeyBoard.key("jump").pressed) {
				movementSpeed = @max(movementSpeed, walkingSpeed);
				movementDir[2] -= walkingSpeed;
			}
		}

		if (movementSpeed != 0 and vec.lengthSquare(movementDir) != 0) {
			if (vec.lengthSquare(movementDir) > movementSpeed*movementSpeed) {
				movementDir = vec.normalize(movementDir);
			} else {
				movementDir /= @splat(movementSpeed);
			}
			acc += movementDir*@as(Vec3d, @splat(movementSpeed*fricMul));
		}

		const newSlot: i32 = @as(i32, @intCast(Player.selectedSlot)) -% main.Window.scrollOffsetInteger;
		Player.selectedSlot = @intCast(@mod(newSlot, 12));

		const newPos = Vec2f{
			@floatCast(main.KeyBoard.key("cameraRight").value - main.KeyBoard.key("cameraLeft").value),
			@floatCast(main.KeyBoard.key("cameraDown").value - main.KeyBoard.key("cameraUp").value),
		}*@as(Vec2f, @splat(std.math.pi*settings.controllerSensitivity));
		main.game.camera.moveRotation(newPos[0]/64.0, newPos[1]/64.0);
	}

	Player.crouching = main.Window.grabbed and KeyBoard.key("crouch").pressed and !Player.isFlying.load(.monotonic);

	if (physics.collision.collides(.client, .x, 0, Player.super.pos + Player.standingBoundingBoxExtent - Player.crouchingBoundingBoxExtent, .{
		.min = -Player.standingBoundingBoxExtent,
		.max = Player.standingBoundingBoxExtent,
	}) == null) {
		if (Player.onGround) {
			if (Player.crouching) {
				Player.crouchPerc += @floatCast(deltaTime*10);
			} else {
				Player.crouchPerc -= @floatCast(deltaTime*10);
			}
			Player.crouchPerc = std.math.clamp(Player.crouchPerc, 0, 1);
		}

		const smoothPerc = Player.crouchPerc*Player.crouchPerc*(3 - 2*Player.crouchPerc);

		const newOuterBox = (Player.crouchingBoundingBoxExtent - Player.standingBoundingBoxExtent)*@as(Vec3d, @splat(smoothPerc)) + Player.standingBoundingBoxExtent;

		Player.super.pos += newOuterBox - Player.outerBoundingBoxExtent + Vec3d{0.0, 0.0, 0.0001*@abs(newOuterBox[2] - Player.outerBoundingBoxExtent[2])};

		Player.outerBoundingBoxExtent = newOuterBox;

		Player.outerBoundingBox = .{
			.min = -Player.outerBoundingBoxExtent,
			.max = Player.outerBoundingBoxExtent,
		};
		Player.eye.box = .{
			.min = -Vec3d{Player.outerBoundingBoxExtent[0]*0.2, Player.outerBoundingBoxExtent[1]*0.2, Player.outerBoundingBoxExtent[2] - 0.2},
			.max = Vec3d{Player.outerBoundingBoxExtent[0]*0.2, Player.outerBoundingBoxExtent[1]*0.2, Player.outerBoundingBoxExtent[2] - 0.05},
		};
		Player.eye.desiredPos = (Vec3d{0, 0, 1.3 - Player.crouchingBoundingBoxExtent[2]} - Vec3d{0, 0, 1.7 - Player.standingBoundingBoxExtent[2]})*@as(Vec3f, @splat(smoothPerc)) + Vec3d{0, 0, 1.7 - Player.standingBoundingBoxExtent[2]};
	}

	const gravity: f64 = if (Player.isFlying.load(.monotonic)) 0.0 else physics.baseGravity;
	const jumpHeight: f64 = if (jumping) Player.jumpHeight else 0.0;
	var motion = physics.calculateMotion(.client, deltaTime, Player.friction, Player.volumeProperties, physics.playerDensity, Player.super.pos, &Player.super.vel, acc, gravity, jumpHeight);

	{
		Player.mutex.lock();
		defer Player.mutex.unlock();

		var stepAmount: f64 = 0.0;
		if (!Player.isGhost.load(.monotonic)) {
			const steppingHeightLimit = Player.eye.pos[2] - Player.eye.box.min[2];
			stepAmount = physics.calculateWallCollision(.client, &motion, &Player.super.pos, &Player.super.vel, &Player.onGround, Player.friction, Player.outerBoundingBox, Player.steppingHeight()[2], steppingHeightLimit, Player.crouching);
		}
		physics.calculateEyeMovement(.client, deltaTime, Player.super.pos, Player.super.vel, &Player.eye, stepAmount);
		var didCollide: bool = false;
		const wasOnGround = Player.onGround;
		const prevPos = Player.super.pos;
		const prevVel = Player.super.vel;
		if (!Player.isGhost.load(.monotonic)) {
			const bouncinessMultiplier: f64 = if (Player.isFlying.load(.monotonic)) 0.0 else if (Player.crouching) 0.5 else 1.0;
			didCollide = physics.calculateVerticalCollision(.client, deltaTime, &Player.super.pos, &Player.super.vel, &Player.jumpCoyote, &Player.onGround, Player.outerBoundingBox, motion, bouncinessMultiplier);
			if (didCollide) {
				const velocityChange = @abs(@abs(prevVel[2]) - @abs(Player.super.vel[2]));
				const damage: f32 = @floatCast(@round(@max((velocityChange*velocityChange)/(2*physics.baseGravity) - 7, 0))/2);
				if (damage > 0.01) {
					main.sync.addHealth(-damage, .fall, .client, Player.id);
				}
			}
			physics.calculateVerticalCollisionEyeMovement(deltaTime, &Player.eye, didCollide, Player.onGround, wasOnGround, prevPos, Player.super.pos, prevVel, Player.super.vel, motion, Player.steppingHeight()[2]);
			physics.collision.touchBlocks(.client, &Player.super, Player.outerBoundingBox, deltaTime);
		} else {
			Player.super.pos += motion;
		}

		Player.eye.pos = @max(Player.eye.box.min, @min(Player.eye.pos, Player.eye.box.max));
		Player.eye.coyote -= deltaTime;
		Player.jumpCoyote -= deltaTime;
	}

	const time = main.timestamp();
	if (nextBlockPlaceTime) |*placeTime| {
		if (placeTime.durationTo(time).nanoseconds >= 0) {
			placeTime.* = placeTime.addDuration(main.settings.updateRepeatSpeed);
			Player.placeBlock(main.KeyBoard.key("placeBlock").modsOnPress);
		}
	}
	if (nextBlockBreakTime) |*breakTime| {
		if (breakTime.durationTo(time).nanoseconds >= 0 or !Player.isCreative()) {
			breakTime.* = breakTime.addDuration(main.settings.updateRepeatSpeed);
			Player.breakBlock(deltaTime);
		}
	}

	world.?.update(deltaTime);
	particles.ParticleSystem.update(@floatCast(deltaTime));
}
pub fn restart() void {
	if (world) |_world| {
		_world.pause();

		network.protocols.reload.informServerOfRestart(_world.conn);

		_world.@"continue"() catch |err| {
			std.log.err("Encountered error while opening world: {s}", .{@errorName(err)});
			main.gui.windowlist.notification.raiseNotification("Encountered error while opening world: {s}", .{@errorName(err)});
			world = null;

			main.gui.openWindow("main");
			return;
		};
		main.gui.openHud();
	}
}
