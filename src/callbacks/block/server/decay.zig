const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const vec = main.vec;
const Vec3i = vec.Vec3i;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const ZonElement = main.ZonElement;
const server = main.server;
const branch = main.rotation.rotations.@"cubyz:branch";

decayReplacement: blocks.Block,
prevention: []const main.Tag,
blockDrops: []const blocks.BlockDrop,

pub fn init(zon: ZonElement, creator: main.callbacks.Creator) ?*@This() {
	const block = switch (creator) {
		.block => |b| b,

	};
	const result = main.worldArena.create(@This());

	if (zon.get([]const u8, "replacement")) |blockname| {
		result.decayReplacement = main.blocks.parseBlock(blockname);
	} else result.decayReplacement = main.blocks.Block.air;

	if (zon.getChildOrNull("drops")) |_| {
		result.blockDrops = blocks.loadBlockDrop(block.id(), zon);
	} else result.blockDrops = block.blockDrops();

	result.prevention = &.{};
	if (zon.getChildOrNull("prevention")) |tagNames| {
		if (tagNames == .array) {
			var prevention = main.List(main.Tag).initCapacity(main.worldArena, tagNames.array.items.len);
			for (tagNames.array.items) |value| {
				const tagName = value.as([]const u8) orelse {
					std.log.err("Invalid TagName for decay prevention.", .{});
					continue;
				};
				prevention.appendAssumeCapacity(main.Tag.find(tagName));
			}
			result.prevention = prevention.items;
		}
	}
	return result;
}
fn getIndexInCheckArray(relativePosition: Vec3i, checkRange: comptime_int) usize {
	const checkLength = checkRange*2 + 1;

	const arrayIndexX = relativePosition[0] + checkRange;
	const arrayIndexY = relativePosition[1] + checkRange;
	const arrayIndexZ = relativePosition[2] + checkRange;
	return @as(usize, @intCast((arrayIndexX*checkLength + arrayIndexY)*checkLength + arrayIndexZ));
}
fn preventsDecay(self: *@This(), log: Block) bool {
	for (self.prevention) |tag| {
		if (log.hasTag(tag)) return true;
	}
	return false;
}
fn foundWayToLog(self: *@This(), world: *server.ServerWorld, leaf: Block, wx: i32, wy: i32, wz: i32) bool {

	const checkRange = 5;
	const checkLength = checkRange*2 + 1;
	var checked: [checkLength*checkLength*checkLength]bool = undefined;
	for (0..checkLength*checkLength*checkLength) |i| {
		checked[i] = false;
	}

	var queue = main.utils.CircularBufferQueue(Vec3i).init(main.stackAllocator, 32);
	defer queue.deinit();

	queue.pushBack(Vec3i{0, 0, 0});
	checked[getIndexInCheckArray(Vec3i{0, 0, 0}, checkRange)] = true;

	const branchRotation = main.rotation.getByID("cubyz:branch");
	const sourceIsBranch = leaf.mode() == branchRotation;

	while (queue.popFront()) |value| {

		if (world.getBlock(value[0] +% wx, value[1] +% wy, value[2] +% wz)) |log| {

			if (self.preventsDecay(log)) {
				return true;
			}

			if (!sourceIsBranch and log.typ != leaf.typ) continue;
			if (sourceIsBranch and log.mode() != branchRotation and !log.viewThrough()) return true;
			const branchData = branch.BranchData.init(log.data);

			for (main.chunk.Neighbor.iterable) |offset| {
				const relativePosition = value + offset.relPos();

				if (vec.lengthSquare(relativePosition) > checkRange*checkRange) continue;
				if (sourceIsBranch and !branchData.isConnected(offset)) continue;

				if (checked[getIndexInCheckArray(relativePosition, checkRange)]) continue;
				checked[getIndexInCheckArray(relativePosition, checkRange)] = true;
				queue.pushBack(relativePosition);
			}
		}
	}
	return false;
}
pub fn run(self: *@This(), params: main.callbacks.ServerBlockCallback.Params) main.callbacks.Result {
	const wx = params.chunk.super.pos.wx + params.blockPos.x;
	const wy = params.chunk.super.pos.wy + params.blockPos.y;
	const wz = params.chunk.super.pos.wz + params.blockPos.z;

	if (params.block.mode() == main.rotation.getByID("cubyz:decayable")) {
		if (params.block.data != 0) return .ignored;
	} else if (params.block.mode() == main.rotation.getByID("cubyz:branch")) {
		const bd = branch.BranchData.init(params.block.data);
		if (bd.placedByHuman) return .ignored;
	} else {
		std.log.err("Expected {s} to have cubyz:decayable or cubyz:branch as rotation", .{params.block.id()});
	}

	if (server.world) |world| {
		if (world.getBlock(wx, wy, wz)) |leaf| {

			if (self.foundWayToLog(world, leaf, wx, wy, wz)) return .ignored;

			if (world.cmpxchgBlock(wx, wy, wz, leaf, self.decayReplacement) == null) {
				for (self.blockDrops) |drop| {
					if (drop.chance == 1 or main.random.nextFloat(&main.seed) < drop.chance) {
						for (drop.items) |stack| {
							var dir = main.vec.normalize(main.random.nextFloatVectorSigned(3, &main.seed));

							dir[2] += main.random.nextFloat(&main.seed)*4.0;
							const model = leaf.mode().model(leaf).model();
							const pos = Vec3f{
								@as(f32, @floatFromInt(wx)) + model.min[0] + main.random.nextFloat(&main.seed)*(model.max[0] - model.min[0]),
								@as(f32, @floatFromInt(wy)) + model.min[1] + main.random.nextFloat(&main.seed)*(model.max[1] - model.min[1]),
								@as(f32, @floatFromInt(wz)) + model.min[2] + main.random.nextFloat(&main.seed)*(model.max[2] - model.min[2]),
							};
							main.server.world.?.drop(stack.clone(), pos, dir, 1);
						}
					}
				}
				return .handled;
			}
		}
	}
	return .ignored;
}
