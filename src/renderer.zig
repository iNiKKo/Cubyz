const std = @import("std");
const Atomic = std.atomic.Value;

const blocks = @import("blocks.zig");
const chunk = @import("chunk.zig");
const entity = @import("entity.zig");
const graphics = @import("graphics.zig");
const particles = @import("particles.zig");
const game = @import("game.zig");
const World = game.World;
const itemdrop = @import("itemdrop.zig");
const main = @import("main");
const gpu_performance_measuring = main.gui.windowlist.gpu_performance_measuring;
const crosshair = main.gui.windowlist.crosshair;
const Window = main.Window;
const models = @import("models.zig");
const network = @import("network.zig");
const settings = @import("settings.zig");
const vec = @import("vec.zig");
const Vec2f = vec.Vec2f;
const Vec3i = vec.Vec3i;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const Vec4f = vec.Vec4f;
const Mat4f = vec.Mat4f;

const c = @import("c");

pub const chunk_meshing = @import("renderer/chunk_meshing.zig");
pub const lighting = @import("renderer/lighting.zig");
pub const mesh_storage = @import("renderer/mesh_storage.zig");
pub const clouds = @import("renderer/clouds.zig");
pub const thin_clouds = @import("renderer/thin_clouds.zig");
pub const rain = @import("renderer/rain.zig");
pub const fsr = @import("renderer/fsr.zig");
pub const fsr2 = @import("renderer/fsr2.zig");

const maximumMeshTime: std.Io.Duration = .fromMilliseconds(12);
pub const zNear = 0.1;
pub const zFar = 65536.0;

const submergedTerrainRenderDistance: f64 = 72.0;

fn isWithinSubmergedTerrainRenderRange(mesh: *const chunk_meshing.ChunkMesh, playerPos: Vec3d) bool {
	const chunkSize: f64 = @floatFromInt(chunk.chunkSize * mesh.pos.voxelSize);
	const halfSize = chunkSize * 0.5;
	const centerX = @as(f64, @floatFromInt(mesh.pos.wx)) + halfSize;
	const centerY = @as(f64, @floatFromInt(mesh.pos.wy)) + halfSize;
	const nearX = @max(@abs(centerX - playerPos[0]) - halfSize, 0.0);
	const nearY = @max(@abs(centerY - playerPos[1]) - halfSize, 0.0);
	return nearX*nearX + nearY*nearY <= submergedTerrainRenderDistance*submergedTerrainRenderDistance;
}

var deferredRenderPassPipeline: graphics.Pipeline = undefined;
var deferredUniforms: struct {
	@"fog.color": c_int,
	@"fog.density": c_int,
	@"fog.fogLower": c_int,
	@"fog.fogHigher": c_int,
	fogWhitening: c_int,
	weatherFogStrength: c_int,

	skyIslandGroundFade: c_int,
	skyIslandMistStrength: c_int,
	skyIslandFogColor: c_int,
	cloudColor: c_int,
	tanXY: c_int,
	zNear: c_int,
	zFar: c_int,
	invViewMatrix: c_int,
	godRayTint: c_int,
	waterTime: c_int,
} = undefined;
var fakeReflectionPipeline: graphics.Pipeline = undefined;
var fakeReflectionUniforms: struct {
	normalVector: c_int,
	upVector: c_int,
	rightVector: c_int,
	frequency: c_int,
	reflectionMapSize: c_int,
} = undefined;

pub var activeFrameBuffer: c_uint = 0;
var startTimestamp: std.Io.Timestamp = undefined;

pub const reflectionCubeMapSize = 64;
var reflectionCubeMap: graphics.CubeMapTexture = undefined;

pub fn init() void {
	startTimestamp = main.timestamp();
	deferredRenderPassPipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/deferred_render_pass.vert",
		"assets/cubyz/shaders/deferred_render_pass.frag",
		"",
		&deferredUniforms,
		graphics.draw.SimpleVertex2D,
		&.{},
		.{.cullMode = .none},
		.{.depthTest = false, .depthWrite = false},
		.{.attachments = &.{.noBlending}},
	);
	fakeReflectionPipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/fake_reflection.vert",
		"assets/cubyz/shaders/fake_reflection.frag",
		"",
		&fakeReflectionUniforms,
		graphics.draw.SimpleVertex2D,
		&.{},
		.{.cullMode = .none},
		.{.depthTest = false, .depthWrite = false},
		.{.attachments = &.{.noBlending}},
	);
	worldFrameBuffer.init(true, c.GL_NEAREST, c.GL_CLAMP_TO_EDGE);
	worldFrameBuffer.updateSize(Window.width, Window.height, c.GL_RGB16F);
	cloudFrameBuffer.init(true, c.GL_NEAREST, c.GL_CLAMP_TO_EDGE);
	cloudFrameBuffer.updateSize(Window.width, Window.height, c.GL_RGBA16F);
	waterSurfaceFrameBuffer.init(true, c.GL_NEAREST, c.GL_CLAMP_TO_EDGE);
	waterSurfaceFrameBuffer.updateSize(Window.width, Window.height, c.GL_RGBA16F);
	MSAA.init();
	FXAA.init();
	TAA.init();
	Bloom.init();
	GodRays.init();
	MeshSelection.init();
	MenuBackGround.init();
	Skybox.init();
	ShadowRaymarch.init();
	CascadedShadowMap.init();
	clouds.init();
	thin_clouds.init();
	rain.init();
	fsr.init();
	fsr2.init();
	chunk_meshing.init();
	mesh_storage.init();
	reflectionCubeMap = .init();
	reflectionCubeMap.generate(reflectionCubeMapSize, reflectionCubeMapSize);
	initReflectionCubeMap();
}

pub fn deinit() void {
	deferredRenderPassPipeline.deinit();
	fakeReflectionPipeline.deinit();
	worldFrameBuffer.deinit();
	cloudFrameBuffer.deinit();
	waterSurfaceFrameBuffer.deinit();
	MSAA.deinit();
	FXAA.deinit();
	TAA.deinit();
	Bloom.deinit();
	GodRays.deinit();
	MeshSelection.deinit();
	MenuBackGround.deinit();
	Skybox.deinit();
	ShadowRaymarch.deinit();
	CascadedShadowMap.deinit();
	clouds.deinit();
	thin_clouds.deinit();
	rain.deinit();
	fsr.deinit();
	fsr2.deinit();
	mesh_storage.deinit();
	chunk_meshing.deinit();
	reflectionCubeMap.deinit();
}

fn initReflectionCubeMap() void {
	c.glViewport(0, 0, reflectionCubeMapSize, reflectionCubeMapSize);
	var framebuffer: graphics.FrameBuffer = undefined;
	framebuffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
	defer framebuffer.deinit();
	framebuffer.bind();
	fakeReflectionPipeline.bind(null);
	c.glUniform1f(fakeReflectionUniforms.frequency, 1);
	c.glUniform1f(fakeReflectionUniforms.reflectionMapSize, reflectionCubeMapSize);
	for (0..6) |face| {
		c.glUniform3fv(fakeReflectionUniforms.normalVector, 1, @ptrCast(&graphics.CubeMapTexture.faceNormal(face)));
		c.glUniform3fv(fakeReflectionUniforms.upVector, 1, @ptrCast(&graphics.CubeMapTexture.faceUp(face)));
		c.glUniform3fv(fakeReflectionUniforms.rightVector, 1, @ptrCast(&graphics.CubeMapTexture.faceRight(face)));
		reflectionCubeMap.bindToFramebuffer(framebuffer, @intCast(face));
		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}
}

var worldFrameBuffer: graphics.FrameBuffer = undefined;

var cloudFrameBuffer: graphics.FrameBuffer = undefined;

var waterSurfaceFrameBuffer: graphics.FrameBuffer = undefined;

const haltonJitterSequence = [8]Vec2f{
	.{1.0/2.0 - 0.5, 1.0/3.0 - 0.5},
	.{1.0/4.0 - 0.5, 2.0/3.0 - 0.5},
	.{3.0/4.0 - 0.5, 1.0/9.0 - 0.5},
	.{1.0/8.0 - 0.5, 4.0/9.0 - 0.5},
	.{5.0/8.0 - 0.5, 7.0/9.0 - 0.5},
	.{3.0/8.0 - 0.5, 2.0/9.0 - 0.5},
	.{7.0/8.0 - 0.5, 5.0/9.0 - 0.5},
	.{1.0/16.0 - 0.5, 8.0/9.0 - 0.5},
};
var taaJitterIndex: usize = 0;

fn jitteredProjectionMatrix(base: Mat4f, pixelWidth: u31, pixelHeight: u31) Mat4f {
	if (settings.antiAliasingMode != .taa and settings.upscalerMode != .fsr2) return base;
	const jitter = haltonJitterSequence[taaJitterIndex % haltonJitterSequence.len];
	var result = base;
	result.rows[0][1] += jitter[0]*2.0/@as(f32, @floatFromInt(pixelWidth));
	result.rows[1][1] += jitter[1]*2.0/@as(f32, @floatFromInt(pixelHeight));
	return result;
}

pub var lastWidth: u31 = 0;
pub var lastHeight: u31 = 0;
var lastFov: f32 = 0;
pub fn updateFov(fov: f32) void {
	if (lastFov != fov) {
		lastFov = fov;
		game.projectionMatrix = Mat4f.perspective(std.math.degreesToRadians(fov), @as(f32, @floatFromInt(lastWidth))/@as(f32, @floatFromInt(lastHeight)), zNear, zFar);
	}
}
pub fn updateViewport(width: u31, height: u31) void {
	lastWidth = @trunc(@as(f32, @floatFromInt(width))*main.settings.resolutionScale);
	lastHeight = @trunc(@as(f32, @floatFromInt(height))*main.settings.resolutionScale);
	game.projectionMatrix = Mat4f.perspective(std.math.degreesToRadians(lastFov), @as(f32, @floatFromInt(lastWidth))/@as(f32, @floatFromInt(lastHeight)), zNear, zFar);
	worldFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGB16F);
	cloudFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGBA16F);
	waterSurfaceFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGBA16F);
	worldFrameBuffer.unbind();
	fsr.updateSize(lastWidth, lastHeight, width, height);
	CascadedShadowMap.updateMapSize(main.settings.resolutionScale);
}

pub fn render(playerPosition: Vec3d, deltaTime: f64) void {

	std.debug.assert(game.world != null);

	const nightColor: Vec3f = .{0.3, 0.4, 0.5};
	var ambient = @max(nightColor*@as(Vec3f, @splat(settings.nightBrightness)), @as(Vec3f, @splat(game.world.?.dayTime.ambientLight)));
	if (settings.shadows) {
		ambient = @min(ambient*@as(Vec3f, @splat(1.25)), @as(Vec3f, @splat(1.0)));
	}

	itemdrop.ItemDisplayManager.update(deltaTime);
	renderWorld(game.world.?, ambient, game.world.?.dayTime.fog.skyColor, playerPosition);
	const startTime = main.timestamp();
	mesh_storage.updateMeshes(startTime.addDuration(maximumMeshTime));
}

pub fn crosshairDirection(rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31) Vec3f {

	const invRotationMatrix = rotationMatrix.transpose();
	const cameraDir = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 1, 0, 1}));
	const cameraUp = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 0, 1, 1}));
	const cameraRight = vec.xyz(invRotationMatrix.mulVec(Vec4f{1, 0, 0, 1}));

	const screenSize = Vec2f{@floatFromInt(width), @floatFromInt(height)};
	const screenCoord = (crosshair.window.pos + crosshair.window.contentSize*Vec2f{0.5, 0.5}*@as(Vec2f, @splat(crosshair.window.scale)))*@as(Vec2f, @splat(main.gui.scale*main.settings.resolutionScale));

	const halfVSide = std.math.tan(std.math.degreesToRadians(fovY)*0.5);
	const halfHSide = halfVSide*screenSize[0]/screenSize[1];
	const sides = Vec2f{halfHSide, halfVSide};

	const scale = (Vec2f{-1, 1} + Vec2f{2, -2}*screenCoord/screenSize)*sides;
	const forwards = cameraDir;
	const horizontal = cameraRight*@as(Vec3f, @splat(scale[0]));
	const vertical = cameraUp*@as(Vec3f, @splat(scale[1]));

	const adjusted = forwards + horizontal + vertical;
	return adjusted;
}

