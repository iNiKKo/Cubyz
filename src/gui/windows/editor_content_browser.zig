const std = @import("std");
const main = @import("main");
const Vec2f = main.vec.Vec2f;
const ZonElement = main.ZonElement;
const draw = main.graphics.draw;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const Label = @import("../components/Label.zig");
const Button = @import("../components/Button.zig");
const Icon = @import("../components/Icon.zig");
const HorizontalList = @import("../components/HorizontalList.zig");
const VerticalList = @import("../components/VerticalList.zig");
const StructureBuildingBlock = main.server.terrain.sbb.StructureBuildingBlock;
const structure_preview = main.server.terrain.structure_preview;

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

/// Arms a structure drag when its row button is clicked; actual placement happens on
/// mouse-release over the 3D world (see gui.structureDrag in ../gui.zig).
fn armStructure(structure: *const StructureBuildingBlock) void {
	gui.structureDrag.arm(structure.id);
}

const tileWidth: f32 = 64;
const tileHeight: f32 = 64;
const tileSpacing: f32 = 4;
const scrollBarWidth: f32 = 10 + 2*3;

/// Lazily-generated, process-lifetime cache of structure thumbnail textures keyed by structure id
/// (which is stable/interned in main.worldArena for as long as the world is loaded - see sbb.zig).
/// Generating one is a full offscreen render pass - doing this for the whole registry (100+
/// structures) synchronously in one frame (e.g. the moment the browser first opens) caused a
/// multi-second stall/lag spiral. Instead, every not-yet-ready tile's icon is sized to zero (so it
/// draws nothing - see makeTile()) and its structure gets queued in pendingThumbnails; update()
/// drains a small budget of that queue per frame (see thumbnailBudgetPerFrame) so the cost is
/// spread across many frames instead of one. (A shared placeholder GL texture was tried first, but
/// every tile going blank at the exact same instant pointed at GL texture-id lifecycle/reuse risk
/// from sharing one texture object across ~150 icons - safer to just not touch a texture at all
/// until the real one exists.)
var thumbnailCache: std.StringHashMapUnmanaged(main.graphics.Texture) = .{};
const thumbnailBudgetPerFrame: u32 = 2;

fn generateThumbnail(structure: *const StructureBuildingBlock) main.graphics.Texture {
	const preview = structure_preview.assemble(main.globalAllocator, structure);
	defer preview.deinit(main.globalAllocator);
	return main.graphics.generateStructureTexture(preview.buffer, preview.extent);
}

fn makeTile(structure: *const StructureBuildingBlock) struct {button: *Button, icon: *Icon} {
	const ready = thumbnailCache.get(structure.id);
	// Texture id 0 is GL's always-valid "no texture" binding - a safe placeholder for the
	// not-ready case, where icon.size is also zero so nothing actually gets drawn with it.
	const icon = Icon.init(.{0, 0}, if (ready != null) .{tileWidth - 6, tileHeight - 6} else .{0, 0}, ready orelse .{.textureID = 0});
	const button = main.globalAllocator.create(Button);
	button.* = Button{
		.pos = .{0, 0},
		.size = .{tileWidth, tileHeight},
		.onAction = .initWithPtr(armStructure, @constCast(structure)),
		.child = icon.toComponent(),
	};
	return .{.button = button, .icon = icon};
}

/// (button, icon, structure) for every tile currently built: update() uses Button.hovered (see
/// updateHoveredTooltip()) for the tooltip, and swaps each Icon's texture in place once its
/// thumbnail finishes generating (see updatePendingThumbnails()).
var tiles: main.ListManaged(struct {button: *Button, icon: *Icon, structure: *const StructureBuildingBlock}) = .init(main.globalAllocator);
var hoveredTileId: ?[]const u8 = null;
/// Structures whose thumbnail hasn't been generated (or queued) yet - drained a few at a time
/// per frame by updatePendingThumbnails().
var pendingThumbnails: main.ListManaged(*const StructureBuildingBlock) = .init(main.globalAllocator);

fn updatePendingThumbnails() void {
	var remaining = thumbnailBudgetPerFrame;
	while (remaining > 0 and pendingThumbnails.items.len > 0) : (remaining -= 1) {
		const structure = pendingThumbnails.pop();
		if (thumbnailCache.contains(structure.id)) continue;

		const texture = generateThumbnail(structure);
		thumbnailCache.put(main.globalAllocator.allocator, structure.id, texture) catch unreachable;

		for (tiles.items) |tile| {
			if (tile.structure == structure) {
				tile.icon.updateTexture(texture) catch unreachable;
				tile.icon.size = .{tileWidth - 6, tileHeight - 6};
				break;
			}
		}
	}
}

