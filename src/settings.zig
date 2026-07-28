const std = @import("std");
const builtin = @import("builtin");

const main = @import("main");
const ZonElement = main.ZonElement;
const Window = @import("graphics/Window.zig");

pub const version = @import("utils/version.zig");

pub const defaultPort: u16 = 47649;
pub const connectionTimeout = 60_000_000;

pub const entityLookback: i16 = 100;

pub const highestSupportedLod: u3 = 5;

pub var lastVersionString: []const u8 = "";

pub var simulationDistance: u16 = 4;

pub var cpuThreads: ?u64 = null;

pub var anisotropicFiltering: u8 = 4.0;

pub var fpsCap: ?u32 = null;

pub var fov: f32 = 70;

pub var mouseSensitivity: f32 = 1;
pub var controllerSensitivity: f32 = 1;

pub var invertMouseY: bool = false;

pub var renderDistance: u16 = 12;

pub var highestLod: u3 = highestSupportedLod;

pub var resolutionScale: f32 = 1.0;
pub var fsrSharpness: f32 = 0.5;

pub const UpscalerMode = enum(u8) { off, fsr1, fsr2 };
pub var upscalerMode: UpscalerMode = .fsr1;

pub const AntiAliasingMode = enum(u8) { off, fxaa, msaa, taa };
pub var antiAliasingMode: AntiAliasingMode = .fxaa;

pub var bloom: bool = true;

pub var reflections: bool = true;

pub var shadows: bool = true;

/// Controls how dark terrain shadows are (0.0 = no shadows/fully lit, 0.50 = normal default shadows, 1.0 = extra dark shadows).
pub var shadowDarkness: f32 = 0.50;

/// Max sun/moon shadow ray length, in blocks (see shadow.glsl's sampleSunShadow) — a raymarch distance
/// cap, not a shadow-map coverage radius.
pub var shadowDistance: f32 = 128.0;

/// DDA step cap for the sun/moon shadow raymarch (see shadow.glsl) — counts both coarse (4x4x4-block)
/// and fine (per-voxel) steps combined, bounding worst-case per-pixel cost. The coarse skip only lowers
/// the *typical* cost (most of a ray is empty air); the worst case (dense occupancy the whole way) still
/// needs close to shadowDistance*1.75 steps, so this shouldn't be set much below that or rays will give
/// up before reaching real occluders — see shadow.glsl's sampleSunShadow for why that reads as patchy,
/// missing-in-random-places shadows rather than a clean quality falloff.
pub var shadowRaySteps: i32 = 256;

/// Whether grass/flowers/mushrooms/etc. (`viewThrough` blocks that aren't leaves — leaves always cast a
/// full solid shadow regardless of this setting, see chunk_meshing.zig's uploadOccupancy) cast a shadow
/// at all. When on, the shadow raymarch gives them a soft, compounding partial shadow (see shadow.glsl's
/// foliageAttenuationPerVoxel) rather than a hard hit — off by default since even that reads as somewhat
/// busy/noisy for dense grass; on gives it a shadow instead of none at all.
pub var foliageShadows: bool = false;

pub var clouds: bool = true;

pub var cloudDistance: f32 = 512.0;

pub var godRays: bool = true;

pub var godRayIntensity: f32 = 1.0;

/// Instant on/off toggle for a first, deliberately simple rain effect: real falling raindrop quads (see
/// renderer/rain.zig) spawned only in an AOE grid around the player — not a full weather system (no
/// gradual transitions, no per-biome/climate logic, no puddles/wetness, no sound yet).
pub var rain: bool = false;

pub var vsync: bool = true;

pub var playerName: []const u8 = "";

pub var showPlayerIndexWithName: bool = false;

pub var streamerMode: bool = false;

pub var lastUsedIPAddress: []const u8 = "";

pub var storedAccount: main.network.authentication.PasswordEncodedAccountCode = .empty;

pub var guiScale: ?f32 = null;

pub var musicVolume: f32 = 1;

pub var leavesQuality: u16 = 2;

pub var @"lod0.5Distance": f32 = 200;

pub var blockContrast: f32 = 0;

pub var nightBrightness: f32 = 0.5;

pub var storageTime: std.Io.Duration = .fromSeconds(5);

pub var updateRepeatSpeed: std.Io.Duration = .fromMilliseconds(200);

pub var updateRepeatDelay: std.Io.Duration = .fromMilliseconds(500);

pub var controllerAxisDeadzone: f32 = 0.2;

const settingsFile = if (builtin.mode == .Debug) "debug_settings.zig.zon" else "settings.zig.zon";

