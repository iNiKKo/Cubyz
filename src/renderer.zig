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

/// Time after which no more chunk meshes are created. This allows the game to run smoother on movement.
const maximumMeshTime: std.Io.Duration = .fromMilliseconds(12);
pub const zNear = 0.1;
pub const zFar = 65536.0; // TODO: Fix z-fighting problems.

var deferredRenderPassPipeline: graphics.Pipeline = undefined;
var deferredUniforms: struct {
	@"fog.color": c_int,
	@"fog.density": c_int,
	@"fog.fogLower": c_int,
	@"fog.fogHigher": c_int,
	tanXY: c_int,
	zNear: c_int,
	zFar: c_int,
	invViewMatrix: c_int,
	godRayTint: c_int,
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

pub const reflectionCubeMapSize = 64;
var reflectionCubeMap: graphics.CubeMapTexture = undefined;

pub fn init() void {
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
	worldFrameBuffer.unbind();
}

pub fn render(playerPosition: Vec3d, deltaTime: f64) void {
	// TODO: player bobbing
	// TODO: Handle colors and sun position in the world.
	std.debug.assert(game.world != null);

	const nightColor: Vec3f = .{0.3, 0.4, 0.5};
	var ambient = @max(nightColor*@as(Vec3f, @splat(settings.nightBrightness)), @as(Vec3f, @splat(game.world.?.dayTime.ambientLight)));
	if (settings.shadows) {
		// Shadows only ever remove light (shadowed ground loses brightness no matter how bright the sky
		// is), so a scene with shadows on reads as noticeably duller overall than the same scene with
		// shadows off, even in the fully-lit areas — bump the ambient floor to compensate. Capped well
		// short of blowing out fully-lit surfaces to white, and shadowed areas still read as darker than
		// lit ones (this boosts the light shadows are subtracted *from*, not shadowAmbientFloor itself
		// in shadow.glsl, so shadow contrast is preserved).
		ambient = @min(ambient*@as(Vec3f, @splat(1.25)), @as(Vec3f, @splat(1.0)));
	}

	itemdrop.ItemDisplayManager.update(deltaTime);
	renderWorld(game.world.?, ambient, game.world.?.dayTime.fog.skyColor, playerPosition);
	const startTime = main.timestamp();
	mesh_storage.updateMeshes(startTime.addDuration(maximumMeshTime));
}

pub fn crosshairDirection(rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31) Vec3f {
	// stolen code from Frustum.init
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
	const vertical = cameraUp*@as(Vec3f, @splat(scale[1])); // adjust for y coordinate

	const adjusted = forwards + horizontal + vertical;
	return adjusted;
}

/// Projects a world-space *direction* (e.g. the sun's direction, not a position) into screen-space
/// texture coordinates ([0,1]x[0,1]). No Y flip: matches this codebase's own fullscreen-quad convention
/// (`gl_Position = vec4(inTexCoords*2 - 1, 0, 1)` in mask.vert/blur.vert/deferred_render_pass.vert —
/// inTexCoords and NDC share the same Y direction, unflipped) rather than the more common
/// texture-sampling Y-down convention, which would otherwise vertically mirror the result relative to
/// where the sun/moon's own billboard actually renders. Returns null if the direction is behind the
/// camera (`clip[3] <= 0`), since a screen position isn't meaningful there — callers (god rays) should
/// fall back to their disabled/faded-out path in that case.
fn projectDirection(viewProj: Mat4f, dir: Vec3f) ?Vec2f {
	const clip = viewProj.mulVec(Vec4f{dir[0], dir[1], dir[2], 0});
	if (clip[3] <= 1e-4) return null;
	const ndc = vec.xy(clip)/@as(Vec2f, @splat(clip[3]));
	return ndc*@as(Vec2f, @splat(0.5)) + Vec2f{0.5, 0.5};
}

pub fn renderWorld(world: *World, ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void { // MARK: renderWorld()
	worldFrameBuffer.bind();
	c.glViewport(0, 0, lastWidth, lastHeight);
	gpu_performance_measuring.startQuery(.clear);
	worldFrameBuffer.clear(Vec4f{skyColor[0], skyColor[1], skyColor[2], 1});
	gpu_performance_measuring.stopQuery();
	game.camera.updateViewMatrix();

	main.graphics.frame_uniforms.uploadNewFrame(.{
		.playerPositionInteger = @as(Vec3i, @floor(playerPos)),
		.playerPositionFraction = @as(Vec3f, @floatCast(@mod(playerPos, Vec3d{1, 1, 1}))),
		.projectionMatrix = game.projectionMatrix.toGl(),
		.viewMatrix = game.camera.viewMatrix.toGl(),
	});

	// Uses FrustumCulling on the chunks.
	const frustum = Frustum.init(Vec3f{0, 0, 0}, game.camera.viewMatrix, lastFov, lastWidth, lastHeight);

	const time: u32 = @intCast(main.timestamp().toMilliseconds() & std.math.maxInt(u32));

	gpu_performance_measuring.startQuery(.skybox);
	Skybox.render();
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

	// Must run before opaque terrain draws: terrain samples the cloud coverage texture this uploads
	// for cloud shadows, even though the clouds' own geometry isn't drawn until later (clouds.draw()).
	clouds.update(playerPos);
	rain.update(playerPos, game.camera.viewMatrix);

	var chunkLists: [main.settings.highestSupportedLod + 1]main.ListManaged(u32) = @splat(main.ListManaged(u32).init(main.stackAllocator));
	defer for (chunkLists) |list| list.deinit();
	for (meshes) |mesh| {
		mesh.prepareRendering(&chunkLists);
	}
	gpu_performance_measuring.stopQuery();
	gpu_performance_measuring.startQuery(.chunk_rendering);
	chunk_meshing.drawChunksIndirect(&chunkLists, ambientLight, false);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.entity_rendering);
	main.entity.client.render(ambientLight, playerPos, main.lastDeltaTime.load(.monotonic));
	// Entities don't cast shadows: the voxel raymarch (see ShadowRaymarch) only tests against static
	// terrain occupancy, not entity meshes.

	itemdrop.ItemDropRenderer.renderItemDrops(ambientLight, playerPos);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.block_entity_rendering);
	main.block_entity.renderAll(ambientLight);
	gpu_performance_measuring.stopQuery();

	gpu_performance_measuring.startQuery(.particle_rendering);
	particles.ParticleSystem.render(game.projectionMatrix, game.camera.viewMatrix, ambientLight);
	gpu_performance_measuring.stopQuery();

	// Rebind block textures back to their original slots
	c.glActiveTexture(c.GL_TEXTURE0);
	blocks.meshes.blockTextureArray.bind();
	c.glActiveTexture(c.GL_TEXTURE1);
	blocks.meshes.emissionTextureArray.bind();

	MeshSelection.render(playerPos);

	// Render transparent chunk meshes:
	worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE5);

	gpu_performance_measuring.startQuery(.transparent_rendering_preparation);
	c.glTextureBarrier();

	{
		for (&chunkLists) |*list| list.clearRetainingCapacity();
		var i: usize = meshes.len;
		while (true) {
			if (i == 0) break;
			i -= 1;
			meshes[i].prepareTransparentRendering(playerPos, &chunkLists);
		}
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.transparent_rendering);
		chunk_meshing.drawChunksIndirect(&chunkLists, ambientLight, true);
		gpu_performance_measuring.stopQuery();
	}

	// Drawn after transparent blocks (ice, glass, water, ...), not before: those don't write depth (see
	// transparentPipeline's .depthWrite = false), so a cloud in front of one couldn't otherwise occlude
	// it — the transparent block would draw right over the cloud regardless of which was actually closer
	// to the camera, showing through "perfectly clear" instead of being obscured like opaque terrain
	// already correctly is. Drawing clouds last composites them over both opaque and transparent geometry
	// alike, using the same depth test (against the opaque depth buffer, still the only depth transparent
	// draws leave behind) that already made clouds correctly occlude opaque blocks.
	clouds.draw(ambientLight, skyColor);
	// Thin wispy high-altitude layer, drawn on top of the main clouds per user request — see
	// thin_clouds.zig; deliberately a separate module/pipeline/shaders from clouds.zig.
	thin_clouds.draw(ambientLight, skyColor, playerPos);
	// Same depth-test-against-opaque-and-transparent reasoning as clouds.draw() above — drops behind a
	// wall should be hidden, and transparent blocks don't write depth so this still needs to run after
	// them, not before.
	rain.draw();

	c.glDepthRange(0, 0.001);
	itemdrop.ItemDropRenderer.renderDisplayItems(ambientLight, playerPos);
	c.glDepthRange(0.001, 1);

	chunk_meshing.endRender();

	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);

	const playerBlock = mesh_storage.getBlockFromAnyLodFromRenderThread(@floor(playerPos[0]), @floor(playerPos[1]), @floor(playerPos[2]));

	if (settings.bloom) {
		Bloom.render(lastWidth, lastHeight, playerBlock, game.camera.viewMatrix);
	} else {
		Bloom.bindReplacementImage();
	}
	if (settings.godRays) {
		gpu_performance_measuring.startQuery(.god_rays);
		GodRays.render(lastWidth, lastHeight, game.camera.viewMatrix);
		gpu_performance_measuring.stopQuery();
	} else {
		GodRays.bindReplacementImage();
	}
	gpu_performance_measuring.startQuery(.final_copy);
	if (activeFrameBuffer == 0) c.glViewport(0, 0, main.Window.width, main.Window.height);
	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);
	worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE4);
	worldFrameBuffer.unbind();
	deferredRenderPassPipeline.bind(null);
	if (!blocks.meshes.hasFog(playerBlock)) {
		c.glUniform3fv(deferredUniforms.@"fog.color", 1, @ptrCast(&game.world.?.dayTime.fog.fogColor));
		c.glUniform1f(deferredUniforms.@"fog.density", game.world.?.dayTime.fog.density);
		c.glUniform1f(deferredUniforms.@"fog.fogLower", game.world.?.dayTime.fog.fogLower);
		c.glUniform1f(deferredUniforms.@"fog.fogHigher", game.world.?.dayTime.fog.fogHigher);
	} else {
		const fogColor = blocks.meshes.fogColor(playerBlock);
		c.glUniform3f(deferredUniforms.@"fog.color", @as(f32, @floatFromInt(fogColor >> 16 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 8 & 255))/255.0, @as(f32, @floatFromInt(fogColor >> 0 & 255))/255.0);
		c.glUniform1f(deferredUniforms.@"fog.density", blocks.meshes.fogDensity(playerBlock));
		c.glUniform1f(deferredUniforms.@"fog.fogLower", 1e10);
		c.glUniform1f(deferredUniforms.@"fog.fogHigher", 1e10);
	}
	c.glUniformMatrix4fv(deferredUniforms.invViewMatrix, 1, c.GL_TRUE, @ptrCast(&game.camera.viewMatrix.transpose()));
	c.glUniform1f(deferredUniforms.zNear, zNear);
	c.glUniform1f(deferredUniforms.zFar, zFar);
	c.glUniform2f(deferredUniforms.tanXY, 1.0/game.projectionMatrix.rows[0][0], 1.0/game.projectionMatrix.rows[1][2]);
	{
		// Sun-colored during the day, moon-colored (near-white, not warm yellow) at night — matches
		// Skybox.drawCelestial's own tints for the two bodies, so the ray color agrees with whichever
		// billboard is actually visible. Was checking getShadowLightDirection()[2] >= 0, which is true
		// for *both* bodies whenever each is the one currently active (that's exactly the condition
		// under which getShadowLightDirection returns them) — always picked the sun's warm tint even at
		// night. isSunlight() actually distinguishes which body is providing the light.
		const isSunlight = game.world.?.dayTime.isSunlight();
		const tint: Vec3f = if (isSunlight) Vec3f{1.0, 0.9, 0.6} else Vec3f{0.9, 0.92, 0.95};
		c.glUniform3fv(deferredUniforms.godRayTint, 1, @ptrCast(&tint));
	}

	c.glBindFramebuffer(c.GL_FRAMEBUFFER, activeFrameBuffer);

	graphics.draw.rectVao.bind();
	c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

	c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

	if (!main.gui.hideGui) main.entity.client.renderHud(ambientLight, playerPos);
	gpu_performance_measuring.stopQuery();
}

