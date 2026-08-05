const std = @import("std");
const main = @import("main");
const Vec2f = main.vec.Vec2f;
const ZonElement = main.ZonElement;
const draw = main.graphics.draw;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const Label = @import("../components/Label.zig");
const HorizontalList = @import("../components/HorizontalList.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var toolbarHeight: f32 = 28;
pub var browserHeight: f32 = 220;
pub var detailsWidth: f32 = 320;

/// User-dragged overrides, in GUI-space units. Null until the user drags a resize handle,
/// at which point ensureDockSizes() prefers this over the auto-fit fraction of screen size.
var browserHeightOverride: ?f32 = null;
var detailsWidthOverride: ?f32 = null;
var toolbarHeightOverride: ?f32 = null;

/// Called by editor_details_panel.zig while the user drags its left-edge resize handle.
pub fn setDetailsWidthOverride(width: f32) void {
	detailsWidthOverride = width;
}

/// Called by editor_toolbar.zig while the user drags its bottom-edge resize handle.
pub fn setToolbarHeightOverride(height: f32) void {
	toolbarHeightOverride = height;
}

pub fn saveDockSizesPublic() void {
	saveDockSizes();
}

const minBrowserHeight: f32 = 60;
const maxBrowserHeightFraction: f32 = 0.7;
const minDetailsWidth: f32 = 160;
const maxDetailsWidthFraction: f32 = 0.7;
const minToolbarHeight: f32 = 20;
const maxToolbarHeightFraction: f32 = 0.3;

/// Docked panels are sized in GUI-space units, but GUI-space shrinks as `gui.scale` grows
/// on higher-resolution screens (windowSize = framebuffer/scale). Without this, fixed sizes
/// like 220/320 can eat most of the GUI-space screen and leave no room for the 3D viewport.
/// Clamp each dock to a fraction of the current screen instead of a fixed constant, unless
/// the user has manually dragged a size for it.
pub fn ensureDockSizes(screen: Vec2f) void {
	if (browserHeightOverride) |override| {
		browserHeight = std.math.clamp(override, minBrowserHeight, screen[1]*maxBrowserHeightFraction);
	} else {
		browserHeight = std.math.clamp(screen[1]*0.22, 120.0, 220.0);
	}
	if (detailsWidthOverride) |override| {
		detailsWidth = std.math.clamp(override, minDetailsWidth, screen[0]*maxDetailsWidthFraction);
	} else {
		detailsWidth = std.math.clamp(screen[0]*0.2, 300.0, 320.0);
	}
	if (toolbarHeightOverride) |override| {
		toolbarHeight = std.math.clamp(override, minToolbarHeight, screen[1]*maxToolbarHeightFraction);
	} else {
		toolbarHeight = 28;
	}
}

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .upper, .otherAttachmentPoint = .upper}},
	},
	.contentSize = Vec2f{640, 220},
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
var dragStartMouseY: f32 = 0;
var dragStartHeight: f32 = 0;

pub fn loadDockSizes() void {
	const zon: ZonElement = main.files.cubyzDir().readToZon(main.stackAllocator, "editor_dock_sizes.zig.zon") catch |err| blk: {
		if (err != error.FileNotFound) {
			std.log.err("Could not read editor_dock_sizes.zig.zon: {s}", .{@errorName(err)});
		}
		break :blk .null;
	};
	defer zon.deinit(main.stackAllocator);
	if (zon == .object) {
		browserHeightOverride = zon.get(f32, "browserHeight");
		detailsWidthOverride = zon.get(f32, "detailsWidth");
		toolbarHeightOverride = zon.get(f32, "toolbarHeight");
	}
}

fn saveDockSizes() void {
	var zon = ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	if (toolbarHeightOverride) |v| zon.put("toolbarHeight", v);
	if (browserHeightOverride) |v| zon.put("browserHeight", v);
	if (detailsWidthOverride) |v| zon.put("detailsWidth", v);
	main.files.cubyzDir().writeZon("editor_dock_sizes.zig.zon", zon) catch |err| {
		std.log.err("Could not write editor_dock_sizes.zig.zon: {s}", .{@errorName(err)});
	};
}

fn ensureLayoutMetrics() void {
	const screen = main.Window.getWindowSize()/@as(Vec2f, @splat(gui.scale));
	ensureDockSizes(screen);
	const width = @max(320.0, screen[0] - detailsWidth);
	window.contentSize = .{width, browserHeight};
}

pub fn onOpen() void {
	loadDockSizes();
	ensureLayoutMetrics();
	const list = VerticalList.init(.{padding, handleThickness + padding}, 300, 3);
	list.add(Label.initWithFontSize(.{0, 0}, 240, "Content Browser", .left, smallFont));
	const tabs = HorizontalList.init();
	tabs.add(Label.initWithFontSize(.{0, 0}, 60, "Assets", .left, smallFont));
	tabs.add(Label.initWithFontSize(.{0, 0}, 60, "Blocks", .left, smallFont));
	tabs.add(Label.initWithFontSize(.{0, 0}, 60, "Items", .left, smallFont));
	tabs.finish(.{0, 0}, .left);
	list.add(tabs.toComponent());
	window.rootComponent = list.toComponent();
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	dragging = false;
}

/// Hit-tests and handles the top-edge drag handle in framebuffer/window mouse space directly,
/// bypassing the normal component tree since the handle straddles the window's own top edge.
fn updateResizeDrag() void {
	const mousePos = main.Window.getMousePosition()/@as(Vec2f, @splat(gui.scale));
	const overHandle = mousePos[0] >= window.pos[0] and mousePos[0] <= window.pos[0] + window.size[0] and
		mousePos[1] >= window.pos[1] and mousePos[1] <= window.pos[1] + handleThickness;
	draggingHovered = overHandle;

	if (!dragging) {
		if (overHandle and main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = true;
			dragStartMouseY = mousePos[1];
			dragStartHeight = browserHeight;
		}
	} else {
		if (!main.KeyBoard.key("mainGuiButton").pressed) {
			dragging = false;
			browserHeightOverride = browserHeight;
			saveDockSizes();
		} else {
			const delta = dragStartMouseY - mousePos[1];
			browserHeightOverride = dragStartHeight + delta;
			ensureLayoutMetrics();
			gui.updateWindowPositions();
		}
	}
}

fn renderResizeHandle() void {
	const oldColor = draw.setColor(if (dragging or draggingHovered) 0xffa0c0ff else 0xff606060);
	defer draw.restoreColor(oldColor);
	draw.rect(.{0, 0}, .{window.contentSize[0], handleThickness});
}

pub fn update() void {
	const oldSize = window.contentSize;
	ensureLayoutMetrics();
	if (@reduce(.Or, oldSize != window.contentSize)) {
		gui.updateWindowPositions();
	}
	updateResizeDrag();
}
