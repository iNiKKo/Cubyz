const std = @import("std");

const main = @import("main");
const random = main.random;
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMap = terrain.CaveMap;
const CaveBiomeMap = terrain.CaveBiomeMap;
const vec = main.vec;
const Vec3d = vec.Vec3d;

pub const id = "cubyz:mob_spawn";

pub const priority = 200000;

pub const generatorSeed = 0x6d6f66666f6c6f21;

pub const defaultState = .enabled;

const spawnChance: f32 = 0.9;

const allowedBiomes = [_][]const u8{
	"cubyz:grassland",
	"cubyz:prairie/base",
};

fn isAllowedBiome(biomeId: []const u8) bool {
	for (allowedBiomes) |allowed| {
		if (std.mem.eql(u8, biomeId, allowed)) return true;
	}
	return false;
}

pub fn init(parameters: ZonElement) void {
	_ = parameters;
}

pub fn generate(worldSeed: u64, chunk: *main.chunk.ServerChunk, caveMap: CaveMap.CaveMapView, biomeMap: CaveBiomeMap.CaveBiomeMapView) void {
	_ = caveMap;
	if (chunk.super.pos.voxelSize != 1) return;

	var seed = random.initSeed3D(worldSeed, .{chunk.super.pos.wx, chunk.super.pos.wy, chunk.super.pos.wz});
	if (random.nextFloat(&seed) >= spawnChance) return;

	const x = random.nextIntBounded(u31, &seed, main.chunk.chunkSize);
	const y = random.nextIntBounded(u31, &seed, main.chunk.chunkSize);
	const wx = chunk.super.pos.wx +% x;
	const wy = chunk.super.pos.wy +% y;

	const worldSurfaceZ = biomeMap.getSurfaceHeight(wx, wy);
	const relZ = worldSurfaceZ -% chunk.super.pos.wz;
	if (relZ < 0 or relZ + 2 >= chunk.super.width) return;

	const biome = biomeMap.getBiome(x, y, relZ);
	if (biome.isCave or !isAllowedBiome(biome.id)) return;

	const ground = chunk.getBlock(x, y, relZ);
	if (ground.typ == 0 or !ground.collide()) return;
	if (chunk.getBlock(x, y, relZ + 1).typ != 0) return;
	if (chunk.getBlock(x, y, relZ + 2).typ != 0) return;

	const modelIndex = main.entityModel.getById("cubyz:moffalo") orelse main.entityModel.default();
	const halfHeight: f64 = @floatCast(modelIndex.get().height*0.5);
	const pos = Vec3d{@floatFromInt(wx), @floatFromInt(wy), @as(f64, @floatFromInt(worldSurfaceZ + 1)) + halfHeight};
	main.server.world.?.mobManager.spawn(pos, .moffalo);
}
