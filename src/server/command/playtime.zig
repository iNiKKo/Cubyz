const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Check your playtime or the server leaderboard";
pub const usage = "\\/playtime\n\\/playtime list";
pub const Args = union(enum) {
	@"/playtime": struct {},
	@"/playtime <action>": struct { action: enum { list } },
};

const Entry = struct {
	name: []const u8,
	seconds: u64,

	fn greaterThan(_: void, a: Entry, b: Entry) bool {
		return a.seconds > b.seconds;
	}
};

fn currentPlaytime(user: *main.server.User) u64 {
	const now: i64 = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1_000_000_000));
	return user.player().playtimeSeconds + @as(u64, @intCast(@max(now - user.player().sessionStartSeconds, 0)));
}

pub fn execute(args: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	switch (args) {
		.@"/playtime" => {
			const seconds = currentPlaytime(user);
			user.sendMessage("#00ff00Your total playtime: #ffff00{d}h {d}m", .{seconds/3600, (seconds%3600)/60});
		},
		.@"/playtime <action>" => {
			const world = main.server.world.?;
			world.saveAllPlayers() catch {
				user.sendMessage("#ff0000Could not read the playtime leaderboard.", .{});
				return;
			};
			const path = main.stackAllocator.print("saves/{s}/players", .{world.path});
			defer main.stackAllocator.free(path);
			var directory = main.files.cubyzDir().openIterableDir(path) catch {
				user.sendMessage("#ffff00No player data has been saved yet.", .{});
				return;
			};
			defer directory.close();
			var entries: main.ListManaged(Entry) = .init(main.stackAllocator);
			defer {
				for (entries.items) |entry| main.stackAllocator.free(entry.name);
				entries.deinit();
			}
			var iterator = directory.iterate();
			while (iterator.next(main.io) catch null) |file| {
				if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".zon")) continue;
				const filePath = main.stackAllocator.print("{s}/{s}", .{path, file.name});
				defer main.stackAllocator.free(filePath);
				const data = main.files.cubyzDir().readToZon(main.stackAllocator, filePath) catch continue;
				defer data.deinit(main.stackAllocator);
				const entity = data.getChildOrNull("entity") orelse continue;
				const name = data.get([]const u8, "name") orelse "Unknown Player";
				const seconds = entity.get(u64, "playtimeSeconds") orelse 0;
				var alreadyAdded = false;
				for (entries.items) |*entry| {
					if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
					entry.seconds = @max(entry.seconds, seconds);
					alreadyAdded = true;
					break;
				}
				if (!alreadyAdded) entries.append(.{.name = main.stackAllocator.dupe(u8, name), .seconds = seconds});
			}
			std.mem.sort(Entry, entries.items, {}, Entry.greaterThan);
			user.sendMessage("#ffff00--- Server Playtime Leaderboard ---", .{});
			for (entries.items[0..@min(entries.items.len, 10)], 0..) |entry, i| {
				user.sendMessage("#00ff00{d}. #ffff00{s} #00ff00- {d}h {d}m", .{i + 1, entry.name, entry.seconds/3600, (entry.seconds%3600)/60});
			}
		},
	}
}
