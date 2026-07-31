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

	/// Phase 1 animation: a deliberately subtle procedural idle pose. Resetting from the model's rest
	/// nodes every update keeps this independent from later imported keyframe clips.
	fn nodeHasAncestor(entModel: *const main.entityModel.EntityModel, nodeId: u16, ancestorId: u16) bool {
		var current = entModel.nodeParents[nodeId];
		while (current) |parent| {
			if (parent == ancestorId) return true;
			current = entModel.nodeParents[parent];
		}
		return false;
	}

	/// Wraps an angle difference into (-pi, pi], so turning e.g. from 179deg to -179deg reads as a small
	/// step in one direction instead of a near-full-circle jump the wrong way.
	fn wrapAngle(angle: f32) f32 {
		const twoPi = 2.0*std.math.pi;
		var a = @mod(angle + std.math.pi, twoPi);
		if (a < 0) a += twoPi;
		return a - std.math.pi;
	}

	/// Layered look-turn: head absorbs the first `headBudget` of a look-direction change, then beyond
	/// that the root itself starts rotating to catch up and the head offset eases back toward 0 (since
	/// the root is now carrying that rotation instead). This is purely a visual pose for how OTHER
	/// players see this avatar turn/look; it never affects the local camera, aim, or actual movement
	/// direction. Torso rotation was tried and removed - head-only reads more clearly.
	fn updateLayeredLookYaw(component: *main.entity.components.@"cubyz:model".client.Component, targetYaw: f32, dt: f32, horizontalSpeed: f32) void {
		const headBudget = std.math.degreesToRadians(30.0); // Raised from 10 - player found 10 too restricted.
		const turnSpeed = std.math.degreesToRadians(360.0); // How fast the head/root ease toward their target.
		// How long the look direction has to stay actually still (not just within the head's budget - the
		// previous version accidentally treated any slow, ongoing look movement as "held" too, since it
		// only checked whether totalDelta stayed under headBudget rather than whether the player was
		// actually still moving their view. That meant slow deliberate looking always ran out this timer
		// and forced a recenter within ~1.2s, so the head pose was only ever visible while moving the
		// mouse fast enough to keep re-triggering totalDelta past headBudget every frame - exactly the
		// "only works by spamming left/right fast" symptom.) before the body re-centers to face it anyway.
		const holdBeforeResetTime = 1.2;
		// Degrees/second below which the look direction counts as "not actively moving." Measured from an
		// actual angular rate (change in targetYaw over dt), not a fixed per-frame degree threshold, so it
		// isn't sensitive to frame rate.
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
		// Starting to walk also forces the body to re-center and face the look direction, on top of the
		// hold-then-recenter timer above - an angled-off body while actively moving reads as wrong/broken
		// far faster than while standing still, so movement should snap the recenter decision immediately
		// rather than waiting out the same 1.2s idle-hold delay.
		const movingThreshold = 0.3;
		const forceRootCatchUp = component.lookHoldTime >= holdBeforeResetTime or horizontalSpeed > movingThreshold;

		if (@abs(totalDelta) <= headBudget and !forceRootCatchUp) {
			// Within the head's budget and still actively moving (or too recently stopped): head alone
			// tracks the look direction.
			component.headYawOffset = moveToward(component.headYawOffset, totalDelta, turnSpeed*dt);
		} else {
			// Look direction has either turned further than the head can absorb, or been held still long
			// enough that the body re-centers to face it anyway: the root itself now turns to catch up
			// toward the actual target, while the head offset eases back toward 0 since the root is
			// carrying the rotation instead.
			component.rootYaw = component.rootYaw + moveToward(0, totalDelta, turnSpeed*dt);
			component.headYawOffset = moveToward(component.headYawOffset, 0, turnSpeed*dt);
		}
	}
	fn moveToward(current: f32, target: f32, maxDelta: f32) f32 {
		const diff = target - current;
		if (@abs(diff) <= maxDelta) return target;
		return current + std.math.sign(diff)*maxDelta;
	}

	fn updateNodeMatrices(component: *main.entity.components.@"cubyz:model".client.Component, rotation: Vec3f, horizontalSpeed: f32, verticalVelocity: f32, isHoldingItem: bool, miningSwing: ?f32) void {
		const entModel = component.entityModel.get();
		@memcpy(component.nodes, entModel.nodes);
		const elapsedNanoseconds = main.renderer.chunk_meshing.startTimestamp.durationTo(main.timestamp()).toNanoseconds();
		const time: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
		const phase = @as(f32, @floatFromInt(component.entityModel.index % 17)) * 0.73;
		const breathe = @sin(time * 1.35 + phase);
		const sway = @sin(time * 0.72 + phase);
		// Shared per-component frame delta, used both for the walk cycle below and for the layered
		// look-turn easing. Tracked from real elapsed time (not derived from elapsedTime*frequency) so
		// neither system jumps discontinuously if the frame rate or update cadence varies; see the walk
		// cycle comment further down for the bug this specifically avoided.
		if (!component.hasWalkUpdateTime) {
			component.lastWalkUpdateTime = time;
			component.hasWalkUpdateTime = true;
		}
		const dt = std.math.clamp(time - component.lastWalkUpdateTime, 0.0, 0.1);
		component.lastWalkUpdateTime = time;
		const torsoId = entModel.nodeIndexMap.get("Torso");
		// Layered look-turn: figure out how much of the current look yaw the head is absorbing versus the
		// root, before applying any node rotations below (root yaw is read back out by the modelMatrix
		// builders at each of this function's call sites). Head-only - torso rotation was tried and
		// removed for reading more clearly as just a head turn.
		updateLayeredLookYaw(component, rotation[2], dt, horizontalSpeed);
		if (torsoId) |id| {
			component.nodes[id].pos[2] += breathe * 0.012;
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, sway * 0.018);
		}
		// Snale/Snela export Head and arms as separate roots; Cubert parents them under Torso.
		// Make both layouts breathe as one upper body, without applying the offset twice to children.
		inline for ([_][]const u8{"Head", "Eyestalks", "LeftArm", "RightArm"}) |name| {
			if (entModel.nodeIndexMap.get(name)) |id| {
				if (torsoId == null or !nodeHasAncestor(entModel, id, torsoId.?)) component.nodes[id].pos[2] += breathe * 0.012;
			}
		}
		// Legs are planted rather than drifting with the breathing torso. This is a lightweight
		// root-lock for the existing hierarchy; proper IK can replace it when locomotion arrives.
		if (torsoId) |torso| {
			inline for ([_][]const u8{"LeftLeg", "RightLeg"}) |name| {
				if (entModel.nodeIndexMap.get(name)) |id| {
					if (nodeHasAncestor(entModel, id, torso)) component.nodes[id].pos[2] -= breathe * 0.012;
				}
			}
		}
		// Airborne pose: a simple velocity-driven jump takes over from the walk cycle while off the
		// ground (no real jump/land events are wired into animation yet, so this is derived the same way
		// as the walk gait - from replicated vertical velocity - rather than a triggered one-shot clip).
		// Right leg steps slightly forward, left leg slightly back (opposite signs on the same axis the
		// walk cycle already uses for "forward"/"back"), held for the duration of the jump rather than
		// both legs rotating the same way. A threshold well above normal ground jitter keeps this from
		// flickering on/off from small vertical noise while walking on uneven terrain.
		const airborneThreshold = 0.5;
		const isAirborne = @abs(verticalVelocity) > airborneThreshold;
		if (isAirborne) {
			// +1 while rising fast, -1 while falling fast, smoothly through 0 near the top of the arc.
			const jumpBlend = std.math.clamp(verticalVelocity/3.0, -1.0, 1.0);
			const legSplit = 0.35*std.math.clamp(jumpBlend, 0.0, 1.0); // eases in on the way up, relaxes on the way down
			if (entModel.nodeIndexMap.get("LeftLeg")) |id| {
				component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, -legSplit);
			}
			if (entModel.nodeIndexMap.get("RightLeg")) |id| {
				component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, legSplit);
			}
			// RightArm is reserved for the held-item pose (applied later below) whenever something is
			// actually held, so it never fights over that node; with empty hands there's no held-item
			// pose to protect, so both arms swing in the jump - RightArm forward, LeftArm back, mirroring
			// the leg split above.
			const armSwing = 0.6*std.math.clamp(jumpBlend, 0.0, 1.0);
			if (entModel.nodeIndexMap.get("LeftArm")) |id| {
				component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, armSwing);
			}
			if (!isHoldingItem) {
				if (entModel.nodeIndexMap.get("RightArm")) |id| {
					component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, -armSwing);
				}
			}
		} else {
			// Basic locomotion deliberately affects legs only. Horizontal entity velocity is already part
			// of ordinary position replication, so every client derives the same gait without a new
			// animation packet. Faster movement both increases the swing amplitude and advances the cycle
			// faster. (dt was already computed above, shared with the layered look-turn update.)
			const walkBlend = std.math.clamp(horizontalSpeed/4.5, 0.0, 1.0);
			if (walkBlend > 0.02) {
				// Normal walking is ~4.5 blocks/s. Base cadence raised 50% then a further 25% (0.90/0.90)
				// after still being reported too slow; very fast movement still scales up naturally from
				// this base.
				component.walkPhase += (0.90 + horizontalSpeed*0.90)*dt;
				// Continuous opposite-phase swing: both legs are always moving, one forward while the
				// other is back, crossing through the rest pose together - the usual walk-cycle shape,
				// replacing the earlier "lift one leg, pause, then lift the other" sequential pattern.
				const step = @sin(component.walkPhase + phase);
				const legSwing: f32 = 0.58*walkBlend;
				if (entModel.nodeIndexMap.get("LeftLeg")) |id| {
					component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, step*legSwing);
				}
				if (entModel.nodeIndexMap.get("RightLeg")) |id| {
					component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, -step*legSwing);
				}
			}
		}
		// Every current player model places RightArm's node origin at the shoulder, so rotating this
		// single existing arm node gives a clean shoulder-pivoted "present item" pose. A future
		// UpperArm/Forearm rig can replace this with a real elbow bend without changing held-item logic.
		if (isHoldingItem) {
			if (entModel.nodeIndexMap.get("RightArm")) |id| {
				const swing = if (miningSwing) |progress| @sin(progress * std.math.pi) * 0.80 else 0.0;
				component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, -0.52 - swing);
			}
		}
		const headId = entModel.nodeIndexMap.get("Head");
		if (headId) |id| {
			const headRot: f32 = rotation[0];
			component.nodes[id].rot = vec.Quat.quatFromAxisAngle(Vec3f{0, 0, 1}, component.headYawOffset)
				.mul(vec.Quat.quatFromAxisAngle(Vec3f{1, 0, 0}, headRot));
		}
		// Eyestalks (Snale/Snela's snail eyes) get no rotation/animation of their own at all - they're
		// welded rigidly to Head below by borrowing Head's fully computed world matrix as their parent
		// matrix, exactly as if they were an actual child of Head in the model (which they aren't -
		// they're exported as a separate root). Previously they got a scaled-down copy of the head's own
		// rotation applied around their OWN pivot, which swings/arcs them independently since their pivot
		// isn't at the head's pivot - not the same as being rigidly attached.
		// Head's world matrix is computed explicitly up front (not just read out of component.matrices
		// during the loop below) so this doesn't depend on Head happening to have a lower node index than
		// Eyestalks - node export order isn't guaranteed, and reading a stale/not-yet-updated matrix would
		// leave Eyestalks a frame behind.
		var headWorldMat: Mat4f = Mat4f.identity();
		if (headId) |id| {
			const headParentMat = if (entModel.nodeParents[id]) |p| component.matrices[p].transpose() else Mat4f.identity();
			headWorldMat = headParentMat.mul(component.nodes[id].recalc(entModel.nodePivots[id]));
		}
		const eyestalksId = entModel.nodeIndexMap.get("Eyestalks");
		for (component.nodes, 0..) |*node, i| {
			const parentMat = if (eyestalksId != null and eyestalksId.? == i and headId != null)
				headWorldMat
			else if (entModel.nodeParents[i]) |p|
				component.matrices[p].transpose()
			else
				Mat4f.identity();
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
					const velocity = game.Player.getVelBlocking();
					const horizontalSpeed: f32 = @floatCast(@sqrt(velocity[0]*velocity[0] + velocity[1]*velocity[1]));
					const verticalVelocity: f32 = @floatCast(velocity[2]);
					updateNodeMatrices(component, rotation, horizontalSpeed, verticalVelocity, game.Player.inventory.getItem(game.Player.selectedSlot) != .null, renderer.MeshSelection.heldItemSwingProgress());
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
			// This pass is deliberately for player avatars only; generic entities keep their current rendering
			// behaviour until they have their own shadow-quality policy.
			if (entity.components.@"cubyz:player".client.get(id) == null) continue;
			if (id == game.Player.id) continue;
			const ent = main.client.entity_manager.getEntity(id) orelse continue;
			const horizontalSpeed: f32 = @floatCast(@sqrt(ent._interpolationVel[0]*ent._interpolationVel[0] + ent._interpolationVel[1]*ent._interpolationVel[1]));
			const verticalVelocity: f32 = @floatCast(ent._interpolationVel[2]);
			updateNodeMatrices(component, ent.rot, horizontalSpeed, verticalVelocity, main.itemdrop.ItemDisplayManager.hasRemoteHeldItem(id), main.itemdrop.ItemDisplayManager.remoteMiningSwing(id));
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
			const horizontalSpeed: f32 = @floatCast(@sqrt(ent._interpolationVel[0]*ent._interpolationVel[0] + ent._interpolationVel[1]*ent._interpolationVel[1]));
			const verticalVelocity: f32 = @floatCast(ent._interpolationVel[2]);
			updateNodeMatrices(component, ent.rot, horizontalSpeed, verticalVelocity, main.itemdrop.ItemDisplayManager.hasRemoteHeldItem(id), main.itemdrop.ItemDisplayManager.remoteMiningSwing(id));
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
				.mul(Mat4f.rotationZ(-component.rootYaw)));
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