fn projectDirection(viewProj: Mat4f, dir: Vec3f) ?Vec2f {
	const clip = viewProj.mulVec(Vec4f{dir[0], dir[1], dir[2], 0});
	if (clip[3] <= 1e-4) return null;
	const ndc = vec.xy(clip)/@as(Vec2f, @splat(clip[3]));
	return ndc*@as(Vec2f, @splat(0.5)) + Vec2f{0.5, 0.5};
}

pub fn renderWorld(world: *World, ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void {
	const msaaActive = settings.antiAliasingMode == .msaa;
	if (msaaActive) {
		MSAA.updateSize(lastWidth, lastHeight);
		MSAA.frameBuffer.bind();
		c.glEnable(c.GL_MULTISAMPLE);
	} else {
		c.glDisable(c.GL_MULTISAMPLE);
		c.glDisable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
		worldFrameBuffer.bind();
	}
	c.glViewport(0, 0, lastWidth, lastHeight);
	gpu_performance_measuring.startQuery(.clear);
	if (msaaActive) {
		MSAA.frameBuffer.clear(Vec4f{skyColor[0], skyColor[1], skyColor[2], 1});
	} else {
		worldFrameBuffer.clear(Vec4f{skyColor[0], skyColor[1], skyColor[2], 1});
	}
	gpu_performance_measuring.stopQuery();
	game.camera.updateViewMatrix();

	const jitteredProjection = jitteredProjectionMatrix(game.projectionMatrix, lastWidth, lastHeight);
	main.graphics.frame_uniforms.uploadNewFrame(.{
		.playerPositionInteger = @as(Vec3i, @floor(playerPos)),
		.playerPositionFraction = @as(Vec3f, @floatCast(@mod(playerPos, Vec3d{1, 1, 1}))),
		.projectionMatrix = jitteredProjection.toGl(),
		.viewMatrix = game.camera.viewMatrix.toGl(),
	});

	const frustum = Frustum.init(Vec3f{0, 0, 0}, game.camera.viewMatrix, lastFov, lastWidth, lastHeight);

	const time: u32 = @intCast(main.timestamp().toMilliseconds() & std.math.maxInt(u32));

	gpu_performance_measuring.startQuery(.skybox);
	Skybox.render(playerPos);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.animation);
	blocks.meshes.preProcessAnimationData(time);
	gpu_performance_measuring.stopQuery();

	c.glActiveTexture(c.GL_TEXTURE0);
	blocks.meshes.blockTextureArray.bind();
	c.glActiveTexture(c.GL_TEXTURE1);
	blocks.meshes.emissionTextureArray.bind();
	c.glActiveTexture(c.GL_TEXTURE2);
	blocks.meshes.reflectivityAndAbsorptionTextureArray.bind();
	c.glActiveTexture(c.GL_TEXTURE5);
	blocks.meshes.ditherTexture.bind();
	reflectionCubeMap.bindTo(4);

	chunk_meshing.quadsDrawn = 0;
	chunk_meshing.transparentQuadsDrawn = 0;

	const playerBlock = mesh_storage.getBlockFromRenderThread(@floor(playerPos[0]), @floor(playerPos[1]), @floor(playerPos[2])) orelse blocks.Block{.typ = 0, .data = 0};
	const isSubmerged = blocks.meshes.hasFog(playerBlock);
	const meshes = mesh_storage.updateAndGetRenderChunks(world.conn, &frustum, playerPos, settings.renderDistance);

	gpu_performance_measuring.startQuery(.chunk_rendering_preparation);
	const direction = crosshairDirection(game.camera.viewMatrix, lastFov, lastWidth, lastHeight);
	MeshSelection.select(playerPos, direction, game.Player.inventory.getItem(game.Player.selectedSlot));

	chunk_meshing.beginRender();

	if (settings.shadows) {
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.shadow_rendering);
		ShadowRaymarch.update(playerPos);
		CascadedShadowMap.update(playerPos);
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.chunk_rendering_preparation);
	}

	clouds.update(playerPos);
	rain.update(playerPos, game.camera.viewMatrix, ambientLight);

	var chunkLists: [main.settings.highestSupportedLod + 1]main.ListManaged(u32) = @splat(main.ListManaged(u32).init(main.stackAllocator));
	defer for (chunkLists) |list| list.deinit();
	for (meshes) |mesh| {
		if (isSubmerged and !isWithinSubmergedTerrainRenderRange(mesh, playerPos)) continue;
		mesh.prepareRendering(&chunkLists);
	}
	gpu_performance_measuring.stopQuery();
	if (msaaActive) {
		c.glEnable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
	}
	gpu_performance_measuring.startQuery(.chunk_rendering);
	chunk_meshing.drawChunksIndirect(&chunkLists, ambientLight, false);
	gpu_performance_measuring.stopQuery();
	if (msaaActive) {
		c.glDisable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
	}

	gpu_performance_measuring.startQuery(.entity_rendering);

	main.entity.client.render(ambientLight, playerPos, main.lastDeltaTime.load(.monotonic));

	if (msaaActive) c.glEnable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
	itemdrop.ItemDropRenderer.renderItemDrops(ambientLight, playerPos);
	itemdrop.ItemDropRenderer.renderRemoteHeldLights(ambientLight, playerPos);
	if (msaaActive) c.glDisable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.block_entity_rendering);
	main.block_entity.renderAll(ambientLight);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.particle_rendering);
	particles.ParticleSystem.render(game.projectionMatrix, game.camera.viewMatrix, ambientLight);
	gpu_performance_measuring.stopQuery();

	if (msaaActive) {
		gpu_performance_measuring.startQuery(.msaa_resolve);
		MSAA.frameBuffer.resolveTo(&worldFrameBuffer, lastWidth, lastHeight);
		c.glDisable(c.GL_MULTISAMPLE);
		c.glDisable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
		worldFrameBuffer.bind();
		gpu_performance_measuring.stopQuery();
	}

	c.glActiveTexture(c.GL_TEXTURE0);
	blocks.meshes.blockTextureArray.bind();
	c.glActiveTexture(c.GL_TEXTURE1);
	blocks.meshes.emissionTextureArray.bind();

	MeshSelection.render(playerPos);

	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);
	worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE5);

	gpu_performance_measuring.startQuery(.transparent_rendering_preparation);
	c.glTextureBarrier();

	{
		for (&chunkLists) |*list| list.clearRetainingCapacity();
		var i: usize = meshes.len;
		while (true) {
			if (i == 0) break;
			i -= 1;
			if (isSubmerged and !isWithinSubmergedTerrainRenderRange(meshes[i], playerPos)) continue;
			meshes[i].prepareTransparentRendering(playerPos, &chunkLists);
		}
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.transparent_rendering);
		chunk_meshing.drawChunksIndirect(&chunkLists, ambientLight, true);
		gpu_performance_measuring.stopQuery();
	}

	c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, worldFrameBuffer.frameBuffer);
	c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, waterSurfaceFrameBuffer.frameBuffer);
	c.glBlitFramebuffer(0, 0, lastWidth, lastHeight, 0, 0, lastWidth, lastHeight, c.GL_DEPTH_BUFFER_BIT, c.GL_NEAREST);
	waterSurfaceFrameBuffer.bind();
	c.glClearColor(0, 0, 0, 0);
	c.glClear(c.GL_COLOR_BUFFER_BIT);
	const weatherWaterMask = !isSubmerged and world.dayTime.weatherVisibility > 0.001 and playerPos[2] < 6000.0;
	if (isSubmerged or weatherWaterMask) {
		chunk_meshing.drawWaterSurfaceMask(&chunkLists, ambientLight, weatherWaterMask);
	}
	worldFrameBuffer.bind();

	c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, worldFrameBuffer.frameBuffer);
	c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, cloudFrameBuffer.frameBuffer);
	c.glBlitFramebuffer(0, 0, lastWidth, lastHeight, 0, 0, lastWidth, lastHeight, c.GL_DEPTH_BUFFER_BIT, c.GL_NEAREST);
	cloudFrameBuffer.bind();
	c.glClearColor(0, 0, 0, 0);
	c.glClear(c.GL_COLOR_BUFFER_BIT);

	if (!isSubmerged and playerPos[2] < 6000.0) {
		clouds.draw(ambientLight, skyColor, playerPos);
		thin_clouds.draw(ambientLight, skyColor, playerPos);
	}
	worldFrameBuffer.bind();
	if (!isSubmerged) {
		rain.draw();
	}

	c.glDepthRange(0, 0.001);
	itemdrop.ItemDropRenderer.renderDisplayItems(ambientLight, playerPos);
	c.glDepthRange(0.001, 1);

	chunk_meshing.endRender();

	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);

	if (settings.bloom) {
		Bloom.render(lastWidth, lastHeight, playerBlock, game.camera.viewMatrix);
	} else {
		Bloom.bindReplacementImage();
	}

	if (settings.godRays and game.world.?.dayTime.weatherVisibility < 0.02) {
		gpu_performance_measuring.startQuery(.god_rays);
		GodRays.render(lastWidth, lastHeight, game.camera.viewMatrix);
		gpu_performance_measuring.stopQuery();
	} else {
		GodRays.bindReplacementImage();
	}
	gpu_performance_measuring.startQuery(.final_copy);
	c.glViewport(0, 0, lastWidth, lastHeight);
	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);
	worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE4);
	cloudFrameBuffer.bindTexture(c.GL_TEXTURE11);
	waterSurfaceFrameBuffer.bindTexture(c.GL_TEXTURE12);
	worldFrameBuffer.unbind();
	deferredRenderPassPipeline.bind(null);

	const skyIslandGroundFade = std.math.clamp(@as(f32, @floatCast((playerPos[2] - 2000.0)/4000.0)), 0.0, 1.0);
	c.glUniform1f(deferredUniforms.skyIslandGroundFade, skyIslandGroundFade);
	const skyIslandMistStrength = std.math.clamp(@as(f32, @floatCast((playerPos[2] - 8000.0)/2000.0)), 0.0, 1.0);
	c.glUniform1f(deferredUniforms.skyIslandMistStrength, skyIslandMistStrength);
	c.glUniform3f(deferredUniforms.skyIslandFogColor, 0.0, 0.0, 0.0);
	if (clouds.isPlayerInsideCloud(playerPos)) {
		const cloudFogColor = Vec3f{0.92, 0.95, 1.0} * game.world.?.dayTime.fog.fogColor;
		c.glUniform3fv(deferredUniforms.@"fog.color", 1, @ptrCast(&cloudFogColor));
		c.glUniform1f(deferredUniforms.@"fog.density", 0.08);
		c.glUniform1f(deferredUniforms.@"fog.fogLower", -1e5);
		c.glUniform1f(deferredUniforms.@"fog.fogHigher", 1e5);
		c.glUniform1f(deferredUniforms.fogWhitening, 0.15);
		c.glUniform1f(deferredUniforms.weatherFogStrength, 0.0);
	} else if (!blocks.meshes.hasFog(playerBlock)) {
		const skyColorVal = game.world.?.dayTime.fog.skyColor;
		const baseFogColor = game.world.?.dayTime.fog.fogColor;

		c.glUniform3fv(deferredUniforms.skyIslandFogColor, 1, @ptrCast(&skyColorVal));
		var fogColor = skyColorVal;
		var fogDensity = game.world.?.dayTime.fog.density;
		const playerZ: f32 = @floatCast(playerPos[2]);

		const cloudAltDist = @abs(playerZ - 453.0);
		const cloudAltFactor = 1.0 - std.math.clamp((cloudAltDist - 10.0) / 40.0, 0.0, 1.0);

		const lodScale: f32 = @floatFromInt(@as(u32, 1) << main.settings.highestLod);
		const totalMaxLodDist: f32 = @as(f32, @floatFromInt(@as(u32, main.settings.renderDistance) * 32)) * lodScale;

		if (totalMaxLodDist > 0) fogDensity = 1.0 / totalMaxLodDist;

		const skyIslandMist = std.math.clamp((playerZ - 8000.0)/2000.0, 0.0, 1.0);
		const skyIslandFogRange: f32 = 750.0;
		fogDensity = std.math.lerp(fogDensity, 1.0/skyIslandFogRange, skyIslandMist);

		if (playerZ <= 2000.0) {

			fogColor = skyColorVal + (baseFogColor - skyColorVal) * @as(Vec3f, @splat(cloudAltFactor));
		}

		const weatherVisibility = if (playerZ > 6000.0) 0.0 else game.world.?.dayTime.weatherVisibility;
		if (weatherVisibility > 0.001) {
			const weatherFogTint = std.math.clamp(weatherVisibility * 1.15, 0.0, 0.85);
			fogColor += (baseFogColor - fogColor) * @as(Vec3f, @splat(weatherFogTint));
		}
		fogDensity = @max(fogDensity, weatherVisibility / game.world.?.dayTime.weatherFogRange);

		c.glUniform3fv(deferredUniforms.@"fog.color", 1, @ptrCast(&fogColor));
		c.glUniform1f(deferredUniforms.@"fog.density", fogDensity);

		c.glUniform1f(deferredUniforms.@"fog.fogLower", if (playerZ > 2000.0) -1e5 else game.world.?.dayTime.fog.fogLower);
		c.glUniform1f(deferredUniforms.@"fog.fogHigher", if (playerZ > 2000.0) 1e5 else game.world.?.dayTime.fog.fogHigher);

		c.glUniform1f(deferredUniforms.fogWhitening, if (weatherVisibility > 0.001 or skyIslandMist > 0.001) 0.0 else 0.7);
		c.glUniform1f(deferredUniforms.weatherFogStrength, weatherVisibility);
	} else {
		const fogColor = blocks.meshes.fogColor(playerBlock);
		c.glUniform3f(deferredUniforms.@"fog.color", @as(f32, @floatFromInt(fogColor >> 16 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 8 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 0 & 255))/255.0);
		c.glUniform1f(deferredUniforms.@"fog.density", blocks.meshes.fogDensity(playerBlock));
		c.glUniform1f(deferredUniforms.@"fog.fogLower", 1e10);
		c.glUniform1f(deferredUniforms.@"fog.fogHigher", 1e10);
		c.glUniform1f(deferredUniforms.fogWhitening, 0.0);
		c.glUniform1f(deferredUniforms.weatherFogStrength, 0.0);
	}
	c.glUniformMatrix4fv(deferredUniforms.invViewMatrix, 1, c.GL_TRUE, @ptrCast(&game.camera.viewMatrix.transpose()));
	c.glUniform1f(deferredUniforms.zNear, zNear);
	c.glUniform1f(deferredUniforms.zFar, zFar);
	c.glUniform2f(deferredUniforms.tanXY, 1.0/game.projectionMatrix.rows[0][0], 1.0/game.projectionMatrix.rows[1][2]);
	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const waterTime: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds)) * 1e-9);
	c.glUniform1f(deferredUniforms.waterTime, waterTime);
	{

		const isSunlight = game.world.?.dayTime.isSunlight();
		const tint: Vec3f = if (isSunlight) Vec3f{1.0, 0.9, 0.6} else Vec3f{0.9, 0.92, 0.95};
		c.glUniform3fv(deferredUniforms.godRayTint, 1, @ptrCast(&tint));
	}

	const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else activeFrameBuffer;

	switch (settings.antiAliasingMode) {
		.fxaa => FXAA.preDraw(lastWidth, lastHeight),
		.taa => TAA.preDraw(lastWidth, lastHeight),
		.off, .msaa => c.glBindFramebuffer(c.GL_FRAMEBUFFER, targetFBO),
	}

	graphics.draw.rectVao.bind();
	c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

	switch (settings.antiAliasingMode) {
		.fxaa => FXAA.render(lastWidth, lastHeight),
		.taa => {

			gpu_performance_measuring.stopQuery();
			gpu_performance_measuring.startQuery(.taa_resolve);
			TAA.render(playerPos, jitteredProjection, game.camera.viewMatrix);
			gpu_performance_measuring.stopQuery();
			gpu_performance_measuring.startQuery(.final_copy);
			TAA.endFrame(playerPos, game.camera.viewMatrix, game.projectionMatrix);
			taaJitterIndex +%= 1;
		},
		.off, .msaa => {},
	}

	if (main.settings.resolutionScale < 1.0) {
		c.glViewport(0, 0, main.Window.width, main.Window.height);
		if (main.settings.upscalerMode == .fsr2) {
			const jitter = haltonJitterSequence[taaJitterIndex % haltonJitterSequence.len];
			fsr2.render(fsr.inputFrameBuffer.texture, worldFrameBuffer.depthTexture, lastWidth, lastHeight, main.Window.width, main.Window.height, jitter, activeFrameBuffer);
			taaJitterIndex +%= 1;
		} else {
			fsr.render(lastWidth, lastHeight, main.Window.width, main.Window.height, activeFrameBuffer);
		}
	} else {
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
	}

	if (!main.gui.hideGui) main.entity.client.renderHud(ambientLight, playerPos);
	gpu_performance_measuring.stopQuery();
}

