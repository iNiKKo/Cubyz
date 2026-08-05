const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const Vec3i = main.vec.Vec3i;

const Blueprint = main.blueprint.Blueprint;

pub const description = "Paste clipboard content above the current selection (or beside it if blocked).";
pub const usage = "/pasteabove";

pub const Args = union(enum) {
	@"/pasteabove": struct {},
};

/// Whether the axis-aligned box [pos, pos+extent) is entirely air, so a paste won't silently
/// overwrite existing structures. Missing chunks count as blocked (conservative).
fn regionIsFree(pos: Vec3i, extent: Vec3i) bool {
	var x: i32 = 0;
	while (x < extent[0]) : (x += 1) {
		var y: i32 = 0;
		while (y < extent[1]) : (y += 1) {
			var z: i32 = 0;
			while (z < extent[2]) : (z += 1) {
				const block = main.server.world.?.getBlock(pos[0] + x, pos[1] + y, pos[2] + z) orelse return false;
				if (block.typ != 0) return false;
			}
		}
	}
	return true;
}

pub fn execute(_: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const clipboard = user.worldEditData.clipboard orelse {
		user.sendMessage("#ff0000Error: No clipboard content to paste.", .{});
		return;
	};

	const selection = command.getCurrentSelection(user) catch return;
	const extent = clipboard.extent();

	const above: Vec3i = .{selection.minPos[0], selection.minPos[1], selection.maxPos[2]};
	const besideX: Vec3i = .{selection.maxPos[0], selection.minPos[1], selection.minPos[2]};
	const besideNegX: Vec3i = .{selection.minPos[0] -% extent[0], selection.minPos[1], selection.minPos[2]};

	const pos: Vec3i = if (regionIsFree(above, extent))
		above
	else if (regionIsFree(besideX, extent))
		besideX
	else
		besideNegX;

	user.sendMessage("Pasting: {}", .{pos});

	const pasteSelection: Blueprint.Selection = .initFromExtent(pos, extent);
	const undo = Blueprint.capture(main.globalAllocator, pasteSelection);
	switch (undo) {
		.success => |blueprint| {
			user.worldEditData.undoHistory.push(.init(blueprint, pos, "pasteabove"));
			user.worldEditData.redoHistory.clear();
		},
		.failure => {
			user.sendMessage("#ff0000Error: Could not capture undo history.", .{});
		},
	}

	clipboard.paste(pos, .{});
}
