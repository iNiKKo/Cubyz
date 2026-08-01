const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "List online players and their IDs";
pub const usage = "\\/players";
pub const Args = struct {};

pub fn execute(_: Args, source: Source) void {
	const users = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(users);
	if (users.len == 0) {
		source.sendMessage("#ffff00There are no players online.", .{});
		return;
	}
	source.sendMessage("#00ff00--- Online Players ({d}) ---", .{users.len});
	for (users) |user| {
		source.sendMessage("#ffffff- {s} #aaaaaa(@{d})", .{user.name, user.playerIndex});
	}
}
