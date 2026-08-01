const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Toggle your away-from-keyboard status";
pub const usage = "\\/afk";
pub const Args = struct {};

pub fn execute(_: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	user.isAfk = !user.isAfk;
	if (user.isAfk) main.server.sendMessage("{s}§#aaaaaa is now AFK", .{user.name}) else main.server.sendMessage("{s}§#00ff00 is no longer AFK", .{user.name});
}