const MSAA = struct {
	var frameBuffer: graphics.MultisampledFrameBuffer = undefined;
	var width: u31 = std.math.maxInt(u31);
	var height: u31 = std.math.maxInt(u31);

	var lastSamples: u8 = 0;

	pub fn init() void {
		frameBuffer.init(main.settings.msaaSamples);
		lastSamples = main.settings.msaaSamples;
	}

	pub fn deinit() void {
		frameBuffer.deinit();
	}

	fn updateSize(currentWidth: u31, currentHeight: u31) void {

		if (lastSamples != main.settings.msaaSamples) {
			frameBuffer.deinit();
			frameBuffer.init(main.settings.msaaSamples);
			lastSamples = main.settings.msaaSamples;
			width = std.math.maxInt(u31);
			height = std.math.maxInt(u31);
		}
		if (width != currentWidth or height != currentHeight) {
			width = currentWidth;
			height = currentHeight;

			frameBuffer.updateSize(width, height, c.GL_RGBA16F);
			std.debug.assert(frameBuffer.validate());
		}
	}
};

const FXAA = struct {
	var buffer: graphics.FrameBuffer = undefined;
	var width: u31 = std.math.maxInt(u31);
	var height: u31 = std.math.maxInt(u31);
	var pipeline: graphics.Pipeline = undefined;
	var uniforms: struct {
		inverseScreenSize: c_int,
	} = undefined;

	pub fn init() void {
		buffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/fxaa.vert",
			"assets/cubyz/shaders/fxaa.frag",
			"",
			&uniforms,
			graphics.draw.SimpleVertex2D,
			&.{.{.binding = 3, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}}},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
	}

	pub fn deinit() void {
		buffer.deinit();
		pipeline.deinit();
	}

	fn preDraw(currentWidth: u31, currentHeight: u31) void {
		if (width != currentWidth or height != currentHeight) {
			width = currentWidth;
			height = currentHeight;
			buffer.updateSize(width, height, c.GL_RGBA8);
			std.debug.assert(buffer.validate());
		}
		buffer.bind();
	}

	fn render(currentWidth: u31, currentHeight: u31) void {
		pipeline.bind(null);
		buffer.bindTexture(c.GL_TEXTURE3);
		const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else activeFrameBuffer;
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, targetFBO);
		c.glUniform2f(uniforms.inverseScreenSize, 1.0/@as(f32, @floatFromInt(currentWidth)), 1.0/@as(f32, @floatFromInt(currentHeight)));
		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}
};

const TAA = struct {

	var currentBuffer: graphics.FrameBuffer = undefined;

	var resolveBuffers: [2]graphics.FrameBuffer = undefined;
	var resolveIndex: usize = 0;
	var width: u31 = std.math.maxInt(u31);
	var height: u31 = std.math.maxInt(u31);
	var pipeline: graphics.Pipeline = undefined;
	var uniforms: struct {
		tanXY: c_int,
		zNear: c_int,
		zFar: c_int,
		invViewMatrix: c_int,
		lastViewProjMatrix: c_int,
		cameraDelta: c_int,
		historyBlendFactor: c_int,
	} = undefined;

	var lastPlayerPos: Vec3d = .{0, 0, 0};
	var lastViewMatrix: Mat4f = Mat4f.identity();
	var lastProjectionMatrix: Mat4f = Mat4f.identity();
	var hasHistory: bool = false;

	pub fn init() void {
		currentBuffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		for (&resolveBuffers) |*buffer| buffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/taa_resolve.vert",
			"assets/cubyz/shaders/taa_resolve.frag",
			"",
			&uniforms,
			graphics.draw.SimpleVertex2D,
			&.{
				.{.binding = 3, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}},
				.{.binding = 4, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}},
				.{.binding = 6, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}},
			},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
	}

	pub fn deinit() void {
		currentBuffer.deinit();
		for (&resolveBuffers) |*buffer| buffer.deinit();
		pipeline.deinit();
	}

	fn updateSize(currentWidth: u31, currentHeight: u31) void {
		if (width != currentWidth or height != currentHeight) {
			width = currentWidth;
			height = currentHeight;
			currentBuffer.updateSize(width, height, c.GL_RGBA8);
			std.debug.assert(currentBuffer.validate());
			for (&resolveBuffers) |*buffer| {
				buffer.updateSize(width, height, c.GL_R11F_G11F_B10F);
				std.debug.assert(buffer.validate());
			}
			hasHistory = false;
		}
	}

	fn preDraw(currentWidth: u31, currentHeight: u31) void {
		updateSize(currentWidth, currentHeight);
		currentBuffer.bind();
	}

	fn render(playerPos: Vec3d, projectionMatrix: Mat4f, invViewMatrix: Mat4f) void {
		const writeIndex = resolveIndex;
		const readIndex = 1 - resolveIndex;
		resolveIndex = readIndex;

		pipeline.bind(null);
		currentBuffer.bindTexture(c.GL_TEXTURE3);
		resolveBuffers[readIndex].bindTexture(c.GL_TEXTURE6);
		resolveBuffers[writeIndex].bind();

		c.glUniform2f(uniforms.tanXY, 1.0/projectionMatrix.rows[0][0], 1.0/projectionMatrix.rows[1][2]);
		c.glUniform1f(uniforms.zNear, zNear);
		c.glUniform1f(uniforms.zFar, zFar);
		c.glUniformMatrix4fv(uniforms.invViewMatrix, 1, c.GL_TRUE, @ptrCast(&invViewMatrix.transpose()));

		const cameraDelta: Vec3f = @floatCast(playerPos - lastPlayerPos);
		c.glUniform3fv(uniforms.cameraDelta, 1, @ptrCast(&cameraDelta));

		const lastViewProj = lastProjectionMatrix.mul(lastViewMatrix);
		c.glUniformMatrix4fv(uniforms.lastViewProjMatrix, 1, c.GL_TRUE, @ptrCast(&lastViewProj.transpose()));

		c.glUniform1f(uniforms.historyBlendFactor, if (hasHistory) 0.9 else 0.0);

		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

		c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, resolveBuffers[writeIndex].frameBuffer);
		const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else activeFrameBuffer;
		c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, targetFBO);
		c.glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
	}

	fn endFrame(playerPos: Vec3d, viewMatrix: Mat4f, projectionMatrix: Mat4f) void {
		lastPlayerPos = playerPos;
		lastViewMatrix = viewMatrix;
		lastProjectionMatrix = projectionMatrix;
		hasHistory = true;
	}
};

