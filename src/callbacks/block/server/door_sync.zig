const main = @import("main");
const Block = main.blocks.Block;
const ZonElement = main.ZonElement;

const upperHalf: u16 = 8;

pub fn init(_: ZonElement, _: main.callbacks.Creator) ?*@This() {
	return @as(*@This(), undefined);
}

pub fn run(_: *@This(), params: main.callbacks.ServerBlockCallback.Params) main.callbacks.Result {
	const wx = params.chunk.super.pos.wx + params.blockPos.x;
	const wy = params.chunk.super.pos.wy + params.blockPos.y;
	const wz = params.chunk.super.pos.wz + params.blockPos.z;
	const world = main.server.world.?;
	const baseData = params.block.data & 7;

	if (params.block.data & upperHalf != 0) {
		const lower = world.getBlock(wx, wy, wz - 1) orelse return .ignored;
		if (lower.typ != params.block.typ or lower.data & 3 != baseData & 3) {
			_ = world.cmpxchgBlock(wx, wy, wz, params.block, .air);
			return .handled;
		}
		if (lower.data & 7 != baseData) {
			_ = world.cmpxchgBlock(wx, wy, wz - 1, lower, .{.typ = lower.typ, .data = baseData});
		}
		return .handled;
	}

	const support = world.getBlock(wx, wy, wz - 1) orelse return .ignored;
	if (support.replaceable()) {
		if (world.getBlock(wx, wy, wz + 1)) |upper| {
			_ = world.cmpxchgBlock(wx, wy, wz + 1, upper, upper);
		}
		_ = world.cmpxchgBlock(wx, wy, wz, params.block, .air);
		return .handled;
	}

	const upper = world.getBlock(wx, wy, wz + 1) orelse return .ignored;
	const expectedUpper = Block{.typ = params.block.typ, .data = baseData | upperHalf};
	if (upper.typ == params.block.typ) {
		if (upper.data & 3 != baseData & 3) {
			_ = world.cmpxchgBlock(wx, wy, wz + 1, upper, upper);
			_ = world.cmpxchgBlock(wx, wy, wz, params.block, .air);
			return .handled;
		}
		if (upper != expectedUpper) _ = world.cmpxchgBlock(wx, wy, wz + 1, upper, expectedUpper);
		return .handled;
	}
	if (!upper.replaceable()) {
		_ = world.cmpxchgBlock(wx, wy, wz + 1, upper, upper);
		_ = world.cmpxchgBlock(wx, wy, wz, params.block, .air);
		return .handled;
	}
	_ = world.cmpxchgBlock(wx, wy, wz + 1, upper, expectedUpper);
	return .handled;
}
