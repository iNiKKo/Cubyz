const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const Neighbor = main.chunk.Neighbor;
const ZonElement = main.ZonElement;
const server = main.server;

/// Water level is stored directly in the block's raw `data` field (no custom RotationMode needed,
/// since the default mode already treats `data` as opaque per-block storage):
/// `sourceLevel` = a PERMANENT source (player-placed or world-gen ocean/lake) - never decays, keeps
/// spreading/falling forever. `maxFlowLevel`..1 = flowing water - decays if it loses its supply, even if
/// a waterfall has topped it up all the way to `maxFlowLevel` (full visual strength). These must be two
/// distinct values: a flowing block topped up to full strength by a falling column is NOT the same thing
/// as an actual permanent source, and needs to be tellable apart so it can still decay once whatever fed
/// it is gone - see the dated fix note in this file's history for the exact bug this distinction fixes
/// (destroying the source block on a pillar/waterfall left everything below the very top segment
/// permanently alive, since a fed block sitting at the old single "full strength" value was
/// indistinguishable from a real source and therefore skipped the decay check entirely).
/// 0 is unused (a flowing block that would drop to 0 reverts to air instead of persisting at level 0).
pub const maxFlowLevel: u16 = 4;
pub const sourceLevel: u16 = maxFlowLevel + 1;

sourceBlock: Block,

pub fn init(zon: ZonElement, creator: main.callbacks.Creator) ?*@This() {
	const block = switch (creator) {
		.block => |b| b,
	};
	_ = zon;
	const result = main.worldArena.create(@This());
	result.sourceBlock = .{.typ = block.typ, .data = sourceLevel};
	return result;
}

fn isFluid(self: *@This(), block: Block) bool {
	return block.typ == self.sourceBlock.typ;
}

/// Highest level among horizontal neighbors that could feed this position (falling supply from directly
/// above is handled separately in `run`, since a falling column always supplies at full flowing strength
/// regardless of the source's own level - see the comment on `fedByFallingAbove`). Returns 0 if no
/// horizontal fluid neighbor can supply it. A permanent source neighbor supplies at `maxFlowLevel` (not
/// `sourceLevel`) - the flowing water spreading away from it is never itself a source.
fn bestHorizontalSupplyLevel(self: *@This(), world: *main.server.ServerWorld, wx: i32, wy: i32, wz: i32) u16 {
	var best: u16 = 0;
	for ([_]Neighbor{.dirPosX, .dirNegX, .dirPosY, .dirNegY}) |neighbor| {
		const neighborBlock = world.getBlock(wx +% neighbor.relX(), wy +% neighbor.relY(), wz +% neighbor.relZ()) orelse continue;
		if (!self.isFluid(neighborBlock)) continue;
		const supplyLevel = if (neighborBlock.data == sourceLevel) maxFlowLevel else neighborBlock.data;
		if (supplyLevel > best) best = supplyLevel;
	}
	return best;
}

