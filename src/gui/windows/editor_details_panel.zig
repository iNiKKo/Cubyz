const std = @import("std");
const main = @import("main");
const Vec2f = main.vec.Vec2f;
const draw = main.graphics.draw;
const EditorGizmo = main.renderer.EditorGizmo;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const Label = @import("../components/Label.zig");
const VerticalList = @import("../components/VerticalList.zig");

const content_browser = @import("editor_content_browser.zig");

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .upper, .otherAttachmentPoint = .upper}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
	},
	.contentSize = Vec2f{320, 360},
	.showTitleBar = false,
	.hideIfMouseIsGrabbed = false,
	.closeable = false,
	.renderFn = &renderResizeHandle,
};

const padding: f32 = 6;
const handleThickness: f32 = 5;
const smallFont: f32 = 10;

var dragging: bool = false;
var draggingHovered: bool = false;
var dragStartMouseX: f32 = 0;
var dragStartWidth: f32 = 0;

var locationLabel: ?*Label = null;
var locationTextBuf: [64]u8 = undefined;
var rotationLabel: ?*Label = null;
var rotationTextBuf: [32]u8 = undefined;

fn locationText() []const u8 {
	const info = EditorGizmo.selectedDisplayInfo() orelse return "Location: -";
	switch (info) {
		.block => |pos| return std.fmt.bufPrint(&locationTextBuf, "Location: {} {} {}", .{pos[0], pos[1], pos[2]}) catch "Location: ?",
		.entityPos => |pos| return std.fmt.bufPrint(&locationTextBuf, "Location: {d:.1} {d:.1} {d:.1}", .{pos[0], pos[1], pos[2]}) catch "Location: ?",
	}
}

fn rotationText() []const u8 {
	return std.fmt.bufPrint(&rotationTextBuf, "Rotation: {}°", .{EditorGizmo.cumulativeRotationDegrees}) catch "Rotation: ?";
}

fn ensureLayoutMetrics() void {
	const screen = main.Window.getWindowSize()/@as(Vec2f, @splat(gui.scale));
	content_browser.ensureDockSizes(screen);
	const height = @max(180.0, screen[1] - content_browser.toolbarHeight);
	const centerY = content_browser.toolbarHeight + height*0.5;
	window.contentSize = .{content_browser.detailsWidth, height};
	window.relativePosition[1] = .{.ratio = centerY/screen[1]};
}

pub fn onOpen() void {
	ensureLayoutMetrics();
	const list = VerticalList.init(.{handleThickness + padding, padding}, 800, 3);
	list.add(Label.initWithFontSize(.{0, 0}, 240, "Details", .left, smallFont));
	const location = Label.initWithFontSize(.{0, 0}, 280, locationText(), .left, smallFont);
	locationLabel = location;
	list.add(location);
	const rotation = Label.initWithFontSize(.{0, 0}, 280, rotationText(), .left, smallFont);
	rotationLabel = rotation;
	list.add(rotation);
	window.rootComponent = list.toComponent();
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	locationLabel = null;
	rotationLabel = null;
	dragging = false;
}

/// Hit-tests and handles the left-edge drag handle in framebuffer/window mouse space directly,
/// bypassing the normal component tree since the handle straddles the window's own left edge.
fn updateResizeDrag() void {
	const mousePos = main.Window.getMousePosition()/@as(Vec2f, @splat(gui.scale));
	const overHandle = mousePos[1] >= window.pos[1] and mousePos[1] <= window.pos[1] + window.size[1] and
		mousePos[0] >= window.pos[0] and mousePos[0] <= window.pos[0] + handleThickness;
	draggingHovered = overHandle;

	if (!dragging) {
		if (overHandle and main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = true;
			dragStartMouseX = mousePos[0];
			dragStartWidth = content_browser.detailsWidth;
		}
	} else {
		if (!main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = false;
			content_browser.setDetailsWidthOverride(content_browser.detailsWidth);
			content_browser.saveDockSizesPublic();
		} else {
			const delta = mousePos[0] - dragStartMouseX;
			content_browser.setDetailsWidthOverride(dragStartWidth - delta);
			ensureLayoutMetrics();
			gui.updateWindowPositions();
		}
	}
}

fn renderResizeHandle() void {
	const oldColor = draw.setColor(if (dragging or draggingHovered) 0xffa0c0ff else 0xff606060);
	defer draw.restoreColor(oldColor);
	draw.rect(.{0, 0}, .{handleThickness, window.contentSize[1]});
}

pub fn update() void {
	if (locationLabel) |label| {
		label.updateText(locationText());
	}
	if (rotationLabel) |label| {
		label.updateText(rotationText());
	}
	const oldSize = window.contentSize;
	const oldRelPos = window.relativePosition[1];
	ensureLayoutMetrics();
	if (@reduce(.Or, oldSize != window.contentSize) or !std.meta.eql(oldRelPos, window.relativePosition[1])) {
		gui.updateWindowPositions();
	}
	updateResizeDrag();
}