const Bloom = struct {
	var buffer1: graphics.FrameBuffer = undefined;
	var buffer2: graphics.FrameBuffer = undefined;
	var emptyBuffer: graphics.Texture = undefined;
	var width: u31 = std.math.maxInt(u31);
	var height: u31 = std.math.maxInt(u31);
	var firstPassPipeline: graphics.Pipeline = undefined;
	var secondPassPipeline: graphics.Pipeline = undefined;
	var colorExtractAndDownsamplePipeline: graphics.Pipeline = undefined;
	var colorExtractUniforms: struct {
		zNear: c_int,
		zFar: c_int,
		tanXY: c_int,
		@"fog.color": c_int,
		@"fog.density": c_int,
		@"fog.fogLower": c_int,
		@"fog.fogHigher": c_int,
		invViewMatrix: c_int,
	} = undefined;

	pub fn init() void {
		buffer1.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		buffer2.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		emptyBuffer = .init();
		emptyBuffer.generate(graphics.Image.emptyImage);
		firstPassPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/bloom/first_pass.vert",
			"assets/cubyz/shaders/bloom/first_pass.frag",
			"",
			null,
			graphics.draw.SimpleVertex2D,
			&.{.sampler(3, .{.fragment = true})},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
		secondPassPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/bloom/second_pass.vert",
			"assets/cubyz/shaders/bloom/second_pass.frag",
			"",
			null,
			graphics.draw.SimpleVertex2D,
			&.{.sampler(3, .{.fragment = true})},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
		colorExtractAndDownsamplePipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/bloom/color_extractor_downsample.vert",
			"assets/cubyz/shaders/bloom/color_extractor_downsample.frag",
			"",
			&colorExtractUniforms,
			graphics.draw.SimpleVertex2D,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
	}

	pub fn deinit() void {
		buffer1.deinit();
		buffer2.deinit();
		firstPassPipeline.deinit();
		secondPassPipeline.deinit();
		colorExtractAndDownsamplePipeline.deinit();
	}

	fn extractImageDataAndDownsample(playerBlock: blocks.Block, viewMatrix: Mat4f) void {
		colorExtractAndDownsamplePipeline.bind(null);
		worldFrameBuffer.bindTexture(c.GL_TEXTURE3);
		worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE4);
		buffer1.bind();
		if (!blocks.meshes.hasFog(playerBlock)) {
			c.glUniform3fv(colorExtractUniforms.@"fog.color", 1, @ptrCast(&game.world.?.dayTime.fog.fogColor));
			c.glUniform1f(colorExtractUniforms.@"fog.density", game.world.?.dayTime.fog.density);
			c.glUniform1f(colorExtractUniforms.@"fog.fogLower", game.world.?.dayTime.fog.fogLower);
			c.glUniform1f(colorExtractUniforms.@"fog.fogHigher", game.world.?.dayTime.fog.fogHigher);
		} else {
			const fogColor = blocks.meshes.fogColor(playerBlock);
			c.glUniform3f(colorExtractUniforms.@"fog.color", @as(f32, @floatFromInt(fogColor >> 16 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 8 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 0 & 255))/255.0);
			c.glUniform1f(colorExtractUniforms.@"fog.density", blocks.meshes.fogDensity(playerBlock));
			c.glUniform1f(colorExtractUniforms.@"fog.fogLower", 1e10);
			c.glUniform1f(colorExtractUniforms.@"fog.fogHigher", 1e10);
		}

		c.glUniformMatrix4fv(colorExtractUniforms.invViewMatrix, 1, c.GL_TRUE, @ptrCast(&viewMatrix.transpose()));
		c.glUniform1f(colorExtractUniforms.zNear, zNear);
		c.glUniform1f(colorExtractUniforms.zFar, zFar);
		c.glUniform2f(colorExtractUniforms.tanXY, 1.0/game.projectionMatrix.rows[0][0], 1.0/game.projectionMatrix.rows[1][2]);
		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	fn firstPass() void {
		firstPassPipeline.bind(null);
		buffer1.bindTexture(c.GL_TEXTURE3);
		buffer2.bind();
		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	fn secondPass() void {
		secondPassPipeline.bind(null);
		buffer2.bindTexture(c.GL_TEXTURE3);
		buffer1.bind();
		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	fn render(currentWidth: u31, currentHeight: u31, playerBlock: blocks.Block, viewMatrix: Mat4f) void {
		if (width != currentWidth or height != currentHeight) {
			width = currentWidth;
			height = currentHeight;
			buffer1.updateSize(width/4, height/4, c.GL_R11F_G11F_B10F);
			std.debug.assert(buffer1.validate());
			buffer2.updateSize(width/4, height/4, c.GL_R11F_G11F_B10F);
			std.debug.assert(buffer2.validate());
		}
		gpu_performance_measuring.startQuery(.bloom_extract_downsample);

		c.glViewport(0, 0, width/4, height/4);
		extractImageDataAndDownsample(playerBlock, viewMatrix);
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.bloom_first_pass);
		firstPass();
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.bloom_second_pass);
		secondPass();

		c.glViewport(0, 0, width, height);
		buffer1.bindTexture(c.GL_TEXTURE5);

		gpu_performance_measuring.stopQuery();
	}

	fn bindReplacementImage() void {
		emptyBuffer.bindTo(5);
	}
};

const GodRays = struct {
	var maskBuffer: graphics.FrameBuffer = undefined;
	var rayBuffer: graphics.FrameBuffer = undefined;
	var emptyBuffer: graphics.Texture = undefined;
	var width: u31 = std.math.maxInt(u31);
	var height: u31 = std.math.maxInt(u31);
	var maskPipeline: graphics.Pipeline = undefined;
	var maskUniforms: struct {
		invViewMatrix: c_int,
		tanXY: c_int,
		cloudCoverageOrigin: c_int,
		cloudCoverageWorldSize: c_int,
		cloudHeightRelative: c_int,
		sunDirection: c_int,
		sunScreenPos: c_int,
		aspectRatio: c_int,
	} = undefined;
	var blurPipeline: graphics.Pipeline = undefined;
	var blurUniforms: struct {
		sunScreenPos: c_int,
		strength: c_int,
	} = undefined;

	pub fn init() void {
		maskBuffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		rayBuffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
		emptyBuffer = .init();
		emptyBuffer.generate(graphics.Image.emptyImage);
		maskPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/godrays/mask.vert",
			"assets/cubyz/shaders/godrays/mask.frag",
			"",
			&maskUniforms,
			graphics.draw.SimpleVertex2D,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
		blurPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/godrays/blur.vert",
			"assets/cubyz/shaders/godrays/blur.frag",
			"",
			&blurUniforms,
			graphics.draw.SimpleVertex2D,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
	}

	pub fn deinit() void {
		maskBuffer.deinit();
		rayBuffer.deinit();
		maskPipeline.deinit();
		blurPipeline.deinit();
	}

	const offScreenSentinel = Vec2f{-10, -10};

	fn maskPass(viewMatrix: Mat4f, sunDirection: Vec3f, sunScreenPos: Vec2f, aspectRatio: f32) void {
		maskPipeline.bind(null);
		worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE4);

		maskBuffer.bind();

		c.glUniformMatrix4fv(maskUniforms.invViewMatrix, 1, c.GL_TRUE, @ptrCast(&viewMatrix.transpose()));
		c.glUniform2f(maskUniforms.tanXY, 1.0/game.projectionMatrix.rows[0][0], 1.0/game.projectionMatrix.rows[1][2]);
		c.glUniform2f(maskUniforms.cloudCoverageOrigin, clouds.coverageOriginRelative[0], clouds.coverageOriginRelative[1]);
		c.glUniform1f(maskUniforms.cloudCoverageWorldSize, clouds.coverageWorldSize);
		c.glUniform1f(maskUniforms.cloudHeightRelative, clouds.cloudHeightRelative);
		c.glUniform3fv(maskUniforms.sunDirection, 1, @ptrCast(&sunDirection));
		c.glUniform2f(maskUniforms.sunScreenPos, sunScreenPos[0], sunScreenPos[1]);
		c.glUniform1f(maskUniforms.aspectRatio, aspectRatio);

		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	fn blurPass(sunScreenPos: Vec2f, strength: f32) void {
		blurPipeline.bind(null);
		maskBuffer.bindTexture(c.GL_TEXTURE3);
		rayBuffer.bind();

		c.glUniform2f(blurUniforms.sunScreenPos, sunScreenPos[0], sunScreenPos[1]);
		c.glUniform1f(blurUniforms.strength, strength);

		graphics.draw.rectVao.bind();
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	fn render(currentWidth: u31, currentHeight: u31, viewMatrix: Mat4f) void {
		if (width != currentWidth or height != currentHeight) {
			width = currentWidth;
			height = currentHeight;
			maskBuffer.updateSize(width/4, height/4, c.GL_R11F_G11F_B10F);
			std.debug.assert(maskBuffer.validate());
			rayBuffer.updateSize(width/4, height/4, c.GL_R11F_G11F_B10F);
			std.debug.assert(rayBuffer.validate());
		}

		const lightDir = game.world.?.dayTime.getVisibleCelestialDirection();
		const viewProj = game.projectionMatrix.mul(viewMatrix);

		const sunScreenPos = projectDirection(viewProj, lightDir) orelse offScreenSentinel;

		const moonDimming: f32 = if (game.world.?.dayTime.isSunlight()) 1.0 else 0.5;

		const centerDist = vec.length(sunScreenPos - Vec2f{0.5, 0.5});
		const centerFadeInner: f32 = 0.15;
		const centerFadeOuter: f32 = 0.9;
		const centerFadeT = std.math.clamp((centerDist - centerFadeInner)/(centerFadeOuter - centerFadeInner), 0.0, 1.0);
		const centerFade = 1.0 - centerFadeT*centerFadeT*(3.0 - 2.0*centerFadeT);

		const transitionFade = game.world.?.dayTime.getShadowTransitionFade();
		const strength = Skybox.horizonFade(lightDir)*settings.godRayIntensity*moonDimming*centerFade*transitionFade;

		const aspectRatio = (1.0/game.projectionMatrix.rows[0][0])/(1.0/game.projectionMatrix.rows[1][2]);

		c.glViewport(0, 0, width/4, height/4);
		maskPass(viewMatrix, lightDir, sunScreenPos, aspectRatio);
		blurPass(sunScreenPos, strength);

		c.glViewport(0, 0, width, height);
		rayBuffer.bindTexture(c.GL_TEXTURE10);
	}

	fn bindReplacementImage() void {
		emptyBuffer.bindTo(10);
	}
};

pub const MenuBackGround = struct {
	var pipeline: graphics.Pipeline = undefined;

	var vao: graphics.VertexArray = undefined;
	var texture: graphics.Texture = undefined;

	var angle: f32 = 0;

	fn init() void {
		const MenuBackgroundVertex = struct {
			pos: [3]f32,
			uv: [2]f32,

			pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
				.{
					.location = 0,
					.format = c.VK_FORMAT_R32G32B32_SFLOAT,
					.offset = @offsetOf(@This(), "pos"),
				},
				.{
					.location = 1,
					.format = c.VK_FORMAT_R32G32_SFLOAT,
					.offset = @offsetOf(@This(), "uv"),
				},
			};
		};
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/background/vertex.vert",
			"assets/cubyz/shaders/background/fragment.frag",
			"",
			null,
			MenuBackgroundVertex,
			&.{.sampler(0, .{.fragment = true})},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);

		const rawData = [_]MenuBackgroundVertex{
			.{.pos = .{-1, 1, -1}, .uv = .{1, 1}},
			.{.pos = .{-1, 1, 1}, .uv = .{1, 0}},
			.{.pos = .{-1, -1, -1}, .uv = .{0.75, 1}},
			.{.pos = .{-1, -1, 1}, .uv = .{0.75, 0}},
			.{.pos = .{1, -1, -1}, .uv = .{0.5, 1}},
			.{.pos = .{1, -1, 1}, .uv = .{0.5, 0}},
			.{.pos = .{1, 1, -1}, .uv = .{0.25, 1}},
			.{.pos = .{1, 1, 1}, .uv = .{0.25, 0}},
			.{.pos = .{-1, 1, -1}, .uv = .{0, 1}},
			.{.pos = .{-1, 1, 1}, .uv = .{0, 0}},
		};

		const indices = [_]u32{
			0, 1, 2,
			2, 3, 1,
			2, 3, 4,
			4, 5, 3,
			4, 5, 6,
			6, 7, 5,
			6, 7, 8,
			8, 9, 7,
		};

		vao = .init(MenuBackgroundVertex, &rawData, &indices);

		const backgroundPath = chooseBackgroundImagePath(main.stackAllocator) catch |err| {
			std.log.err("Couldn't open background path: {s}", .{@errorName(err)});
			texture = .{.textureID = 0};
			return;
		};
		defer main.stackAllocator.free(backgroundPath);
		texture = graphics.Texture.initFromFile(backgroundPath);
	}

	fn chooseBackgroundImagePath(allocator: main.heap.NeverFailingAllocator) ![]const u8 {
		var dir = try main.files.cubyzDir().openIterableDir("backgrounds");
		defer dir.close();

		if (!std.mem.eql(u8, settings.lastVersionString, settings.version.version)) {
			const defaultImageData = try main.files.cwd().read(main.stackAllocator, "assets/cubyz/default_background.png");
			defer main.stackAllocator.free(defaultImageData);
			try dir.write("default_background.png", defaultImageData);

			return allocator.print("{s}/backgrounds/default_background.png", .{main.files.cubyzDirStr()});
		}

		var walker = dir.walk(main.stackAllocator);
		defer walker.deinit();
		var fileList: main.List([]const u8) = .empty;
		defer {
			for (fileList.items) |fileName| {
				main.stackAllocator.free(fileName);
			}
			fileList.deinit(main.stackAllocator);
		}

		while (try walker.next(main.io)) |entry| {
			if (entry.kind == .file and std.ascii.endsWithIgnoreCase(entry.basename, ".png")) {
				fileList.append(main.stackAllocator, main.stackAllocator.dupe(u8, entry.path));
			}
		}
		if (fileList.items.len == 0) {
			return error.NoBackgroundImagesFound;
		}
		const theChosenOne = main.random.nextIntBounded(u32, &main.seed, @as(u32, @intCast(fileList.items.len)));
		return allocator.print("{s}/backgrounds/{s}", .{main.files.cubyzDirStr(), fileList.items[theChosenOne]});
	}

	pub fn deinit() void {
		pipeline.deinit();
		vao.deinit();
	}

	pub fn hasImage() bool {
		return texture.textureID != 0;
	}

	pub fn render(deltaTime: f64) void {
		c.glViewport(0, 0, main.Window.width, main.Window.height);
		if (texture.textureID == 0) return;

		angle += @as(f32, @floatCast(deltaTime))/20.0;
		const viewMatrix = Mat4f.rotationZ(angle);
		main.graphics.frame_uniforms.uploadNewFrame(.{
			.playerPositionInteger = @splat(0),
			.playerPositionFraction = @splat(0),
			.projectionMatrix = game.projectionMatrix.toGl(),
			.viewMatrix = viewMatrix.toGl(),
		});
		pipeline.bind(null);

		texture.bindTo(0);

		vao.bind();
		c.glDrawElements(c.GL_TRIANGLES, 24, c.GL_UNSIGNED_INT, null);
	}

	pub fn takeBackgroundImage() void {
		const size: usize = 1024;
		const pixels: []u32 = main.stackAllocator.alloc(u32, size*size);
		defer main.stackAllocator.free(pixels);

		const oldResolutionScale = main.settings.resolutionScale;
		main.settings.resolutionScale = 1;
		updateViewport(size, size);
		updateFov(90.0);
		defer updateFov(main.settings.fov);
		main.settings.resolutionScale = oldResolutionScale;
		defer updateViewport(Window.width, Window.height);

		var buffer: graphics.FrameBuffer = undefined;
		buffer.init(true, c.GL_NEAREST, c.GL_REPEAT);
		defer buffer.deinit();
		buffer.updateSize(size, size, c.GL_RGBA8);

		activeFrameBuffer = buffer.frameBuffer;
		defer activeFrameBuffer = 0;

		const oldRotation = game.camera.rotation;
		defer game.camera.rotation = oldRotation;

		const angles = [_]f32{std.math.pi/2.0, std.math.pi, std.math.pi*3/2.0, std.math.pi*2};

		const image = graphics.Image.init(main.stackAllocator, 4*size, size);
		defer image.deinit(main.stackAllocator);

		for (0..4) |i| {
			c.glDepthFunc(c.GL_LESS);
			c.glDepthMask(c.GL_TRUE);
			c.glDisable(c.GL_SCISSOR_TEST);
			game.camera.rotation = .{0, 0, angles[i]};

			buffer.bind();
			c.glClear(c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT | c.GL_COLOR_BUFFER_BIT);
			main.renderer.render(game.Player.getEyePosBlocking(), 0);

			buffer.bind();
			c.glReadPixels(0, 0, size, size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);

			for (0..size) |y| {
				for (0..size) |x| {
					const index = x + y*size;

					image.setRGB(x + size*i, size - 1 - y, @bitCast(pixels[index]));
				}
			}
		}
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

		const fileName = main.stackAllocator.print("{s}/backgrounds/{s}_{}.png", .{main.files.cubyzDirStr(), game.world.?.name, game.world.?.gameTime.load(.monotonic)});
		defer main.stackAllocator.free(fileName);
		image.exportToFile(fileName) catch |err| {
			std.log.err("Cannot write file {s} due to {s}", .{fileName, @errorName(err)});
		};

	}
};

