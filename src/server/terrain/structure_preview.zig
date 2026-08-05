const std = @import("std");

const main = @import("main");
const Vec3i = main.vec.Vec3i;
const sbb = main.server.terrain.sbb;
const Neighbor = main.chunk.Neighbor;
const Block = main.blocks.Block;
const Array3D = main.utils.Array3D;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

/// Mirrors src/server/command/worldedit/placestructure.zig's computeStructureBounds() exactly -
/// computes the world-space (here: preview-space) bounding box of a fully assembled structure
/// without writing any blocks, so the preview buffer can be sized correctly up front.
fn computeBounds(min: *Vec3i, max: *Vec3i, structure: *const sbb.StructureBuildingBlock, placementPosition: Vec3i, placementDirection: ?Neighbor, rotation: sbb.Rotation, seed: *u64) void {
	const blueprints = &(structure.getBlueprints(seed).* orelse return);

	const origin = blueprints[0].originBlock;
	const blueprintRotation = rotation.apply(alignDirections(origin.direction(), placementDirection orelse origin.direction()) catch return);
	const rotated = &blueprints[@intFromEnum(blueprintRotation.fixed)];
	const rotatedOrigin = rotated.originBlock.pos();
	const pastePosition = placementPosition - rotatedOrigin - (placementDirection orelse origin.direction()).relPos();

	min.* = @min(min.*, pastePosition);
	max.* = @max(max.*, pastePosition +% rotated.blueprint.extent());

	for (rotated.childBlocks) |childBlock| {
		const child = structure.getChildStructure(childBlock) orelse continue;
		const childRotation = blueprintRotation.getChildRotation(seed, child.rotation, childBlock.direction());
		computeBounds(min, max, child, pastePosition + childBlock.pos(), childBlock.direction(), childRotation, seed);
	}
}

/// Mirrors placestructure.zig's placeStructure() exactly, but writes into an in-memory Array3D
/// buffer (preview-local coordinates, offset by `bufferMin`) instead of the live world - used to
/// build a fully-assembled composite structure for thumbnail rendering.
fn assembleInto(buffer: Array3D(Block), bufferMin: Vec3i, structure: *const sbb.StructureBuildingBlock, placementPosition: Vec3i, placementDirection: ?Neighbor, rotation: sbb.Rotation, seed: *u64) void {
	const blueprints = &(structure.getBlueprints(seed).* orelse return);

	const origin = blueprints[0].originBlock;
	const blueprintRotation = rotation.apply(alignDirections(origin.direction(), placementDirection orelse origin.direction()) catch return);
	const rotated = &blueprints[@intFromEnum(blueprintRotation.fixed)];
	const rotatedOrigin = rotated.originBlock.pos();
	const pastePosition = placementPosition - rotatedOrigin - (placementDirection orelse origin.direction()).relPos();

	const voidType = main.blueprint.getVoidBlock().typ;
	for (0..rotated.blueprint.blocks.width) |x| {
		for (0..rotated.blueprint.blocks.depth) |y| {
			for (0..rotated.blueprint.blocks.height) |z| {
				const block = rotated.blueprint.blocks.get(x, y, z);
				if (block.typ == voidType) continue;
				const local = pastePosition + Vec3i{@intCast(x), @intCast(y), @intCast(z)} - bufferMin;
				if (@reduce(.Or, local < Vec3i{0, 0, 0})) continue;
				if (local[0] >= buffer.width or local[1] >= buffer.depth or local[2] >= buffer.height) continue;
				buffer.set(@intCast(local[0]), @intCast(local[1]), @intCast(local[2]), block);
			}
		}
	}

	for (rotated.childBlocks) |childBlock| {
		const child = structure.getChildStructure(childBlock) orelse continue;
		const childRotation = blueprintRotation.getChildRotation(seed, child.rotation, childBlock.direction());
		assembleInto(buffer, bufferMin, child, pastePosition + childBlock.pos(), childBlock.direction(), childRotation, seed);
	}
}

/// Copied from placestructure.zig/SbbGen.zig: computes the fixed rotation needed so a structure's
/// origin-block facing direction matches the desired placement direction.
fn alignDirections(input: Neighbor, desired: Neighbor) !sbb.Rotation.FixedRotation {
	comptime var alignTable: [6][6]error{NotPossibleToAlign}!sbb.Rotation.FixedRotation = undefined;
	comptime for (Neighbor.iterable) |in| {
		for (Neighbor.iterable) |out| blk: {
			var current = in;
			for (0..4) |i| {
				if (current == out) {
					alignTable[in.toInt()][out.toInt()] = @enumFromInt(i);
					break :blk;
				}
				current = current.rotateZ();
			}
			alignTable[in.toInt()][out.toInt()] = error.NotPossibleToAlign;
		}
	};
	const runtimeTable = alignTable;
	return runtimeTable[input.toInt()][desired.toInt()];
}

pub const Preview = struct {
	buffer: Array3D(Block),
	extent: Vec3i,

	pub fn deinit(self: Preview, allocator: NeverFailingAllocator) void {
		self.buffer.deinit(allocator);
	}
};

/// Assembles a structure (root + all recursively-placed children) into an in-memory block buffer
/// for thumbnail rendering, using a seed derived deterministically from the structure's own id -
/// not main.seed/main.random - so a given structure always previews the same way instead of
/// re-rolling its random blueprint/rotation variants on every regeneration.
pub fn assemble(allocator: NeverFailingAllocator, structure: *const sbb.StructureBuildingBlock) Preview {
	var seed = std.hash.Wyhash.hash(0, structure.id);
	const initialRotation = structure.rotation.getInitialRotation(&seed);

	var min: Vec3i = .{0, 0, 0};
	var max: Vec3i = .{0, 0, 0};
	computeBounds(&min, &max, structure, .{0, 0, 0}, null, initialRotation, &seed);

	// The renderer places the buffer at local coordinate (1,1,1) within a single BlockPos (u5,
	// max 31) so that every boundary face's neighbor position also stays in range - that caps
	// the usable extent to 30 per axis. Oversized composites get soft-clamped rather than
	// blocking the whole feature; this crops rather than scales, so an oversized structure's
	// preview may be missing its outermost slice on the clamped axis/axes.
	const maxPreviewExtent = 30;
	var extent = max -% min;
	// computeBounds() bails out without touching min/max if the root structure's weighted blueprint
	// pick lands on a null entry (a legitimate "place nothing" outcome for probabilistic entries),
	// leaving a degenerate zero-size buffer. Give those a 1x1x1 all-air buffer instead, so callers
	// get a valid (empty) preview rather than a zero-dimension Array3D.
	if (@reduce(.Or, extent <= @as(Vec3i, @splat(0)))) {
		extent = .{1, 1, 1};
	}
	if (@reduce(.Or, extent > @as(Vec3i, @splat(maxPreviewExtent)))) {
		std.log.warn("Structure '{s}' preview extent {} exceeds the {}-voxel-per-axis preview limit; thumbnail will be cropped.", .{structure.id, extent, maxPreviewExtent});
		extent = @min(extent, @as(Vec3i, @splat(maxPreviewExtent)));
	}
	const buffer: Array3D(Block) = .init(allocator, @intCast(extent[0]), @intCast(extent[1]), @intCast(extent[2]));
	@memset(buffer.mem, Block{.typ = 0, .data = 0});

	seed = std.hash.Wyhash.hash(0, structure.id);
	_ = structure.rotation.getInitialRotation(&seed);
	assembleInto(buffer, min, structure, .{0, 0, 0}, null, initialRotation, &seed);

	return .{.buffer = buffer, .extent = extent};
}