pub fn init() void {
	const zon: ZonElement = main.files.cubyzDir().readToZon(main.stackAllocator, settingsFile) catch |err| blk: {
		if (err != error.FileNotFound) {
			std.log.err("Could not read settings file: {s}", .{@errorName(err)});
		}
		break :blk .null;
	};
	defer zon.deinit(main.stackAllocator);

	inline for (@typeInfo(@This()).@"struct".decls) |decl| runtimeContinueInsideOfComptimeBlock: {
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			comptime var DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .optional) {
				DeclType = @typeInfo(DeclType).optional.child;
			}
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) {
					const defaultMilli = @as(f64, @floatFromInt(@field(@This(), decl.name).toNanoseconds()))/1.0e6;
					@field(@This(), decl.name) = .fromNanoseconds(@trunc((zon.get(f64, decl.name) orelse defaultMilli)*1.0e6));
					continue;
				}
				@field(@This(), decl.name) = DeclType.fromZon(main.globalAllocator, zon.getChild(decl.name)) catch |err| {
					std.log.err("Got error while loading setting {s}: {s}", .{decl.name, @errorName(err)});
					break :runtimeContinueInsideOfComptimeBlock;
				};
				continue;
			}
			@field(@This(), decl.name) = zon.get(DeclType, decl.name) orelse @field(@This(), decl.name);
			if (@typeInfo(DeclType) == .pointer) {
				if (@typeInfo(DeclType).pointer.size == .slice) {
					@field(@This(), decl.name) = main.globalAllocator.dupe(@typeInfo(DeclType).pointer.child, @field(@This(), decl.name));
				} else {
					@compileError("Not implemented yet.");
				}
			}
		}
	}

	if (resolutionScale < 0.25 or resolutionScale > 1.0) resolutionScale = 1.0;
	if (fsrSharpness < 0.0 or fsrSharpness > 1.0) fsrSharpness = 0.2;

	// keyboard settings:
	const keyboard = zon.getChild("keyboard");
	for (&main.KeyBoard.keys) |*key| {
		const keyZon = keyboard.getChild(key.name);
		key.key = keyZon.get(c_int, "key") orelse key.key;
		key.mouseButton = keyZon.get(c_int, "mouseButton") orelse key.mouseButton;
		key.scancode = keyZon.get(c_int, "scancode") orelse key.scancode;
		if (key.isToggling != .never) {
			key.isToggling = std.meta.stringToEnum(Window.Key.IsToggling, keyZon.get([]const u8, "isToggling") orelse "") orelse key.isToggling;
		}
	}
}

pub fn deinit() void {
	save();
	inline for (@typeInfo(@This()).@"struct".decls) |decl| {
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			const DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) continue;
				@field(@This(), decl.name).deinit(main.globalAllocator);
				continue;
			}
			if (@typeInfo(DeclType) == .pointer) {
				if (@typeInfo(DeclType).pointer.size == .slice) {
					main.globalAllocator.free(@field(@This(), decl.name));
				} else {
					@compileError("Not implemented yet.");
				}
			}
		}
	}
}

pub fn save() void {
	var zonObject = ZonElement.initObject(main.stackAllocator);
	defer zonObject.deinit(main.stackAllocator);

	inline for (@typeInfo(@This()).@"struct".decls) |decl| {
		if (comptime std.mem.eql(u8, decl.name, "lastVersionString")) {
			zonObject.put(decl.name, version.version);
			continue;
		}
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			const DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) {
					zonObject.put(decl.name, @as(f64, @floatFromInt(@field(@This(), decl.name).toNanoseconds()))/1.0e6);
					continue;
				}
				zonObject.put(decl.name, @field(@This(), decl.name).toZon(main.stackAllocator));
				continue;
			}
			if (DeclType == []const u8) {
				zonObject.putOwnedString(decl.name, @field(@This(), decl.name));
			} else {
				zonObject.put(decl.name, @field(@This(), decl.name));
			}
		}
	}

	// keyboard settings:
	const keyboard = ZonElement.initObject(main.stackAllocator);
	for (&main.KeyBoard.keys) |key| {
		const keyZon = ZonElement.initObject(main.stackAllocator);
		keyZon.put("key", key.key);
		keyZon.put("mouseButton", key.mouseButton);
		keyZon.put("scancode", key.scancode);
		if (key.isToggling != .never) {
			keyZon.put("isToggling", @tagName(key.isToggling));
		}
		keyboard.put(key.name, keyZon);
	}
	zonObject.put("keyboard", keyboard);

	// Merge with the old settings file to preserve unknown settings.
	var oldZonObject: ZonElement = main.files.cubyzDir().readToZon(main.stackAllocator, settingsFile) catch |err| blk: {
		if (err != error.FileNotFound) {
			std.log.err("Could not read settings file: {s}", .{@errorName(err)});
		}
		break :blk .null;
	};
	defer oldZonObject.deinit(main.stackAllocator);

	if (oldZonObject == .object) {
		zonObject.join(.preferLeft, oldZonObject);
	}

	main.files.cubyzDir().writeZon(settingsFile, zonObject) catch |err| {
		std.log.err("Couldn't write settings to file: {s}", .{@errorName(err)});
	};
}

pub const launchConfig = struct {
	pub var cubyzDir: []const u8 = "";
	pub var autoEnterWorld: []const u8 = "";
	pub var headlessServer: bool = false;
	pub var preferredAuthenticationAlgorithm: main.network.authentication.KeyTypeEnum = .ed25519;

	pub var vulkanTestingMode: bool = false;

	pub fn init() void {
		const zon: ZonElement = main.files.cwd().readToZon(main.stackAllocator, "launchConfig.zon") catch |err| blk: {
			std.log.err("Could not read launchConfig.zon: {s}", .{@errorName(err)});
			break :blk .null;
		};
		defer zon.deinit(main.stackAllocator);

		cubyzDir = main.globalArena.dupe(u8, zon.get([]const u8, "cubyzDir") orelse cubyzDir);
		headlessServer = zon.get(bool, "headlessServer") orelse headlessServer;
		autoEnterWorld = main.globalArena.dupe(u8, zon.get([]const u8, "autoEnterWorld") orelse autoEnterWorld);
		preferredAuthenticationAlgorithm = zon.get(main.network.authentication.KeyTypeEnum, "preferredAuthenticationAlgorithm") orelse preferredAuthenticationAlgorithm;
		vulkanTestingMode = zon.get(bool, "vulkanTestingMode") orelse false;
	}
};

pub const environment = struct {
	pub var SDL_GAMECONTROLLERCONFIG: ?[]const u8 = null;

	pub var env: std.process.Environ = undefined;

	pub fn init(_env: std.process.Environ) void {
		env = _env;
		SDL_GAMECONTROLLERCONFIG = env.getAlloc(main.globalArena.allocator, "SDL_GAMECONTROLLERCONFIG") catch null;
	}
};
