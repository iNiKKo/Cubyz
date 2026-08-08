const std = @import("std");

const main = @import("main");
const settings = main.settings;
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const CheckBox = @import("../components/CheckBox.zig");
const ContinuousSlider = @import("../components/ContinuousSlider.zig");
const DiscreteSlider = @import("../components/DiscreteSlider.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow{
	.contentSize = Vec2f{128, 256},
	.closeIfMouseIsGrabbed = true,
};

const padding: f32 = 16;

const antiAliasingModes = [_][]const u8{"Off", "FXAA", "MSAA", "TAA"};
const graphicsPlusPresets = [_][]const u8{"OFF", "BALANCED", "ULTRA"};
var refreshAfterPresetChange = false;

fn graphicsPlusPresetCallback(newValue: u16) void {
	const preset: settings.GraphicsPlusPreset = @enumFromInt(newValue);
	settings.graphicsPlusPreset = preset;

	switch (preset) {
		.off => {
			settings.antiAliasingMode = .off;
			settings.msaaSamples = 2;
			settings.bloom = false;
			settings.reflectionMode = .off;
			settings.reflections = false;
			settings.waterReflectionDistance = 32.0;
			settings.shadows = false;
			settings.ownPlayerShadow = false;
			settings.shadowDarkness = 0.50;
			settings.shadowDistance = 32.0;
			settings.shadowRaySteps = 32;
			settings.foliageShadows = false;
			settings.foliageSway = false;
			settings.clouds = false;
			settings.cloudDistance = 64.0;
			settings.godRays = false;
			settings.godRayIntensity = 0.0;
			settings.rain = false;
			settings.weatherFog = false;
		},
		.balanced => {
			settings.antiAliasingMode = .msaa;
			settings.msaaSamples = 2;
			settings.bloom = true;
			settings.reflectionMode = .ssr;
			settings.reflections = true;
			settings.waterReflectionDistance = 600.0;
			settings.shadows = true;
			settings.ownPlayerShadow = true;
			settings.shadowDarkness = 0.50;
			settings.shadowDistance = 120.0;
			settings.shadowRaySteps = 265;
			settings.foliageShadows = false;
			settings.foliageSway = true;
			settings.clouds = true;
			settings.cloudDistance = 1150.0;
			settings.godRays = true;
			settings.godRayIntensity = 1.0;
			settings.rain = true;
			settings.weatherFog = false;
		},
		.ultra => {
			settings.antiAliasingMode = .taa;
			settings.msaaSamples = 8;
			settings.bloom = true;
			settings.reflectionMode = .planar;
			settings.reflections = true;
			settings.waterReflectionDistance = 2048.0;
			settings.shadows = true;
			settings.ownPlayerShadow = true;
			settings.shadowDarkness = 0.50;
			settings.shadowDistance = 512.0;
			settings.shadowRaySteps = 512;
			settings.foliageShadows = true;
			settings.foliageSway = true;
			settings.clouds = true;
			settings.cloudDistance = 2048.0;
			settings.godRays = true;
			settings.godRayIntensity = 2.0;
			settings.rain = true;
			settings.weatherFog = true;
		},
	}

	settings.save();
	refreshAfterPresetChange = true;
}

fn antiAliasingCallback(newValue: u16) void {
	settings.antiAliasingMode = @enumFromInt(newValue);
	settings.save();
}

const msaaSampleCounts = [_]u8{2, 4, 8};

fn msaaSamplesCallback(newValue: u16) void {
	settings.msaaSamples = msaaSampleCounts[newValue];
	settings.save();
}

fn bloomCallback(newValue: bool) void {
	settings.bloom = newValue;
	settings.save();
}

const reflectionModes = [_][]const u8{"Off", "SSR", "Planar"};

fn reflectionModeCallback(newValue: u16) void {
	settings.reflectionMode = @enumFromInt(newValue);
	settings.reflections = settings.reflectionMode != .off;
	settings.save();
}

fn waterReflectionDistanceFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffWater Reflection Distance: {d:.0}m", .{@round(value)});
}

fn waterReflectionDistanceCallback(newValue: f32) void {
	settings.waterReflectionDistance = @round(newValue);
	settings.save();
}

fn shadowsCallback(newValue: bool) void {
	settings.shadows = newValue;
	settings.save();
}

fn ownPlayerShadowCallback(newValue: bool) void {
	settings.ownPlayerShadow = newValue;
	settings.save();
}

fn shadowDistanceFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffDynamic Shadow Distance: {d:.0}m", .{@round(value)});
}

