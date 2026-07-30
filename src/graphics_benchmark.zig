const std = @import("std");

const main = @import("main");
const settings = main.settings;

const warmupSeconds: f64 = 12.0;
const settleSeconds: f64 = 2.0;
const sampleSeconds: f64 = 6.0;

const Test = enum { baseline, fxaa, taa, bloom, reflections, shadows, foliage_shadows, foliage_sway, clouds, god_rays };
const tests = [_]Test{ .baseline, .fxaa, .taa, .bloom, .reflections, .shadows, .foliage_shadows, .foliage_sway, .clouds, .god_rays };

const Result = struct { name: []const u8, average_fps: f64, average_frame_ms: f64 };
const SavedSettings = struct {
	antiAliasingMode: settings.AntiAliasingMode, bloom: bool, reflections: bool, foliageSway: bool,
	waterReflectionDistance: f32, shadows: bool, ownPlayerShadow: bool, foliageShadows: bool,
	clouds: bool, godRays: bool, rain: bool, fpsCap: ?u32, vsync: bool, hideGui: bool,
};
const State = enum { idle, waiting_for_world, warming_up, settling, sampling, complete };

var state: State = .idle;
var savedSettings: SavedSettings = undefined;
var timer: f64 = 0.0;
var testIndex: usize = 0;
var totalFrameTime: f64 = 0.0;
var sampleCount: u32 = 0;
var results: [tests.len]Result = undefined;
var benchmarkWorldName: []const u8 = "unknown";
var benchmarkWorldSeed: u64 = 0;

/// Arms a run while the benchmark world is opened. The run starts after the client joins it.
pub fn armForBenchmarkWorld(worldName: []const u8, worldSeed: u64) void {
	if (state != .idle and state != .complete) return;
	benchmarkWorldName = worldName;
	benchmarkWorldSeed = worldSeed;
	state = .waiting_for_world;
	std.log.info("Graphics benchmark armed: loading the fixed seed world, then warming up for {d:.0}s.", .{warmupSeconds});
}

/// Useful for repeating a measurement after already loading the benchmark world.
pub fn startCurrentWorld() void {
	if (state != .idle and state != .complete) return;
	if (main.game.world == null) {
		std.log.warn("Cannot start graphics benchmark without a loaded world.", .{});
		return;
	}
	begin();
}

pub fn isRunning() bool {
	return state != .idle and state != .complete;
}

pub fn update(deltaTime: f64) void {
	switch (state) {
		.idle, .complete => return,
		.waiting_for_world => {
			if (main.game.world != null) begin();
			return;
		},
		.warming_up => {
			timer += deltaTime;
			if (timer >= warmupSeconds) beginTest();
		},
		.settling => {
			timer += deltaTime;
			if (timer >= settleSeconds) {
				timer = 0.0;
				totalFrameTime = 0.0;
				sampleCount = 0;
				state = .sampling;
			}
		},
		.sampling => {
			const frameTime = main.lastFrameTime.load(.monotonic);
			if (frameTime > 0.0 and frameTime < 0.25) {
				totalFrameTime += frameTime;
				sampleCount += 1;
			}
			timer += deltaTime;
			if (timer >= sampleSeconds) finishTest();
		},
	}
}

fn begin() void {
	savedSettings = .{
		.antiAliasingMode = settings.antiAliasingMode, .bloom = settings.bloom, .reflections = settings.reflections,
		.foliageSway = settings.foliageSway, .waterReflectionDistance = settings.waterReflectionDistance,
		.shadows = settings.shadows, .ownPlayerShadow = settings.ownPlayerShadow, .foliageShadows = settings.foliageShadows,
		.clouds = settings.clouds, .godRays = settings.godRays, .rain = settings.rain, .fpsCap = settings.fpsCap,
		.vsync = settings.vsync, .hideGui = main.gui.hideGui,
	};
	settings.fpsCap = null;
	settings.vsync = false;
	main.Window.reloadSettings();
	main.gui.hideGui = true;
	applyBaseline();
	timer = 0.0;
	testIndex = 0;
	state = .warming_up;
	std.log.info("Graphics benchmark started. GUI, VSync, and FPS cap are temporarily disabled; do not move the camera.", .{});
}

fn applyBaseline() void {
	settings.antiAliasingMode = .off;
	settings.bloom = false;
	settings.reflections = false;
	settings.foliageSway = false;
	settings.waterReflectionDistance = 32.0;
	settings.shadows = false;
	settings.ownPlayerShadow = false;
	settings.foliageShadows = false;
	settings.clouds = false;
	settings.godRays = false;
	settings.rain = false;
}

