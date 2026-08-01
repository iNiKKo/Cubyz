const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const blocks = main.blocks;
const Neighbor = main.chunk.Neighbor;
const ZonElement = main.ZonElement;
const server = main.server;

pub const maxFlowLevel: u16 = 4;
pub const sourceLevel: u16 = maxFlowLevel + 1;
const levelMask: u16 = 0x7;
const shapeValidBit: u16 = 0x8000;

sourceBlock: Block,
flowLevel: u16,
shapeMaxLevel: u16,
updateDelayMs: i64,

pub fn init(zon: ZonElement, creator: main.callbacks.Creator) ?*@This() {
	const block = switch (creator) {
		.block => |b| b,
	};
	_ = zon;
	const result = main.worldArena.create(@This());
	result.sourceBlock = .{.typ = block.typ, .data = sourceLevel};
	if (std.mem.eql(u8, block.id(), "cubyz:lava")) {
		result.flowLevel = maxFlowLevel;
		result.shapeMaxLevel = 4;
		result.updateDelayMs = 3000;
	} else {
		result.flowLevel = maxFlowLevel;
		result.shapeMaxLevel = maxFlowLevel;
		result.updateDelayMs = 750;
	}
	return result;
}

fn isFluid(self: *@This(), block: Block) bool {
	return block.typ == self.sourceBlock.typ;
}

fn level(block: Block) u16 {
	return block.data & levelMask;
}

fn withLevel(block: Block, newLevel: u16) Block {
	return .{.typ = block.typ, .data = (block.data & ~levelMask) | newLevel};
}

fn surfaceLevel(self: *@This(), block: Block) u16 {
	if (!self.isFluid(block)) return 0;
	return @min(if (level(block) == sourceLevel) self.shapeMaxLevel else level(block), self.shapeMaxLevel);
}

fn cornerLevel(self: *@This(), world: *main.server.ServerWorld, wx: i32, wy: i32, wz: i32, dx: i32, dy: i32, fallback: Block) u16 {
	const a = self.surfaceLevel(fallback);
	const b = self.surfaceLevel(world.getBlock(wx +% dx, wy, wz) orelse Block.air);
	const c = self.surfaceLevel(world.getBlock(wx, wy +% dy, wz) orelse Block.air);
	const d = self.surfaceLevel(world.getBlock(wx +% dx, wy +% dy, wz) orelse Block.air);
	return @max(a, @max(b, @max(c, d)));
}

fn withShape(self: *@This(), world: *main.server.ServerWorld, wx: i32, wy: i32, wz: i32, block: Block) Block {
	const above = world.getBlock(wx, wy, wz +% 1) orelse Block.air;
	const below = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const verticalFlow = self.isFluid(above) or (below.replaceable() and !below.hasTag(.fluid));
	const pos_x_pos_y = if (verticalFlow) self.shapeMaxLevel else self.cornerLevel(world, wx, wy, wz, 1, 1, block);
	const neg_x_pos_y = if (verticalFlow) self.shapeMaxLevel else self.cornerLevel(world, wx, wy, wz, -1, 1, block);
	const pos_x_neg_y = if (verticalFlow) self.shapeMaxLevel else self.cornerLevel(world, wx, wy, wz, 1, -1, block);
	const neg_x_neg_y = if (verticalFlow) self.shapeMaxLevel else self.cornerLevel(world, wx, wy, wz, -1, -1, block);
	return .{.typ = block.typ, .data = (block.data & levelMask) | shapeValidBit | pos_x_pos_y << 3 | neg_x_pos_y << 6 | pos_x_neg_y << 9 | neg_x_neg_y << 12};
}

