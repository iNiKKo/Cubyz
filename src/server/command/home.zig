const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Manage and teleport to saved home locations";
pub const usage =
	\\/home <name>
	\\/home add <name>
	\\/home remove <name>
	\\/home list
	\\/home spawn <name>
;

pub const Args = union(enum) {
	@"/home add <name>": struct { action: enum { add }, name: []const u8 },
	@"/home remove <name>": struct { action: enum { remove }, name: []const u8 },
	@"/home spawn <name>": struct { action: enum { spawn }, name: []const u8 },
	@"/home list": struct { action: enum { list } },
	@"/home <name>": struct { name: []const u8 },
};

const maxHomes = 3;
const reservedNames = .{"add", "remove", "list", "spawn"};

fn isReservedName(name: []const u8) bool {
	inline for (reservedNames) |reservedName| if (std.ascii.eqlIgnoreCase(name, reservedName)) return true;
	return false;
}

fn findHome(user: *main.server.User, name: []const u8) ?usize {
	for (user.player().homeNames, 0..) |savedName, i| {
		if (savedName) |value| {
			if (std.ascii.eqlIgnoreCase(value, name)) return i;
		}
	}
	return null;
}

pub fn execute(args: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	switch (args) {
		.@"/home list" => {
			var message: main.ListManaged(u8) = .init(main.stackAllocator);
			defer message.deinit();
			message.appendSlice("#00ff00Your saved homes:");
			var count: usize = 0;
			for (user.player().homeNames, 0..) |name, i| {
				if (name) |value| {
					if (user.player().homePositions[i] != null) {
						message.print("\n#ffffff- {s}", .{value});
						count += 1;
					}
				}
			}
			if (count == 0) user.sendMessage("#ffff00You do not have any saved homes.", .{}) else user.sendMessage("{s}", .{message.items});
		},
		.@"/home add <name>" => |params| {
			if (params.name.len == 0 or params.name.len > 32 or std.mem.indexOfAny(u8, params.name, "\\/\n\r") != null or isReservedName(params.name)) {
				user.sendMessage("#ff0000Home names must be 1-32 characters and cannot contain slashes.", .{});
				return;
			}
			const slot = findHome(user, params.name) orelse blk: {
				for (user.player().homeNames, 0..) |name, i| if (name == null) break :blk i;
				user.sendMessage("#ff0000You can save up to {d} homes. Remove one first.", .{maxHomes});
				return;
			};
			if (user.player().homeNames[slot] == null) user.player().homeNames[slot] = main.globalAllocator.dupe(u8, params.name);
			user.player().homePositions[slot] = user.player().pos;
			user.sendMessage("#00ff00Home '{s}' saved.", .{params.name});
		},
		.@"/home remove <name>" => |params| {
			const slot = findHome(user, params.name) orelse {
				user.sendMessage("#ff0000No home matching '{s}' was found.", .{params.name});
				return;
			};
			if (user.player().homeNames[slot]) |name| main.globalAllocator.free(name);
			user.player().homeNames[slot] = null;
			user.player().homePositions[slot] = null;
			if (user.player().respawnHome == @as(u2, @intCast(slot))) user.player().respawnHome = null;
			user.sendMessage("#00ff00Home '{s}' removed.", .{params.name});
		},
		.@"/home spawn <name>" => |params| {
			const slot = findHome(user, params.name) orelse {
				user.sendMessage("#ff0000No home matching '{s}' was found.", .{params.name});
				return;
			};
			if (user.player().homePositions[slot] == null) {
				user.sendMessage("#ff0000That home has no position.", .{});
				return;
			}
			user.player().respawnHome = @intCast(slot);
			user.sendMessage("#00ff00Home '{s}' is now your respawn point.", .{params.name});
		},
		.@"/home <name>" => |params| {
			if (isReservedName(params.name)) {
				user.sendMessage("#ffff00Usage:\n{s}", .{usage});
				return;
			}
			const slot = findHome(user, params.name) orelse {
				user.sendMessage("#ff0000No home matching '{s}' was found.", .{params.name});
				return;
			};
			const position = user.player().homePositions[slot] orelse {
				user.sendMessage("#ff0000That home has no position.", .{});
				return;
			};
			user.teleport(position, true);
			user.sendMessage("#00ff00Teleported to home '{s}'.", .{params.name});
		},
	}
}
