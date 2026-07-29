const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const Neighbor = main.chunk.Neighbor;
const ZonElement = main.ZonElement;
const server = main.server;

/// Water level is stored directly in the block's raw `data` field (no custom RotationMode needed,
/// since the default mode already treats `data` as opaque per-block storage):
/// 8 = source (never decays, keeps spreading forever), 1-7 = flowing (decays if it loses its supply),
/// 0 is unused (a flowing block that would drop to 0 reverts to air instead of persisting at level 0).
pub const sourceLevel: u16 = 4;

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

/// Highest level among neighbors that could feed this position (not counting straight-down fall).
/// Returns 0 if no fluid neighbor can supply it.
fn bestSupplyLevel(self: *@This(), world: *main.server.ServerWorld, wx: i32, wy: i32, wz: i32) u16 {
	var best: u16 = 0;
	for ([_]Neighbor{.dirPosX, .dirNegX, .dirPosY, .dirNegY}) |neighbor| {
		const neighborBlock = world.getBlock(wx +% neighbor.relX(), wy +% neighbor.relY(), wz +% neighbor.relZ()) orelse continue;
		if (!self.isFluid(neighborBlock)) continue;
		if (neighborBlock.data > best) best = neighborBlock.data;
	}
	// A fluid block sitting on top of us (falling water) supplies us at `above.data - 1` (falling consumes 1 level of distance budget)
	// unless `above` is a full source block (which maintains a full falling waterfall column).
	const above = world.getBlock(wx, wy, wz +% 1) orelse Block.air;
	if (self.isFluid(above) and above.data > 0) {
		const supplyFromAbove: u16 = if (above.data == sourceLevel) sourceLevel else (above.data -| 1);
		best = @max(best, supplyFromAbove);
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

	// A fluid block with data==0 is normalized to sourceLevel
	if (thisBlock.data == 0) {
		const normalized = Block{.typ = thisBlock.typ, .data = sourceLevel};
		if (world.cmpxchgBlock(wx, wy, wz, thisBlock, normalized) != null) {
			const current = world.getBlock(wx, wy, wz) orelse return .ignored;
			if (current.data == 0) {
				if (world.cmpxchgBlock(wx, wy, wz, current, normalized) != null) return .ignored;
			} else {
				thisBlock = current;
			}
		} else {
			thisBlock = normalized;
		}
	}

	var handled = false;

	// Falling: an open space below receives `thisBlock.data - 1` (or sourceLevel if falling from source)
	const belowBlock = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const wasOpenBelow = belowBlock.replaceable() and !self.isFluid(belowBlock);
	const fallingLevel: u16 = if (thisBlock.data == sourceLevel) sourceLevel else (thisBlock.data -| 1);

	if (fallingLevel > 0) {
		const fallingBlock = Block{.typ = thisBlock.typ, .data = fallingLevel};
		if (wasOpenBelow) {
			if (world.cmpxchgBlock(wx, wy, wz -% 1, belowBlock, fallingBlock) == null) {
				handled = true;
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz -% 1, 150);
			}
		} else if (self.isFluid(belowBlock) and belowBlock.data < fallingLevel) {
			if (world.cmpxchgBlock(wx, wy, wz -% 1, belowBlock, fallingBlock) == null) {
				handled = true;
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz -% 1, 150);
			}
		}
	}

	// Non-source blocks decay if they've lost their supply
	if (thisBlock.data != sourceLevel) {
		const supply = self.bestSupplyLevel(world, wx, wy, wz);
		const shouldBe: u16 = if (supply > 0) supply -| 1 else 0;
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

	// Spread horizontally into replaceable neighbors at level-1, but NOT if falling into open air below (enforces L-shaped waterfall flow)
	const canSpreadHere = !wasOpenBelow;
	if (canSpreadHere and thisBlock.data > 1) {
		const spreadLevel = thisBlock.data - 1;
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