fn beginTest() void {
	applyBaseline();
	const benchmarkTest = tests[testIndex];
	switch (benchmarkTest) {
		.baseline => {}, .fxaa => settings.antiAliasingMode = .fxaa, .taa => settings.antiAliasingMode = .taa,
		.bloom => settings.bloom = true, .reflections => settings.reflections = true, .shadows => settings.shadows = true,
		.foliage_shadows => { settings.shadows = true; settings.foliageShadows = true; },
		.foliage_sway => settings.foliageSway = true, .clouds => settings.clouds = true, .god_rays => settings.godRays = true,
	}
	timer = 0.0;
	state = .settling;
	std.log.info("Graphics benchmark: testing {s}.", .{testName(benchmarkTest)});
}

fn finishTest() void {
	const averageFrameTime = if (sampleCount == 0) 0.0 else totalFrameTime / @as(f64, @floatFromInt(sampleCount));
	results[testIndex] = .{ .name = testName(tests[testIndex]), .average_frame_ms = averageFrameTime * 1000.0, .average_fps = if (totalFrameTime == 0.0) 0.0 else @as(f64, @floatFromInt(sampleCount)) / totalFrameTime };
	std.log.info("Graphics benchmark: {s}: {d:.1} FPS, {d:.2} ms.", .{ results[testIndex].name, results[testIndex].average_fps, results[testIndex].average_frame_ms });
	testIndex += 1;
	if (testIndex == tests.len) finish() else beginTest();
}

fn finish() void {
	settings.antiAliasingMode = savedSettings.antiAliasingMode;
	settings.bloom = savedSettings.bloom;
	settings.reflections = savedSettings.reflections;
	settings.foliageSway = savedSettings.foliageSway;
	settings.waterReflectionDistance = savedSettings.waterReflectionDistance;
	settings.shadows = savedSettings.shadows;
	settings.ownPlayerShadow = savedSettings.ownPlayerShadow;
	settings.foliageShadows = savedSettings.foliageShadows;
	settings.clouds = savedSettings.clouds;
	settings.godRays = savedSettings.godRays;
	settings.rain = savedSettings.rain;
	settings.fpsCap = savedSettings.fpsCap;
	settings.vsync = savedSettings.vsync;
	main.Window.reloadSettings();
	main.gui.hideGui = savedSettings.hideGui;
	state = .complete;
	writeReport();
	std.log.info("Graphics benchmark complete. Results were saved to the Cubyz data logs folder.", .{});
}

fn writeReport() void {
	main.files.cubyzDir().makePath("logs") catch |err| {
		std.log.err("Could not create benchmark log folder: {s}", .{@errorName(err)});
		return;
	};
	var report: main.List(u8) = .empty;
	defer report.clearAndFree(main.globalAllocator);
	report.print(main.globalAllocator, "Cubyz graphics benchmark\nWorld: {s} (seed {})\nWarm-up: {d:.0}s; per test: {d:.0}s settle + {d:.0}s sample\n\n", .{ benchmarkWorldName, benchmarkWorldSeed, warmupSeconds, settleSeconds, sampleSeconds });
	report.print(main.globalAllocator, "{s: <20} {s: >12} {s: >14}\n", .{ "Test", "Average FPS", "Frame time" });
	for (results) |result| report.print(main.globalAllocator, "{s: <20} {d: >10.1} {d: >11.2} ms\n", .{ result.name, result.average_fps, result.average_frame_ms });
	report.print(main.globalAllocator, "\nEach feature is measured independently over the same disabled-effects baseline. MSAA is omitted because changing its framebuffer sample count requires a renderer restart; rain is omitted because weather is intentionally world-state dependent.\n", .{});
	const reportPath = main.stackAllocator.print("logs/{s}.txt", .{benchmarkWorldName});
	defer main.stackAllocator.free(reportPath);
	main.files.cubyzDir().write(reportPath, report.items) catch |err| std.log.err("Could not write graphics benchmark report: {s}", .{@errorName(err)});
}

fn testName(benchmarkTest: Test) []const u8 {
	return switch (benchmarkTest) {
		.baseline => "Baseline", .fxaa => "FXAA", .taa => "TAA", .bloom => "Bloom", .reflections => "SSR reflections",
		.shadows => "Dynamic shadows", .foliage_shadows => "Foliage shadows", .foliage_sway => "Foliage sway", .clouds => "Clouds", .god_rays => "God rays",
	};
}