fn shadowDistanceCallback(newValue: f32) void {
	settings.shadowDistance = @round(newValue);
	settings.save();
}

fn shadowRayStepsFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffShadow Quality: {d:.0}", .{@round(value)});
}

fn shadowRayStepsCallback(newValue: f32) void {
	settings.shadowRaySteps = @intFromFloat(@round(newValue));
	settings.save();
}

fn foliageShadowsCallback(newValue: bool) void {
	settings.foliageShadows = newValue;
	settings.save();
}

fn foliageSwayCallback(newValue: bool) void {
	settings.foliageSway = newValue;
	settings.save();
}

fn cloudsCallback(newValue: bool) void {
	settings.clouds = newValue;
	settings.save();
}

fn cloudDistanceFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffCloud Distance: {d:.0}", .{@round(value)});
}

fn cloudDistanceCallback(newValue: f32) void {
	settings.cloudDistance = @round(newValue);
	settings.save();
}

fn godRaysCallback(newValue: bool) void {
	settings.godRays = newValue;
	settings.save();
}

fn godRayIntensityFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffGod Ray Intensity: {d:.1}", .{value});
}

fn godRayIntensityCallback(newValue: f32) void {
	settings.godRayIntensity = newValue;
	settings.save();
}

fn rainCallback(newValue: bool) void {
	settings.rain = newValue;
	settings.save();
}

fn weatherFogCallback(newValue: bool) void {
	settings.weatherFog = newValue;
	settings.save();
}

fn shadowDarknessFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffShadow Darkness: {d:.0}%", .{value * 100.0});
}

fn shadowDarknessCallback(newValue: f32) void {
	settings.shadowDarkness = newValue;
	settings.save();
}

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, 380, 16);
	list.add(DiscreteSlider.init(.{0, 0}, 200, "#ffffffGraphics+ Preset: ", "{s}", &graphicsPlusPresets, @intFromEnum(settings.graphicsPlusPreset), &graphicsPlusPresetCallback));
	list.add(DiscreteSlider.init(.{0, 0}, 200, "#ffffffAnti-Aliasing: ", "{s}", &antiAliasingModes, @intFromEnum(settings.antiAliasingMode), &antiAliasingCallback));
	list.add(DiscreteSlider.init(.{0, 0}, 200, "#ffffffMSAA Samples: ", "{}x", &msaaSampleCounts, switch (settings.msaaSamples) {
		2 => 0,
		4 => 1,
		8 => 2,
		else => 1,
	}, &msaaSamplesCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "Bloom", settings.bloom, &bloomCallback));
	list.add(DiscreteSlider.init(.{0, 0}, 200, "#ffffffReflections: ", "{s}", &reflectionModes, @intFromEnum(settings.reflectionMode), &reflectionModeCallback));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 32.0, 2048.0, settings.waterReflectionDistance, &waterReflectionDistanceCallback, &waterReflectionDistanceFormatter));
	list.add(CheckBox.init(.{0, 0}, 200, "Shadows", settings.shadows, &shadowsCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "Own Player Shadow", settings.ownPlayerShadow, &ownPlayerShadowCallback));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 0.0, 1.0, settings.shadowDarkness, &shadowDarknessCallback, &shadowDarknessFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 32.0, 512.0, settings.shadowDistance, &shadowDistanceCallback, &shadowDistanceFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 32.0, 512.0, @floatFromInt(settings.shadowRaySteps), &shadowRayStepsCallback, &shadowRayStepsFormatter));
	list.add(CheckBox.init(.{0, 0}, 200, "Grass Shadows", settings.foliageShadows, &foliageShadowsCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "Foliage Sway", settings.foliageSway, &foliageSwayCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "Clouds", settings.clouds, &cloudsCallback));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 64.0, 2048.0, settings.cloudDistance, &cloudDistanceCallback, &cloudDistanceFormatter));
	list.add(CheckBox.init(.{0, 0}, 200, "God Rays", settings.godRays, &godRaysCallback));
	list.add(ContinuousSlider.init(.{0, 0}, 200, 0.0, 3.0, settings.godRayIntensity, &godRayIntensityCallback, &godRayIntensityFormatter));
	list.add(CheckBox.init(.{0, 0}, 200, "Rain", settings.rain, &rainCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "Weather Fog", settings.weatherFog, &weatherFogCallback));
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn update() void {
	if (refreshAfterPresetChange) {
		refreshAfterPresetChange = false;
		onClose();
		onOpen();
	}
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
}
