const std = @import("std");

const main = @import("main");
const blocks = main.blocks;
const Block = blocks.Block;
const Neighbor = main.chunk.Neighbor;
const ModelIndex = main.models.ModelIndex;
const Degrees = main.rotation.Degrees;
const Mat4f = main.vec.Mat4f;
const Vec3f = main.vec.Vec3f;
const Vec3i = main.vec.Vec3i;
const ZonElement = main.ZonElement;

var rotatedModels: std.StringHashMap(ModelIndex) = undefined;

pub const dependsOnNeighbors = true;

pub fn init() void {
	rotatedModels = .init(main.globalAllocator.allocator);
}

pub fn deinit() void {
	rotatedModels.deinit();
}

pub fn reset() void {
	rotatedModels.clearRetainingCapacity();
}

pub fn createBlockModel(block: Block, _: *u16, zon: ZonElement) ModelIndex {
	const modelId = zon.as([]const u8) orelse blk: {
		std.log.err("Invalid model data for block {s}", .{block.id()});
		break :blk "cubyz:cube";
	};
	if (rotatedModels.get(modelId)) |modelIndex| return modelIndex;

	const baseModel = main.models.getModelIndex(modelId).model();
	const modelIndex = baseModel.transformModel(main.rotation.rotationMatrixTransform, .{Mat4f.rotationZ(-std.math.pi/2.0)});
	_ = baseModel.transformModel(main.rotation.rotationMatrixTransform, .{Mat4f.rotationZ(std.math.pi/2.0)});
	_ = baseModel.transformModel(main.rotation.rotationMatrixTransform, .{Mat4f.identity()});
	_ = baseModel.transformModel(main.rotation.rotationMatrixTransform, .{Mat4f.rotationZ(std.math.pi)});
	rotatedModels.put(modelId, modelIndex) catch unreachable;
	return modelIndex;
}

pub fn model(block: Block) ModelIndex {
	return blocks.meshes.modelIndexStart(block).add(@min(block.data, 3));
}

pub fn rotateZ(data: u16, angle: Degrees) u16 {
	comptime var rotationTable: [4][4]u8 = undefined;
	comptime for (0..4) |i| {
		rotationTable[0][i] = i;
	};
	comptime for (1..4) |a| {
		for (0..4) |i| {
			const support: Neighbor = switch (rotationTable[a - 1][i]) {
				0 => .dirNegX,
				1 => .dirPosX,
				2 => .dirNegY,
				3 => .dirPosY,
				else => unreachable,
			};
			rotationTable[a][i] = switch (support.rotateZ()) {
				.dirNegX => 0,
				.dirPosX => 1,
				.dirNegY => 2,
				.dirPosY => 3,
				else => unreachable,
			};
		}
	};
	if (data >= 4) return 0;
	const runtimeTable = rotationTable;
	return runtimeTable[@intFromEnum(angle)][data];
}

pub fn generateData(_: *main.game.World, _: Vec3i, _: Vec3f, _: Vec3f, relativeDir: Vec3i, neighbor: ?Neighbor, currentData: *Block, neighborBlock: Block, blockPlacing: bool) bool {
	if (!blockPlacing) return false;
	const supportFace = neighbor orelse return false;
	if (!blocks.meshes.model(neighborBlock).model().isNeighborOccluded[supportFace.toInt()]) return false;
	if (relativeDir[0] == -1) currentData.data = 0 else if (relativeDir[0] == 1) currentData.data = 1 else if (relativeDir[1] == -1) currentData.data = 2 else if (relativeDir[1] == 1) currentData.data = 3 else return false;
	return true;
}

pub fn updateData(block: *Block, neighbor: Neighbor, neighborBlock: Block) bool {
	const support = switch (block.data) {
		0 => Neighbor.dirNegX,
		1 => Neighbor.dirPosX,
		2 => Neighbor.dirNegY,
		3 => Neighbor.dirPosY,
		else => return false,
	};
	if (neighbor == support and !blocks.meshes.model(neighborBlock).model().isNeighborOccluded[neighbor.reverse().toInt()]) {
		block.* = .air;
		return true;
	}
	return false;
}

pub fn updateBlockFromNeighborConnectivity(block: *Block, neighborSupportive: [6]bool) void {
	const support = switch (block.data) {
		0 => Neighbor.dirNegX,
		1 => Neighbor.dirPosX,
		2 => Neighbor.dirNegY,
		3 => Neighbor.dirPosY,
		else => return,
	};
	if (!neighborSupportive[support.toInt()]) block.* = .air;
}