pub fn run(self: *@This(), params: main.callbacks.ServerBlockCallback.Params) main.callbacks.Result {
	const wx = params.chunk.super.pos.wx + params.blockPos.x;
	const wy = params.chunk.super.pos.wy + params.blockPos.y;
	const wz = params.chunk.super.pos.wz + params.blockPos.z;

	const world = server.world orelse return .ignored;
	var thisBlock = world.getBlock(wx, wy, wz) orelse return .ignored;
	if (!self.isFluid(thisBlock)) return .ignored;

	// A fluid block with data==0 is never a meaningful steady state (see the type doc comment above) -
	// encountering one here means it was just placed (e.g. via the creative menu) and hasn't been
	// normalized yet. Treat it as a freshly placed permanent source.
	if (thisBlock.data == 0) {
		const normalized = Block{.typ = thisBlock.typ, .data = sourceLevel};
		if (world.cmpxchgBlock(wx, wy, wz, thisBlock, normalized) != null) return .ignored;
		thisBlock = normalized;
	}

	var handled = false;
	const isSource = thisBlock.data == sourceLevel;

	// Falling: water above open space always falls at FULL flowing strength all the way down, matching
	// vanilla Minecraft - a waterfall never weakens as it falls, no matter how far, but the falling water
	// itself is flowing water (maxFlowLevel), not a new permanent source, even when it fell from one.
	// This also means a block that is currently falling (has open air below it) must NOT spread sideways
	// itself; only once it actually lands (below is solid ground or an existing water surface) does it
	// start spreading outward, decaying by 1 per horizontal step from THAT point - exactly the "keep
	// going down for free, then start counting the spread allowance from the first block it touches"
	// behavior requested.
	const belowBlock = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const isFalling = belowBlock.replaceable() and !self.isFluid(belowBlock);
	if (isFalling) {
		const fallingBlock = Block{.typ = self.sourceBlock.typ, .data = maxFlowLevel};
		if (world.cmpxchgBlock(wx, wy, wz -% 1, belowBlock, fallingBlock) == null) {
			handled = true;
			world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz -% 1, 150);
		}
	}

	// Non-source blocks decay if they've lost their supply. A block being actively fed by a falling
	// column directly above it counts as fully supplied at maxFlowLevel (falling water always tops up
	// what it lands in), independent of the horizontal-neighbor-based supply check below. Permanent
	// sources skip this decay check entirely - they never lose their own strength, only what flows away
	// from them can run dry.
	if (!isSource) {
		const above = world.getBlock(wx, wy, wz +% 1) orelse Block.air;
		const fedByFallingAbove = self.isFluid(above);
		const horizontalSupply = self.bestHorizontalSupplyLevel(world, wx, wy, wz);
		const shouldBe: u16 = if (fedByFallingAbove) maxFlowLevel else if (horizontalSupply > 0) horizontalSupply -| 1 else 0;
		if (shouldBe == 0) {
			if (world.cmpxchgBlock(wx, wy, wz, thisBlock, Block.air) == null) {
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz, 150);
				return .handled;
			}
			return .ignored;
		} else if (shouldBe != thisBlock.data) {
			const updated = Block{.typ = thisBlock.typ, .data = shouldBe};
			if (world.cmpxchgBlock(wx, wy, wz, thisBlock, updated) == null) {
				handled = true;
				thisBlock = updated;
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz, 150);
			}
		}
	}

	// Spread horizontally only once this block is resting on solid, non-fluid ground - NOT merely "has
	// something non-open below it," since water is itself replaceable/fluid and a tall vertical column
	// (e.g. a pillar of source blocks stacked in open air, or a still-falling waterfall) would otherwise
	// have every block in the column see fluid directly beneath it and think it had "landed." That bug
	// produced a pyramid many times wider than intended - every level of a falling column was spreading
	// a full 3 tiles outward, not just the block actually touching the ground. Re-read belowBlock fresh
	// in case the fall above just changed it (e.g. this exact block just finished falling onto ground).
	const restingBelow = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const canSpreadHere = !restingBelow.replaceable() and !self.isFluid(restingBelow);
	const spreadFrom = if (isSource) maxFlowLevel else thisBlock.data;
	if (canSpreadHere and spreadFrom > 1) {
		const spreadLevel = spreadFrom - 1;
		for ([_]Neighbor{.dirPosX, .dirNegX, .dirPosY, .dirNegY}) |neighbor| {
			const nx = wx +% neighbor.relX();
			const ny = wy +% neighbor.relY();
			const nz = wz +% neighbor.relZ();
			const neighborBlock = world.getBlock(nx, ny, nz) orelse continue;
			if (self.isFluid(neighborBlock)) continue;
			if (!neighborBlock.replaceable()) continue;
			const newBlock = Block{.typ = thisBlock.typ, .data = spreadLevel};
			if (world.cmpxchgBlock(nx, ny, nz, neighborBlock, newBlock) == null) {
				handled = true;
				world.triggerNeighborBlockUpdatesWithDelay(nx, ny, nz, 150);
			}
		}
	}

	if (handled) return .handled;
	return .ignored;
}
