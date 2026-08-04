const std = @import("std");

const main = @import("main");
const game = main.game;
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
	},
	.contentSize = Vec2f{160, 96},
	.showTitleBar = false,
	.hideIfMouseIsGrabbed = false,
	.closeable = false,
};

const padding: f32 = 16;

var simButton: ?*Button = null;

fn simButtonLabel() []const u8 {
	return if (game.devSimulationPaused.load(.monotonic)) "Simulation: Paused" else "Simulation: Running";
}

fn toggleSim() void {
	game.toggleSimulationPause();
	update();
}

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, 250, 8);
	const button = Button.initText(.{0, 0}, 220, simButtonLabel(), .{.onAction = .init(toggleSim)});
	simButton = button;
	list.add(button);
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	simButton = null;
}

/// Refreshes the sim-pause button label if the server broadcast a paused-state change while the toolbar is open.
pub fn update() void {
	if (simButton) |button| {
		button.child.deinit();
		const label = GuiComponent.Label.init(undefined, button.size[0] - 9, simButtonLabel(), .center);
		button.child = label.toComponent();
	}
}