pub const Skybox = struct {
	var starPipeline: graphics.Pipeline = undefined;
	var starUniforms: struct {
		mvp: c_int,
		starOpacity: c_int,
	} = undefined;

	var starVao: graphics.VertexArray = undefined;

	var starSsbo: graphics.SSBO = undefined;

	const numStars = 10000;

	var celestialPipeline: graphics.Pipeline = undefined;
	var celestialUniforms: struct {
		worldCenter: c_int,
		billboardRight: c_int,
		billboardUp: c_int,
		billboardSize: c_int,
		color: c_int,
		opacity: c_int,
		cloudAttenuation: c_int,
	} = undefined;
	var celestialVao: graphics.VertexArray = undefined;

	fn getStarPos(seed: *u64) Vec3f {
		const x: f32 = @floatCast(main.random.nextFloatGauss(seed));
		const y: f32 = @floatCast(main.random.nextFloatGauss(seed));
		const z: f32 = @floatCast(main.random.nextFloatGauss(seed));

		const r = std.math.cbrt(main.random.nextFloat(seed))*5000.0;

		return vec.normalize(Vec3f{x, y, z})*@as(Vec3f, @splat(r));
	}

	fn getStarColor(temperature: f32, light: f32, image: graphics.Image) Vec3f {
		const rgbCol = image.getRGB(@trunc(std.math.clamp(temperature/15000.0*@as(f32, @floatFromInt(image.width)), 0.0, @as(f32, @floatFromInt(image.width - 1)))), 0);
		var rgb: Vec3f = @floatFromInt(Vec3i{rgbCol.r, rgbCol.g, rgbCol.b});
		rgb /= @splat(255.0);

		rgb *= @as(Vec3f, @splat(light));

		const m = @reduce(.Max, rgb);
		if (m > 1.0) {
			rgb /= @as(Vec3f, @splat(m));
		}

		return rgb;
	}

	fn init() void {
		const starColorImage = graphics.Image.readFromFile(main.stackAllocator, "assets/cubyz/star.png", .{.orientation = .openGl}) catch |err| {
			std.log.err("Failed to load star image: {s}", .{@errorName(err)});
			return;
		};
		defer starColorImage.deinit(main.stackAllocator);

		starPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/skybox/star.vert",
			"assets/cubyz/shaders/skybox/star.frag",
			"",
			&starUniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.{
				.srcColorBlendFactor = .one,
				.dstColorBlendFactor = .one,
				.colorBlendOp = .add,
				.srcAlphaBlendFactor = .one,
				.dstAlphaBlendFactor = .one,
				.alphaBlendOp = .add,
			}}},
		);

		var starData: [numStars*20]f32 = undefined;

		const starDist = 200.0;

		const off: f32 = @sqrt(3.0)/6.0;

		const triVertA = Vec3f{0.5, starDist, -off};
		const triVertB = Vec3f{-0.5, starDist, -off};
		const triVertC = Vec3f{0.0, starDist, @sqrt(3.0)/2.0 - off};

		var seed: u64 = 0;

		for (0..numStars) |i| {
			var pos: Vec3f = undefined;

			var radius: f32 = undefined;

			var temperature: f32 = undefined;

			var light: f32 = 0;

			while (light < 0.1) {
				pos = getStarPos(&seed);

				radius = @floatCast(main.random.nextFloatExp(&seed)*4 + 0.2);

				temperature = @floatCast(@abs(main.random.nextFloatGauss(&seed)*3000.0 + 5000.0) + 1000.0);

				light = (3.6e-12*radius*radius*temperature*temperature*temperature*temperature)/(vec.dot(pos, pos));
			}

			pos = vec.normalize(pos)*@as(Vec3f, @splat(starDist));

			const normPos = vec.normalize(pos);

			const color = getStarColor(temperature, light, starColorImage);

			const latitude: f32 = @floatCast(std.math.asin(normPos[2]));
			const longitude: f32 = @floatCast(std.math.atan2(-normPos[0], normPos[1]));

			const mat = Mat4f.rotationZ(longitude).mul(Mat4f.rotationX(latitude));

			const posA = vec.xyz(mat.mulVec(.{triVertA[0], triVertA[1], triVertA[2], 1.0}));
			const posB = vec.xyz(mat.mulVec(.{triVertB[0], triVertB[1], triVertB[2], 1.0}));
			const posC = vec.xyz(mat.mulVec(.{triVertC[0], triVertC[1], triVertC[2], 1.0}));

			starData[i*20 ..][0..3].* = posA;
			starData[i*20 + 4 ..][0..3].* = posB;
			starData[i*20 + 8 ..][0..3].* = posC;

			starData[i*20 + 12 ..][0..3].* = pos;
			starData[i*20 + 16 ..][0..3].* = color;
		}

		starSsbo = graphics.SSBO.initStatic(f32, &starData);

		starVao = .init(graphics.VertexArray.EmptyVertex, &.{}, null);

		celestialPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/skybox/celestial.vert",
			"assets/cubyz/shaders/skybox/celestial.frag",
			"",
			&celestialUniforms,
			graphics.draw.SimpleVertex2D,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.{
				.srcColorBlendFactor = .one,
				.dstColorBlendFactor = .one,
				.colorBlendOp = .add,
				.srcAlphaBlendFactor = .one,
				.dstAlphaBlendFactor = .one,
				.alphaBlendOp = .add,
			}}},
		);
		const quadData = [_]graphics.draw.SimpleVertex2D{
			.{.pos = .{-1, -1}},
			.{.pos = .{-1, 1}},
			.{.pos = .{1, -1}},
			.{.pos = .{1, 1}},
		};
		celestialVao = .init(graphics.draw.SimpleVertex2D, &quadData, null);
	}

	pub fn deinit() void {
		starPipeline.deinit();
		starSsbo.deinit();
		starVao.deinit();
		celestialPipeline.deinit();
		celestialVao.deinit();
	}

	fn horizonFade(direction: Vec3f) f32 {
		const halfWindow = 0.05;
		return std.math.clamp((direction[2] + halfWindow)/(2*halfWindow), 0.0, 1.0);
	}

	fn celestialBillboardBasis(direction: Vec3f) struct {right: Vec3f, up: Vec3f} {
		const worldXAxis = Vec3f{1, 0, 0};
		const right = vec.cross(worldXAxis, direction);
		const up = vec.cross(direction, right);
		return .{.right = right, .up = up};
	}

	fn drawCelestial(worldCenter: Vec3f, billboardRight: Vec3f, billboardUp: Vec3f, size: f32, color: Vec3f, opacity: f32, cloudAttenuation: f32) void {
		if (opacity <= 0) return;
		c.glUniform3fv(celestialUniforms.worldCenter, 1, @ptrCast(&worldCenter));
		c.glUniform3fv(celestialUniforms.billboardRight, 1, @ptrCast(&billboardRight));
		c.glUniform3fv(celestialUniforms.billboardUp, 1, @ptrCast(&billboardUp));
		c.glUniform1f(celestialUniforms.billboardSize, size);
		c.glUniform3fv(celestialUniforms.color, 1, @ptrCast(&color));
		c.glUniform1f(celestialUniforms.opacity, opacity);
		c.glUniform1f(celestialUniforms.cloudAttenuation, cloudAttenuation);
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	pub fn render(playerPos: Vec3d) void {
		const viewMatrix = game.camera.viewMatrix;

		const starOpacity: f32 = game.world.?.dayTime.getStarOpacity();

		if (starOpacity != 0) {
			starPipeline.bind(null);

			const starMatrix = game.projectionMatrix.mul(viewMatrix.mul(Mat4f.rotationX(2*std.math.pi*game.world.?.dayTime.getDayProgress())));

			starSsbo.bind(12);

			c.glUniform1f(starUniforms.starOpacity, starOpacity);
			c.glUniformMatrix4fv(starUniforms.mvp, 1, c.GL_TRUE, @ptrCast(&starMatrix));

			starVao.bind();
			c.glDrawArrays(c.GL_TRIANGLES, 0, numStars*3);

			c.glBindBuffer(c.GL_SHADER_STORAGE_BUFFER, 0);
		}

		{
			celestialPipeline.bind(null);
			celestialVao.bind();

			const sunDir = game.world.?.dayTime.getSunDirection();
			const moonDir = -sunDir;
			const celestialDist: f32 = 300.0;

			const sunBasis = celestialBillboardBasis(sunDir);
			const moonBasis = celestialBillboardBasis(moonDir);

			const sunCloudAtten = clouds.getCloudAttenuationForDirection(playerPos, sunDir);
			const moonCloudAtten = clouds.getCloudAttenuationForDirection(playerPos, moonDir);

			drawCelestial(sunDir*@as(Vec3f, @splat(celestialDist)), sunBasis.right, sunBasis.up, 19.0, Vec3f{1.0, 0.9, 0.6}, horizonFade(sunDir) * sunCloudAtten, sunCloudAtten);
			drawCelestial(moonDir*@as(Vec3f, @splat(celestialDist)), moonBasis.right, moonBasis.up, 14.0, Vec3f{0.85, 0.9, 1.0}, horizonFade(moonDir)*0.6 * moonCloudAtten, moonCloudAtten);
		}
	}
};

