const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const Neighbor = main.chunk.Neighbor;
const ZonElement = main.ZonElement;
const server = main.server;

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

	if (thisBlock.data == 0) {
		const normalized = Block{.typ = thisBlock.typ, .data = sourceLevel};
		if (world.cmpxchgBlock(wx, wy, wz, thisBlock, normalized) != null) return .ignored;
		thisBlock = normalized;
	}

	var handled = false;
	const isSource = thisBlock.data == sourceLevel;

	const belowBlock = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const isFalling = belowBlock.replaceable() and !self.isFluid(belowBlock);
	if (isFalling) {
		const fallingBlock = Block{.typ = self.sourceBlock.typ, .data = maxFlowLevel};
		if (world.cmpxchgBlock(wx, wy, wz -% 1, belowBlock, fallingBlock) == null) {
			handled = true;
			world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz -% 1, 150);
		}
	}

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
