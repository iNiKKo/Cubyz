const std = @import("std");

const main = @import("main");
const Array3D = main.utils.Array3D;
const ChunkPosition = main.chunk.ChunkPosition;
const random = main.random;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

pub fn generateAligned(allocator: NeverFailingAllocator, wx: i32, wy: i32, wz: i32, voxelSize: u31, width: u31, depth: u31, height: u31, worldSeed: u64, scale: u31) Array3D(f32) {
	std.debug.assert(wx & scale - 1 == 0 and wy & scale - 1 == 0 and wz & scale - 1 == 0);
	std.debug.assert(width - 1 & scale/voxelSize - 1 == 0 and height - 1 & scale/voxelSize - 1 == 0 and depth - 1 & scale/voxelSize - 1 == 0);
	std.debug.assert(width > 1 and height > 1 and depth > 1);
	const map = Array3D(f32).init(allocator, width, depth, height);

	const scaledScale = scale/voxelSize;
	var x0: u31 = 0;
	while (x0 < width) : (x0 += scaledScale) {
		var y0: u31 = 0;
		while (y0 < depth) : (y0 += scaledScale) {
			var z0: u31 = 0;
			while (z0 < height) : (z0 += scaledScale) {
				var seed = random.initSeed3D(worldSeed, .{wx +% x0*voxelSize, wy +% y0*voxelSize, wz +% z0*voxelSize});
				map.ptr(x0, y0, z0).* = (random.nextFloat(&seed) - 0.5)*@as(f32, @floatFromInt(scale));
			}
		}
	}

	generateInitializedFractalTerrain(wx, wy, wz, scaledScale, worldSeed, map, voxelSize);

	return map;
}

fn generateInitializedFractalTerrain(wx: i32, wy: i32, wz: i32, startingScale: u31, worldSeed: u64, bigMap: Array3D(f32), maxResolution: u31) void {

	var seed: u64 = undefined;
	var res: u31 = startingScale/2;
	while (res != 0) : (res /= 2) {
		const randomnessScale: f32 = @floatFromInt(res*maxResolution);

		var x: u31 = 0;
		while (x < bigMap.width) : (x += 2*res) {
			var y: u31 = 0;
			while (y < bigMap.depth) : (y += 2*res) {
				var z: u31 = res;
				while (z + res < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x, y, z - res) + bigMap.get(x, y, z + res))/2;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = 0;
		while (x < bigMap.width) : (x += 2*res) {
			var y: u31 = res;
			while (y + res < bigMap.depth) : (y += 2*res) {
				var z: u31 = 0;
				while (z < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x, y - res, z) + bigMap.get(x, y + res, z))/2;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = res;
		while (x + res < bigMap.width) : (x += 2*res) {
			var y: u31 = 0;
			while (y < bigMap.depth) : (y += 2*res) {
				var z: u31 = 0;
				while (z < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x - res, y, z) + bigMap.get(x + res, y, z))/2;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = 0;
		while (x < bigMap.width) : (x += 2*res) {
			var y: u31 = res;
			while (y + res < bigMap.depth) : (y += 2*res) {
				var z: u31 = res;
				while (z + res < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x, y - res, z) + bigMap.get(x, y + res, z) + bigMap.get(x, y, z - res) + bigMap.get(x, y, z + res))/4;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = res;
		while (x + res < bigMap.width) : (x += 2*res) {
			var y: u31 = 0;
			while (y < bigMap.depth) : (y += 2*res) {
				var z: u31 = res;
				while (z + res < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x - res, y, z) + bigMap.get(x + res, y, z) + bigMap.get(x, y, z - res) + bigMap.get(x, y, z + res))/4;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = res;
		while (x + res < bigMap.width) : (x += 2*res) {
			var y: u31 = res;
			while (y + res < bigMap.depth) : (y += 2*res) {
				var z: u31 = 0;
				while (z < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x - res, y, z) + bigMap.get(x + res, y, z) + bigMap.get(x, y - res, z) + bigMap.get(x, y + res, z))/4;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}

		x = res;
		while (x < bigMap.width) : (x += 2*res) {
			var y: u31 = res;
			while (y + res < bigMap.depth) : (y += 2*res) {
				var z: u31 = res;
				while (z + res < bigMap.height) : (z += 2*res) {
					seed = random.initSeed3D(worldSeed, .{x*maxResolution +% wx, y*maxResolution +% wy, z*maxResolution +% wz});
					bigMap.ptr(x, y, z).* = (bigMap.get(x - res, y, z) + bigMap.get(x + res, y, z) + bigMap.get(x, y - res, z) + bigMap.get(x, y + res, z) + bigMap.get(x, y, z - res) + bigMap.get(x, y, z + res))/6;
					bigMap.ptr(x, y, z).* += randomnessScale*(random.nextFloat(&seed) - 0.5);
				}
			}
		}
	}
}