pub const Frustum = struct {
	const Plane = struct {
		pos: Vec3f,
		norm: Vec3f,
	};
	planes: [4]Plane,

	pub fn init(cameraPos: Vec3f, rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31) Frustum {
		const invRotationMatrix = rotationMatrix.transpose();
		const cameraDir = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 1, 0, 1}));
		const cameraUp = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 0, 1, 1}));
		const cameraRight = vec.xyz(invRotationMatrix.mulVec(Vec4f{1, 0, 0, 1}));

		const halfVSide = std.math.tan(std.math.degreesToRadians(fovY)*0.5);
		const halfHSide = halfVSide*@as(f32, @floatFromInt(width))/@as(f32, @floatFromInt(height));

		var self: Frustum = undefined;
		self.planes[0] = Plane{.pos = cameraPos, .norm = vec.cross(cameraUp, cameraDir + cameraRight*@as(Vec3f, @splat(halfHSide)))};
		self.planes[1] = Plane{.pos = cameraPos, .norm = vec.cross(cameraDir - cameraRight*@as(Vec3f, @splat(halfHSide)), cameraUp)};
		self.planes[2] = Plane{.pos = cameraPos, .norm = vec.cross(cameraRight, cameraDir - cameraUp*@as(Vec3f, @splat(halfVSide)))};
		self.planes[3] = Plane{.pos = cameraPos, .norm = vec.cross(cameraDir + cameraUp*@as(Vec3f, @splat(halfVSide)), cameraRight)};
		return self;
	}

	pub fn testAAB(self: Frustum, pos: Vec3f, dim: Vec3f) bool {
		inline for (self.planes) |plane| {
			var dist: f32 = vec.dot(pos - plane.pos, plane.norm);

			dist += @reduce(.Add, @max(Vec3f{0, 0, 0}, dim*plane.norm));
			if (dist < 0) return false;
		}
		return true;
	}
};

pub const ShadowRaymarch = struct {
	const emptySentinel: u32 = 0xFFFFFFFF;

	const maxWindowDim: u32 = 48;

	var indexSSBO: graphics.SSBO = undefined;
	var indexData: [maxWindowDim*maxWindowDim*maxWindowDim]u32 = undefined;

	pub var windowOrigin: Vec3i = .{0, 0, 0};

	pub var windowDim: u32 = 0;

	fn init() void {
		indexSSBO = .init();
		indexSSBO.bind(21);
	}

	fn deinit() void {
		indexSSBO.deinit();
	}

	fn update(playerPos: Vec3d) void {
		const size = chunk.chunkSize;
		const desiredDim: u32 = @as(u32, @intFromFloat(@ceil(2*settings.shadowDistance/@as(f32, @floatFromInt(size))))) + 2;
		const dim = std.math.clamp(desiredDim, 2, maxWindowDim);
		windowDim = dim;

		const playerBlock: Vec3i = @as(Vec3i, @floor(playerPos));
		const halfSpan: i32 = @as(i32, @intCast(dim/2))*size;

		const origin = Vec3i{
			(playerBlock[0] & ~@as(i32, size - 1)) -% halfSpan,
			(playerBlock[1] & ~@as(i32, size - 1)) -% halfSpan,
			(playerBlock[2] & ~@as(i32, size - 1)) -% halfSpan,
		};
		windowOrigin = origin;

		var index: usize = 0;
		var cz: u32 = 0;
		while (cz < dim) : (cz += 1) {
			var cy: u32 = 0;
			while (cy < dim) : (cy += 1) {
				var cx: u32 = 0;
				while (cx < dim) : (cx += 1) {
					const wx = origin[0] +% @as(i32, @intCast(cx))*size;
					const wy = origin[1] +% @as(i32, @intCast(cy))*size;
					const wz = origin[2] +% @as(i32, @intCast(cz))*size;
					const mesh = mesh_storage.getMesh(.{.wx = wx, .wy = wy, .wz = wz, .voxelSize = 1});
					if (mesh == null or mesh.?.occupancyAllocation.len == 0) {
						indexData[index] = emptySentinel;
					} else {
						indexData[index] = mesh.?.occupancyAllocation.start;
					}
					index += 1;
				}
			}
		}

		indexSSBO.bufferData(u32, indexData[0 .. dim*dim*dim]);
	}
};

