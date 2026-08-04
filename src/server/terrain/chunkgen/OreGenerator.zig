const std = @import("std");

const main = @import("main");
const random = main.random;
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMap = terrain.CaveMap;
const CaveBiomeMap = terrain.CaveBiomeMap;
const vec = main.vec;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;

pub const id = "cubyz:ore";

pub const priority = 32768;

pub const generatorSeed = 0x88773787bc9e0105;

pub const defaultState = .enabled;

var ores: []main.blocks.Ore = undefined;

pub fn init(parameters: ZonElement) void {
	_ = parameters;
	ores = main.blocks.ores.items;
}

pub fn generate(worldSeed: u64, chunk: *main.chunk.ServerChunk, caveMap: CaveMap.CaveMapView, biomeMap: CaveBiomeMap.CaveBiomeMapView) void {
	_ = caveMap;
	_ = biomeMap;
	if (chunk.super.pos.voxelSize != 1) return;
	const cx = chunk.super.pos.wx >> main.chunk.chunkShift;
	const cy = chunk.super.pos.wy >> main.chunk.chunkShift;
	const cz = chunk.super.pos.wz >> main.chunk.chunkShift;

	// Generate ores from all nearby chunks:
	var x = cx - 1;
	while (x < cx + 1) : (x +%= 1) {
		var y = cy - 1;
		while (y < cy + 1) : (y +%= 1) {
			var z = cz - 1;
			while (z < cz + 1) : (z +%= 1) {
				const seed = random.initSeed3D(worldSeed, .{x, y, z});
				const relX: f32 = @floatFromInt(x - cx << main.chunk.chunkShift);
				const relY: f32 = @floatFromInt(y - cy << main.chunk.chunkShift);
				const relZ: f32 = @floatFromInt(z - cz << main.chunk.chunkShift);
				for (ores) |*ore| {
					if (ore.maxHeight <= z << main.chunk.chunkShift or ore.minHeight > z << main.chunk.chunkShift) continue;
					considerCoordinates(ore, relX, relY, relZ, chunk, seed);
				}
			}
		}
	}
}

fn considerCoordinates(ore: *const main.blocks.Ore, relX: f32, relY: f32, relZ: f32, chunk: *main.chunk.ServerChunk, startSeed: u64) void {
	const chunkSizeFloat: f32 = @floatFromInt(main.chunk.chunkSize);

	var seed = startSeed ^ ore.seed;

	const veins: u32 = @trunc(random.nextFloat(&seed)*ore.veins*2);
	for (0..veins) |_| {

		const veinRelX = relX + random.nextFloat(&seed)*chunkSizeFloat;
		const veinRelY = relY + random.nextFloat(&seed)*chunkSizeFloat;
		const veinRelZ = relZ + random.nextFloat(&seed)*chunkSizeFloat;

		const size = (random.nextFloat(&seed) + 0.5)*ore.size;
		const expectedVolume = 2*size/ore.density;
		const radius = std.math.cbrt(expectedVolume*3/4/std.math.pi);
		var xMin: i32 = @floor(veinRelX - radius);
		var xMax: i32 = @ceil(veinRelX + radius);
		var yMin: i32 = @floor(veinRelY - radius);
		var yMax: i32 = @ceil(veinRelY + radius);
		xMin = @max(xMin, 0);
		xMax = @min(xMax, chunk.super.width);
		yMin = @max(yMin, 0);
		yMax = @min(yMax, chunk.super.width);

		var veinSeed = random.nextInt(u64, &seed);
		var curX = xMin;
		while (curX < xMax) : (curX += 1) {
			const distToCenterX = (@as(f32, @floatFromInt(curX)) - veinRelX)/radius;
			var curY = yMin;
			while (curY < yMax) : (curY += 1) {
				const distToCenterY = (@as(f32, @floatFromInt(curY)) - veinRelY)/radius;
				const xyDistSqr = distToCenterX*distToCenterX + distToCenterY*distToCenterY;
				if (xyDistSqr > 1) continue;
				const zDistance = radius*@sqrt(1 - xyDistSqr);
				var zMin: i32 = @floor(veinRelZ - zDistance);
				var zMax: i32 = @ceil(veinRelZ + zDistance);
				zMin = @max(zMin, 0);
				zMax = @min(zMax, chunk.super.width);
				var curZ = zMin;
				while (curZ < zMax) : (curZ += 1) {
					const distToCenterZ = (@as(f32, @floatFromInt(curZ)) - veinRelZ)/radius;
					const distSqr = xyDistSqr + distToCenterZ*distToCenterZ;
					if (distSqr < 1) {

						if ((1 - distSqr)*ore.density >= random.nextFloat(&veinSeed)) {
							const stoneBlock = chunk.getBlock(curX, curY, curZ);
							if (stoneBlock.allowOres()) {
								chunk.updateBlockInGeneration(curX, curY, curZ, .{.typ = ore.blockType, .data = stoneBlock.typ});
							}
						}
					}
				}
			}
		}
	}
}
