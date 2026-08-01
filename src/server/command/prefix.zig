const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Add or remove chat prefixes for players";
pub const usage =
	\\/prefix add @<playerIndex> <text>
	\\/prefix remove @<playerIndex>
;
pub const Args = union(enum) {
	@"/prefix add <playerIndex> <text>": struct { action: enum { add }, playerIndex: command.PlayerIndex, text: command.RestText },
	@"/prefix remove <playerIndex>": struct { action: enum { remove }, playerIndex: command.PlayerIndex },
};

pub fn execute(args: Args, source: Source) void {
	if (!source.requirePermission("/command/prefix/admin")) return;
	switch (args) {
		.@"/prefix add <playerIndex> <text>" => |params| {
			if (params.text.text.len == 0 or params.text.text.len > 64) {
				source.sendMessage("#ff0000Prefixes must be between 1 and 64 characters.", .{});
				return;
			}
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			if (target.user.player().prefix) |value| main.globalAllocator.free(value);
			target.user.player().prefix = main.globalAllocator.dupe(u8, params.text.text);
			source.sendMessage("#00ff00Assigned a prefix to {s}.", .{target.user.name});
			target.user.sendMessage("#00ff00Your chat prefix was updated.", .{});
		},
		.@"/prefix remove <playerIndex>" => |params| {
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			const value = target.user.player().prefix orelse {
				source.sendMessage("#ff0000Player {s} has no prefix.", .{target.user.name});
				return;
			};
			main.globalAllocator.free(value);
			target.user.player().prefix = null;
			source.sendMessage("#00ff00Removed the prefix from {s}.", .{target.user.name});
			target.user.sendMessage("#ffff00Your chat prefix was removed.", .{});
		},
	}
}
