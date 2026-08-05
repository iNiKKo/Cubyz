const std = @import("std");

const main = @import("main");
const Vec3i = main.vec.Vec3i;
const ZonElement = main.ZonElement;
const Dir = main.files.Dir;
const List = main.List;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

/// One previously-placed structure instance: its world-space bounding box plus every offset
/// (relative to `min`) that was actually written - not the whole box, since structures like trees
/// are mostly empty air inside their bounding box. Lets a later click on any of its blocks
/// reselect the exact footprint for move/delete, instead of just a rectangular region.
pub const TrackedStructure = struct {
	min: Vec3i,
	max: Vec3i,
	/// Relative to `min`.
	offsets: []Vec3i,

	fn deinit(self: TrackedStructure) void {
		main.globalAllocator.free(self.offsets);
	}
};

var registry: List(TrackedStructure) = .empty;
/// Maps every absolute position occupied by some tracked structure to its index in `registry`,
/// for O(1) click hit-testing instead of scanning every structure's offset list per click.
var positionToIndex: std.AutoHashMapUnmanaged(Vec3i, usize) = .{};

/// Records a newly-placed structure's exact footprint. `min` is the structure's bounding-box
/// min corner; `absoluteOffsets` are the exact world positions it occupies (ownership of the
/// slice is taken - caller must not free it).
pub fn register(min: Vec3i, max: Vec3i, absoluteOffsets: []Vec3i) void {
	const index = registry.items.len;

	for (absoluteOffsets) |*pos| {
		positionToIndex.put(main.globalAllocator.allocator, pos.*, index) catch unreachable;
		pos.* -%= min;
	}

	registry.append(main.globalAllocator, .{.min = min, .max = max, .offsets = absoluteOffsets});
}

/// Returns the tracked structure occupying `pos`, if any.
pub fn find(pos: Vec3i) ?*const TrackedStructure {
	const index = positionToIndex.get(pos) orelse return null;
	return &registry.items[index];
}

/// Absolute world positions occupied by `structure` - caller owns the returned slice.
pub fn absolutePositions(allocator: NeverFailingAllocator, structure: *const TrackedStructure) []Vec3i {
	const result = allocator.alloc(Vec3i, structure.offsets.len);
	for (structure.offsets, result) |offset, *out| {
		out.* = structure.min +% offset;
	}
	return result;
}

pub fn loadFromDisk(dir: Dir) void {
	std.debug.assert(registry.items.len == 0);
	std.debug.assert(positionToIndex.count() == 0);

	const zon = dir.readToZon(main.stackAllocator, "placed_structures.zig.zon") catch |err| {
		if (err != error.FileNotFound) {
			std.log.err("Could not read placed_structures.zig.zon: {s}", .{@errorName(err)});
		}
		return;
	};
	defer zon.deinit(main.stackAllocator);
	if (zon != .array) return;

	registry.ensureCapacity(main.globalAllocator, zon.array.items.len);
	for (zon.array.items) |entry| {
		const min = entry.get(Vec3i, "min") orelse continue;
		const max = entry.get(Vec3i, "max") orelse continue;
		const offsetsZon = entry.getChild("offsets");
		if (offsetsZon != .array) continue;

		const offsets = main.globalAllocator.alloc(Vec3i, offsetsZon.array.items.len);
		for (offsetsZon.array.items, offsets) |offsetZon, *out| {
			out.* = offsetZon.as(Vec3i) orelse .{0, 0, 0};
		}

		const index = registry.items.len;
		for (offsets) |offset| {
			positionToIndex.put(main.globalAllocator.allocator, min +% offset, index) catch unreachable;
		}
		registry.appendAssumeCapacity(.{.min = min, .max = max, .offsets = offsets});
	}
}

pub fn saveToDisk(dir: Dir) void {
	const zon = ZonElement.initArray(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);

	for (registry.items) |structure| {
		const entry = ZonElement.initObject(main.stackAllocator);
		entry.put("min", structure.min);
		entry.put("max", structure.max);

		const offsetsZon = ZonElement.initArray(main.stackAllocator);
		for (structure.offsets) |offset| offsetsZon.append(offset);
		entry.put("offsets", offsetsZon);

		zon.append(entry);
	}

	dir.writeZon("placed_structures.zig.zon", zon) catch |err| {
		std.log.err("Could not write placed_structures.zig.zon: {s}", .{@errorName(err)});
	};
}

pub fn reset() void {
	for (registry.items) |structure| structure.deinit();
	registry.clearAndFree(main.globalAllocator);
	positionToIndex.clearAndFree(main.globalAllocator.allocator);
}
