const main = @import("main");
const game = main.game;
const Vec2f = main.vec.Vec2f;
const draw = main.graphics.draw;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const HorizontalList = @import("../components/HorizontalList.zig");

const content_browser = @import("editor_content_browser.zig");

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
	},
	.contentSize = Vec2f{320, 28},
	.showTitleBar = false,
	.hideIfMouseIsGrabbed = false,
	.closeable = false,
	.renderFn = &renderResizeHandle,
};

const padding: f32 = 4;
const handleThickness: f32 = 5;
const smallFont: f32 = 10;

var simButton: ?*Button = null;
var moveButton: ?*Button = null;
var rotateButton: ?*Button = null;

var dragging: bool = false;
var draggingHovered: bool = false;
var dragStartMouseY: f32 = 0;
var dragStartHeight: f32 = 0;

fn ensureLayoutMetrics() void {
	const screen = main.Window.getWindowSize()/@as(Vec2f, @splat(gui.scale));
	content_browser.ensureDockSizes(screen);
	window.contentSize = .{screen[0], content_browser.toolbarHeight};
}

fn simButtonLabel() []const u8 {
	return if (game.devSimulationPaused.load(.monotonic)) "Sim: OFF" else "Sim: ON";
}

fn leaveEditor() void {
	if (!game.Player.editorMode.load(.monotonic)) return;
	game.editorModeToggle(.{});
}

fn toggleSim() void {
	game.toggleSimulationPause();
	update();
}

fn moveButtonLabel() []const u8 {
	return if (main.renderer.EditorGizmo.mode == .move) "[Move]" else "Move";
}
fn rotateButtonLabel() []const u8 {
	return if (main.renderer.EditorGizmo.mode == .rotate) "[Rotate]" else "Rotate";
}

fn setMoveMode() void {
	main.renderer.EditorGizmo.mode = .move;
	update();
}
fn setRotateMode() void {
	main.renderer.EditorGizmo.mode = .rotate;
	update();
}

pub fn onOpen() void {
	content_browser.loadDockSizes();
	ensureLayoutMetrics();
	const list = HorizontalList.init();
	list.add(Button.initText(.{0, 0}, 70, "Play", .{.onAction = .init(leaveEditor)}));
	const button = Button.initText(.{0, 0}, 100, simButtonLabel(), .{.onAction = .init(toggleSim)});
	simButton = button;
	list.add(button);
	const move = Button.initText(.{0, 0}, 70, moveButtonLabel(), .{.onAction = .init(setMoveMode)});
	moveButton = move;
	list.add(move);
	const rotate = Button.initText(.{0, 0}, 70, rotateButtonLabel(), .{.onAction = .init(setRotateMode)});
	rotateButton = rotate;
	list.add(rotate);
	list.finish(.{padding, padding}, .center);
	window.rootComponent = list.toComponent();
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	simButton = null;
	moveButton = null;
	rotateButton = null;
	dragging = false;
}

/// Hit-tests and handles the bottom-edge drag handle in framebuffer/window mouse space
/// directly, bypassing the normal component tree since the handle straddles the window's
/// own bottom edge (shared with the 3D viewport's top edge).
fn updateResizeDrag() void {
	const mousePos = main.Window.getMousePosition()/@as(Vec2f, @splat(gui.scale));
	const handleTop = window.pos[1] + window.size[1] - handleThickness;
	const handleBottom = window.pos[1] + window.size[1];
	const overHandle = mousePos[0] >= window.pos[0] and mousePos[0] <= window.pos[0] + window.size[0] and
		mousePos[1] >= handleTop and mousePos[1] <= handleBottom;
	draggingHovered = overHandle;

	if (!dragging) {
		if (overHandle and main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = true;
			dragStartMouseY = mousePos[1];
			dragStartHeight = content_browser.toolbarHeight;
		}
	} else {
		if (!main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = false;
			content_browser.setToolbarHeightOverride(content_browser.toolbarHeight);
			content_browser.saveDockSizesPublic();
		} else {
			const delta = mousePos[1] - dragStartMouseY;
			content_browser.setToolbarHeightOverride(dragStartHeight + delta);
			ensureLayoutMetrics();
			gui.updateWindowPositions();
		}
	}
}

fn renderResizeHandle() void {
	const oldColor = draw.setColor(if (dragging or draggingHovered) 0xffa0c0ff else 0xff606060);
	defer draw.restoreColor(oldColor);
	draw.rect(.{0, window.contentSize[1] - handleThickness}, .{window.contentSize[0], handleThickness});
}

/// Refreshes the sim-pause button label if the server broadcast a paused-state change while the toolbar is open.
pub fn update() void {
	const oldSize = window.contentSize;
	ensureLayoutMetrics();
	if (@reduce(.Or, oldSize != window.contentSize)) {
		gui.updateWindowPositions();
	}
	if (simButton) |button| {
		button.child.label.updateText(simButtonLabel());
	}
	if (moveButton) |button| {
		button.child.label.updateText(moveButtonLabel());
	}
	if (rotateButton) |button| {
		button.child.label.updateText(rotateButtonLabel());
	}
	updateResizeDrag();
}
