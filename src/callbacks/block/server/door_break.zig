const main = @import("main");
const ZonElement = main.ZonElement;

const upperHalf: u16 = 8;

pub fn init(_: ZonElement, _: main.callbacks.Creator) ?*@This() {
	return @as(*@This(), undefined);
}

pub fn run(_: *@This(), params: main.callbacks.ServerBlockCallback.Params) main.callbacks.Result {
	const wx = params.chunk.super.pos.wx + params.blockPos.x;
	const wy = params.chunk.super.pos.wy + params.blockPos.y;
	const wz = params.chunk.super.pos.wz + params.blockPos.z;
	const partnerZ = if (params.block.data & upperHalf == 0) wz + 1 else wz - 1;
	const partner = main.server.world.?.getBlock(wx, wy, partnerZ) orelse return .ignored;
	if (partner.typ != params.block.typ) return .ignored;
	_ = main.server.world.?.cmpxchgBlock(wx, wy, partnerZ, partner, .air);
	return .handled;
}
