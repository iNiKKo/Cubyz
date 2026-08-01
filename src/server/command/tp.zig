const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Teleport to location.";
pub const usage =
	\\/tp <biome>
	\\/tp <x> <y> <z>
	\\/tp @<playerIndex>
	\\/tp <player> <player>
;

pub const Args = union(enum) {
	@"/tp <biome>": struct { biome: command.BiomeId },
	@"/tp <x> <y> <z>": struct {
		x: command.Coordinate,
		y: command.Coordinate,
		z: command.Coordinate,
	},
	@"/tp <playerIndex>": struct { playerIndex: command.PlayerIndex },
	@"/tp <source> <destination>": struct { source: []const u8, destination: []const u8 },
};

pub fn execute(args: Args, source: Source) void {
	const user = source.requireUser() orelse return;
	switch (args) {
		.@"/tp <source> <destination>" => |params| {
			if (!source.requirePermission("/command/tp/admin")) return;
			const users = main.server.getUserList(main.stackAllocator);
			defer main.stackAllocator.free(users);
			const player = command.findUser(users, params.source) orelse {
				user.sendMessage("#ff0000Player '{s}' was not found or the name is ambiguous.", .{params.source});
				return;
			};
			const destination = command.findUser(users, params.destination) orelse {
				user.sendMessage("#ff0000Player '{s}' was not found or the name is ambiguous.", .{params.destination});
				return;
			};
			if (player == destination) {
				user.sendMessage("#ff0000A player cannot be teleported to themselves.", .{});
				return;
			}
			player.teleport(destination.player().pos, true);
			user.sendMessage("#00ff00Teleported {s} to {s}.", .{player.name, destination.name});
			if (player != user) player.sendMessage("#00ff00You were teleported to {s}.", .{destination.name});
			return;
		},
		else => {},
	}
	const pos: main.vec.Vec3d = blk: switch (args) {
		.@"/tp <biome>" => |b| {
			const biome = b.biome.biome;
			if (biome.isCave) {
				user.sendMessage("#ff0000Teleport to biome is only available for surface biomes.", .{});
				return;
			}
			const radius = 16384;
			const mapSize: i32 = main.server.terrain.ClimateMap.ClimateMapFragment.mapSize;

			const spiralLen = 2*radius/mapSize*2*radius/mapSize;
			var wx = user.lastPos[0] & ~(mapSize - 1);
			var wy = user.lastPos[1] & ~(mapSize - 1);
			var dirChanges: usize = 1;
			var dir: main.chunk.Neighbor = .dirNegX;
			var stepsRemaining: usize = 1;
			for (0..spiralLen) |_| {
				const map = main.server.terrain.ClimateMap.getOrGenerateFragment(wx, wy);
				for (0..map.map.len) |_| {
					const x = main.random.nextIntBounded(u31, &main.seed, map.map.len);
					const y = main.random.nextIntBounded(u31, &main.seed, map.map.len);
					const sample = map.map[x][y];
					if (sample.biome == biome) {
						const z = sample.height + sample.hills + sample.mountains + sample.roughness;
						const biomeSize = main.server.terrain.SurfaceMap.MapFragment.biomeSize;
						user.teleport(.{@floatFromInt(wx + x*biomeSize + biomeSize/2), @floatFromInt(wy + y*biomeSize + biomeSize/2), @floatCast(z + biomeSize/2)}, true);
						return;
					}
				}
				switch (dir) {
					.dirNegX => wx -%= mapSize,
					.dirPosX => wx +%= mapSize,
					.dirNegY => wy -%= mapSize,
					.dirPosY => wy +%= mapSize,
					else => unreachable,
				}
				stepsRemaining -= 1;
				if (stepsRemaining == 0) {
					switch (dir) {
						.dirNegX => dir = .dirNegY,
						.dirPosX => dir = .dirPosY,
						.dirNegY => dir = .dirPosX,
						.dirPosY => dir = .dirNegX,
						else => unreachable,
					}
					dirChanges += 1;

					stepsRemaining = dirChanges/2;
				}
			}
			user.sendMessage("#ff0000Couldn't find biome. Searched in a radius of 16384 blocks.", .{});
			return;
		},
		.@"/tp <x> <y> <z>" => |pos| {
			break :blk command.resolveCoordinates(pos.x, pos.y, pos.z, source) catch return;
		},
		.@"/tp <playerIndex>" => |index| {
			const target = command.Target.fromPlayerIndex(index.playerIndex, source) catch return;
			break :blk target.user.player().pos;
		},
		.@"/tp <source> <destination>" => unreachable,
	};
	user.teleport(pos, true);
}
