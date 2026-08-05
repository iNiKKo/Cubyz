const std = @import("std");

const main = @import("main");
const Source = main.server.command.Source;

const Blueprint = main.blueprint.Blueprint;

pub const description = "Delete the current world-edit selection.";
pub const usage = "/delete";

pub const Args = union(enum) {
	@"/delete": struct {},
};

pub fn execute(_: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const selection = main.server.command.getCurrentSelection(user) catch return;

	const undo = Blueprint.capture(main.globalAllocator, selection);
	switch (undo) {
		.success => |blueprint| {
			user.worldEditData.undoHistory.push(.init(blueprint, selection.minPos, "delete"));
			user.worldEditData.redoHistory.clear();
		},
		.failure => |failure| {
			user.sendMessage("#ff0000Error while deleting block {}: {s}", .{failure.pos, failure.message});
			return;
		},
	}

	var x: i32 = selection.minPos[0];
	while (x < selection.maxPos[0]) : (x += 1) {
		var y: i32 = selection.minPos[1];
		while (y < selection.maxPos[1]) : (y += 1) {
			var z: i32 = selection.minPos[2];
			while (z < selection.maxPos[2]) : (z += 1) {
				if (user.worldEditData.mask) |mask| {
					const block = main.server.world.?.getBlock(x, y, z) orelse continue;
					if (!mask.match(block)) continue;
				}
				_ = main.server.world.?.updateBlock(x, y, z, main.blocks.Block.air);
			}
		}
	}

	user.sendMessage("#00ff00Deleted selection.", .{});
}