const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const Vec3i = main.vec.Vec3i;
const sbb = main.server.terrain.sbb;
const Neighbor = main.chunk.Neighbor;
const Blueprint = main.blueprint.Blueprint;
const List = main.List;
const placed_structures = main.server.terrain.placed_structures;

pub const description = "Place a structure building block at an exact world position.";
pub const usage = "/placestructure <id> <x> <y> <z>";

pub const Args = union(enum) {
	@"/placestructure <id> <x> <y> <z>": struct {
		id: []const u8,
		x: i32,
		y: i32,
		z: i32,
	},
};

const Bounds = struct {
	min: Vec3i,
	max: Vec3i,

	fn include(self: *Bounds, pos: Vec3i, extent: Vec3i) void {
		self.min = @min(self.min, pos);
		self.max = @max(self.max, pos +% extent);
	}
};

/// Recursively walks a structure building block and its children exactly like placeStructure(),
/// but only accumulates the world-space bounding box touched, without writing any blocks. Used to
/// capture a correctly-sized undo snapshot before the real placement pass runs.
fn computeStructureBounds(bounds: *Bounds, structure: *const sbb.StructureBuildingBlock, placementPosition: Vec3i, placementDirection: ?Neighbor, rotation: sbb.Rotation, seed: *u64) void {
	const blueprints = &(structure.getBlueprints(seed).* orelse return);

	const origin = blueprints[0].originBlock;
	const blueprintRotation = rotation.apply(alignDirections(origin.direction(), placementDirection orelse origin.direction()) catch return);
	const rotated = &blueprints[@intFromEnum(blueprintRotation.fixed)];
	const rotatedOrigin = rotated.originBlock.pos();
	const pastePosition = placementPosition - rotatedOrigin - (placementDirection orelse origin.direction()).relPos();

	bounds.include(pastePosition, rotated.blueprint.extent());

	for (rotated.childBlocks) |childBlock| {
		const child = structure.getChildStructure(childBlock) orelse continue;
		const childRotation = blueprintRotation.getChildRotation(seed, child.rotation, childBlock.direction());
		computeStructureBounds(bounds, child, pastePosition + childBlock.pos(), childBlock.direction(), childRotation, seed);
	}
}

/// Recursively pastes a structure building block and its children directly into the live world,
/// mirroring src/server/terrain/simple_structures/SbbGen.zig's placeSbb, but using Blueprint.paste
/// (world-space, undo-friendly) instead of pasteInGeneration (chunk-gen-only). Every non-void
/// absolute position actually written is appended to `footprint`, so the caller can register the
/// placed structure's exact shape for later exact-footprint reselection.
fn placeStructure(structure: *const sbb.StructureBuildingBlock, placementPosition: Vec3i, placementDirection: ?Neighbor, rotation: sbb.Rotation, seed: *u64, footprint: *List(Vec3i)) void {
	const blueprints = &(structure.getBlueprints(seed).* orelse return);

	const origin = blueprints[0].originBlock;
	const blueprintRotation = rotation.apply(alignDirections(origin.direction(), placementDirection orelse origin.direction()) catch |err| {
		std.log.err("Could not align directions for structure '{s}' for directions '{s}' and '{s}', error: {s}", .{structure.id, @tagName(origin.direction()), @tagName(placementDirection orelse origin.direction()), @errorName(err)});
		return;
	});
	const rotated = &blueprints[@intFromEnum(blueprintRotation.fixed)];
	const rotatedOrigin = rotated.originBlock.pos();
	const pastePosition = placementPosition - rotatedOrigin - (placementDirection orelse origin.direction()).relPos();

	rotated.blueprint.paste(pastePosition, .{});

	const voidType = main.blueprint.getVoidBlock().typ;
	for (0..rotated.blueprint.blocks.width) |x| {
		for (0..rotated.blueprint.blocks.depth) |y| {
			for (0..rotated.blueprint.blocks.height) |z| {
				if (rotated.blueprint.blocks.get(x, y, z).typ == voidType) continue;
				footprint.append(main.globalAllocator, pastePosition + Vec3i{@intCast(x), @intCast(y), @intCast(z)});
			}
		}
	}

	for (rotated.childBlocks) |childBlock| {
		const child = structure.getChildStructure(childBlock) orelse continue;
		const childRotation = blueprintRotation.getChildRotation(seed, child.rotation, childBlock.direction());
		placeStructure(child, pastePosition + childBlock.pos(), childBlock.direction(), childRotation, seed, footprint);
	}
}

/// Copied from SbbGen.zig: computes the fixed rotation needed so a structure's origin-block
/// facing direction matches the desired placement direction.
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

pub fn execute(args: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	const params = args.@"/placestructure <id> <x> <y> <z>";

	const structure = sbb.getByStringId(params.id) orelse {
		user.sendMessage("#ff0000Error: Unknown structure id '{s}'.", .{params.id});
		return;
	};

	const pos: Vec3i = .{params.x, params.y, params.z};

	// The structure's random rotation/children choices are sampled from main.seed as we walk it,
	// so a dry bounds-only pass and the real placement pass must consume the seed identically -
	// snapshot it and run both passes from the same starting state.
	const seedSnapshot = main.seed;
	const initialRotation = structure.rotation.getInitialRotation(&main.seed);

	var bounds: Bounds = .{.min = pos, .max = pos};
	computeStructureBounds(&bounds, structure, pos, null, initialRotation, &main.seed);

	const undoSelection: Blueprint.Selection = .initFromExtent(bounds.min, bounds.max -% bounds.min);
	const undo = Blueprint.capture(main.globalAllocator, undoSelection);

	// Replay the same getInitialRotation() draw to advance main.seed back to the exact state
	// the bounds pass started its recursion from, so the real pass makes identical random choices.
	main.seed = seedSnapshot;
	_ = structure.rotation.getInitialRotation(&main.seed);
	var footprint: List(Vec3i) = .empty;
	defer footprint.deinit(main.globalAllocator);
	placeStructure(structure, pos, null, initialRotation, &main.seed, &footprint);

	switch (undo) {
		.success => |blueprint| {
			// The stored position must be the captured blueprint's own min-corner (bounds.min),
			// not the structure's placement anchor (pos) - undo/redo reconstruct the selection as
			// .initFromExtent(position, blueprint.extent()), which only lines up with bounds.min.
			user.worldEditData.undoHistory.push(.init(blueprint, bounds.min, "placestructure"));
			user.worldEditData.redoHistory.clear();
		},
		.failure => {
			user.sendMessage("#ff0000Error: Could not capture undo history.", .{});
		},
	}

	// register() takes ownership of the footprint slice.
	placed_structures.register(bounds.min, bounds.max, footprint.toOwnedSlice(main.globalAllocator));

	user.sendMessage("Placed structure '{s}' at {}", .{params.id, pos});
}