const Bloom = struct { // MARK: Bloom
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
			&.{.{.binding = 3, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}}},
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
			&.{.{.binding = 3, .count = 1, .type = .combinedImageSampler, .stageFlags = .{.fragment = true}}},
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

/// Screen-space volumetric light shafts ("god rays"), radiating from wherever the sun/moon peeks
/// through gaps in terrain/foliage. Classic two-pass technique (mask, then radial blur toward the
/// light's screen position) rather than true 3D ray-marching — cheaper, and needs no new depth-pyramid
/// infrastructure. Mirrors Bloom's overall shape (quarter-res buffer(s), publish result on a free
/// texture unit for the final composite to additively sample) but only needs one blur pass, since a
/// radial blur isn't separable the way Bloom's two-pass Gaussian is.
const GodRays = struct { // MARK: GodRays
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

	// Far off-screen sentinel used when the sun/moon is behind the camera: both passes naturally
	// produce zero contribution (the mask's proximity test never triggers, and blurPass separately
	// zeroes `strength`) without either shader needing a special "is there even a light source" branch.
	const offScreenSentinel = Vec2f{-10, -10};

	fn maskPass(viewMatrix: Mat4f, sunDirection: Vec3f, sunScreenPos: Vec2f, aspectRatio: f32) void {
		maskPipeline.bind(null);
		worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE4);
		// Cloud coverage texture (unit 9) was already bound by clouds.update() earlier this frame and
		// nothing has rebound that unit since — no need to rebind it here.
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

		// The *true* (unclamped) direction — deliberately not getShadowLightDirection(), whose elevation
		// clamp keeps shading stable near the horizon but means it disagrees with where the sun/moon
		// actually is. God rays need to visually track the real body: using the clamped direction here
		// made the glow appear to freeze/float above the sun/moon near dawn/dusk instead of continuing to
		// follow it down toward the horizon.
		const lightDir = game.world.?.dayTime.getVisibleCelestialDirection();
		const viewProj = game.projectionMatrix.mul(viewMatrix);
		// Computed once and shared by both passes below — the mask's bright spot and the blur's
		// convergence target must always agree exactly, or the glow visibly drifts from the sun's true
		// position as the camera moves.
		const sunScreenPos = projectDirection(viewProj, lightDir) orelse offScreenSentinel;
		// Reuses Skybox's own horizon-fade curve so god rays fade in/out in lockstep with the sun/moon
		// billboard itself, rather than having their own independent (and possibly mismatched) cutoff.
		// Moonlight rays are dimmer than sunlight ones (mirrors Skybox's own moon billboard, drawn at
		// horizonFade*0.6 — moonlight is just much weaker than direct sun).
		const moonDimming: f32 = if (game.world.?.dayTime.isSunlight()) 1.0 else 0.5;
		// Fades the whole god-ray effect in/out based on how close the sun/moon's projected screen
		// position is to the center of the view, rather than it snapping to full strength the instant
		// the sun's bright disc first clips into the frame at the edge (which is what the mask's own
		// proximity test — a small fixed-radius disc around sunScreenPos — controls; that's a separate,
		// much tighter radius meant to shape the disc itself, not to fade the overall ray strength with
		// view direction). Not aspect-corrected on purpose: a plain radial distance from screen center
		// reads fine here since this only needs to be a smooth global multiplier, not a circular disc.
		const centerDist = vec.length(sunScreenPos - Vec2f{0.5, 0.5});
		const centerFadeInner: f32 = 0.15;
		const centerFadeOuter: f32 = 0.9;
		const centerFadeT = std.math.clamp((centerDist - centerFadeInner)/(centerFadeOuter - centerFadeInner), 0.0, 1.0);
		const centerFade = 1.0 - centerFadeT*centerFadeT*(3.0 - 2.0*centerFadeT); // smoothstep, inverted
		const strength = Skybox.horizonFade(lightDir)*settings.godRayIntensity*moonDimming*centerFade;
		// tanX/tanY (== width/height, per Mat4f.perspective()'s `tanX = aspect*tanY`) — scales the mask's
		// screen-space proximity test so the sun's glow disc reads as circular on screen instead of
		// stretched to match whatever the viewport's aspect ratio happens to be.
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
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.noBlending}},
		);
		// 4 sides of a simple cube with some panorama texture on it.
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

		// Whenever the version changes copy over the new background image and display it.
		if (!std.mem.eql(u8, settings.lastVersionString, settings.version.version)) {
			const defaultImageData = try main.files.cwd().read(main.stackAllocator, "assets/cubyz/default_background.png");
			defer main.stackAllocator.free(defaultImageData);
			try dir.write("default_background.png", defaultImageData);

			return allocator.print("{s}/backgrounds/default_background.png", .{main.files.cubyzDirStr()});
		}

		// Otherwise load a random texture from the backgrounds folder. The player may make their own pictures which can be chosen as well.
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

		// Use a simple rotation around the z axis, with a steadily increasing angle.
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
		const size: usize = 1024; // Use a power of 2 here, to reduce video memory waste.
		const pixels: []u32 = main.stackAllocator.alloc(u32, size*size);
		defer main.stackAllocator.free(pixels);

		// Change the viewport and the matrices to render 4 cube faces:

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

		// All 4 sides are stored in a single image.
		const image = graphics.Image.init(main.stackAllocator, 4*size, size);
		defer image.deinit(main.stackAllocator);

		for (0..4) |i| {
			c.glDepthFunc(c.GL_LESS);
			c.glDepthMask(c.GL_TRUE);
			c.glDisable(c.GL_SCISSOR_TEST);
			game.camera.rotation = .{0, 0, angles[i]};
			// Draw to frame buffer.
			buffer.bind();
			c.glClear(c.GL_DEPTH_BUFFER_BIT | c.GL_STENCIL_BUFFER_BIT | c.GL_COLOR_BUFFER_BIT);
			main.renderer.render(game.Player.getEyePosBlocking(), 0);
			// Copy the pixels directly from OpenGL
			buffer.bind();
			c.glReadPixels(0, 0, size, size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);

			for (0..size) |y| {
				for (0..size) |x| {
					const index = x + y*size;
					// Needs to flip the image in y-direction.
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
		// TODO: Performance is terrible even with -O3. Consider using qoi instead.
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

				// 3.6e-12 can be modified to change the brightness of the stars
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

	/// Fades a celestial body in/out right around the horizon instead of switching abruptly.
	fn horizonFade(direction: Vec3f) f32 {
		const halfWindow = 0.05;
		return std.math.clamp((direction[2] + halfWindow)/(2*halfWindow), 0.0, 1.0);
	}

	/// World-fixed billboard basis for a celestial body, perpendicular to its direction — deliberately
	/// *not* derived from the camera's view matrix, so the sun/moon disc doesn't rotate or distort as
	/// the player looks around; it only changes as `direction` itself sweeps through the day/night
	/// cycle. Uses the world X axis as a stable reference, matching the rotation axis
	/// getSunDirection()/the star field's own rotation already sweep around (direction's X component
	/// is always 0), so `cross(worldXAxis, direction)` is already unit-length — no normalize needed.
	fn celestialBillboardBasis(direction: Vec3f) struct {right: Vec3f, up: Vec3f} {
		const worldXAxis = Vec3f{1, 0, 0};
		const right = vec.cross(worldXAxis, direction);
		const up = vec.cross(direction, right);
		return .{.right = right, .up = up};
	}

	fn drawCelestial(worldCenter: Vec3f, billboardRight: Vec3f, billboardUp: Vec3f, size: f32, color: Vec3f, opacity: f32) void {
		if (opacity <= 0) return;
		c.glUniform3fv(celestialUniforms.worldCenter, 1, @ptrCast(&worldCenter));
		c.glUniform3fv(celestialUniforms.billboardRight, 1, @ptrCast(&billboardRight));
		c.glUniform3fv(celestialUniforms.billboardUp, 1, @ptrCast(&billboardUp));
		c.glUniform1f(celestialUniforms.billboardSize, size);
		c.glUniform3fv(celestialUniforms.color, 1, @ptrCast(&color));
		c.glUniform1f(celestialUniforms.opacity, opacity);
		c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
	}

	pub fn render() void {
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

			drawCelestial(sunDir*@as(Vec3f, @splat(celestialDist)), sunBasis.right, sunBasis.up, 24.0, Vec3f{1.0, 0.9, 0.6}, horizonFade(sunDir));
			drawCelestial(moonDir*@as(Vec3f, @splat(celestialDist)), moonBasis.right, moonBasis.up, 18.0, Vec3f{0.85, 0.9, 1.0}, horizonFade(moonDir)*0.6);
		}
	}
};

pub const Frustum = struct { // MARK: Frustum
	const Plane = struct {
		pos: Vec3f,
		norm: Vec3f,
	};
	planes: [4]Plane, // Who cares about the near/far plane anyways?

	pub fn init(cameraPos: Vec3f, rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31) Frustum {
		const invRotationMatrix = rotationMatrix.transpose();
		const cameraDir = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 1, 0, 1}));
		const cameraUp = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 0, 1, 1}));
		const cameraRight = vec.xyz(invRotationMatrix.mulVec(Vec4f{1, 0, 0, 1}));

		const halfVSide = std.math.tan(std.math.degreesToRadians(fovY)*0.5);
		const halfHSide = halfVSide*@as(f32, @floatFromInt(width))/@as(f32, @floatFromInt(height));

		var self: Frustum = undefined;
		self.planes[0] = Plane{.pos = cameraPos, .norm = vec.cross(cameraUp, cameraDir + cameraRight*@as(Vec3f, @splat(halfHSide)))}; // right
		self.planes[1] = Plane{.pos = cameraPos, .norm = vec.cross(cameraDir - cameraRight*@as(Vec3f, @splat(halfHSide)), cameraUp)}; // left
		self.planes[2] = Plane{.pos = cameraPos, .norm = vec.cross(cameraRight, cameraDir - cameraUp*@as(Vec3f, @splat(halfVSide)))}; // top
		self.planes[3] = Plane{.pos = cameraPos, .norm = vec.cross(cameraDir + cameraUp*@as(Vec3f, @splat(halfVSide)), cameraRight)}; // bottom
		return self;
	}

	pub fn testAAB(self: Frustum, pos: Vec3f, dim: Vec3f) bool {
		inline for (self.planes) |plane| {
			var dist: f32 = vec.dot(pos - plane.pos, plane.norm);
			// Find the most positive corner:
			dist += @reduce(.Add, @max(Vec3f{0, 0, 0}, dim*plane.norm));
			if (dist < 0) return false;
		}
		return true;
	}
};

