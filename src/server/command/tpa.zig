const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Request to teleport to another player";
pub const usage = "\\/tpa <player or @id>";
pub const Args = struct { target: []const u8 };

pub fn execute(args: Args, source: Source) void {
	const requester = source.requireUser() orelse return;
	const destination = command.findOnlineUser(args.target) orelse {
		requester.sendMessage("#ff0000Player '{s}' was not found or the name is ambiguous.", .{args.target});
		return;
	};
	if (destination == requester) {
		requester.sendMessage("#ff0000You cannot teleport to yourself.", .{});
		return;
	}
	destination.tpaRequestFrom = requester.playerIndex;
	requester.sendMessage("#00ff00Teleport request sent to {s}.", .{destination.name});
	destination.sendMessage("#ffff00{s} wants to teleport to you. Type #00ff00/tpaccept #ffff00to accept.", .{requester.name});
}
