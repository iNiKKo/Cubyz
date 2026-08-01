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
const levelMask: u16 = 0x7;
const shapeValidBit: u16 = 0x8000;
const variantsPerLevel: u32 = 625;

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
fn scaleTopDown(quad: *QuadInfo, pos_x_pos_y: f32, neg_x_pos_y: f32, pos_x_neg_y: f32, neg_x_neg_y: f32) void {
	for (&quad.corners) |*corner| {
		if (corner[2] >= 0.999) {
			corner[2] = if (corner[0] >= 0.5)
				if (corner[1] >= 0.5) pos_x_pos_y else pos_x_neg_y
			else
				if (corner[1] >= 0.5) neg_x_pos_y else neg_x_neg_y;
		}
	}
}

fn levelHeight(level: u16) f32 {
	return @as(f32, @floatFromInt(@min(level, levels)))/@as(f32, @floatFromInt(levels));
}

fn shapeIndex(level: u16, pos_x_pos_y: u16, neg_x_pos_y: u16, pos_x_neg_y: u16, neg_x_neg_y: u16) u32 {
	return ((((@as(u32, @min(level, levels) - 1)*5 + @min(pos_x_pos_y, levels))*5 + @min(neg_x_pos_y, levels))*5 + @min(pos_x_neg_y, levels))*5 + @min(neg_x_neg_y, levels));
}

fn packedCornerLevel(data: u16, shift: u4, fallback: u16) u16 {
	if (data & shapeValidBit == 0) return fallback;
	return @min((data >> shift) & levelMask, levels);
}

pub fn createBlockModel(_: Block, _: *u16, zon: ZonElement) ModelIndex {
	const modelId = zon.as([]const u8) orelse "cubyz:cube";
	const baseModel = main.models.getModelIndex(modelId).model();
	var firstIndex: ?ModelIndex = null;
	for (1..levels + 1) |_| {
		for (0..levels + 1) |pos_x_pos_y| {
			for (0..levels + 1) |neg_x_pos_y| {
				for (0..levels + 1) |pos_x_neg_y| {
					for (0..levels + 1) |neg_x_neg_y| {
						const index = baseModel.transformModel(scaleTopDown, .{
							levelHeight(@intCast(pos_x_pos_y)),
							levelHeight(@intCast(neg_x_pos_y)),
							levelHeight(@intCast(pos_x_neg_y)),
							levelHeight(@intCast(neg_x_neg_y)),
						});
						if (firstIndex == null) firstIndex = index;
					}
				}
			}
		}
	}
	return firstIndex.?;
}

pub fn model(block: Block) ModelIndex {
	const base_level = if (block.data & levelMask == 0) levels else @min(block.data & levelMask, levels);
	const pos_x_pos_y = packedCornerLevel(block.data, 3, base_level);
	const neg_x_pos_y = packedCornerLevel(block.data, 6, base_level);
	const pos_x_neg_y = packedCornerLevel(block.data, 9, base_level);
	const neg_x_neg_y = packedCornerLevel(block.data, 12, base_level);
	return blocks.meshes.modelIndexStart(block).add(shapeIndex(base_level, pos_x_pos_y, neg_x_pos_y, pos_x_neg_y, neg_x_neg_y));
}
