const main = @import("main");
const Block = main.blocks.Block;
const Vec3f = main.vec.Vec3f;
const Vec3i = main.vec.Vec3i;
const ZonElement = main.ZonElement;

pub fn init(_: ZonElement, _: main.callbacks.Creator) ?*@This() {
	return @as(*@This(), undefined);
}

pub fn run(_: *@This(), params: main.callbacks.ClientBlockCallback.Params) main.callbacks.Result {
	var newBlock: Block = params.block;
	newBlock.data ^= 4;
	const partnerPos = params.blockPos + Vec3i{0, 0, if ((params.block.data & 8) == 0) 1 else -1};
	if ((newBlock.data & 4) == 0) {
		const playerPos = main.game.Player.getPosBlocking() + main.game.Player.outerBoundingBox.center();
		const playerExtent = main.game.Player.outerBoundingBox.extent();
		if (main.physics.collision.collideWithBlock(newBlock, params.blockPos[0], params.blockPos[1], params.blockPos[2], playerPos, playerExtent, .{0, 0, 0}) != null) return .handled;
		if (main.renderer.mesh_storage.getBlockFromRenderThread(partnerPos[0], partnerPos[1], partnerPos[2])) |partner| {
			const closedPartner = Block{.typ = partner.typ, .data = (partner.data & 8) | (newBlock.data & 7)};
			if (partner.typ == params.block.typ and main.physics.collision.collideWithBlock(closedPartner, partnerPos[0], partnerPos[1], partnerPos[2], playerPos, playerExtent, .{0, 0, 0}) != null) return .handled;
		}
	}
	main.sync.client.executeCommand(.{
		.updateBlock = .{
			.source = .{.inv = main.game.Player.inventory.super, .slot = main.game.Player.selectedSlot},
			.pos = params.blockPos,
			.dropLocation = .{
				.normalDir = Vec3f{0, 0, 1},
				.min = Vec3f{0, 0, 0},
				.max = Vec3f{1, 1, 1},
			},
			.oldBlock = params.block,
			.newBlock = newBlock,
		},
	});
	main.renderer.mesh_storage.updateBlock(.{.pos = params.blockPos, .newBlock = newBlock, .blockEntityData = &.{}});
	if (main.renderer.mesh_storage.getBlockFromRenderThread(partnerPos[0], partnerPos[1], partnerPos[2])) |partner| {
		if (partner.typ == params.block.typ) {
			main.renderer.mesh_storage.updateBlock(.{
				.pos = partnerPos,
				.newBlock = .{.typ = partner.typ, .data = (partner.data & 8) | (newBlock.data & 7)},
				.blockEntityData = &.{},
			});
		}
	}
	return .handled;
}
