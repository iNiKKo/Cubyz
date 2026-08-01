const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Accept a pending teleport request";
pub const usage = "\\/tpaccept";
pub const Args = struct {};

pub fn execute(_: Args, source: Source) void {
	const destination = source.requireUser() orelse return;
	const requesterIndex = destination.tpaRequestFrom orelse {
		destination.sendMessage("#ff0000You have no pending teleport requests.", .{});
		return;
	};
	destination.tpaRequestFrom = null;
	const users = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(users);
	for (users) |requester| {
		if (requester.playerIndex != requesterIndex) continue;
		requester.teleport(destination.player().pos, true);
		requester.sendMessage("#00ff00Teleport request accepted.", .{});
		destination.sendMessage("#00ff00Accepted teleport request from {s}.", .{requester.name});
		return;
	}
	destination.sendMessage("#ff0000The player who sent the request is no longer online.", .{});
}
