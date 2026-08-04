const std = @import("std");

const main = @import("main");
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window: GuiWindow = GuiWindow{
	.contentSize = Vec2f{128, 256},
	.closeIfMouseIsGrabbed = true,
};

const padding: f32 = 12;

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, 380, 18);
	list.add(Button.initText(.{0, 0}, 200, "Graphics", .{.onAction = gui.openWindowCallback("graphics")}));
	list.add(Button.initText(.{0, 0}, 200, "Graphics+", .{.onAction = gui.openWindowCallback("graphics_plus")}));
	list.add(Button.initText(.{0, 0}, 200, "Audio", .{.onAction = gui.openWindowCallback("audio")}));
	list.add(Button.initText(.{0, 0}, 200, "Controls", .{.onAction = gui.openWindowCallback("controls")}));
	list.add(Button.initText(.{0, 0}, 200, "Advanced Controls", .{.onAction = gui.openWindowCallback("advanced_controls")}));
	list.add(Button.initText(.{0, 0}, 200, "Social", .{.onAction = gui.openWindowCallback("social")}));
	list.add(Button.initText(.{0, 0}, 200, "Debug", .{.onAction = gui.openWindowCallback("debug_settings")}));
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