pub const CascadedShadowMap = struct {
	pub const numCascades = 3;
	pub var baseShadowMapSize: u31 = 2048;

	pub var shadowMapSize: u31 = 2048;
	pub var shadowMapSizes: [numCascades]u31 = .{ 2048, 1536, 1024 };

	fn updateCascadeMapSizes() void {
		shadowMapSizes = .{
			shadowMapSize,
			@max(512, @divFloor(shadowMapSize * 3, 4)),
			@max(512, @divFloor(shadowMapSize, 2)),
		};
	}

	pub fn updateMapSize(scale: f32) void {
		const newSize: u31 = @intFromFloat(@max(512.0, @trunc(@as(f32, @floatFromInt(baseShadowMapSize)) * scale)));
		if (shadowMapSize != newSize) {
			shadowMapSize = newSize;
			updateCascadeMapSizes();
			for (0..numCascades) |i| {
				shadowFBs[i].updateSize(shadowMapSizes[i], shadowMapSizes[i], c.GL_R8);
			}
		}
	}

	pub var cascadeFarDistances: [numCascades]f32 = .{ 24.0, 96.0, 512.0 };

	pub var activeCascadeCount: usize = 1;

	pub var shadowFBs: [numCascades]graphics.FrameBuffer = undefined;

	var shadowPipeline: graphics.Pipeline = undefined;
	var shadowPipelineUniforms: struct {
		lightSpaceMatrix: c_int,
		waterTime: c_int,
		foliageSway: c_int,
		weatherWind: c_int,
	} = undefined;

	var lightSpaceMatrices: [numCascades]Mat4f = undefined;

	pub var lightSpaceMatricesGL: [numCascades][4][4]f32 = undefined;
	var baseLightSpaceMatrices: [numCascades]Mat4f = undefined;
	var renderedPlayerPos: [numCascades]Vec3d = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
	var lastRenderedFrame: [numCascades]u32 = .{ 0, 0, 0 };
	pub var shadowFrameCounter: u32 = 0;
	var lastShadowPlayerPos: Vec3d = .{ 0, 0, 0 };
	var lastSunDir: Vec3f = .{ 0, 0, 0 };

	fn init() void {

		c.glActiveTexture(c.GL_TEXTURE0);
		for (0..numCascades) |i| {
			shadowFBs[i].initDepthOnly(c.GL_LINEAR, c.GL_CLAMP_TO_BORDER);

			const border = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
			c.glBindTexture(c.GL_TEXTURE_2D, shadowFBs[i].depthTexture);
			c.glTexParameterfv(c.GL_TEXTURE_2D, c.GL_TEXTURE_BORDER_COLOR, &border);

			shadowFBs[i].updateSize(shadowMapSizes[i], shadowMapSizes[i], c.GL_R8);
		}
		c.glBindTexture(c.GL_TEXTURE_2D, 0);
		shadowPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/shadow_depth.vert",
			"assets/cubyz/shaders/shadow_depth.frag",
			"",
			&shadowPipelineUniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{
				.cullMode = .none,
				.depthBias = .{ .constantFactor = 2.0, .clamp = 0.0, .slopeFactor = 4.0 },
			},
			.{ .depthTest = true, .depthWrite = true },
			.{ .attachments = &.{.{ .enabled = false, .srcColorBlendFactor = .zero, .dstColorBlendFactor = .zero, .colorBlendOp = .add, .srcAlphaBlendFactor = .zero, .dstAlphaBlendFactor = .zero, .alphaBlendOp = .add, .colorWriteMask = .none }} },
		);
	}

	fn deinit() void {
		for (0..numCascades) |i| {
			shadowFBs[i].deinit();
		}
		shadowPipeline.deinit();
	}

	fn computeLightSpaceMatrix(cascade: usize, cascadeFarDepth: f32, lightView: Mat4f, playerPos: Vec3d, zMargin: f32) Mat4f {
		const radius = cascadeFarDepth;

		const playerFrac = Vec3f{
			@floatCast(@mod(playerPos[0], 1.0)),
			@floatCast(@mod(playerPos[1], 1.0)),
			@floatCast(@mod(playerPos[2], 1.0)),
		};
		const playerLightVec4 = lightView.mulVec(Vec4f{ playerFrac[0], playerFrac[1], playerFrac[2], 0 });

		const absX = playerLightVec4[0];
		const absY = playerLightVec4[1];
		const absZ = playerLightVec4[2];

		const diameter = 2.0 * radius;
		const texelSize = diameter / @as(f32, @floatFromInt(shadowMapSizes[cascade]));

		const snappedAbsX = @floor(absX / texelSize) * texelSize;
		const snappedAbsZ = @floor(absZ / texelSize) * texelSize;
		const minL_y = absY - radius - zMargin;
		const snappedAbsMinL_y = @floor(minL_y / texelSize) * texelSize;
		const maxL_y = absY + radius + 32.0;
		const depth = maxL_y - snappedAbsMinL_y;

		const relSnappedX = snappedAbsX - playerLightVec4[0];
		const relSnappedMinL_y = snappedAbsMinL_y - playerLightVec4[1];
		const relSnappedZ = snappedAbsZ - playerLightVec4[2];

		const lightProj = Mat4f.orthographic(diameter, diameter, 0.0, depth);
		const lightTranslation = Mat4f{
			.rows = [4]Vec4f{
				Vec4f{ 1, 0, 0, -relSnappedX },
				Vec4f{ 0, 1, 0, -relSnappedMinL_y },
				Vec4f{ 0, 0, 1, -relSnappedZ },
				Vec4f{ 0, 0, 0, 1 },
			},
		};
		return lightProj.mul(lightTranslation.mul(lightView));
	}

	fn update(playerPos: Vec3d) void {
		if (!settings.shadows) return;
		shadowFrameCounter +%= 1;

		const desiredSize: u31 = if (settings.shadowRaySteps <= 96)
			1024
		else if (settings.shadowRaySteps <= 256)
			2048
		else
			4096;

		const mapsResized = shadowMapSize != desiredSize;
		if (mapsResized) {
			shadowMapSize = desiredSize;
			updateCascadeMapSizes();

			c.glActiveTexture(c.GL_TEXTURE0);
			for (0..numCascades) |i| {
				shadowFBs[i].updateSize(shadowMapSizes[i], shadowMapSizes[i], c.GL_R8);
			}
			c.glBindTexture(c.GL_TEXTURE_2D, 0);
		}

		const maxDist = @max(settings.shadowDistance, 24.0);
		cascadeFarDistances[0] = 24.0;
		cascadeFarDistances[1] = @min(96.0, maxDist);
		cascadeFarDistances[2] = maxDist;

		const lightDir = game.world.?.dayTime.getShadowLightDirection();
		const lightView = Mat4f.lookInDirection(-lightDir);

		const zMargins = [numCascades]f32{ 96.0, 256.0, 1024.0 };
		const occluderSunDists = [numCascades]f32{ 96.0, 256.0, 1024.0 };

		const dirDiff = lightDir - lastSunDir;
		const sunDistSq = dirDiff[0] * dirDiff[0] + dirDiff[1] * dirDiff[1] + dirDiff[2] * dirDiff[2];
		const sunMoved = sunDistSq > 0.00001;
		lastSunDir = lightDir;

		shadowPipeline.bind(null);
		c.glUniform1i(43, @intFromBool(settings.foliageShadows));
		c.glUniform3fv(37, 1, @ptrCast(&lightDir));

		const elapsedNanoseconds = chunk_meshing.startTimestamp.durationTo(main.timestamp()).toNanoseconds();
		const waterTime: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
		c.glUniform1f(shadowPipelineUniforms.waterTime, waterTime);
		c.glUniform1i(shadowPipelineUniforms.foliageSway, @intFromBool(settings.foliageSway));
		const weatherWind = game.world.?.weatherGrid.snapshot().wind;
		c.glUniform2fv(shadowPipelineUniforms.weatherWind, 1, @ptrCast(&weatherWind));
		c.glActiveTexture(c.GL_TEXTURE0);
		blocks.meshes.blockTextureArray.bind();

		c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);

		const activeCascades: usize = if (settings.shadowDistance <= 24.0)
			1
		else if (settings.shadowDistance <= 96.0)
			2
		else
			3;
		activeCascadeCount = activeCascades;

		const maxDistSq: f64 = 2.0 * 2.0;
		const maxFrameAge: u32 = 20;
		const refreshNearFoliageShadowEveryFrame = settings.foliageSway and settings.foliageShadows;

		const refreshNearPlayerShadowEveryFrame = main.entity.systems.modelRenderer.client.hasNearbyPlayerShadowCaster(playerPos, cascadeFarDistances[0]);

		const forceFullRefresh = shadowFrameCounter <= 2 or mapsResized;
		var scheduledRefreshes: usize = 0;

		for (0..activeCascades) |i| {

			const diffX = playerPos[0] - renderedPlayerPos[i][0];
			const diffY = playerPos[1] - renderedPlayerPos[i][1];
			const diffZ = playerPos[2] - renderedPlayerPos[i][2];
			const distSq = diffX * diffX + diffY * diffY + diffZ * diffZ;
			const frameAge = shadowFrameCounter -% lastRenderedFrame[i];
			const cascadeMaxFrameAge: u32 = if ((refreshNearFoliageShadowEveryFrame or refreshNearPlayerShadowEveryFrame) and i == 0) 1 else maxFrameAge;
			const isImmediateNearRefresh = i == 0 and (refreshNearFoliageShadowEveryFrame or refreshNearPlayerShadowEveryFrame);
			const needsReRender = sunMoved or distSq >= maxDistSq or frameAge >= cascadeMaxFrameAge or forceFullRefresh;

			const canRefreshThisFrame = forceFullRefresh or isImmediateNearRefresh or scheduledRefreshes == 0;
			if (needsReRender and canRefreshThisFrame) {
				if (!isImmediateNearRefresh) scheduledRefreshes += 1;
				lastRenderedFrame[i] = shadowFrameCounter;
				renderedPlayerPos[i] = playerPos;
				baseLightSpaceMatrices[i] = computeLightSpaceMatrix(
					i,
					cascadeFarDistances[i],
					lightView,
					playerPos,
					zMargins[i],
				);

				shadowFBs[i].bind();
				c.glViewport(0, 0, shadowMapSizes[i], shadowMapSizes[i]);
				c.glClear(c.GL_DEPTH_BUFFER_BIT);

				shadowPipeline.bind(null);
				c.glUniform1i(43, @intFromBool(settings.foliageShadows));
				c.glUniform3fv(37, 1, @ptrCast(&lightDir));
				c.glUniform1f(shadowPipelineUniforms.waterTime, waterTime);
				c.glUniform1i(shadowPipelineUniforms.foliageSway, @intFromBool(settings.foliageSway));
				c.glUniform2fv(shadowPipelineUniforms.weatherWind, 1, @ptrCast(&weatherWind));
				c.glUniformMatrix4fv(shadowPipelineUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&baseLightSpaceMatrices[i].toGl()));

				const meshes = mesh_storage.getShadowRenderChunks(playerPos, cascadeFarDistances[i], lightDir, occluderSunDists[i]);
				var chunkLists: [main.settings.highestSupportedLod + 1]main.ListManaged(u32) = @splat(main.ListManaged(u32).init(main.stackAllocator));
				defer for (chunkLists) |list| list.deinit();
				for (meshes) |mesh| {
					mesh.prepareRendering(&chunkLists);
				}

				chunk_meshing.vao.bind();
				for (0..1) |lod| {
					const chunkIDs = chunkLists[lod].items;
					if (chunkIDs.len == 0) continue;
					chunk_meshing.bindBuffers(lod);
					const drawCallsEstimate: u31 = @intCast(chunkIDs.len * 8);
					var chunkIDAllocation: main.graphics.SubAllocation = .{ .start = 0, .len = 0 };
					chunk_meshing.chunkIDBuffer.uploadData(chunkIDs, &chunkIDAllocation);
					defer chunk_meshing.chunkIDBuffer.free(chunkIDAllocation);
					const allocation = chunk_meshing.commandBuffer.rawAlloc(drawCallsEstimate);
					defer chunk_meshing.commandBuffer.free(allocation);
					chunk_meshing.commandPipeline.bind();
					c.glUniform1f(chunk_meshing.commandUniforms.lodDistance, main.settings.@"lod0.5Distance");
					c.glUniform1ui(chunk_meshing.commandUniforms.chunkIDIndex, chunkIDAllocation.start);
					c.glUniform1ui(chunk_meshing.commandUniforms.commandIndexStart, allocation.start);
					c.glUniform1ui(chunk_meshing.commandUniforms.size, @intCast(chunkIDs.len));
					c.glUniform1i(chunk_meshing.commandUniforms.isTransparent, 0);
					c.glUniform1i(chunk_meshing.commandUniforms.onlyDrawPreviouslyInvisible, 0);
					c.glUniform1i(chunk_meshing.commandUniforms.forceAllVisible, 1);
					c.glDispatchCompute(@intCast(@divFloor(chunkIDs.len + 63, 64)), 1, 1);
					c.glMemoryBarrier(c.GL_SHADER_STORAGE_BARRIER_BIT | c.GL_COMMAND_BARRIER_BIT);

					shadowPipeline.bind(null);
					c.glUniform1i(43, @intFromBool(settings.foliageShadows));
					c.glUniform3fv(37, 1, @ptrCast(&lightDir));
					c.glUniform1f(shadowPipelineUniforms.waterTime, waterTime);
					c.glUniform1i(shadowPipelineUniforms.foliageSway, @intFromBool(settings.foliageSway));
					c.glUniform2fv(shadowPipelineUniforms.weatherWind, 1, @ptrCast(&weatherWind));
					c.glUniformMatrix4fv(shadowPipelineUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&baseLightSpaceMatrices[i].toGl()));
					chunk_meshing.vao.bind();
					c.glBindBuffer(c.GL_DRAW_INDIRECT_BUFFER, chunk_meshing.commandBuffer.ssbo.bufferID);
					c.glMultiDrawElementsIndirect(c.GL_TRIANGLES, c.GL_UNSIGNED_INT, @ptrFromInt(allocation.start * @sizeOf(chunk_meshing.IndirectData)), drawCallsEstimate, 0);
				}

				main.entity.systems.modelRenderer.client.renderShadows(&baseLightSpaceMatrices[i], playerPos);
			}

			const deltaX: f32 = @floatCast(playerPos[0] - renderedPlayerPos[i][0]);
			const deltaY: f32 = @floatCast(playerPos[1] - renderedPlayerPos[i][1]);
			const deltaZ: f32 = @floatCast(playerPos[2] - renderedPlayerPos[i][2]);
			const translation = Mat4f{
				.rows = [4]Vec4f{
					Vec4f{ 1, 0, 0, deltaX },
					Vec4f{ 0, 1, 0, deltaY },
					Vec4f{ 0, 0, 1, deltaZ },
					Vec4f{ 0, 0, 0, 1 },
				},
			};
			const correctedMatrix = baseLightSpaceMatrices[i].mul(translation);
			lightSpaceMatricesGL[i] = correctedMatrix.toGl();
		}

		c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
		if (settings.antiAliasingMode == .msaa) {
			MSAA.frameBuffer.bind();
		} else {
			worldFrameBuffer.bind();
		}
		c.glViewport(0, 0, lastWidth, lastHeight);
	}
};

