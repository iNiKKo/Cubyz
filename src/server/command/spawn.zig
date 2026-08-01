const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const User = main.server.User;

pub const description = "Teleport to spawn or manage spawn points";
pub const usage =
	\\/spawn
	\\/spawn <x> <y> <z>
	\\/spawn @<playerIndex>
	\\/spawn @<playerIndex> <x> <y> <z>
	\\/spawn world
	\\/spawn world <x> <y> <z>
;

pub const Args = union(enum) {
	@"/spawn": struct {},
	@"/spawn <playerIndex> <x> <y> <z>": struct { playerIndex: ?command.PlayerIndex, x: command.Coordinate, y: command.Coordinate, z: command.Coordinate },
	@"/spawn <world> <x> <y> <z>": struct { world: enum { world }, x: command.Coordinate, y: command.Coordinate, z: command.Coordinate },
	@"/spawn <world>": struct { world: enum { world } },
	@"/spawn <playerIndex>": struct { playerIndex: ?command.PlayerIndex },
};

pub fn execute(args: Args, source: Source) void {
	switch (args) {
		.@"/spawn" => {
			const user = source.requireUser() orelse return;
			user.teleport(@floatFromInt(main.server.world.?.spawn), true);
			user.sendMessage("#00ff00Teleported to global spawn.", .{});
		},
		.@"/spawn <playerIndex> <x> <y> <z>" => |params| {
			if (!source.requirePermission("/command/spawn/admin")) return;
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			target.user.spawnPos = command.resolveCoordinates(params.x, params.y, params.z, source) catch return;
		},
		.@"/spawn <playerIndex>" => |params| {
			if (!source.requirePermission("/command/spawn/admin")) return;
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			source.sendMessage("#ffff00{}", .{target.user.getRespawnPos()});
		},
		.@"/spawn <world> <x> <y> <z>" => |params| {
			if (!source.requirePermission("/command/spawn/admin")) return;
			const pos = command.resolveCoordinates(params.x, params.y, params.z, source) catch return;
			const world = main.server.world.?;
			world.spawn = @trunc(pos);
		},
		.@"/spawn <world>" => {
			if (!source.requirePermission("/command/spawn/admin")) return;
			const world = main.server.world.?;
			source.sendMessage("#ffff00World spawn: {}", .{world.spawn});
		},
	}
}
