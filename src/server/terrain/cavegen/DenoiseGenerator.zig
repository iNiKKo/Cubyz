const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMapFragment = terrain.CaveMap.CaveMapFragment;

pub const id = "cubyz:denoise";

// Must run after every other cave/SDF generator has finished carving/filling the bitmap, so it cleans
// up whatever they produced rather than being carved over itself. Higher than OceanFixer's 262144.
pub const priority = 393216;

pub const generatorSeed = 0xd8e2015a5e13b45f;

pub const defaultState = .enabled;

pub fn init(parameters: ZonElement) void {
	_ = parameters;
}

// A solid voxel touching this many or fewer of its 6 face-neighbors is a stray floating speck and gets
// removed. A voxel in the middle of any wall/bridge at least 2 voxels thick always has >=2 in-plane
// solid neighbors, so this conservative threshold shouldn't eat legitimate thin terrain features.
const removeThreshold: u32 = 1;
// An air voxel touching this many or more solid face-neighbors is a stray single-voxel pinhole and gets
// filled.
const fillThreshold: u32 = 5;

/// Removes single-voxel floating specks and fills single-voxel air pockets left behind by SdfCaveGenerator's
/// per-voxel noise term (see biomes.zig's caveNoiseStrength), which can flip isolated voxels near a solid
/// shape's boundary. Operates purely on 6-connectivity within this fragment: X/Y neighbor columns come from
/// this same fragment (the outermost 1-voxel X/Y rim of each fragment is intentionally left untouched to
/// avoid fetching/recursing into neighboring fragments — a small, symmetric blind spot, not a correctness
/// bug), and Z neighbors come from shifting the column's own bits, with the top/bottom bit of the fragment
/// clamped to itself (no fragment above/below to check, so it never counts as "isolated" from that side alone).
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
			// Z neighbors via shift; the bit shifted in at the fragment's own top/bottom edge is filled in
			// from colC itself (no neighbor fragment consulted), so a voxel at z=0 or z=63 is never treated
			// as missing a neighbor purely because it's at the edge of this fragment's data.
			const colZm = (colC << 1) | (colC & 1);
			const colZp = (colC >> 1) | (colC & (@as(u64, 1) << 63));

			// Bit-sliced (SWAR) full-adder network: sums 6 single-bit masks into a 3-bit count per lane,
			// all 64 lanes (voxels in this column) processed in parallel via plain 64-bit bitwise ops
			// instead of looping bit-by-bit 64 times.
			const a0 = colXm ^ colXp;
			const a1 = colXm & colXp;
			const b0 = colYm ^ colYp;
			const b1 = colYm & colYp;
			const c0 = colZm ^ colZp;
			const c1 = colZm & colZp;

			// Sum the three partial sums (a0+b0+c0 as bits, carries into bit1) plus the three partial
			// carries (a1, b1, c1) plus the carries generated while summing the low bits.
			const s0 = a0 ^ b0;
			const carry0 = a0 & b0;
			const sum0 = s0 ^ c0; // final bit0 of count
			const carry1 = (s0 & c0) | carry0;

			const s1 = a1 ^ b1;
			const carry2 = a1 & b1;
			const sum1a = s1 ^ c1;
			const carry3 = (s1 & c1) | carry2;

			const sum1 = sum1a ^ carry1; // final bit1 of count
			const carry4 = sum1a & carry1;

			const sum2 = carry3 ^ carry4; // final bit2 of count (max count is 6, fits in 3 bits)

			// countLessEq(removeThreshold=1): count is 0 or 1, i.e. bit2=0 and bit1=0.
			const countLessEq1 = ~sum2 & ~sum1;
			// countGreaterEq(fillThreshold=5): count is 5 or 6, i.e. bit2=1 and (bit1=0 or bit0=0... );
			// 5=101, 6=110 -> bit2=1 and (bit1=1 or bit0=1) minus 7(not reachable, max 6) — simpler: count>=5
			// iff bit2=1 and (sum1 | sum0) since 4(100) is the only bit2=1 case below 5, where sum1=0,sum0=0.
			const countGreaterEq5 = sum2 & (sum1 | sum0);

			const removeMask = colC & countLessEq1;
			const fillMask = ~colC & countGreaterEq5;

			newData[@intCast(x*width + y)] = (colC & ~removeMask) | fillMask;
		}
	}

	@memcpy(&map.data, newData);
}