pub const MeshSelection = struct {
	var pipeline: graphics.Pipeline = undefined;
	var uniforms: struct {
		projectionMatrix: c_int,
		viewMatrix: c_int,
		modelPosition: c_int,
		lowerBounds: c_int,
		upperBounds: c_int,
		lineSize: c_int,
	} = undefined;

	pub fn init() void {
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/block_selection_vertex.vert",
			"assets/cubyz/shaders/block_selection_fragment.frag",
			"",
			&uniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = true, .depthWrite = true},
			.{.attachments = &.{.alphaBlending}},
		);
	}

	pub fn deinit() void {
		pipeline.deinit();
	}

	var posBeforeBlock: Vec3i = undefined;
	var neighborOfSelection: chunk.Neighbor = undefined;
	pub var selectedBlockPos: ?Vec3i = null;
	var lastSelectedBlockPos: Vec3i = undefined;
	var currentBlockProgress: f32 = 0;
	var currentSwingProgress: f32 = 0;
	var currentSwingTime: f32 = 0;
	var lastMiningInputTime: std.Io.Timestamp = .fromNanoseconds(0);

	pub fn heldItemSwingProgress() ?f32 {
		const elapsedSinceInput = lastMiningInputTime.durationTo(main.timestamp()).toNanoseconds();
		if (currentSwingTime <= 0 or elapsedSinceInput > 150_000_000) return null;
		return std.math.clamp(currentSwingProgress/currentSwingTime, 0.0, 1.0);
	}
	var selectionMin: Vec3f = undefined;
	var selectionMax: Vec3f = undefined;
	var selectionNormal: Vec3f = undefined;
	var lastPos: Vec3d = undefined;
	var lastDir: Vec3f = undefined;
	pub fn select(pos: Vec3d, _dir: Vec3f, item: main.items.Item) void {
		lastPos = pos;
		const dir: Vec3d = @floatCast(_dir);
		lastDir = _dir;

		const closestDistance: f64 = 6.0;

		const step: Vec3i = std.math.sign(dir);
		const invDir = @as(Vec3d, @splat(1))/dir;
		const tDelta = @abs(invDir);
		var tMax = (@floor(pos) - pos)*invDir;
		tMax = @max(tMax, tMax + tDelta*@as(Vec3f, @floatFromInt(step)));
		tMax = @select(f64, dir == @as(Vec3d, @splat(0)), @as(Vec3d, @splat(std.math.inf(f64))), tMax);
		var voxelPos: Vec3i = @floor(pos);

		var total_tMax: f64 = 0;

		selectedBlockPos = null;

		while (total_tMax < closestDistance) {
			const block = mesh_storage.getBlockFromRenderThread(voxelPos[0], voxelPos[1], voxelPos[2]) orelse break;
			if (block.typ != 0) blk: {
				if (!block.isSelectableByItem(item)) break :blk;

				const relativePlayerPos: Vec3f = @floatCast(pos - @as(Vec3d, @floatFromInt(voxelPos)));
				if (block.mode().rayIntersection(block, item, relativePlayerPos, _dir)) |intersection| {
					if (intersection.distance <= closestDistance) {
						selectedBlockPos = voxelPos;
						selectionMin = intersection.min;
						selectionMax = intersection.max;
						selectionNormal = intersection.normal;
						break;
					}
				}
			}
			posBeforeBlock = voxelPos;
			if (tMax[0] < tMax[1]) {
				if (tMax[0] < tMax[2]) {
					voxelPos[0] +%= step[0];
					total_tMax = tMax[0];
					tMax[0] += tDelta[0];
					neighborOfSelection = if (step[0] == 1) .dirPosX else .dirNegX;
				} else {
					voxelPos[2] +%= step[2];
					total_tMax = tMax[2];
					tMax[2] += tDelta[2];
					neighborOfSelection = if (step[2] == 1) .dirUp else .dirDown;
				}
			} else {
				if (tMax[1] < tMax[2]) {
					voxelPos[1] +%= step[1];
					total_tMax = tMax[1];
					tMax[1] += tDelta[1];
					neighborOfSelection = if (step[1] == 1) .dirPosY else .dirNegY;
				} else {
					voxelPos[2] +%= step[2];
					total_tMax = tMax[2];
					tMax[2] += tDelta[2];
					neighborOfSelection = if (step[2] == 1) .dirUp else .dirDown;
				}
			}
		}

	}

	fn canPlaceBlock(pos: Vec3i, block: main.blocks.Block) bool {
		if (main.physics.collision.collideWithBlock(block, pos[0], pos[1], pos[2], main.game.Player.getPosBlocking() + main.game.Player.outerBoundingBox.center(), main.game.Player.outerBoundingBox.extent(), .{0, 0, 0}) != null) {
			return false;
		}
		return true;
	}

	pub fn placeBlock(inventory: main.items.Inventory.ClientInventory, slot: u32) void {
		if (selectedBlockPos) |selectedPos| {
			var oldBlock = mesh_storage.getBlockFromRenderThread(selectedPos[0], selectedPos[1], selectedPos[2]) orelse return;
			var block = oldBlock;
			switch (inventory.getItem(slot)) {
				.baseItem => |baseItem| {
					if (baseItem.block()) |itemBlock| {
						const rotationMode = blocks.Block.mode(.{.typ = itemBlock, .data = 0});
						var neighborDir = Vec3i{0, 0, 0};

						if (itemBlock == block.typ) {
							const relPos: Vec3f = @floatCast(lastPos - @as(Vec3d, @floatFromInt(selectedPos)));
							if (rotationMode.generateData(main.game.world.?, selectedPos, relPos, lastDir, neighborDir, null, &block, .{.typ = 0, .data = 0}, false)) {
								if (!canPlaceBlock(selectedPos, block)) return;
								updateBlockAndSendUpdate(inventory, slot, selectedPos, oldBlock, block);
								return;
							}
						} else {
							if (rotationMode.modifyBlock(&block, itemBlock)) {
								if (!canPlaceBlock(selectedPos, block)) return;
								updateBlockAndSendUpdate(inventory, slot, selectedPos, oldBlock, block);
								return;
							}
						}

						const neighborPos = posBeforeBlock;
						neighborDir = selectedPos - posBeforeBlock;
						const relPos: Vec3f = @floatCast(lastPos - @as(Vec3d, @floatFromInt(neighborPos)));
						const neighborBlock = block;
						oldBlock = mesh_storage.getBlockFromRenderThread(neighborPos[0], neighborPos[1], neighborPos[2]) orelse return;
						block = oldBlock;
						if (block.typ == itemBlock) {
							if (rotationMode.generateData(main.game.world.?, neighborPos, relPos, lastDir, neighborDir, neighborOfSelection, &block, neighborBlock, false)) {
								if (!canPlaceBlock(neighborPos, block)) return;
								updateBlockAndSendUpdate(inventory, slot, neighborPos, oldBlock, block);
								return;
							}
						} else {
							if (!block.replaceable()) return;
							block.typ = itemBlock;
							block.data = 0;
							if (rotationMode.generateData(main.game.world.?, neighborPos, relPos, lastDir, neighborDir, neighborOfSelection, &block, neighborBlock, true)) {
								if (!canPlaceBlock(neighborPos, block)) return;
								updateBlockAndSendUpdate(inventory, slot, neighborPos, oldBlock, block);
								return;
							}
						}
					}
					if (std.mem.eql(u8, baseItem.id(), "cubyz:selection_wand")) {
						game.Player.selectionPosition2 = selectedPos;
						main.network.protocols.genericUpdate.sendWorldEditPos(main.game.world.?.conn, .selectedPos2, selectedPos);
						return;
					}
				},
				.proceduralItem => |proceduralItem| {
					_ = proceduralItem;
				},
				.null => {},
			}
		}
	}

	pub fn breakBlock(inventory: main.items.Inventory.ClientInventory, slot: u32, deltaTime: f64) void {
		const now = main.timestamp();

		if (lastMiningInputTime.durationTo(now).toNanoseconds() > 150_000_000) {
			currentSwingProgress = 0;
			currentSwingTime = 0;
		}
		lastMiningInputTime = now;
		if (selectedBlockPos) |selectedPos| {
			const stack = inventory.getStack(slot);
			const isSelectionWand = stack.item == .baseItem and std.mem.eql(u8, stack.item.baseItem.id(), "cubyz:selection_wand");
			if (isSelectionWand) {
				game.Player.selectionPosition1 = selectedPos;
				main.network.protocols.genericUpdate.sendWorldEditPos(main.game.world.?.conn, .selectedPos1, selectedPos);
				return;
			}

			if (@reduce(.Or, lastSelectedBlockPos != selectedPos)) {
				mesh_storage.removeBreakingAnimation(lastSelectedBlockPos);
				currentSwingProgress = 0;
				currentSwingTime = 0;
				lastSelectedBlockPos = selectedPos;
				currentBlockProgress = 0;
			}
			const block = mesh_storage.getBlockFromRenderThread(selectedPos[0], selectedPos[1], selectedPos[2]) orelse return;
			const holdingTargetedBlock = stack.item == .baseItem and stack.item.baseItem.block() == block.typ;
			if ((block.hasTag(.fluid) or block.hasTag(.air)) and !holdingTargetedBlock) return;

			const relPos: Vec3f = @floatCast(lastPos - @as(Vec3d, @floatFromInt(selectedPos)));

			main.sync.client.mutex.lock();
			if (!game.Player.isCreative()) {
				var damage: f32 = main.game.Player.defaultBlockDamage;
				const isProceduralItem = stack.item == .proceduralItem;
				if (isProceduralItem) {
					damage = stack.item.proceduralItem.getBlockDamage(block);
				}
				damage -= block.blockResistance();
				if (damage > 0) {
					const swingTime = if (isProceduralItem and stack.item.proceduralItem.isEffectiveOn(block)) 1.0/stack.item.proceduralItem.getProperty(.swingSpeed) else 0.5;
					if (currentSwingTime > swingTime) {
						currentSwingProgress = 0;
						currentSwingTime = 0;
					}
					if (currentSwingTime == 0) {
						const swings = @ceil(block.blockHealth()/damage);
						const damagePerSwing = block.blockHealth()/swings;
						currentSwingTime = damagePerSwing/damage*swingTime;
					}
					currentSwingProgress += @floatCast(deltaTime);
					while (currentSwingProgress > currentSwingTime) {
						currentSwingProgress -= currentSwingTime;
						currentBlockProgress += damage*currentSwingTime/swingTime/block.blockHealth();
						if (currentBlockProgress > 0.9999) break;
						const swings = @ceil(block.blockHealth()/damage);
						const damagePerSwing = block.blockHealth()/swings;
						currentSwingTime = damagePerSwing/damage*swingTime;
					}
					if (currentBlockProgress < 0.9999) {
						mesh_storage.removeBreakingAnimation(lastSelectedBlockPos);
						if (currentBlockProgress != 0) {
							mesh_storage.addBreakingAnimation(lastSelectedBlockPos, currentBlockProgress);
						}
						main.sync.client.mutex.unlock();

						return;
					} else {
						currentSwingProgress = 0;
						mesh_storage.removeBreakingAnimation(lastSelectedBlockPos);
						currentBlockProgress = 0;
						currentSwingTime = 0;
					}
				} else {
					main.sync.client.mutex.unlock();
					return;
				}
			} else {
				mesh_storage.removeBreakingAnimation(lastSelectedBlockPos);
			}

			var newBlock = block;
			block.mode().onBlockBreaking(inventory.getStack(slot).item, relPos, lastDir, &newBlock);
			main.sync.client.mutex.unlock();

			if (newBlock != block) {
				updateBlockAndSendUpdate(inventory, slot, selectedPos, block, newBlock);
			}
		}
	}

	fn updateBlockAndSendUpdate(source: main.items.Inventory.ClientInventory, slot: u32, pos: Vec3i, oldBlock: blocks.Block, newBlock: blocks.Block) void {
		main.sync.client.executeCommand(.{
			.updateBlock = .{
				.source = .{.inv = source.super, .slot = slot},
				.pos = pos,
				.dropLocation = .{
					.normalDir = selectionNormal,
					.min = selectionMin,
					.max = selectionMax,
				},
				.oldBlock = oldBlock,
				.newBlock = newBlock,
			},
		});
		mesh_storage.updateBlock(.{.pos = pos, .newBlock = newBlock, .blockEntityData = &.{}});
	}

	pub fn drawCube(relativePositionToPlayer: Vec3d, min: Vec3f, max: Vec3f) void {
		pipeline.bind(null);

		c.glUniform3f(
			uniforms.modelPosition,
			@floatCast(relativePositionToPlayer[0]),
			@floatCast(relativePositionToPlayer[1]),
			@floatCast(relativePositionToPlayer[2]),
		);
		c.glUniform3f(uniforms.lowerBounds, min[0], min[1], min[2]);
		c.glUniform3f(uniforms.upperBounds, max[0], max[1], max[2]);
		c.glUniform1f(uniforms.lineSize, 1.0/128.0);

		main.renderer.chunk_meshing.vao.bind();
		c.glDrawElements(c.GL_TRIANGLES, 12*6*6, c.GL_UNSIGNED_INT, null);
	}

	pub fn render(playerPos: Vec3d) void {
		if (main.gui.hideGui) return;
		if (selectedBlockPos) |_selectedBlockPos| {
			drawCube(@as(Vec3d, @floatFromInt(_selectedBlockPos)) - playerPos, selectionMin, selectionMax);
		}
		if (game.Player.selectionPosition1) |pos1| {
			if (game.Player.selectionPosition2) |pos2| {
				const bottomLeft: Vec3i = @min(pos1, pos2);
				const topRight: Vec3i = @max(pos1, pos2);
				drawCube(@as(Vec3d, @floatFromInt(bottomLeft)) - playerPos, .{0, 0, 0}, @floatFromInt(topRight - bottomLeft + Vec3i{1, 1, 1}));
			}
		}
	}
};
