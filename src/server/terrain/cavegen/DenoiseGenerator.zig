const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMapFragment = terrain.CaveMap.CaveMapFragment;

pub const id = "cubyz:denoise";

pub const priority = 393216;

pub const generatorSeed = 0xd8e2015a5e13b45f;

pub const defaultState = .enabled;

pub fn init(parameters: ZonElement) void {
	_ = parameters;
}

const removeThreshold: u32 = 1;

const fillThreshold: u32 = 5;

pub fn generate(map: *CaveMapFragment, worldSeed: u64) void {
	_ = worldSeed;
	const width = CaveMapFragment.width;

	const newData = main.stackAllocator.alloc(u64, width*width);
	defer main.stackAllocator.free(newData);
	@memcpy(newData, &map.data);

	var x: i32 = 1;
	while (x < width - 1) : (x += 1) {
		var y: i32 = 1;
		while (y < width - 1) : (y += 1) {
			const colC = map.data[@intCast(x*width + y)];
			const colXm = map.data[@intCast((x - 1)*width + y)];
			const colXp = map.data[@intCast((x + 1)*width + y)];
			const colYm = map.data[@intCast(x*width + (y - 1))];
			const colYp = map.data[@intCast(x*width + (y + 1))];

			const colZm = (colC << 1) | (colC & 1);
			const colZp = (colC >> 1) | (colC & (@as(u64, 1) << 63));

			const a0 = colXm ^ colXp;
			const a1 = colXm & colXp;
			const b0 = colYm ^ colYp;
			const b1 = colYm & colYp;
			const c0 = colZm ^ colZp;
			const c1 = colZm & colZp;

			const s0 = a0 ^ b0;
			const carry0 = a0 & b0;
			const sum0 = s0 ^ c0;
			const carry1 = (s0 & c0) | carry0;

			const s1 = a1 ^ b1;
			const carry2 = a1 & b1;
			const sum1a = s1 ^ c1;
			const carry3 = (s1 & c1) | carry2;

			const sum1 = sum1a ^ carry1;
			const carry4 = sum1a & carry1;

			const sum2 = carry3 ^ carry4;

			const countLessEq1 = ~sum2 & ~sum1;

			const countGreaterEq5 = sum2 & (sum1 | sum0);

			const removeMask = colC & countLessEq1;
			const fillMask = ~colC & countGreaterEq5;

			newData[@intCast(x*width + y)] = (colC & ~removeMask) | fillMask;
		}
	}

	@memcpy(&map.data, newData);
}