/// Per-frame chunk-position -> occupancy-offset lookup window for the sun/moon shadow raymarch (see
/// shadow.glsl's sampleSunShadow). A small, fully-rebuilt-each-frame grid of chunk-sized cells centered
/// on the player, world-chunk-aligned — mirrors clouds.zig's coverage-grid pattern (a fixed small
/// window, snapped to world-aligned cell boundaries, reuploaded whole every frame) rather than a GPU
/// hash table: same shape of problem (world position -> sparse per-chunk data), same solution already
/// proven stable in this codebase.
///
/// Each cell holds either `emptySentinel` (no LOD0 chunk loaded there => treat as passable, matching how
/// an unloaded chunk never cast a shadow under the old cascade system either) or that chunk's starting
/// word offset into chunk_meshing.occupancyBuffer.
pub const ShadowRaymarch = struct { // MARK: ShadowRaymarch
	const emptySentinel: u32 = 0xFFFFFFFF;
	/// Backing array capacity — mirrors clouds.zig's maxGridDim, sized generously for the shadowDistance
	/// slider's max (512 blocks radius -> ~18 chunks radius -> up to ~38^3 cells, comfortably under this).
	const maxWindowDim: u32 = 48;

	var indexSSBO: graphics.SSBO = undefined;
	var indexData: [maxWindowDim*maxWindowDim*maxWindowDim]u32 = undefined;

	/// World-block coordinates (absolute, not player-relative) of the window's corner cell — shader
	/// side reconstructs an absolute voxel coordinate from worldPosRelative + playerPositionInteger/
	/// Fraction and subtracts this to index into indexData. Public for chunk_meshing.zig/
	/// modelRenderer.zig's bindCommonUniforms.
	pub var windowOrigin: Vec3i = .{0, 0, 0};
	/// Cells per axis actually populated this frame (<= maxWindowDim).
	pub var windowDim: u32 = 0;

	fn init() void {
		indexSSBO = .init();
		indexSSBO.bind(21); // 21, not 12 — collides with Skybox's starSsbo, see shadow.glsl's binding comment
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
		// Chunk-aligned window origin (world block coords) — cells only ever pop in/out at the window's
		// outer edge as the player moves, never swim or reindex underfoot.
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

/// Cascaded Shadow Maps (CSM) — replaces the old DDA voxel raymarch with a projection-based approach
/// that produces smooth, properly filtered penumbras.  Three cascades cover progressively wider
/// depth ranges so near objects get sharp, high-res shadows and distant ones get wide, soft ones.
///
/// Algorithm:
///   1. For each cascade, compute a stable orthographic light-space frustum: a player-centered sphere
///      of that cascade's far distance (not fit to the camera's current view frustum — see
///      computeLightSpaceMatrix for why coverage deliberately doesn't depend on view direction).
///      "Stable" means we snap the frustum centre to the nearest shadow-map texel, eliminating the
///      sub-pixel shimmer the previous CSM removal notice cited as its reason for removal.
///   2. Render all opaque LOD-0 chunk faces into a depth-only FBO from the light's point of view.
///   3. Store the resulting light-space VP matrices; chunk_meshing.zig's bindCommonUniforms() uploads
///      them plus the depth textures to the terrain fragment shader every frame.
pub const CascadedShadowMap = struct { // MARK: CascadedShadowMap
	pub const numCascades = 3;
	pub var shadowMapSize: u31 = 2048;

	/// Cascade far distances (blocks from the player); each cascade covers a player-centered sphere of
	/// this radius, not a near/far depth slice — see computeLightSpaceMatrix.
	pub var cascadeFarDistances: [numCascades]f32 = .{ 24.0, 96.0, 512.0 };

	/// One depth-only FBO per cascade. Initialised with GL_COMPARE_REF_TO_TEXTURE so sampling returns
	/// hardware-filtered 0..1 PCF values directly from the fragment shader's sampler2DShadow.
	pub var shadowFBs: [numCascades]graphics.FrameBuffer = undefined;

	/// Shadow-depth-only pipeline: shadow_depth.vert + shadow_depth.frag. Uses depth bias to prevent
	/// self-shadowing acne on steep faces without discarding entire blocks.
	var shadowPipeline: graphics.Pipeline = undefined;
	var shadowPipelineUniforms: struct {
		lightSpaceMatrix: c_int,
	} = undefined;

	/// Light-space VP matrices in the Zig row-major format — used by the cascade frustum computation.
	var lightSpaceMatrices: [numCascades]Mat4f = undefined;
	/// The same matrices flattened into OpenGL column-major layout for glUniformMatrix4fv.
	/// Computed each frame alongside lightSpaceMatrices.
	pub var lightSpaceMatricesGL: [numCascades][4][4]f32 = undefined;

	fn init() void {
		for (0..numCascades) |i| {
			shadowFBs[i].initDepthOnly(c.GL_LINEAR, c.GL_CLAMP_TO_BORDER);
			// For out-of-frustum samples (UV outside [0,1]): treat as fully lit (1.0) so the
			// terrain beyond a cascade's coverage doesn't go dark.
			const border = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
			c.glBindTexture(c.GL_TEXTURE_2D, shadowFBs[i].depthTexture);
			c.glTexParameterfv(c.GL_TEXTURE_2D, c.GL_TEXTURE_BORDER_COLOR, &border);
			// Allocate the depth texture at the initial shadow map resolution.
			shadowFBs[i].updateSize(shadowMapSize, shadowMapSize, c.GL_R8);
		}
		shadowPipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/shadow_depth.vert",
			"assets/cubyz/shaders/shadow_depth.frag",
			"",
			&shadowPipelineUniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{
				.cullMode = .none, // Render all faces during shadow pass to avoid missing shadows on single-sided geometry
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

	/// Compute the rotation-invariant, texel-snapped light-space orthographic frustum for one cascade,
	/// covering a player-centered sphere of radius `cascadeFarDepth` (not a sphere fit to the camera's
	/// current view frustum slice and shifted forward along view direction, which an earlier version
	/// used). That forward-shifted version saved shadow-map resolution by not covering ground outside
	/// the camera's current FOV, but it meant the world-space area a cascade actually covered swept
	/// around with the camera's rotation even while the player stood still — so turning to look away
	/// from a nearby tree (or anything else) could shift the covered disc enough that the very shadow
	/// the player was standing in fell outside it and disappeared, even looking straight at the ground
	/// underneath them. A player-centered sphere matches shadow.glsl's cascade selection (which is
	/// purely distance-based, `cameraDepth` vs `csmCascadeFar`, with no view-direction term) and
	/// getShadowRenderChunks' 360-degree occluder gathering, so coverage no longer depends on which way
	/// the camera happens to be facing — at the cost of some shadow-map resolution being spent on
	/// terrain outside the current view that a frustum-fitted cascade would have skipped.
	fn computeLightSpaceMatrix(cascadeFarDepth: f32, lightView: Mat4f, playerPos: Vec3d) Mat4f {
		const radius = cascadeFarDepth;

		// Add player's fractional offset in light space so snapping is relative to absolute world origin:
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
		const texelSize = diameter / @as(f32, @floatFromInt(shadowMapSize));

		// Snap absolute world coordinates to exact texel multiples:
		const snappedAbsX = @floor(absX / texelSize) * texelSize;
		const snappedAbsZ = @floor(absZ / texelSize) * texelSize;

		const zMargin: f32 = 256.0;
		const minL_y = absY - radius - zMargin;
		const snappedAbsMinL_y = @floor(minL_y / texelSize) * texelSize;
		const maxL_y = absY + radius + 32.0;
		const depth = maxL_y - snappedAbsMinL_y;

		// Shift back to player-relative coordinates for the translation matrix:
		const relSnappedX = snappedAbsX - playerLightVec4[0];
		const relSnappedMinL_y = snappedAbsMinL_y - playerLightVec4[1];
		const relSnappedZ = snappedAbsZ - playerLightVec4[2];

		// Orthographic projection matrix:
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

		// Dynamically scale shadow map resolution according to settings.shadowRaySteps slider (Shadow Quality):
		const desiredSize: u31 = if (settings.shadowRaySteps <= 96)
			1024
		else if (settings.shadowRaySteps <= 256)
			2048
		else
			4096;

		if (shadowMapSize != desiredSize) {
			shadowMapSize = desiredSize;
			for (0..numCascades) |i| {
				shadowFBs[i].updateSize(shadowMapSize, shadowMapSize, c.GL_R8);
			}
		}

		// Keep Cascade 0 locked to 24 blocks so nearby tree shadows and leaf texture cutouts stay sharp
		// regardless of max shadow distance setting, while mid/far cascades expand with settings.shadowDistance:
		const maxDist = @max(settings.shadowDistance, 24.0);
		cascadeFarDistances[0] = 24.0;
		cascadeFarDistances[1] = @min(96.0, maxDist);
		cascadeFarDistances[2] = maxDist;

		const sunDir = game.world.?.dayTime.getShadowLightDirection();
		// Light travels from sky to world along -sunDir (opposite to vector pointing from world to sun).
		const lightView = Mat4f.lookInDirection(-sunDir);

		// Render each cascade:
		for (0..numCascades) |i| {
			lightSpaceMatrices[i] = computeLightSpaceMatrix(
				cascadeFarDistances[i],
				lightView,
				playerPos,
			);
			lightSpaceMatricesGL[i] = lightSpaceMatrices[i].toGl();
		}

		// Shadow pass: render all opaque chunk faces into each cascade's depth FBO.
		shadowPipeline.bind(null);
		c.glUniform1i(43, @intFromBool(settings.foliageShadows));
		c.glActiveTexture(c.GL_TEXTURE0);
		blocks.meshes.blockTextureArray.bind();

		c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);
		c.glViewport(0, 0, shadowMapSize, shadowMapSize);

		for (0..numCascades) |i| {
			shadowFBs[i].bind();
			c.glClear(c.GL_DEPTH_BUFFER_BIT);
			c.glUniformMatrix4fv(shadowPipelineUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&lightSpaceMatricesGL[i]));

			// Gathered per-cascade (using this cascade's own, much smaller far distance) rather than once
			// for all three using cascadeFarDistances[2] (the largest). An earlier version shared one
			// chunk list — gathered at the *largest* cascade's radius — across all three cascades, so
			// cascade 0 (meant to cover only 24 blocks, kept deliberately small so nearby tree shadows stay
			// sharp and cheap) was redundantly re-uploading and re-drawing every chunk out to
			// cascadeFarDistances[2] (potentially hundreds of blocks) three times over. That went
			// unnoticed for a while because the main camera's oldVisibilityState gate (see forceAllVisible
			// above) was accidentally culling most of that excess away — once that gate was correctly
			// bypassed for the shadow pass, this redundant over-scoping became a real, measurable cost.
			const meshes = mesh_storage.getShadowRenderChunks(playerPos, cascadeFarDistances[i]);
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
				// The main camera's oldVisibilityState/per-direction visibility culling is irrelevant here
				// (and actively wrong): a chunk the main camera currently considers invisible — e.g. behind
				// the player after they turn around — must still contribute every opaque face to the
				// shadow depth map, since getShadowRenderChunks already gathered it as a 360-degree occluder.
				// Without this, that chunk silently contributed zero draw commands and its shadow vanished
				// the moment the player looked away from it.
				c.glUniform1i(chunk_meshing.commandUniforms.forceAllVisible, 1);
				c.glDispatchCompute(@intCast(@divFloor(chunkIDs.len + 63, 64)), 1, 1);
				c.glMemoryBarrier(c.GL_SHADER_STORAGE_BARRIER_BIT | c.GL_COMMAND_BARRIER_BIT);

				// Re-bind shadow pipeline after compute (compute unbinds it)
				shadowPipeline.bind(null);
				c.glUniform1i(43, @intFromBool(settings.foliageShadows));
				c.glUniformMatrix4fv(shadowPipelineUniforms.lightSpaceMatrix, 1, c.GL_FALSE, @ptrCast(&lightSpaceMatricesGL[i]));
				chunk_meshing.vao.bind();
				c.glBindBuffer(c.GL_DRAW_INDIRECT_BUFFER, chunk_meshing.commandBuffer.ssbo.bufferID);
				c.glMultiDrawElementsIndirect(c.GL_TRIANGLES, c.GL_UNSIGNED_INT, @ptrFromInt(allocation.start * @sizeOf(chunk_meshing.IndirectData)), drawCallsEstimate, 0);
			}
		}

		// Restore normal rendering state:
		c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
		worldFrameBuffer.bind();
		c.glViewport(0, 0, lastWidth, lastHeight);
	}
};

pub const MeshSelection = struct { // MARK: MeshSelection
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
	var selectionMin: Vec3f = undefined;
	var selectionMax: Vec3f = undefined;
	var selectionNormal: Vec3f = undefined;
	var lastPos: Vec3d = undefined;
	var lastDir: Vec3f = undefined;
	pub fn select(pos: Vec3d, _dir: Vec3f, item: main.items.Item) void {
		lastPos = pos;
		const dir: Vec3d = @floatCast(_dir);
		lastDir = _dir;

		// Test blocks:
		const closestDistance: f64 = 6.0; // selection now limited
		// Implementation of "A Fast Voxel Traversal Algorithm for Ray Tracing"  http://www.cse.yorku.ca/~amana/research/grid.pdf
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
		// TODO: Test entities
	}

	fn canPlaceBlock(pos: Vec3i, block: main.blocks.Block) bool {
		if (main.physics.collision.collideWithBlock(block, pos[0], pos[1], pos[2], main.game.Player.getPosBlocking() + main.game.Player.outerBoundingBox.center(), main.game.Player.outerBoundingBox.extent(), .{0, 0, 0}) != null) {
			return false;
		}
		return true; // TODO: Check other entities
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
						// Check if stuff can be added to the block itself:
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
						// Check the block in front of it:
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
					_ = proceduralItem; // TODO: Tools might change existing blocks.
				},
				.null => {},
			}
		}
	}

	pub fn breakBlock(inventory: main.items.Inventory.ClientInventory, slot: u32, deltaTime: f64) void {
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
