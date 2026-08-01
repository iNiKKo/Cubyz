const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Teleport back to your previous teleport or death location";
pub const usage = "\\/back";
pub const Args = struct {};

pub fn execute(_: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	const position = user.player().backPosition orelse {
		user.sendMessage("#ff0000You do not have a previous location to return to.", .{});
		return;
	};
	user.teleport(position, false);
	user.player().backPosition = null;
	user.sendMessage("#00ff00Teleported back to your previous location.", .{});
}
