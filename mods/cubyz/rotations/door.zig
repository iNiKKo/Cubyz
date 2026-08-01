const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const ModelIndex = main.models.ModelIndex;
const Degrees = main.rotation.Degrees;
const Vec3f = main.vec.Vec3f;
const Vec3i = main.vec.Vec3i;
const ZonElement = main.ZonElement;

var rotatedModels: std.StringHashMap(ModelIndex) = undefined;

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
	var modelIndex: ModelIndex = undefined;
	for (0..8) |i| {
		const direction: f32 = @floatFromInt(i & 3);
		const index = baseModel.transformModel(transformDoor, .{direction*std.math.pi/2.0, (i & 4) != 0});
		if (i == 0) modelIndex = index;
	}
	rotatedModels.put(modelId, modelIndex) catch unreachable;
	return modelIndex;
}

pub fn model(block: Block) ModelIndex {
	return blocks.meshes.modelIndexStart(block).add(@truncate(block.data & 7));
}

pub fn rotateZ(data: u16, angle: Degrees) u16 {
	const half = data & 8;
	const open = data & 4;
	const direction = (data + @intFromEnum(angle)) & 3;
	return half | open | direction;
}

pub fn generateData(_: *main.game.World, _: Vec3i, _: Vec3f, playerDir: Vec3f, _: Vec3i, _: ?main.chunk.Neighbor, currentData: *Block, _: Block, blockPlacing: bool) bool {
	if (!blockPlacing) return false;
	if (@abs(playerDir[0]) > @abs(playerDir[1])) {
		currentData.data = if (playerDir[0] < 0) 1 else 3;
	} else {
		currentData.data = if (playerDir[1] < 0) 2 else 0;
	}
	return true;
}

fn transformDoor(quad: *main.models.QuadInfo, direction: f32, isOpen: bool) void {
	const center = Vec3f{0.5, 0.5, 0.5};
	const hinge = Vec3f{0.0, 0.0, 0.5};
	var normal: Vec3f = quad.normal;
	if (isOpen) normal = main.vec.rotateZ(normal, std.math.pi/2.0);
	normal = main.vec.rotateZ(normal, direction);
	quad.normal = normal;
	for (&quad.corners) |*corner| {
		var position: Vec3f = corner.*;
		if (isOpen) position = main.vec.rotateZ(position - hinge - Vec3f{0.0, 0.125, 0.0}, std.math.pi/2.0) + hinge;
		corner.* = main.vec.rotateZ(position - center, direction) + center;
	}
}