fn bestHorizontalSupplyLevel(self: *@This(), world: *main.server.ServerWorld, wx: i32, wy: i32, wz: i32) u16 {
	var best: u16 = 0;
	for ([_]Neighbor{.dirPosX, .dirNegX, .dirPosY, .dirNegY}) |neighbor| {
		const neighborBlock = world.getBlock(wx +% neighbor.relX(), wy +% neighbor.relY(), wz +% neighbor.relZ()) orelse continue;
		if (!self.isFluid(neighborBlock)) continue;
		const neighborLevel = level(neighborBlock);
		const supplyLevel = if (neighborLevel == sourceLevel) self.flowLevel else neighborLevel;
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

	if (level(thisBlock) == 0) {
		const normalized = withLevel(thisBlock, sourceLevel);
		if (world.cmpxchgBlock(wx, wy, wz, thisBlock, normalized) != null) return .ignored;
		thisBlock = normalized;
	}

	var handled = false;
	const isSource = level(thisBlock) == sourceLevel;

	const belowBlock = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const isFalling = belowBlock.replaceable() and !belowBlock.hasTag(.fluid);
	if (isFalling) {
		const fallingBlock = Block{.typ = self.sourceBlock.typ, .data = self.flowLevel};
		if (world.cmpxchgBlock(wx, wy, wz -% 1, belowBlock, fallingBlock) == null) {
			handled = true;
			world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz -% 1, self.updateDelayMs);
		}
	}

	if (!isSource) {
		const above = world.getBlock(wx, wy, wz +% 1) orelse Block.air;
		const fedByFallingAbove = self.isFluid(above);
		const horizontalSupply = self.bestHorizontalSupplyLevel(world, wx, wy, wz);
		const shouldBe: u16 = if (fedByFallingAbove) self.flowLevel else if (horizontalSupply > 0) horizontalSupply -| 1 else 0;
		if (shouldBe == 0) {
			if (world.cmpxchgBlock(wx, wy, wz, thisBlock, Block.air) == null) {
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz, self.updateDelayMs);
				return .handled;
			}
			return .ignored;
		} else if (shouldBe != level(thisBlock)) {
			const updated = withLevel(thisBlock, shouldBe);
			if (world.cmpxchgBlock(wx, wy, wz, thisBlock, updated) == null) {
				handled = true;
				thisBlock = updated;
				world.triggerNeighborBlockUpdatesWithDelay(wx, wy, wz, self.updateDelayMs);
			}
		}
	}

	const restingBelow = world.getBlock(wx, wy, wz -% 1) orelse Block.air;
	const canSpreadHere = !restingBelow.replaceable() and !restingBelow.hasTag(.fluid);
	const spreadFrom = if (isSource) self.flowLevel else level(thisBlock);
	if (canSpreadHere and spreadFrom > 1) {
		const spreadLevel = spreadFrom - 1;
		for ([_]Neighbor{.dirPosX, .dirNegX, .dirPosY, .dirNegY}) |neighbor| {
			const nx = wx +% neighbor.relX();
			const ny = wy +% neighbor.relY();
			const nz = wz +% neighbor.relZ();
			const neighborBlock = world.getBlock(nx, ny, nz) orelse continue;
			if (neighborBlock.hasTag(.fluid)) continue;
			if (!neighborBlock.replaceable()) continue;
			const newBlock = Block{.typ = thisBlock.typ, .data = spreadLevel};
			if (world.cmpxchgBlock(nx, ny, nz, neighborBlock, newBlock) == null) {
				handled = true;
				world.triggerNeighborBlockUpdatesWithDelay(nx, ny, nz, self.updateDelayMs);
			}
		}
	}

	const shapedBlock = withShape(self, world, wx, wy, wz, thisBlock);
	if (shapedBlock != thisBlock and world.cmpxchgBlock(wx, wy, wz, thisBlock, shapedBlock) == null) {
		handled = true;
		for ([_]i32{-1, 1}) |dx| {
			for ([_]i32{-1, 1}) |dy| world.triggerNeighborBlockUpdatesWithDelay(wx +% dx, wy +% dy, wz, self.updateDelayMs);
		}
	}

	if (handled) return .handled;
	return .ignored;
}