/// (Re)builds the tile grid to match the panel's current size. Cheap to call again on resize:
/// thumbnails already in thumbnailCache aren't regenerated, only the layout (column count, list
/// height) is rederived - the previous VerticalList (if any) is fully torn down first, matching
/// what onClose() does, so nothing leaks across a rebuild.
fn rebuildTiles() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	tiles.clearAndFree();
	pendingThumbnails.clearAndFree();

	const labelHeight = smallFont + 3;
	const listMaxHeight = @max(tileHeight, window.contentSize[1] - handleThickness - 2*padding - labelHeight);
	const list = VerticalList.init(.{padding, handleThickness + padding}, listMaxHeight, 3);
	list.add(Label.initWithFontSize(.{0, 0}, 240, "Content Browser - Structures", .left, smallFont));

	// Reserve room for the vertical scrollbar up front (rather than only after rows overflow),
	// so it lines up flush against the panel's real right edge instead of sitting right after
	// however wide the tile rows happen to be.
	const columns: usize = @max(1, @as(usize, @intFromFloat(@floor((window.contentSize[0] - 2*padding - scrollBarWidth + tileSpacing)/(tileWidth + tileSpacing)))));

	var row: ?*HorizontalList = null;
	var columnIndex: usize = 0;
	for (main.server.terrain.sbb.list()) |*structure| {
		if (row == null) row = HorizontalList.init();
		const tile = makeTile(structure);
		tiles.append(.{.button = tile.button, .icon = tile.icon, .structure = structure});
		if (!thumbnailCache.contains(structure.id)) pendingThumbnails.append(structure);
		row.?.add(tile.button);
		columnIndex += 1;
		if (columnIndex >= columns) {
			row.?.finish(.{0, 0}, .left);
			list.add(row.?.toComponent());
			row = null;
			columnIndex = 0;
		}
	}
	if (row) |r| {
		r.finish(.{0, 0}, .left);
		list.add(r.toComponent());
	}

	list.finish(.left);
	window.rootComponent = list.toComponent();
	gui.updateWindowPositions();
}

pub fn onOpen() void {
	loadDockSizes();
	ensureLayoutMetrics();
	rebuildTiles();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
	tiles.clearAndFree();
	pendingThumbnails.clearAndFree();
	hoveredTileId = null;
	dragging = false;
}

/// Runs between the hover-detection pass and the render pass (see update() below), so
/// Button.hovered still reflects this frame's hit-test before render() consumes/clears it.
fn updateHoveredTooltip() void {
	hoveredTileId = null;
	for (tiles.items) |tile| {
		if (tile.button.hovered) {
			hoveredTileId = tile.structure.id;
			break;
		}
	}
}

/// gui.tooltip.renderFromText() expects screen-absolute coordinates, but this is called from
/// renderResizeHandle() while GuiWindow.render() has an active window-local translation - reset
/// to absolute space temporarily (mirroring how nested GuiComponents save/restore translation)
/// so the tooltip doesn't get double-offset by the window's own position.
fn renderTooltip() void {
	const id = hoveredTileId orelse return;
	const mousePos = main.Window.getMousePosition()/@as(Vec2f, @splat(gui.scale));
	const currentTranslation = main.graphics.draw.setTranslation(.{0, 0});
	main.graphics.draw.restoreTranslation(.{0, 0});
	defer main.graphics.draw.restoreTranslation(currentTranslation);
	gui.tooltip.renderFromText(id, mousePos);
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
	renderTooltip();
}

pub fn update() void {
	const oldSize = window.contentSize;
	ensureLayoutMetrics();
	if (@reduce(.Or, oldSize != window.contentSize)) {
		// The tile grid's column count and the VerticalList's own maxHeight (which drives its
		// scrollbar range/clip rect) are both derived from window.contentSize once at build time -
		// without a rebuild here, resizing the panel changes the window itself but leaves the list
		// still clipping/scrolling against its old, stale height, which looks like the content
		// sliding out from under the panel rather than the panel actually resizing around it.
		rebuildTiles();
		gui.updateWindowPositions();
	}
	updateResizeDrag();
	updateHoveredTooltip();
	updatePendingThumbnails();
}
