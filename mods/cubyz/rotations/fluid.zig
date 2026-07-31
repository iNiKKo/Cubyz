const main = @import("main");
const blocks = main.blocks;
const Block = blocks.Block;
const ModelIndex = main.models.ModelIndex;
const QuadInfo = main.models.QuadInfo;
const ZonElement = main.ZonElement;

pub fn init() void {}
pub fn deinit() void {}
pub fn reset() void {}

/// How many baked height variants exist, matching fluid_spread.zig's `sourceLevel` (the highest level a
/// fluid block can have). Levels 1..sourceLevel each get their own shorter-block model; level 0 never
/// persists (fluid_spread.zig normalizes it away) so it doesn't need a variant of its own.
const levels: u16 = 4;

/// Freshly placed fluid blocks (e.g. via the creative menu, which uses this as its default `data` when
/// none is specified) start as a PERMANENT source, not merely full-strength flowing water - these are two
/// different data values in fluid_spread.zig (sourceLevel = levels + 1) specifically so a block that's
/// merely been topped up to full strength by a waterfall can still decay once its supply is cut, while an
/// actual placed/world-gen source never does. Kept as a separate `levels + 1` expression here (not
/// cross-imported) to avoid a circular dependency: fluid_spread.zig is under src/callbacks (depends on
/// `main`), while this file is a rotation mode `main` itself depends on - the two must be kept in sync by
/// hand if either numbering changes.
pub const naturalStandard: u16 = levels + 1;

/// Lowers every corner that sits at the block's top face (z==1) down to `height`, leaving the bottom
/// face and the lower portion of side faces untouched - this is what makes lower fluid levels render as
/// progressively shorter blocks instead of full cubes, matching Minecraft's flowing-water look.
fn scaleTopDown(quad: *QuadInfo, height: f32) void {
	for (&quad.corners) |*corner| {
		if (corner[2] >= 0.999) corner[2] = height;
	}
}

pub fn createBlockModel(_: Block, _: *u16, zon: ZonElement) ModelIndex {
	const modelId = zon.as([]const u8) orelse "cubyz:cube";
	const baseModel = main.models.getModelIndex(modelId).model();
	var firstIndex: ?ModelIndex = null;
	for (1..levels + 1) |level| {
		const height: f32 = @as(f32, @floatFromInt(level))/@as(f32, @floatFromInt(levels));
		const index = baseModel.transformModel(scaleTopDown, .{height});
		if (firstIndex == null) firstIndex = index;
	}
	return firstIndex.?;
}

pub fn model(block: Block) ModelIndex {
	// data is 1..levels (0 never persists - fluid_spread.zig normalizes it to sourceLevel on first touch).
	const level = if (block.data == 0) levels else @min(block.data, levels);
	return blocks.meshes.modelIndexStart(block).add(@intCast(level - 1));
}
