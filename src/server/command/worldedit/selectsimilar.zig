const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const Vec3i = main.vec.Vec3i;
const Blueprint = main.blueprint.Blueprint;

pub const description = "Flood-select all directly-connected blocks of the same type as position 1 (max 50 blocks).";
pub const usage = "/selectsimilar";

pub const Args = union(enum) {
	@"/selectsimilar": struct {},
};

const maxBlobBlocks = 50;
const neighborOffsets = [6]Vec3i{
	.{1, 0, 0}, .{-1, 0, 0},
	.{0, 1, 0}, .{0, -1, 0},
	.{0, 0, 1}, .{0, 0, -1},
};

pub fn execute(_: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const startPos = user.worldEditData.selectionPosition1 orelse {
		source.sendMessage("#ff0000Position 1 isn't set", .{});
		return;
	};
	const startBlock = main.server.world.?.getBlock(startPos[0], startPos[1], startPos[2]) orelse return;
	if (startBlock.typ == 0) {
		source.sendMessage("#ff0000Cannot select-similar on air", .{});
		return;
	}

	var visited: main.ListManaged(Vec3i) = .init(main.stackAllocator);
	defer visited.deinit();
	var queue: main.ListManaged(Vec3i) = .init(main.stackAllocator);
	defer queue.deinit();

	visited.append(startPos);
	queue.append(startPos);

	var queueIndex: usize = 0;
	while (queueIndex < queue.items.len and visited.items.len < maxBlobBlocks) : (queueIndex += 1) {
		const current = queue.items[queueIndex];
		for (neighborOffsets) |offset| {
			const neighborPos = current +% offset;
			var alreadyVisited = false;
			for (visited.items) |v| {
				if (@reduce(.And, v == neighborPos)) {
					alreadyVisited = true;
					break;
				}
			}
			if (alreadyVisited) continue;
			const neighborBlock = main.server.world.?.getBlock(neighborPos[0], neighborPos[1], neighborPos[2]) orelse continue;
			if (neighborBlock.typ != startBlock.typ) continue;
			visited.append(neighborPos);
			queue.append(neighborPos);
			if (visited.items.len >= maxBlobBlocks) break;
		}
	}

	var minPos = startPos;
	var maxPos = startPos;
	for (visited.items) |pos| {
		minPos = @min(minPos, pos);
		maxPos = @max(maxPos, pos);
	}
	maxPos += @as(Vec3i, @splat(1));

	user.worldEditData.selectionPosition1 = minPos;
	user.worldEditData.selectionPosition2 = maxPos -% @as(Vec3i, @splat(1));
	main.network.protocols.genericUpdate.sendWorldEditPos(user.conn, .selectedPos1, minPos);
	main.network.protocols.genericUpdate.sendWorldEditPos(user.conn, .selectedPos2, maxPos -% @as(Vec3i, @splat(1)));

	if (user.worldEditData.mask) |oldMask| oldMask.deinit(main.globalAllocator);
	user.worldEditData.mask = main.blueprint.Mask.fromBlockType(main.globalAllocator, startBlock.typ);

	user.sendMessage("#00ff00Selected {d} connected blocks.", .{visited.items.len});
}
