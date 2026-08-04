const std = @import("std");

const main = @import("main");
const settings = main.settings;
const Vec2f = main.vec.Vec2f;

const NeverFailingAllocator = main.heap.NeverFailingAllocator;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const CheckBox = @import("../components/CheckBox.zig");
const ContinuousSlider = @import("../components/ContinuousSlider.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow{
	.contentSize = Vec2f{128, 256},
	.closeIfMouseIsGrabbed = true,
};

const padding: f32 = 16;

fn mobNameTagsCallback(newValue: bool) void {
	settings.showMobNameTags = newValue;
	settings.save();
}

fn firstPersonBodyCallback(newValue: bool) void {
	settings.firstPersonBody = newValue;
	settings.save();
}

fn handVelocitySwayScaleCallback(newValue: f32) void {
	settings.handVelocitySwayScale = newValue;
	settings.save();
}
fn handVelocitySwayScaleFormatter(allocator: NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("Hand Velocity Sway: {d:.2}", .{value});
}

const HandStage = enum {down, forward, up};

fn stageLabel(stage: HandStage) []const u8 {
	return switch (stage) {
		.down => "Down",
		.forward => "Forward",
		.up => "Up",
	};
}

fn settingPtr(stage: HandStage) *f32 {
	return switch (stage) {
		.down => &settings.handRestAngleDown,
		.forward => &settings.handRestAngleForward,
		.up => &settings.handRestAngleUp,
	};
}

fn HandSliderCallbacks(comptime stage: HandStage) type {
	return struct {
		fn callback(newValue: f32) void {
			settingPtr(stage).* = newValue;
			settings.save();
		}
		fn formatter(allocator: NeverFailingAllocator, value: f32) []const u8 {
			return allocator.print("{s} Rest Angle: {d:.2}", .{stageLabel(stage), value});
		}
	};
}

fn addHandStageSliders(list: *VerticalList, comptime stage: HandStage) void {
	const funcs = HandSliderCallbacks(stage);
	list.add(ContinuousSlider.init(.{0, 0}, 280, -1.57, 1.57, settingPtr(stage).*, &funcs.callback, &funcs.formatter));
}

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, 300, 16);
	list.add(CheckBox.init(.{0, 0}, 200, "Mob Name Tags", settings.showMobNameTags, &mobNameTagsCallback));
	list.add(CheckBox.init(.{0, 0}, 200, "First-Person Body", settings.firstPersonBody, &firstPersonBodyCallback));
	list.add(ContinuousSlider.init(.{0, 0}, 280, 0.0, 3.0, settings.handVelocitySwayScale, &handVelocitySwayScaleCallback, &handVelocitySwayScaleFormatter));
	addHandStageSliders(list, .down);
	addHandStageSliders(list, .forward);
	addHandStageSliders(list, .up);
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
}
