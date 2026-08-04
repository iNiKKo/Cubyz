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

	fn nodeHasAncestor(entModel: *const main.entityModel.EntityModel, nodeId: usize, ancestorId: usize) bool {
		var current = entModel.nodeParents[nodeId];
		while (current) |parent| {
			if (@as(usize, parent) == ancestorId) return true;
			current = entModel.nodeParents[@as(usize, parent)];
		}
		return false;
	}

	fn wrapAngle(angle: f32) f32 {
		const twoPi = 2.0*std.math.pi;
		var a = @mod(angle + std.math.pi, twoPi);
		if (a < 0) a += twoPi;
		return a - std.math.pi;
	}

	fn updateLayeredLookYaw(component: *main.entity.components.@"cubyz:model".client.Component, targetYaw: f32, dt: f32, horizontalSpeed: f32) void {
		const headBudget = std.math.degreesToRadians(30.0);
		const rootTurnSpeed = std.math.degreesToRadians(140.0);

		const holdBeforeResetTime = 1.2;

		const stillnessRate = std.math.degreesToRadians(4.0);

		if (!component.hasRootYaw) {
			component.rootYaw = targetYaw;
			component.lastTargetYaw = targetYaw;
			component.hasRootYaw = true;
		}

		if (dt > 0) {
			const lookRate = @abs(wrapAngle(targetYaw - component.lastTargetYaw))/dt;
			if (lookRate > stillnessRate) {
				component.lookHoldTime = 0;
			} else {
				component.lookHoldTime += dt;
			}
		}
		component.lastTargetYaw = targetYaw;

		const totalDelta = wrapAngle(targetYaw - component.rootYaw);

		const movingThreshold = 0.3;
		const forceRootCatchUp = component.lookHoldTime >= holdBeforeResetTime or horizontalSpeed > movingThreshold;

		if (@abs(totalDelta) > headBudget or forceRootCatchUp) {
			component.rootYaw = component.rootYaw + moveToward(0, totalDelta, rootTurnSpeed*dt);
		}
		component.headYawOffset = wrapAngle(targetYaw - component.rootYaw);
	}
	fn moveToward(current: f32, target: f32, maxDelta: f32) f32 {
		const diff = target - current;
		if (@abs(diff) <= maxDelta) return target;
		return current + std.math.sign(diff)*maxDelta;
	}

	/// Computes the eye-anchored root transform used to draw the local player's own first-person body,
	/// so anything parented to it (the body mesh, the held item) stays visually locked together.
	pub fn firstPersonBodyRootMatrix(component: *main.entity.components.@"cubyz:model".client.Component, playerPos: Vec3d) Mat4f {
		const entModel = component.entityModel.get();
		const playerEyePos = game.Player.getEyePosBlocking();
		const eyePos: Vec3f = .{
			@floatCast(playerEyePos[0] - playerPos[0]),
			@floatCast(playerEyePos[1] - playerPos[1]),
			@floatCast(playerEyePos[2] - playerPos[2]),
		};
		const headId = entModel.nodeIndexMap.get("Head");
		const headOffset: Vec3f = if (headId) |id| vec.xyz(component.matrices[id].transpose().mulVec(.{0, 0, 0, 1})) else .{0, 0, entModel.height/2};
		const modelPosition: Vec3f = eyePos - headOffset;
		const lookDownPitch: f32 = @max(0.0, game.camera.rotation[0]);
		const baseBack: f32 = 0.05;
		const lookDownShift: f32 = baseBack + lookDownPitch * 0.16;
		const cameraUpShift: f32 = 0.03;
		const yawDir: Vec3f = Vec3f{@sin(game.camera.rotation[2]), @cos(game.camera.rotation[2]), 0};
		const modelOffset: Vec3f = modelPosition - yawDir * Vec3f{lookDownShift, lookDownShift, lookDownShift} + Vec3f{0, 0, cameraUpShift};

		return Mat4f.identity()
			.mul(Mat4f.translation(modelOffset))
			.mul(Mat4f.rotationZ(-component.rootYaw));
	}

	/// Interpolates a hand-pose value across the down/forward/up calibration stages based on camera pitch in [-pi/2, pi/2].
	pub fn interpolateHandPose(pitch: f32, down: f32, forward: f32, up: f32) f32 {
		if (pitch <= 0.0) {
			const t = std.math.clamp(pitch/(-std.math.pi/2.0), 0.0, 1.0);
			return forward + (down - forward)*t;
		} else {
			const t = std.math.clamp(pitch/(std.math.pi/2.0), 0.0, 1.0);
			return forward + (up - forward)*t;
		}
	}

	fn updateNodeMatrices(component: *main.entity.components.@"cubyz:model".client.Component, rotation: Vec3f, horizontalSpeed: f32, verticalVelocity: f32, isHoldingItem: bool, miningSwing: ?f32, hideHead: bool) void {
		const renderFrame = renderer.worldRenderFrame;
		if (component.hasPoseRenderFrame and component.lastPoseRenderFrame == renderFrame and component.lastHideHead == hideHead) return;
		component.lastPoseRenderFrame = renderFrame;
		component.lastHideHead = hideHead;
		component.lastCameraPitch = rotation[0];
		component.hasPoseRenderFrame = true;
		const entModel = component.entityModel.get();
		@memcpy(component.nodes, entModel.nodes);
		const elapsedNanoseconds = main.renderer.chunk_meshing.startTimestamp.durationTo(main.timestamp()).toNanoseconds();
		const time: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
		const phase = @as(f32, @floatFromInt(component.entityModel.index % 17)) * 0.73;
		const breathe = @sin(time * 1.35 + phase);
		const sway = @sin(time * 0.72 + phase);

		if (!component.hasWalkUpdateTime) {
			component.lastWalkUpdateTime = time;
			component.hasWalkUpdateTime = true;
		}
		const dt = std.math.clamp(time - component.lastWalkUpdateTime, 0.0, 0.1);
		component.lastWalkUpdateTime = time;
		const torsoId = entModel.nodeIndexMap.get("Torso");

		updateLayeredLookYaw(component, rotation[2], dt, horizontalSpeed);
		if (torsoId) |id| {
			component.nodes[id].pos[2] += breathe * 0.012;
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, sway * 0.018);
		}

		inline for ([_][]const u8{"Head", "Eyestalks", "LeftArm", "RightArm"}) |name| {
			if (entModel.nodeIndexMap.get(name)) |id| {
				if (torsoId == null or !nodeHasAncestor(entModel, id, torsoId.?)) component.nodes[id].pos[2] += breathe * 0.012;
			}
		}

		if (torsoId) |torso| {
			inline for ([_][]const u8{"LeftLeg", "RightLeg"}) |name| {
				if (entModel.nodeIndexMap.get(name)) |id| {
					if (nodeHasAncestor(entModel, id, torso)) component.nodes[id].pos[2] -= breathe * 0.012;
				}
			}
		}

		const airborneThreshold = 0.5;
		const isAirborne = @abs(verticalVelocity) > airborneThreshold;
		var leftArmTarget: f32 = 0;
		var rightArmTarget: f32 = 0;
		var leftLegTarget: f32 = 0;
		var rightLegTarget: f32 = 0;
		if (isAirborne) {

			const jumpBlend = std.math.clamp(verticalVelocity/3.0, -1.0, 1.0);
			const legSplit = 0.35*std.math.clamp(jumpBlend, 0.0, 1.0);
			leftLegTarget = -legSplit;
			rightLegTarget = legSplit;

			const armSwing = 0.6*std.math.clamp(jumpBlend, 0.0, 1.0);
			leftArmTarget = armSwing;
			if (!isHoldingItem) {
				rightArmTarget = -armSwing;
			}
		} else {

			const walkBlend = std.math.clamp(horizontalSpeed/4.5, 0.0, 1.0);
			if (walkBlend > 0.02) {

				component.walkPhase += (0.90 + horizontalSpeed*0.90)*dt;

				const step = @sin(component.walkPhase + phase);
				const legSwing: f32 = 0.58*walkBlend;
				leftLegTarget = step*legSwing;
				rightLegTarget = -step*legSwing;
			}
		}

		const swing = if (miningSwing) |progress| @sin(progress * std.math.pi) * 0.80 else 0.0;
		const pitch = std.math.clamp(rotation[0], -std.math.pi/2.0, std.math.pi/2.0);
		const handRestAngle = interpolateHandPose(pitch, settings.handRestAngleDown, settings.handRestAngleForward, settings.handRestAngleUp);
		const rightArmVelocitySway: f32 = std.math.clamp(verticalVelocity * 0.05 + horizontalSpeed * 0.015, -0.10, 0.10) * settings.handVelocitySwayScale;
		if (isHoldingItem) {
			rightArmTarget = handRestAngle - swing;
		} else if (miningSwing != null) {
			rightArmTarget = -swing;
		}
		const poseBlend = 1.0 - @exp(-10.0*dt);
		component.leftArmAngle += (leftArmTarget - component.leftArmAngle)*poseBlend;
		component.rightArmAngle += (rightArmTarget - component.rightArmAngle)*poseBlend;
		component.leftLegAngle += (leftLegTarget - component.leftLegAngle)*poseBlend;
		component.rightLegAngle += (rightLegTarget - component.rightLegAngle)*poseBlend;
		if (entModel.nodeIndexMap.get("LeftArm")) |id| {
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, component.leftArmAngle);
		}
		if (entModel.nodeIndexMap.get("RightArm")) |id| {
			const rightArmPitch = component.rightArmAngle + rightArmVelocitySway;
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, rightArmPitch);
		}
		if (entModel.nodeIndexMap.get("LeftLeg")) |id| {
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, component.leftLegAngle);
		}
		if (entModel.nodeIndexMap.get("RightLeg")) |id| {
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, component.rightLegAngle);
		}
		const headId = entModel.nodeIndexMap.get("Head");
		if (headId) |id| {
			const headRot: f32 = rotation[0];
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{0, 0, 1}, component.headYawOffset)
				.mul(vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, headRot));
		}

		var headWorldMat: Mat4f = Mat4f.identity();
		if (headId) |id| {
			const headParentMat = if (entModel.nodeParents[id]) |p| component.matrices[p].transpose() else Mat4f.identity();
			var headNode = component.nodes[id];
			if (hideHead) headNode.scale = @splat(0);
			headWorldMat = headParentMat.mul(headNode.recalc(entModel.nodePivots[id]));
		}
		const eyestalksId = entModel.nodeIndexMap.get("Eyestalks");
		for (component.nodes, 0..) |*node, i| {
			const nodeId: usize = i;
			const parentMat = if (eyestalksId != null and eyestalksId.? == i and headId != null)
				headWorldMat
			else if (entModel.nodeParents[i]) |p|
				component.matrices[p].transpose()
			else
				Mat4f.identity();
			var localNode = node.*;
			if (hideHead and headId != null and (headId.? == i or nodeHasAncestor(entModel, nodeId, headId.?))) localNode.scale = @splat(0);
			component.matrices[i] = parentMat.mul(localNode.recalc(entModel.nodePivots[i])).transpose();
		}
		nodeBuffer.uploadData(component.matrices, &component.bufferAllocation);
	}

	pub fn renderShadows(lightSpaceMatrix: *const Mat4f, playerPos: Vec3d) void {
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		nodeBuffer.beginRender();
		defer nodeBuffer.endRender();
		shadowPipeline.bind(null);
		c.glUniformMatrix4fv(shadowUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&lightSpaceMatrix.toGl()));

		if (settings.ownPlayerShadow) {
			if (entity.components.@"cubyz:model".client.get(game.Player.id)) |component| {
				if (entity.components.@"cubyz:player".client.get(game.Player.id) != null) {
					const pos = game.Player.getPosBlocking() - playerPos;
					const rotation = if (game.Player.editorMode.load(.monotonic)) game.frozenBodyRotation else game.camera.rotation;
					const velocity = game.Player.getVelBlocking();
					const horizontalSpeed: f32 = @floatCast(@sqrt(velocity[0]*velocity[0] + velocity[1]*velocity[1]));
					const verticalVelocity: f32 = @floatCast(velocity[2]);
					updateNodeMatrices(component, rotation, horizontalSpeed, verticalVelocity, game.Player.inventory.getItem(game.Player.selectedSlot) != .null, renderer.MeshSelection.heldItemSwingProgress(), false);
					const entModel = component.entityModel.get();
					entModel.bind();
					entModel.defaultTexture.?.bindTo(0);
					const modelMatrix = Mat4f.identity()
						.mul(Mat4f.translation(Vec3f{ @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2] - entModel.height/2) }))
						.mul(Mat4f.rotationZ(-component.rootYaw));
					c.glUniformMatrix4fv(shadowUniforms.modelMatrix, 1, c.GL_TRUE, @ptrCast(&modelMatrix));
					c.glUniform1ui(shadowUniforms.nodeBufferOffset, @intCast(component.bufferAllocation.start));
					c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
				}
			}
		}
		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |*component, id| {

			if (entity.components.@"cubyz:player".client.get(id) == null) continue;
			if (id == game.Player.id) continue;
			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			const horizontalSpeed: f32 = @floatCast(@sqrt(ent._interpolationVel[0]*ent._interpolationVel[0] + ent._interpolationVel[1]*ent._interpolationVel[1]));
			const verticalVelocity: f32 = @floatCast(ent._interpolationVel[2]);
			const heldAnimation = main.itemdrop.ItemDisplayManager.remoteHeldAnimationState(id);
			updateNodeMatrices(component, ent.rot, horizontalSpeed, verticalVelocity, heldAnimation.isHoldingItem, heldAnimation.miningSwing, false);
			const entModel = component.entityModel.get();
			entModel.bind();
			entModel.defaultTexture.?.bindTo(0);
			const pos = ent.getRenderPosition() - playerPos;
			const modelMatrix = Mat4f.identity()
				.mul(Mat4f.translation(Vec3f{ @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2] - entModel.height/2) }))
				.mul(Mat4f.rotationZ(-component.rootYaw));
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
			if (ent.id == game.Player.id) continue;
			if (ent.name.len == 0 and !settings.showPlayerIndexWithName) continue;
			const isPlayer = entity.components.@"cubyz:player".client.get(ent.id) != null;
			if (!isPlayer and !settings.showMobNameTags) continue;

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

		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |*component, id| {
			if (id == game.Player.id) continue;

			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			const horizontalSpeed: f32 = @floatCast(@sqrt(ent._interpolationVel[0]*ent._interpolationVel[0] + ent._interpolationVel[1]*ent._interpolationVel[1]));
			const verticalVelocity: f32 = @floatCast(ent._interpolationVel[2]);
			const heldAnimation = main.itemdrop.ItemDisplayManager.remoteHeldAnimationState(id);
			updateNodeMatrices(component, ent.rot, horizontalSpeed, verticalVelocity, heldAnimation.isHoldingItem, heldAnimation.miningSwing, false);
		}

		if (settings.firstPersonBody and !game.Player.editorMode.load(.monotonic)) {
			if (entity.components.@"cubyz:model".client.get(game.Player.id)) |component| {
				if (entity.components.@"cubyz:player".client.get(game.Player.id) != null) {
					const rotation = game.camera.rotation;
					const velocity = game.Player.getVelBlocking();
					const horizontalSpeed: f32 = @floatCast(@sqrt(velocity[0]*velocity[0] + velocity[1]*velocity[1]));
					const verticalVelocity: f32 = @floatCast(velocity[2]);
					updateNodeMatrices(component, rotation, horizontalSpeed, verticalVelocity, game.Player.inventory.getItem(game.Player.selectedSlot) != .null, renderer.MeshSelection.heldItemSwingProgress(), true);
				}
			}
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

		const nearestRemoteLight = main.itemdrop.ItemDisplayManager.closestRemoteLightWithEntitiesLocked(playerPos);
		c.glUniform3fv(uniforms.remoteHandLightPositionRelative, 1, @ptrCast(&nearestRemoteLight.positionRelative));
		c.glUniform3fv(uniforms.remoteHandLightColor, 1, @ptrCast(&nearestRemoteLight.color));

		main.entity.systems.modelRenderer.client.nodeBuffer.beginRender();

		for (entity.components.@"cubyz:model".client.components.dense.items, entity.components.@"cubyz:model".client.components.denseToSparseIndex.items) |component, id| {
			if (id == game.Player.id) continue;

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
				.mul(Mat4f.rotationZ(-component.rootYaw)));
			const modelViewMatrix = game.camera.viewMatrix.mul(modelMatrix);
			c.glUniformMatrix4fv(uniforms.modelViewMatrix, 1, c.GL_TRUE, @ptrCast(&modelViewMatrix));
			c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
		}

		if (settings.firstPersonBody) {
			if (entity.components.@"cubyz:model".client.get(game.Player.id)) |component| {
				if (entity.components.@"cubyz:player".client.get(game.Player.id) != null) {
					const entModel = component.entityModel.get();

					entModel.bind();
					entModel.defaultTexture.?.bindTo(0);
					const playerEyePos = game.Player.getEyePosBlocking();
					const blockPos: vec.Vec3i = @floor(playerEyePos);
					const lightVals: [6]u8 = main.renderer.mesh_storage.getLight(blockPos[0], blockPos[1], blockPos[2]) orelse @splat(0);
					const light = (@as(u32, lightVals[0] >> 3) << 25 |
						@as(u32, lightVals[1] >> 3) << 20 |
						@as(u32, lightVals[2] >> 3) << 15 |
						@as(u32, lightVals[3] >> 3) << 10 |
						@as(u32, lightVals[4] >> 3) << 5 |
						@as(u32, lightVals[5] >> 3) << 0);

					c.glUniform1ui(uniforms.light, @bitCast(@as(u32, light)));
					c.glUniform1ui(uniforms.nodeBufferOffset, @bitCast(@as(u32, component.bufferAllocation.start)));

					const modelMatrix = firstPersonBodyRootMatrix(component, playerPos);
					const modelViewMatrix = game.camera.viewMatrix.mul(modelMatrix);
					c.glUniformMatrix4fv(uniforms.modelViewMatrix, 1, c.GL_TRUE, @ptrCast(&modelViewMatrix));
					c.glDrawElements(c.GL_TRIANGLES, entModel.indexCount, c.GL_UNSIGNED_INT, null);
				}
			}
		}

		main.entity.systems.modelRenderer.client.nodeBuffer.endRender();
	}
};

pub const server = struct {
	pub fn init() void {}
	pub fn deinit() void {}

	pub fn update() void {}
};
