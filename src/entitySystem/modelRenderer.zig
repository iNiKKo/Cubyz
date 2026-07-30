const std = @import("std");

const main = @import("main");
const chunk = main.chunk;
const ServerChunk = chunk.ServerChunk;
const game = main.game;
const graphics = main.graphics;
const ZonElement = main.ZonElement;
const renderer = main.renderer;
const settings = main.settings;
const utils = main.utils;
const BinaryReader = utils.BinaryReader;
const BinaryWriter = utils.BinaryWriter;
const vec = main.vec;
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const Vec3i = vec.Vec3i;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const blocks = main.blocks;
const World = game.World;
const ServerWorld = main.server.ServerWorld;
const items = main.items;
const ItemStack = items.ItemStack;
const random = main.random;
const entity = main.entity;

const c = @import("c");

// ############################# Client only stuff ################################
pub const client = struct {
	var pipeline: graphics.Pipeline = undefined;
	var shadowPipeline: graphics.Pipeline = undefined;
	pub var nodeBuffer: graphics.LargeBuffer(Mat4f) = undefined;

	var uniforms: struct {
		modelViewMatrix: c_int,
		light: c_int,
		contrast: c_int,
		ambientLight: c_int,
		nodeBufferOffset: c_int,
		shadowsEnabled: c_int,
		shadowWindowOrigin: c_int,
		shadowWindowDim: c_int,
		shadowMaxDistance: c_int,
		shadowMaxSteps: c_int,
		foliageShadowsEnabled: c_int,
		cloudCoverageOrigin: c_int,
		cloudCoverageWorldSize: c_int,
		cloudHeightRelative: c_int,
		sunDirection: c_int,
		isSunlight: c_int,
		shadowTransitionFade: c_int,
		handLightPositionRelative: c_int,
		handLightColor: c_int,
		dropLightPosition0: c_int,
		dropLightColor0: c_int,
		dropLightPosition1: c_int,
		dropLightColor1: c_int,
		dropLightPosition2: c_int,
		dropLightColor2: c_int,
		dropLightPosition3: c_int,
		dropLightColor3: c_int,
		dropLightPosition4: c_int,
		dropLightColor4: c_int,
		dropLightPosition5: c_int,
		dropLightColor5: c_int,
		dropLightPosition6: c_int,
		dropLightColor6: c_int,
		dropLightPosition7: c_int,
		dropLightColor7: c_int,
		handLightRadius: c_int,
		remoteHandLightPositionRelative: c_int,
		remoteHandLightColor: c_int,
	} = undefined;
	var shadowUniforms: struct {
		lightSpaceMatrix: c_int,
		modelMatrix: c_int,
		nodeBufferOffset: c_int,
	} = undefined;

	pub fn init() void {
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/entity_vertex.vert",
			"assets/cubyz/shaders/entity_fragment.frag",
			"",
			&uniforms,
			main.entityModel.EntityModel.Vertex,
			&.{},
			.{},
			.{.depthTest = true},
			.{.attachments = &.{.noBlending}},
		);
		shadowPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/entity_shadow_depth.vert",
			"assets/cubyz/shaders/entity_shadow_depth.frag",
			"",
			&shadowUniforms,
			main.entityModel.EntityModel.Vertex,
			&.{},
			.{ .cullMode = .none, .depthBias = .{ .constantFactor = 2.0, .clamp = 0.0, .slopeFactor = 4.0 } },
			.{ .depthTest = true, .depthWrite = true },
			.{ .attachments = &.{.{ .enabled = false, .srcColorBlendFactor = .zero, .dstColorBlendFactor = .zero, .colorBlendOp = .add, .srcAlphaBlendFactor = .zero, .dstAlphaBlendFactor = .zero, .alphaBlendOp = .add, .colorWriteMask = .none }} },
		);

		nodeBuffer.init(main.globalAllocator, 1 << 20, 15);
	}
	pub fn deinit() void {
		pipeline.deinit();
		shadowPipeline.deinit();
		nodeBuffer.deinit();
	}
	pub fn clear() void {}

	fn updateNodeMatrices(component: *main.entity.components.@"cubyz:model".client.Component, rotation: Vec3f) void {
		const entModel = component.entityModel.get();
		if (entModel.nodeIndexMap.get("Head")) |headId| {
			var headRot: f32 = rotation[0];
			if (entModel.nodeIndexMap.get("Eyestalks")) |eyestalksId| {
				const stalkRot = rotation[0]*0.25;
				headRot = rotation[0]*0.75;
				component.nodes[eyestalksId].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, stalkRot);
			}
			component.nodes[headId].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, headRot);
		}
		for (component.nodes, 0..) |*node, i| {
			const parentMat = if (entModel.nodeParents[i]) |p| component.matrices[p].transpose() else Mat4f.identity();
			component.matrices[i] = parentMat.mul(node.recalc(entModel.nodePivots[i])).transpose();
		}
		nodeBuffer.uploadData(component.matrices, &component.bufferAllocation);
	}

	/// Used by CSM update. Entity positions/rotations are already replicated normally, so rendering their
	/// depth locally is deterministic from the receiving client's perspective and needs no shadow packets.
	pub fn renderShadows(lightSpaceMatrix: *const Mat4f, playerPos: Vec3d) void {
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		nodeBuffer.beginRender();
		defer nodeBuffer.endRender();
		shadowPipeline.bind(null);
		c.glUniformMatrix4fv(shadowUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&lightSpaceMatrix.toGl()));
		// The local avatar is deliberately absent from entity_manager so it is not drawn in first
		// person. Its model component is still loaded from the handshake, so feed it directly to the
		// depth-only pass when the client enables its own shadow.
		if (settings.ownPlayerShadow) {
			if (entity.components.@"cubyz:model".client.get(game.Player.id)) |component| {
				if (entity.components.@"cubyz:player".client.get(game.Player.id) != null) {
					const pos = game.Player.getPosBlocking() - playerPos;
					const rotation = game.camera.rotation;
					updateNodeMatrices(component, rotation);
					const entModel = component.entityModel.get();
					entModel.bind();
					entModel.defaultTexture.?.bindTo(0);
					const modelMatrix = Mat4f.identity()
						.mul(Mat4f.translation(Vec3f{ @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2] - entModel.height/2) }))
						.mul(Mat4f.rotationZ(-rotation[2]));
					c.glUniformMatrix4fv(shadowUniforms.modelMatrix, 1, c.GL_TRUE, @ptrCast(&modelMatrix));
					c.glUniform1ui(shadowUniforms.nodeBufferOffset, @intCast(component.bufferAllocation.start));
					c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
				}
			}
		}
		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |*component, id| {
			// This pass is deliberately for player avatars only; generic entities keep their current rendering
			// behaviour until they have their own shadow-quality policy.
			if (entity.components.@"cubyz:player".client.get(id) == null) continue;
			if (id == game.Player.id) continue;
			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			updateNodeMatrices(component, ent.rot);
			const entModel = component.entityModel.get();
			entModel.bind();
			entModel.defaultTexture.?.bindTo(0);
			const pos = ent.getRenderPosition() - playerPos;
			const modelMatrix = Mat4f.identity()
				.mul(Mat4f.translation(Vec3f{ @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2] - entModel.height/2) }))
				.mul(Mat4f.rotationZ(-ent.rot[2]));
			c.glUniformMatrix4fv(shadowUniforms.modelMatrix, 1, c.GL_TRUE, @ptrCast(&modelMatrix));
			c.glUniform1ui(shadowUniforms.nodeBufferOffset, @intCast(component.bufferAllocation.start));
			c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
		}
	}

	pub fn hasNearbyPlayerShadowCaster(playerPos: Vec3d, radius: f64) bool {
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		if (settings.ownPlayerShadow and entity.components.@"cubyz:model".client.get(game.Player.id) != null and entity.components.@"cubyz:player".client.get(game.Player.id) != null) {
			const offset = game.Player.getPosBlocking() - playerPos;
			if (offset[0]*offset[0] + offset[1]*offset[1] + offset[2]*offset[2] <= radius*radius) return true;
		}
		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |_, id| {
			if (entity.components.@"cubyz:player".client.get(id) == null) continue;
			if (id == game.Player.id) continue;
			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			const offset = ent.getRenderPosition() - playerPos;
			if (offset[0]*offset[0] + offset[1]*offset[1] + offset[2]*offset[2] <= radius*radius) return true;
		}
		return false;
	}

	pub fn renderHud(_: Vec3f, playerPos: Vec3d) void {
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();

		const screenUnits = @as(f32, @floatFromInt(main.Window.height))/1024;
		const fontBaseSize = 128.0;
		const fontMinScreenSize = 16.0;
		const fontScreenSize = fontBaseSize*screenUnits;

		for (main.client.entity_manager.entities.items()) |ent| {
			if (ent.id == game.Player.id) continue; // don't render local player
			if (ent.name.len == 0 and !settings.showPlayerIndexWithName) continue;

			var offsetText: f32 = 0;
			if (main.entity.components.@"cubyz:model".client.get(ent.id)) |component| {
				const entModel = component.entityModel.get();
				offsetText = entModel.height/2;
			}

			const pos3d = ent.getRenderPosition() - playerPos;
			const pos4f = Vec4f{
				@floatCast(pos3d[0]),
				@floatCast(pos3d[1]),
				@floatCast(pos3d[2] + offsetText + 0.1),
				1,
			};

			const rotatedPos = game.camera.viewMatrix.mulVec(pos4f);
			const projectedPos = Mat4f.fromGl(main.graphics.frame_uniforms.frameData().projectionMatrix).mulVec(rotatedPos);
			if (projectedPos[2] < 0) continue;
			const xCenter = (1 + projectedPos[0]/projectedPos[3])*@as(f32, @floatFromInt(main.Window.width/2));
			const yCenter = (1 - projectedPos[1]/projectedPos[3])*@as(f32, @floatFromInt(main.Window.height/2));

			const transparency = 38.0*std.math.log10(vec.lengthSquare(pos3d) + 1) - 80.0;
			const alpha: u32 = @trunc(std.math.clamp(0xff - transparency, 0, 0xff));
			const oldColor = graphics.draw.setColor(alpha << 24 | 0xffffff);
			defer graphics.draw.restoreColor(oldColor);

			const renderedName = main.stackAllocator.print("{f}", .{ent});
			defer main.stackAllocator.free(renderedName);

			var buf = graphics.TextBuffer.init(main.stackAllocator, renderedName, .{.color = 0xffffff}, false, .center);
			defer buf.deinit();
			const fontSize = std.mem.max(f32, &.{fontMinScreenSize, fontScreenSize/projectedPos[3]});
			const size = buf.calculateLineBreaks(fontSize, @floatFromInt(main.Window.width*8));
			buf.render(xCenter - size[0]/2, yCenter - size[1], fontSize);
		}
	}
	pub fn render(ambientLight: Vec3f, playerPos: Vec3d, deltaTime: f64) void {
		_ = deltaTime;
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();

		// TODO: #3342
		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |*component, id| {
			if (id == game.Player.id) continue; // don't process local player

			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			updateNodeMatrices(component, ent.rot);
		}

		pipeline.bind(null);

		c.glUniform3fv(uniforms.ambientLight, 1, @ptrCast(&ambientLight));
		c.glUniform1f(uniforms.contrast, 0.12);
		c.glUniform1i(uniforms.shadowsEnabled, @intFromBool(settings.shadows));
		const shadowWindowOrigin = renderer.ShadowRaymarch.windowOrigin;
		c.glUniform3i(uniforms.shadowWindowOrigin, shadowWindowOrigin[0], shadowWindowOrigin[1], shadowWindowOrigin[2]);
		c.glUniform1ui(uniforms.shadowWindowDim, renderer.ShadowRaymarch.windowDim);
		c.glUniform1f(uniforms.shadowMaxDistance, settings.shadowDistance);
		c.glUniform1i(uniforms.shadowMaxSteps, settings.shadowRaySteps);
		c.glUniform1i(uniforms.foliageShadowsEnabled, @intFromBool(settings.foliageShadows));
		const cloudCoverageOrigin = renderer.clouds.coverageOriginRelative;
		c.glUniform2f(uniforms.cloudCoverageOrigin, cloudCoverageOrigin[0], cloudCoverageOrigin[1]);
		c.glUniform1f(uniforms.cloudCoverageWorldSize, renderer.clouds.coverageWorldSize);
		c.glUniform1f(uniforms.cloudHeightRelative, renderer.clouds.cloudHeightRelative);
		const sunDirection = game.world.?.dayTime.getShadowLightDirection();
		c.glUniform3fv(uniforms.sunDirection, 1, @ptrCast(&sunDirection));
		c.glUniform1i(uniforms.isSunlight, @intFromBool(game.world.?.dayTime.isSunlight()));
		c.glUniform1f(uniforms.shadowTransitionFade, game.world.?.dayTime.getShadowTransitionFade());
		c.glUniform3fv(uniforms.handLightPositionRelative, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.handLightPositionRelative));
		c.glUniform3fv(uniforms.handLightColor, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.handLightColor));
		c.glUniform3fv(uniforms.dropLightPosition0, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[0]));
		c.glUniform3fv(uniforms.dropLightColor0, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[0]));
		c.glUniform3fv(uniforms.dropLightPosition1, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[1]));
		c.glUniform3fv(uniforms.dropLightColor1, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[1]));
		c.glUniform3fv(uniforms.dropLightPosition2, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[2]));
		c.glUniform3fv(uniforms.dropLightColor2, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[2]));
		c.glUniform3fv(uniforms.dropLightPosition3, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[3]));
		c.glUniform3fv(uniforms.dropLightColor3, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[3]));
		c.glUniform3fv(uniforms.dropLightPosition4, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[4]));
		c.glUniform3fv(uniforms.dropLightColor4, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[4]));
		c.glUniform3fv(uniforms.dropLightPosition5, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[5]));
		c.glUniform3fv(uniforms.dropLightColor5, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[5]));
		c.glUniform3fv(uniforms.dropLightPosition6, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[6]));
		c.glUniform3fv(uniforms.dropLightColor6, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[6]));
		c.glUniform3fv(uniforms.dropLightPosition7, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightPositionsRelative[7]));
		c.glUniform3fv(uniforms.dropLightColor7, 1, @ptrCast(&main.itemdrop.ItemDisplayManager.dropLightColors[7]));
		c.glUniform1f(uniforms.handLightRadius, main.itemdrop.ItemDisplayManager.handLightRadius);
		// entity_manager is already locked by this render pass, so compute the closest remote light
		// directly here instead of calling ItemDisplayManager.closestRemoteLight (which locks it).
		var nearestRemoteLightPos: Vec3f = @splat(0);
		var nearestRemoteLightColor: Vec3f = @splat(0);
		var nearestRemoteLightDistance: f32 = std.math.inf(f32);
		for (main.client.entity_manager.entities.items()) |ent| {
			if (ent.id == game.Player.id) continue;
			const blockType = main.itemdrop.ItemDisplayManager.remoteHeldLight(ent.id) orelse continue;
			const rel: Vec3f = @floatCast(ent.getRenderPosition() - playerPos + Vec3d{0.35, 0.0, 0.1});
			const dist = vec.lengthSquare(rel);
			if (dist < nearestRemoteLightDistance) {
				nearestRemoteLightDistance = dist;
				nearestRemoteLightPos = rel;
				const light = (blocks.Block{ .typ = blockType, .data = 0 }).light();
				nearestRemoteLightColor = Vec3f{ @floatFromInt(light >> 16 & 255), @floatFromInt(light >> 8 & 255), @floatFromInt(light & 255) } / @as(Vec3f, @splat(255.0));
			}
		}
		c.glUniform3fv(uniforms.remoteHandLightPositionRelative, 1, @ptrCast(&nearestRemoteLightPos));
		c.glUniform3fv(uniforms.remoteHandLightColor, 1, @ptrCast(&nearestRemoteLightColor));

		main.entity.systems.modelRenderer.client.nodeBuffer.beginRender();

		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |component, id| {
			if (id == game.Player.id) continue; // don't render local player

			const entModel = component.entityModel.get();
			const ent = main.client.entity_manager.getEntity(id) orelse continue;

			entModel.bind();
			const entTexture = entModel.defaultTexture;

			entTexture.?.bindTo(0);
			const blockPos: vec.Vec3i = @floor(ent.pos);
			const lightVals: [6]u8 = main.renderer.mesh_storage.getLight(blockPos[0], blockPos[1], blockPos[2]) orelse @splat(0);
			const light = (@as(u32, lightVals[0] >> 3) << 25 |
				@as(u32, lightVals[1] >> 3) << 20 |
				@as(u32, lightVals[2] >> 3) << 15 |
				@as(u32, lightVals[3] >> 3) << 10 |
				@as(u32, lightVals[4] >> 3) << 5 |
				@as(u32, lightVals[5] >> 3) << 0);

			c.glUniform1ui(uniforms.light, @bitCast(@as(u32, light)));
			c.glUniform1ui(uniforms.nodeBufferOffset, @bitCast(@as(u32, component.bufferAllocation.start)));

			const pos: Vec3d = ent.getRenderPosition() - playerPos;
			const modelMatrix = (Mat4f.identity()
				.mul(Mat4f.translation(Vec3f{
					@floatCast(pos[0]),
					@floatCast(pos[1]),
					@floatCast(pos[2] - entModel.height/2),
				}))
				.mul(Mat4f.rotationZ(-ent.rot[2])));
			const modelViewMatrix = game.camera.viewMatrix.mul(modelMatrix);
			c.glUniformMatrix4fv(uniforms.modelViewMatrix, 1, c.GL_TRUE, @ptrCast(&modelViewMatrix));
			c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
		}

		main.entity.systems.modelRenderer.client.nodeBuffer.endRender();
	}
};
// ############################# Server only stuff ################################
pub const server = struct {
	pub fn init() void {}
	pub fn deinit() void {}

	pub fn update() void {}
};
