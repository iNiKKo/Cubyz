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
const editor_toolbar = main.gui.windowlist.editor_toolbar;
const editor_content_browser = main.gui.windowlist.editor_content_browser;
const editor_details_panel = main.gui.windowlist.editor_details_panel;
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
pub const lightning = @import("renderer/lightning.zig");
pub const fsr = @import("renderer/fsr.zig");
pub const fsr2 = @import("renderer/fsr2.zig");

const maximumMeshTime: std.Io.Duration = .fromMilliseconds(12);
pub const zNear = 0.1;
pub const zFar = 65536.0;
pub var worldRenderFrame: u64 = 0;

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
pub var initialized: bool = false;

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
	editorCompositeFrameBuffer.init(false, c.GL_NEAREST, c.GL_CLAMP_TO_EDGE);
	editorCompositeFrameBuffer.updateSize(Window.width, Window.height, c.GL_RGB16F);
	MSAA.init();
	FXAA.init();
	TAA.init();
	Bloom.init();
	GodRays.init();
	MeshSelection.init();
	EditorGizmo.init();
	MenuBackGround.init();
	Skybox.init();
	ShadowRaymarch.init();
	CascadedShadowMap.init();
	PlanarReflection.init();
	clouds.init();
	thin_clouds.init();
	rain.init();
	lightning.init();
	fsr.init();
	fsr2.init();
	chunk_meshing.init();
	mesh_storage.init();
	reflectionCubeMap = .init();
	reflectionCubeMap.generate(reflectionCubeMapSize, reflectionCubeMapSize);
	initReflectionCubeMap();
	updateViewport(Window.width, Window.height);
	initialized = true;
}

pub fn deinit() void {
	initialized = false;
	deferredRenderPassPipeline.deinit();
	fakeReflectionPipeline.deinit();
	worldFrameBuffer.deinit();
	cloudFrameBuffer.deinit();
	waterSurfaceFrameBuffer.deinit();
	editorCompositeFrameBuffer.deinit();
	MSAA.deinit();
	FXAA.deinit();
	TAA.deinit();
	Bloom.deinit();
	GodRays.deinit();
	MeshSelection.deinit();
	EditorGizmo.deinit();
	MenuBackGround.deinit();
	Skybox.deinit();
	ShadowRaymarch.deinit();
	CascadedShadowMap.deinit();
	PlanarReflection.deinit();
	clouds.deinit();
	thin_clouds.deinit();
	rain.deinit();
	lightning.deinit();
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
	framebuffer.unbind();
}

var worldFrameBuffer: graphics.FrameBuffer = undefined;

var cloudFrameBuffer: graphics.FrameBuffer = undefined;

var waterSurfaceFrameBuffer: graphics.FrameBuffer = undefined;

var editorCompositeFrameBuffer: graphics.FrameBuffer = undefined;

var lastOutputWidth: u31 = 0;
var lastOutputHeight: u31 = 0;
var editorViewportX: u31 = 0;
var editorViewportY: u31 = 0; // Top-left Y in framebuffer pixels.

const ViewportMetrics = struct {
	enabled: bool,
	x: u31,
	y: u31,
	renderWidth: u31,
	renderHeight: u31,
	outputWidth: u31,
	outputHeight: u31,
};

fn computeViewportMetrics() ViewportMetrics {
	if (!game.Player.editorMode.load(.monotonic)) {
		const outputWidth = main.Window.width;
		const outputHeight = main.Window.height;
		return .{
			.enabled = false,
			.x = 0,
			.y = 0,
			.outputWidth = outputWidth,
			.outputHeight = outputHeight,
			.renderWidth = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(outputWidth))*main.settings.resolutionScale))),
			.renderHeight = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(outputHeight))*main.settings.resolutionScale))),
		};
	}

	const scale = main.gui.scale;
	const framebufferWidth = main.Window.width;
	const framebufferHeight = main.Window.height;

	const leftPx: u31 = 0;
	var topPx: u31 = 0;
	var rightPx: u31 = framebufferWidth;
	var bottomPx: u31 = framebufferHeight;

	const toolbarOpen = main.gui.isWindowOpen("editor_toolbar");
	if (toolbarOpen) {
		const toolbarBottom = @as(u31, @intFromFloat((editor_toolbar.window.pos[1] + editor_toolbar.window.size[1]) * scale));
		topPx = @min(framebufferHeight - 1, toolbarBottom);
	}

	const browserOpen = main.gui.isWindowOpen("editor_content_browser");
	if (browserOpen) {
		const browserTop = @as(u31, @intFromFloat(editor_content_browser.window.pos[1] * scale));
		bottomPx = @min(framebufferHeight, browserTop);
	}

	const detailsOpen = main.gui.isWindowOpen("editor_details_panel");
	if (detailsOpen) {
		const detailsLeft = @as(u31, @intFromFloat(editor_details_panel.window.pos[0] * scale));
		rightPx = @min(framebufferWidth, detailsLeft);
	}

	if (rightPx <= leftPx) rightPx = @min(framebufferWidth, leftPx + 1);
	if (bottomPx <= topPx) bottomPx = @min(framebufferHeight, topPx + 1);

	const outputWidth = rightPx - leftPx;
	const outputHeight = bottomPx - topPx;

	return .{
		.enabled = true,
		.x = leftPx,
		.y = topPx,
		.outputWidth = outputWidth,
		.outputHeight = outputHeight,
		.renderWidth = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(outputWidth))*main.settings.resolutionScale))),
		.renderHeight = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(outputHeight))*main.settings.resolutionScale))),
	};
}

fn syncRenderSizes(metrics: ViewportMetrics) void {
	editorViewportX = metrics.x;
	editorViewportY = metrics.y;
	if (lastWidth == metrics.renderWidth and lastHeight == metrics.renderHeight and lastOutputWidth == metrics.outputWidth and lastOutputHeight == metrics.outputHeight) return;

	lastWidth = metrics.renderWidth;
	lastHeight = metrics.renderHeight;
	lastOutputWidth = metrics.outputWidth;
	lastOutputHeight = metrics.outputHeight;

	game.projectionMatrix = Mat4f.perspective(std.math.degreesToRadians(lastFov), @as(f32, @floatFromInt(lastWidth))/@as(f32, @floatFromInt(lastHeight)), zNear, zFar);
	worldFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGB16F);
	cloudFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGBA16F);
	waterSurfaceFrameBuffer.updateSize(lastWidth, lastHeight, c.GL_RGBA16F);
	editorCompositeFrameBuffer.updateSize(lastOutputWidth, lastOutputHeight, c.GL_RGB16F);
	worldFrameBuffer.unbind();
	fsr.updateSize(lastWidth, lastHeight, lastOutputWidth, lastOutputHeight);
	CascadedShadowMap.updateMapSize(main.settings.resolutionScale);
}

fn finalOutputFBO(metrics: ViewportMetrics) c_uint {
	if (metrics.enabled) return editorCompositeFrameBuffer.frameBuffer;
	return activeFrameBuffer;
}

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
	syncRenderSizes(.{
		.enabled = false,
		.x = 0,
		.y = 0,
		.outputWidth = width,
		.outputHeight = height,
		.renderWidth = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(width))*main.settings.resolutionScale))),
		.renderHeight = @max(1, @as(u31, @intFromFloat(@as(f32, @floatFromInt(height))*main.settings.resolutionScale))),
	});
}

pub fn render(playerPosition: Vec3d, deltaTime: f64) void {

	std.debug.assert(game.world != null);

	const viewport = computeViewportMetrics();
	syncRenderSizes(viewport);

	const nightColor: Vec3f = .{0.3, 0.4, 0.5};
	var ambient = @max(nightColor*@as(Vec3f, @splat(settings.nightBrightness)), @as(Vec3f, @splat(game.world.?.dayTime.ambientLight)));
	if (settings.shadows) {
		ambient = @min(ambient*@as(Vec3f, @splat(1.25)), @as(Vec3f, @splat(1.0)));
	}
	const lightningFlash = game.world.?.dayTime.lightningFlash;
	ambient = @min(ambient + @as(Vec3f, @splat(lightningFlash*0.9)), @as(Vec3f, @splat(1.0)));
	const skyColor = game.world.?.dayTime.fog.skyColor + (Vec3f{0.82, 0.88, 1.0} - game.world.?.dayTime.fog.skyColor)*@as(Vec3f, @splat(lightningFlash*0.7));

	itemdrop.ItemDisplayManager.update(deltaTime);
	renderWorld(game.world.?, ambient, skyColor, playerPosition);
	const startTime = main.timestamp();
	mesh_storage.updateMeshes(startTime.addDuration(maximumMeshTime));
}

/// Computes a world-space ray direction for an arbitrary screen-space point (in pixels, top-left origin),
/// using the same tan(fov/2) unprojection as crosshairDirection. Used for mouse-driven picking (e.g. the
/// editor gizmo) where the ray origin isn't the fixed screen-center crosshair.
pub fn screenPointDirection(rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31, screenCoord: Vec2f) Vec3f {
	const invRotationMatrix = rotationMatrix.transpose();
	const cameraDir = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 1, 0, 1}));
	const cameraUp = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 0, 1, 1}));
	const cameraRight = vec.xyz(invRotationMatrix.mulVec(Vec4f{1, 0, 0, 1}));

	const screenSize = Vec2f{@floatFromInt(width), @floatFromInt(height)};

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

/// Converts GLFW cursor coordinates into the current render-target pixel space used by
/// screenPointDirection/lastWidth/lastHeight. Handles HiDPI window-vs-framebuffer scale.
pub fn mouseScreenCoordForRenderTarget() Vec2f {
	var logicalWidth: c_int = 0;
	var logicalHeight: c_int = 0;
	c.glfwGetWindowSize(main.Window.window, &logicalWidth, &logicalHeight);

	var framebufferToWindowScale = Vec2f{1, 1};
	if (logicalWidth > 0 and logicalHeight > 0) {
		const framebufferSize = main.Window.getWindowSize();
		const logicalSize = Vec2f{@floatFromInt(logicalWidth), @floatFromInt(logicalHeight)};
		framebufferToWindowScale = framebufferSize/logicalSize;
	}

	const rawScreen = main.Window.getMousePosition()*framebufferToWindowScale;
	const viewport = computeViewportMetrics();
	if (!viewport.enabled) {
		return rawScreen*@as(Vec2f, @splat(main.settings.resolutionScale));
	}
	const local = rawScreen - Vec2f{@floatFromInt(viewport.x), @floatFromInt(viewport.y)};
	const maxCoord = Vec2f{@floatFromInt(viewport.outputWidth - 1), @floatFromInt(viewport.outputHeight - 1)};
	const clamped = @max(Vec2f{0, 0}, @min(local, maxCoord));
	const normalized = clamped/Vec2f{@floatFromInt(viewport.outputWidth), @floatFromInt(viewport.outputHeight)};
	return normalized*Vec2f{@floatFromInt(lastWidth), @floatFromInt(lastHeight)};
}

pub fn crosshairDirection(rotationMatrix: Mat4f, fovY: f32, width: u31, height: u31) Vec3f {
	const screenCoord = (crosshair.window.pos + crosshair.window.contentSize*Vec2f{0.5, 0.5}*@as(Vec2f, @splat(crosshair.window.scale)))*@as(Vec2f, @splat(main.gui.scale*main.settings.resolutionScale));
	return screenPointDirection(rotationMatrix, fovY, width, height, screenCoord);
}

fn projectDirection(viewProj: Mat4f, dir: Vec3f) ?Vec2f {
	const clip = viewProj.mulVec(Vec4f{dir[0], dir[1], dir[2], 0});
	if (clip[3] <= 1e-4) return null;
	const ndc = vec.xy(clip)/@as(Vec2f, @splat(clip[3]));
	return ndc*@as(Vec2f, @splat(0.5)) + Vec2f{0.5, 0.5};
}

pub fn renderWorld(world: *World, ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void {
	worldRenderFrame +%= 1;
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
	if (game.Player.editorMode.load(.monotonic)) {
		const mouseScreenCoord = mouseScreenCoordForRenderTarget();
		const mouseDirection = screenPointDirection(game.camera.viewMatrix, lastFov, lastWidth, lastHeight, mouseScreenCoord);
		MeshSelection.select(playerPos, mouseDirection, game.Player.inventory.getItem(game.Player.selectedSlot));
		MeshSelection.selectEntity(playerPos, mouseDirection);
		EditorGizmo.update(playerPos, mouseDirection, mouseScreenCoord);
	} else {
		MeshSelection.select(playerPos, direction, game.Player.inventory.getItem(game.Player.selectedSlot));
		MeshSelection.selectEntity(playerPos, direction);
	}

	chunk_meshing.beginRender();

	if (settings.shadows) {
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.shadow_rendering);
		CascadedShadowMap.update(playerPos);
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.chunk_rendering_preparation);
	}

	if (settings.reflectionMode == .planar) {
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.shadow_rendering);
		PlanarReflection.update(playerPos, ambientLight, meshes);
		gpu_performance_measuring.stopQuery();
		gpu_performance_measuring.startQuery(.chunk_rendering_preparation);
	} else {
		PlanarReflection.valid = false;
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

	main.systems.client.render(ambientLight, playerPos, main.lastDeltaTime.load(.monotonic));

	if (msaaActive) c.glEnable(c.GL_SAMPLE_ALPHA_TO_COVERAGE);
	itemdrop.ItemDropRenderer.renderItemDrops(ambientLight, playerPos);
	itemdrop.ItemDropRenderer.renderRemoteHeldLights(ambientLight, playerPos);
	itemdrop.ItemDropRenderer.renderLocalHandHeldItem(ambientLight, playerPos);
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
	EditorGizmo.render(playerPos);

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

	const framebufferSrgb = c.glIsEnabled(c.GL_FRAMEBUFFER_SRGB) == c.GL_TRUE;
	if (framebufferSrgb) c.glDisable(c.GL_FRAMEBUFFER_SRGB);
	c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, worldFrameBuffer.frameBuffer);
	c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, waterSurfaceFrameBuffer.frameBuffer);
	c.glBlitFramebuffer(0, 0, lastWidth, lastHeight, 0, 0, lastWidth, lastHeight, c.GL_DEPTH_BUFFER_BIT, c.GL_NEAREST);
	if (framebufferSrgb) c.glEnable(c.GL_FRAMEBUFFER_SRGB);
	waterSurfaceFrameBuffer.bind();
	c.glClearColor(0, 0, 0, 0);
	c.glClear(c.GL_COLOR_BUFFER_BIT);
	const weatherVisibilityAtPlayer = world.dayTime.weatherVisibilityAtAltitude(playerPos[2]);
	const weatherWaterMask = !isSubmerged and weatherVisibilityAtPlayer > 0.001;
	if (isSubmerged or weatherWaterMask) {
		chunk_meshing.drawWaterSurfaceMask(&chunkLists, ambientLight, weatherWaterMask);
	}
	worldFrameBuffer.bind();

	if (framebufferSrgb) c.glDisable(c.GL_FRAMEBUFFER_SRGB);
	c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, worldFrameBuffer.frameBuffer);
	c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, cloudFrameBuffer.frameBuffer);
	c.glBlitFramebuffer(0, 0, lastWidth, lastHeight, 0, 0, lastWidth, lastHeight, c.GL_DEPTH_BUFFER_BIT, c.GL_NEAREST);
	if (framebufferSrgb) c.glEnable(c.GL_FRAMEBUFFER_SRGB);
	cloudFrameBuffer.bind();
	c.glClearColor(0, 0, 0, 0);
	c.glClear(c.GL_COLOR_BUFFER_BIT);

	if (!isSubmerged and playerPos[2] < 6000.0) {
		worldFrameBuffer.bindDepthTexture(c.GL_TEXTURE13);
		clouds.draw(ambientLight, skyColor, playerPos);
		thin_clouds.draw(ambientLight, skyColor, playerPos);
		lightning.draw(playerPos);
	}
	worldFrameBuffer.bind();
	if (!isSubmerged) {
		rain.draw();
	}

	chunk_meshing.endRender();

	worldFrameBuffer.bindTexture(c.GL_TEXTURE3);

	if (settings.bloom) {
		Bloom.render(lastWidth, lastHeight, playerBlock, game.camera.viewMatrix);
	} else {
		Bloom.bindReplacementImage();
	}

	if (settings.godRays and weatherVisibilityAtPlayer <= 0.001) {
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

		const weatherVisibility = game.world.?.dayTime.weatherVisibilityAtAltitude(playerPos[2]);
		if (weatherVisibility > 0.001) {
			fogColor = game.world.?.dayTime.weatherFogColor(fogColor, weatherVisibility);
		}
		fogDensity = game.world.?.dayTime.weatherFogDensity(fogDensity, playerPos[2]);

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
		// A hard isSunlight() boolean pick here used to snap between the two tints right at the
		// horizon crossing, right where god rays are most visible (sunrise/sunset) - smoothly
		// blending via dayNightFactor() avoids the flicker.
		const dayNightFactor = game.world.?.dayTime.dayNightFactor();
		const tint = @as(Vec3f, @splat(1 - dayNightFactor))*Vec3f{0.9, 0.92, 0.95} + @as(Vec3f, @splat(dayNightFactor))*Vec3f{1.0, 0.9, 0.6};
		c.glUniform3fv(deferredUniforms.godRayTint, 1, @ptrCast(&tint));
	}

	const viewport = computeViewportMetrics();
	const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else finalOutputFBO(viewport);

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
		c.glViewport(0, 0, lastOutputWidth, lastOutputHeight);
		if (main.settings.upscalerMode == .fsr2) {
			const jitter = haltonJitterSequence[taaJitterIndex % haltonJitterSequence.len];
			fsr2.render(fsr.inputFrameBuffer.texture, worldFrameBuffer.depthTexture, lastWidth, lastHeight, lastOutputWidth, lastOutputHeight, jitter, finalOutputFBO(viewport));
			taaJitterIndex +%= 1;
		} else {
			fsr.render(lastWidth, lastHeight, lastOutputWidth, lastOutputHeight, finalOutputFBO(viewport));
		}
	} else {
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, finalOutputFBO(viewport));
	}

	itemdrop.ItemDropRenderer.renderDisplayItems(ambientLight, playerPos);

	if (!main.gui.hideGui and !game.Player.editorMode.load(.monotonic)) main.systems.client.renderHud(ambientLight, playerPos);

	if (viewport.enabled) {
		const dstY0: u31 = main.Window.height - (editorViewportY + lastOutputHeight);
		const dstY1: u31 = dstY0 + lastOutputHeight;
		c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, editorCompositeFrameBuffer.frameBuffer);
		c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
		c.glBlitFramebuffer(
			0,
			0,
			@intCast(lastOutputWidth),
			@intCast(lastOutputHeight),
			@intCast(editorViewportX),
			@intCast(dstY0),
			@intCast(editorViewportX + lastOutputWidth),
			@intCast(dstY1),
			c.GL_COLOR_BUFFER_BIT,
			c.GL_NEAREST,
		);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
		// The blit above leaves the GL viewport set to the reduced editor render
		// size (lastOutputWidth/lastOutputHeight at origin). Everything drawn after
		// renderWorld() returns (GUI dock panels, HUD-independent overlays) assumes
		// the viewport spans the full window, since shaders read GL_VIEWPORT to
		// compute screen-space coordinates. Without this reset, GUI rendering was
		// silently drawing into/using the wrong (tiny) viewport, making dock panels
		// and everything else disappear.
		c.glViewport(0, 0, main.Window.width, main.Window.height);
	}
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
		const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else finalOutputFBO(computeViewportMetrics());
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
		const targetFBO = if (main.settings.resolutionScale < 1.0) fsr.inputFrameBuffer.frameBuffer else finalOutputFBO(computeViewportMetrics());
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

		// Smoothly blended via dayNightFactor() rather than a hard isSunlight() flip, which used to
		// snap god-ray strength right at the horizon crossing - the exact moment god rays are most
		// visible - and looked like a flicker.
		const moonDimming: f32 = std.math.lerp(@as(f32, 0.5), @as(f32, 1.0), game.world.?.dayTime.dayNightFactor());

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
	var sunCloudAttenuation: f32 = 1.0;
	var moonCloudAttenuation: f32 = 1.0;
	var celestialWeatherAttenuation: f32 = 1.0;

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

			const smoothing = 1.0 - @exp(-@as(f32, @floatCast(main.lastDeltaTime.load(.monotonic))) * 9.0);
			const sunCloudTarget = clouds.getCloudAttenuationForDirection(playerPos, sunDir);
			const moonCloudTarget = clouds.getCloudAttenuationForDirection(playerPos, moonDir);
			sunCloudAttenuation += (sunCloudTarget - sunCloudAttenuation)*smoothing;
			moonCloudAttenuation += (moonCloudTarget - moonCloudAttenuation)*smoothing;
			const weatherVisibility = game.world.?.dayTime.weatherVisibilityAtAltitude(playerPos[2]);
			// Continuous falloff instead of a hard >0.001 threshold - that hard cutoff snapping the
			// sun/moon sprite's opacity target between 0 and 1 was most visible right at low sun
			// angle (sunrise/sunset), where horizonFade() already makes the sprite faint, so the
			// snap read as a flicker between "there" and "not there" instead of a smooth fade.
			const celestialWeatherTarget: f32 = 1.0 - std.math.clamp(weatherVisibility/0.25, 0.0, 1.0);
			celestialWeatherAttenuation += (celestialWeatherTarget - celestialWeatherAttenuation)*smoothing;

			drawCelestial(sunDir*@as(Vec3f, @splat(celestialDist)), sunBasis.right, sunBasis.up, 19.0, Vec3f{1.0, 0.9, 0.6}, horizonFade(sunDir) * sunCloudAttenuation * celestialWeatherAttenuation, sunCloudAttenuation * celestialWeatherAttenuation);
			drawCelestial(moonDir*@as(Vec3f, @splat(celestialDist)), moonBasis.right, moonBasis.up, 14.0, Vec3f{0.85, 0.9, 1.0}, horizonFade(moonDir)*0.6 * moonCloudAttenuation * celestialWeatherAttenuation, moonCloudAttenuation * celestialWeatherAttenuation);
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
	var lastDynamicShadowRefreshMilliseconds: i64 = 0;
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

		const refreshNearPlayerShadowEveryFrame = main.systems.systems.modelRenderer.client.hasNearbyPlayerShadowCaster(playerPos, cascadeFarDistances[0]);
		const nowMilliseconds = main.timestamp().toMilliseconds();
		const dynamicShadowRefreshDue = nowMilliseconds - lastDynamicShadowRefreshMilliseconds >= 16;

		const forceFullRefresh = shadowFrameCounter <= 2 or mapsResized;
		var scheduledRefreshes: usize = 0;

		for (0..activeCascades) |i| {

			const diffX = playerPos[0] - renderedPlayerPos[i][0];
			const diffY = playerPos[1] - renderedPlayerPos[i][1];
			const diffZ = playerPos[2] - renderedPlayerPos[i][2];
			const distSq = diffX * diffX + diffY * diffY + diffZ * diffZ;
			const frameAge = shadowFrameCounter -% lastRenderedFrame[i];
			const hasNearDynamicShadowCaster = (refreshNearFoliageShadowEveryFrame or refreshNearPlayerShadowEveryFrame) and i == 0;
			const isImmediateNearRefresh = hasNearDynamicShadowCaster and dynamicShadowRefreshDue;
			const needsReRender = sunMoved or distSq >= maxDistSq or frameAge >= maxFrameAge or isImmediateNearRefresh or forceFullRefresh;

			const canRefreshThisFrame = forceFullRefresh or isImmediateNearRefresh or scheduledRefreshes == 0;
			if (needsReRender and canRefreshThisFrame) {
				if (!isImmediateNearRefresh) scheduledRefreshes += 1;
				if (hasNearDynamicShadowCaster) lastDynamicShadowRefreshMilliseconds = nowMilliseconds;
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

				main.systems.systems.modelRenderer.client.renderShadows(&baseLightSpaceMatrices[i], playerPos);
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

/// Additive water reflection mode selected via main.settings.reflectionMode == .planar - mirrors the
/// opaque scene across the water surface nearest the camera into a small offscreen texture, sampled
/// directly (no raymarch) by transparent_fragment.frag's samplePlanar(). Does not replace SSR (.ssr
/// stays fully intact); this pass simply doesn't run unless .planar is selected.
///
/// Water has no single global height in this game (lakes/oceans/cave pools can coexist at any Z), so
/// this scopes itself to "the water surface closest to the player" via a cheap CPU-side vertical scan
/// each frame - correct for the common case of looking at one body of water, and simply contributes no
/// reflection (shader falls back to the sky cubemap, same as SSR's off-screen fallback) when no water
/// is nearby, which is an accepted limitation rather than a bug.
pub const PlanarReflection = struct {
	const verticalSearchRadius = 64;
	const horizontalSearchRadius = 96;
	const horizontalSearchStep = 8;

	var reflectionFB: graphics.FrameBuffer = undefined;
	var fbWidth: u31 = 0;
	var fbHeight: u31 = 0;

	pub var valid: bool = false;
	pub var viewMatrix: Mat4f = Mat4f.identity();
	pub var projectionMatrix: Mat4f = Mat4f.identity();
	pub var cameraPositionInteger: Vec3i = .{0, 0, 0};
	pub var cameraPositionFraction: Vec3f = .{0, 0, 0};

	fn init() void {
		reflectionFB.init(true, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
	}

	fn deinit() void {
		reflectionFB.deinit();
	}

	pub fn bindTexture(target: c_uint) void {
		reflectionFB.bindTexture(target);
	}

	/// Returns the world Z of the water surface nearest `playerPos`, or null if none is found within
	/// range. Scans a horizontal grid around the player (not just their exact column) since standing
	/// near but not directly over/under water - the common case of looking at a lake from its shore -
	/// otherwise made reflections activate only within a couple blocks of the player, which looked like
	/// a broken distance cutoff rather than the intended "no water nearby" fallback.
	fn findNearestWaterPlaneZ(playerPos: Vec3d) ?f64 {
		const waterType = blocks.getTypeById("cubyz:water");
		const px: i32 = @intFromFloat(@floor(playerPos[0]));
		const py: i32 = @intFromFloat(@floor(playerPos[1]));
		const pz: i32 = @intFromFloat(@floor(playerPos[2]));

		var bestDistSq: i32 = std.math.maxInt(i32);
		var bestZ: ?f64 = null;

		var dx: i32 = -horizontalSearchRadius;
		while (dx <= horizontalSearchRadius) : (dx += horizontalSearchStep) {
			var dy: i32 = -horizontalSearchRadius;
			while (dy <= horizontalSearchRadius) : (dy += horizontalSearchStep) {
				const x = px + dx;
				const y = py + dy;

				var dz: i32 = -verticalSearchRadius;
				while (dz <= verticalSearchRadius) : (dz += 1) {
					const z = pz + dz;
					const block = mesh_storage.getBlockFromRenderThread(x, y, z) orelse continue;
					if (block.typ != waterType) continue;
					const above = mesh_storage.getBlockFromRenderThread(x, y, z + 1);
					if (above != null and above.?.typ == waterType) continue;

					const distSq = dx*dx + dy*dy + dz*dz;
					if (distSq < bestDistSq) {
						bestDistSq = distSq;
						bestZ = @as(f64, @floatFromInt(z)) + 1.0;
					}
					break;
				}
			}
		}
		return bestZ;
	}

	pub fn update(playerPos: Vec3d, ambientLight: Vec3f, meshes: []*chunk_meshing.ChunkMesh) void {
		valid = false;
		if (settings.reflectionMode != .planar) return;

		const waterPlaneZ = findNearestWaterPlaneZ(playerPos) orelse return;

		const desiredWidth = @max(1, lastWidth/2);
		const desiredHeight = @max(1, lastHeight/2);
		if (fbWidth != desiredWidth or fbHeight != desiredHeight) {
			fbWidth = desiredWidth;
			fbHeight = desiredHeight;
			reflectionFB.updateSize(fbWidth, fbHeight, c.GL_RGB16F);
		}

		const savedFrameData = graphics.frame_uniforms.frameData();

		const mirroredRotation = Vec3f{-game.camera.rotation[0], game.camera.rotation[1], game.camera.rotation[2]};
		viewMatrix = Mat4f.identity().mul(Mat4f.rotationX(mirroredRotation[0])).mul(Mat4f.rotationZ(mirroredRotation[2]));

		const mirroredPlayerZ = 2.0*waterPlaneZ - playerPos[2];
		const mirroredPlayerPos = Vec3d{playerPos[0], playerPos[1], mirroredPlayerZ};

		projectionMatrix = Mat4f.perspective(std.math.degreesToRadians(lastFov), @as(f32, @floatFromInt(fbWidth))/@as(f32, @floatFromInt(fbHeight)), zNear, zFar);

		cameraPositionInteger = @as(Vec3i, @floor(mirroredPlayerPos));
		cameraPositionFraction = @as(Vec3f, @floatCast(@mod(mirroredPlayerPos, Vec3d{1, 1, 1})));

		graphics.frame_uniforms.uploadNewFrame(.{
			.playerPositionInteger = cameraPositionInteger,
			.playerPositionFraction = cameraPositionFraction,
			.projectionMatrix = projectionMatrix.toGl(),
			.viewMatrix = viewMatrix.toGl(),
		});

		reflectionFB.bind();
		c.glViewport(0, 0, fbWidth, fbHeight);
		reflectionFB.clear(Vec4f{0, 0, 0, 1});

		c.glActiveTexture(c.GL_TEXTURE0);
		blocks.meshes.blockTextureArray.bind();
		c.glActiveTexture(c.GL_TEXTURE1);
		blocks.meshes.emissionTextureArray.bind();
		c.glActiveTexture(c.GL_TEXTURE2);
		blocks.meshes.reflectivityAndAbsorptionTextureArray.bind();
		c.glActiveTexture(c.GL_TEXTURE5);
		blocks.meshes.ditherTexture.bind();
		reflectionCubeMap.bindTo(4);

		// Submitting the whole render-distance mesh list here (same set the main opaque pass uses)
		// would roughly double per-chunk draw overhead every frame regardless of what's actually near
		// the water - so this pass only includes chunks within waterReflectionDistance of the mirrored
		// camera, matching the distance SSR itself already gives up at (main.settings.waterReflectionDistance).
		const maxDist = @max(32.0, main.settings.waterReflectionDistance) + @as(f64, chunk.chunkSize)*2.0;
		const maxDistSq = maxDist*maxDist;

		var chunkLists: [main.settings.highestSupportedLod + 1]main.ListManaged(u32) = @splat(main.ListManaged(u32).init(main.stackAllocator));
		defer for (chunkLists) |list| list.deinit();
		for (meshes) |mesh| {
			const chunkSpan: f64 = @floatFromInt(@as(i64, mesh.pos.voxelSize)*chunk.chunkSize);
			const centerX = @as(f64, @floatFromInt(mesh.pos.wx)) + chunkSpan*0.5;
			const centerY = @as(f64, @floatFromInt(mesh.pos.wy)) + chunkSpan*0.5;
			const centerZ = @as(f64, @floatFromInt(mesh.pos.wz)) + chunkSpan*0.5;
			const dx = centerX - mirroredPlayerPos[0];
			const dy = centerY - mirroredPlayerPos[1];
			const dz = centerZ - mirroredPlayerPos[2];
			if (dx*dx + dy*dy + dz*dz > maxDistSq) continue;

			mesh.prepareRendering(&chunkLists);
		}

		chunk_meshing.clipPlane = @floatCast(waterPlaneZ);
		chunk_meshing.drawChunksIndirect(&chunkLists, ambientLight, false);
		chunk_meshing.clipPlane = null;

		graphics.frame_uniforms.uploadNewFrame(savedFrameData);
		if (settings.antiAliasingMode == .msaa) {
			MSAA.frameBuffer.bind();
		} else {
			worldFrameBuffer.bind();
		}
		c.glViewport(0, 0, lastWidth, lastHeight);

		valid = true;
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

	/// The last empty voxel stepped through before hitting the block at selectedBlockPos - i.e.
	/// the position adjacent to the hovered face, on the empty side. Only meaningful alongside a
	/// non-null selectedBlockPos (both are set together, in the same select() call).
	pub var posBeforeBlock: Vec3i = undefined;
	var neighborOfSelection: chunk.Neighbor = undefined;
	pub var selectedBlockPos: ?Vec3i = null;
	pub var selectedEntity: ?main.entity.Entity = null;
	var lastSelectedBlockPos: ?Vec3i = null;
	var currentBlockProgress: f32 = 0;
	var currentSwingProgress: f32 = 0;
	var currentSwingTime: f32 = 0;
	var activeBreakingPos: ?Vec3i = null;
	var airPunchStart: ?std.Io.Timestamp = null;
	var lastMiningInputTime: std.Io.Timestamp = .fromNanoseconds(0);
	var lastBreakingProgressSent: std.Io.Timestamp = .fromNanoseconds(0);
	var firstPersonSwingStart: ?std.Io.Timestamp = null;

	fn sendBreakingProgress(pos: Vec3i, progress: f32) void {
		const now = main.timestamp();
		if (progress >= 0 and lastBreakingProgressSent.durationTo(now).toNanoseconds() < 50_000_000) return;
		lastBreakingProgressSent = now;
		if (game.world) |world| main.network.protocols.genericUpdate.sendBlockBreaking(world.conn, pos, progress);
	}

	pub fn stopBreaking() void {
		if (activeBreakingPos) |pos| {
			mesh_storage.removeBreakingAnimation(pos);
			sendBreakingProgress(pos, -1.0);
			activeBreakingPos = null;
		}
		currentBlockProgress = 0;
	}

	pub fn updateBreakingProgress(deltaTime: f64) void {
		const pos = activeBreakingPos orelse return;
		if (lastMiningInputTime.durationTo(main.timestamp()).toNanoseconds() <= 300_000_000) return;
		currentBlockProgress = @max(0, currentBlockProgress - @as(f32, @floatCast(deltaTime))*0.10);
		if (currentBlockProgress <= 0) {
			stopBreaking();
			return;
		}
		mesh_storage.removeBreakingAnimation(pos);
		mesh_storage.addBreakingAnimation(pos, currentBlockProgress);
		sendBreakingProgress(pos, currentBlockProgress);
	}

	pub fn heldItemSwingProgress() ?f32 {
		if (airPunchStart) |start| {
			const elapsed = start.durationTo(main.timestamp()).toNanoseconds();
			const progress: f32 = @floatCast(@as(f64, @floatFromInt(elapsed))*1e-9/0.32);
			if (progress < 1.0) return std.math.clamp(progress, 0.0, 1.0);
			return null;
		}
		const elapsedSinceInput = lastMiningInputTime.durationTo(main.timestamp()).toNanoseconds();
		if (currentSwingTime <= 0 or elapsedSinceInput > 150_000_000) return null;
		return std.math.clamp(currentSwingProgress/currentSwingTime, 0.0, 1.0);
	}
	pub fn firstPersonHeldItemSwingProgress() ?f32 {
		if (airPunchStart != null) return heldItemSwingProgress();
		const start = firstPersonSwingStart orelse return null;
		if (lastMiningInputTime.durationTo(main.timestamp()).toNanoseconds() > 150_000_000) return null;
		const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(start.durationTo(main.timestamp()).toNanoseconds()))*1e-9);
		const phase = elapsed - @floor(elapsed/0.32)*0.32;
		return phase/0.32;
	}
	pub fn startAirPunch() void {
		if (selectedBlockPos != null) return;
		airPunchStart = main.timestamp();
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
				if (!game.Player.editorMode.load(.monotonic) and !block.isSelectableByItem(item)) break :blk;

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

	/// Finds the nearest non-player entity whose position lies close to the aim ray,
	/// within maxReach, using a simple ray-vs-sphere test sized from the entity's model.
	pub fn selectEntity(pos: Vec3d, _dir: Vec3f) void {
		selectedEntity = null;
		const dir: Vec3d = @floatCast(_dir);
		const maxReach: f64 = 5.0;

		var bestT: f64 = std.math.inf(f64);
		main.client.entity_manager.mutex.lock();
		defer main.client.entity_manager.mutex.unlock();
		for (main.client.entity_manager.entities.items()) |ent| {
			if (ent.id == game.Player.id) continue;
			var radius: f64 = 0.5;
			if (main.entity.components.@"cubyz:model".client.get(ent.id)) |component| {
				radius = @floatCast(component.entityModel.get().height*0.5);
			}

			const toEntity = ent.getRenderPosition() - pos;
			const t = std.math.clamp(vec.dot(toEntity, dir), 0, maxReach);
			if (t >= bestT) continue;
			const closestPoint = pos + dir*@as(Vec3d, @splat(t));
			const perpDistSqr = vec.lengthSquare(ent.getRenderPosition() - closestPoint);
			if (perpDistSqr > radius*radius) continue;

			bestT = t;
			selectedEntity = ent.id;
		}
	}

	fn canPlaceBlock(pos: Vec3i, block: main.blocks.Block) bool {
		if (main.physics.collision.collideWithBlock(block, pos[0], pos[1], pos[2], main.game.Player.getPosBlocking() + main.game.Player.outerBoundingBox.center(), main.game.Player.outerBoundingBox.extent(), .{0, 0, 0}) != null) {
			return false;
		}
		return true;
	}

	fn canPlaceDoor(pos: Vec3i, block: main.blocks.Block) bool {
		if (block.mode() != main.rotation.getByID("cubyz:door")) return true;
		const support = mesh_storage.getBlockFromRenderThread(pos[0], pos[1], pos[2] - 1) orelse return false;
		if (support.replaceable() or main.blocks.meshes.model(support).model().neighborFacingQuads[main.chunk.Neighbor.dirUp.toInt()].len == 0) return false;
		const upper = mesh_storage.getBlockFromRenderThread(pos[0], pos[1], pos[2] + 1) orelse return false;
		return upper.replaceable() and canPlaceBlock(pos + Vec3i{0, 0, 1}, block);
	}

	fn placeDoorUpperHalf(pos: Vec3i, block: main.blocks.Block) void {
		if (block.mode() != main.rotation.getByID("cubyz:door")) return;
		const upperPos = pos + Vec3i{0, 0, 1};
		const upper = mesh_storage.getBlockFromRenderThread(upperPos[0], upperPos[1], upperPos[2]) orelse return;
		if (!upper.replaceable()) return;
		mesh_storage.updateBlock(.{
			.pos = upperPos,
			.newBlock = .{.typ = block.typ, .data = (block.data & 7) | 8},
			.blockEntityData = &.{},
		});
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
								if (!canPlaceBlock(neighborPos, block) or !canPlaceDoor(neighborPos, block)) return;
								updateBlockAndSendUpdate(inventory, slot, neighborPos, oldBlock, block);
								placeDoorUpperHalf(neighborPos, block);
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
			firstPersonSwingStart = null;
		}
		lastMiningInputTime = now;
		if (selectedBlockPos) |selectedPos| {
			airPunchStart = null;
			const stack = inventory.getStack(slot);
			const isSelectionWand = stack.item == .baseItem and std.mem.eql(u8, stack.item.baseItem.id(), "cubyz:selection_wand");
			if (isSelectionWand) {
				game.Player.selectionPosition1 = selectedPos;
				main.network.protocols.genericUpdate.sendWorldEditPos(main.game.world.?.conn, .selectedPos1, selectedPos);
				return;
			}

			if (lastSelectedBlockPos == null or @reduce(.Or, lastSelectedBlockPos.? != selectedPos)) {
				stopBreaking();
				currentSwingProgress = 0;
				currentSwingTime = 0;
				lastSelectedBlockPos = selectedPos;
				currentBlockProgress = 0;
			}
			const block = mesh_storage.getBlockFromRenderThread(selectedPos[0], selectedPos[1], selectedPos[2]) orelse return;
			const holdingTargetedBlock = stack.item == .baseItem and stack.item.baseItem.block() == block.typ;
			if ((block.hasTag(.fluid) or block.hasTag(.air)) and !holdingTargetedBlock) {
				stopBreaking();
				return;
			}

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
					if (firstPersonSwingStart == null) firstPersonSwingStart = now;
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
						// One iteration here = one swing actually landing on the block (not yet
						// breaking it - that's the separate "block destroyed" sound in sync.zig's
						// UpdateBlock.run()) - without this, mining a multi-hit block like stone was
						// completely silent for however long it took to break.
						{
							const material = block.soundMaterial();
							const soundId = main.stackAllocator.print("cubyz:block_break/{s}", .{material});
							defer main.stackAllocator.free(soundId);
							const hitPos = Vec3d{
								@as(f64, @floatFromInt(selectedPos[0])) + 0.5,
								@as(f64, @floatFromInt(selectedPos[1])) + 0.5,
								@as(f64, @floatFromInt(selectedPos[2])) + 0.5,
							};
							main.audio.playSoundVariant(soundId, main.audio.soundVariantCount("block_break", material), hitPos, 0.4, 16.0);
						}
						if (currentBlockProgress > 0.9999) break;
						const swings = @ceil(block.blockHealth()/damage);
						const damagePerSwing = block.blockHealth()/swings;
						currentSwingTime = damagePerSwing/damage*swingTime;
					}
					if (currentBlockProgress < 0.9999) {
						mesh_storage.removeBreakingAnimation(selectedPos);
						if (currentBlockProgress != 0) {
							mesh_storage.addBreakingAnimation(selectedPos, currentBlockProgress);
							activeBreakingPos = selectedPos;
							sendBreakingProgress(selectedPos, currentBlockProgress);
						}
						main.sync.client.mutex.unlock();

						return;
					} else {
						currentSwingProgress = 0;
						stopBreaking();
						currentBlockProgress = 0;
						currentSwingTime = 0;
					}
				} else {
					main.sync.client.mutex.unlock();
					stopBreaking();
					return;
				}
			} else {
				stopBreaking();
			}

			var newBlock = block;
			block.mode().onBlockBreaking(inventory.getStack(slot).item, relPos, lastDir, &newBlock);
			main.sync.client.mutex.unlock();

			if (newBlock != block) {
				updateBlockAndSendUpdate(inventory, slot, selectedPos, block, newBlock);
			}
		} else {
			stopBreaking();
			lastSelectedBlockPos = null;
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

/// Draws a 3-axis move gizmo (red=X, green=Y, blue=Z) at the editor's currently selected entity or
/// block, and lets the player click-drag an axis to move it, persisting the move to the server via
/// genericUpdate.sendMoveEntity / sendMoveBlock. Selection is click-only: hovering never selects,
/// only clicking (on the gizmo axis to drag, or elsewhere to pick whatever's under the cursor).
pub const EditorGizmo = struct {
	const axisLength: f32 = 1.0;
	const blockDragPixelsPerStep: f64 = 12.0;

	const Selection = union(enum) {
		entity: main.entity.Entity,
		block: Vec3i,
	};

	var pipeline: graphics.Pipeline = undefined;
	var uniforms: struct {
		projectionMatrix: c_int,
		viewMatrix: c_int,
		modelPosition: c_int,
		axisLength: c_int,
		lineSize: c_int,
		hoveredAxis: c_int,
		grabbedAxis: c_int,
		errorActive: c_int,
		flashPhase: c_int,
		gizmoMode: c_int,
	} = undefined;

	pub const Mode = enum {move, rotate};
	pub var mode: Mode = .move;
	const ringSegments = 32;

	var selection: ?Selection = null;
	var hoveredAxis: ?u2 = null;
	var grabbedAxis: ?u2 = null;
	var grabOriginAtStart: Vec3d = .{0, 0, 0};
	var grabSelectionPos1AtStart: Vec3i = .{0, 0, 0};
	var grabSelectionPos2AtStart: Vec3i = .{0, 0, 0};
	var grabSelectionPos1Current: Vec3i = .{0, 0, 0};
	var grabSelectionPos2Current: Vec3i = .{0, 0, 0};
	var grabSelectionActive: bool = false;
	var grabPlaneNormal: Vec3d = .{0, 0, 1};
	var grabPlaneHitAtStart: Vec3d = .{0, 0, 0};
	var grabHasPlaneSolver: bool = false;
	var grabMouseScreenAtStart: Vec2f = .{0, 0};
	var grabScreenAxisDir: Vec2f = .{1, 0};
	var grabScreenPixelsPerAxisUnit: f64 = 96.0;
	var grabBlockPosAtStart: Vec3i = .{0, 0, 0};
	var lastSentPos: Vec3d = .{0, 0, 0};
	var grabbedBlockType: main.blocks.Block = .{.typ = 0, .data = 0};
	var lastSentBlockPos: Vec3i = .{0, 0, 0};
	var grabErrorUntil: ?std.Io.Timestamp = null;
	var visualAxisLength: f32 = 2.0;
	var visualHalfWidth: f32 = 0.10;

	pub fn init() void {
		pipeline = graphics.Pipeline.init(
			"assets/cubyz/shaders/editor_gizmo_vertex.vert",
			"assets/cubyz/shaders/editor_gizmo_fragment.frag",
			"",
			&uniforms,
			graphics.VertexArray.EmptyVertex,
			&.{},
			.{.cullMode = .none},
			.{.depthTest = false, .depthWrite = false},
			.{.attachments = &.{.alphaBlending}},
		);
	}

	pub fn deinit() void {
		pipeline.deinit();
	}

	pub fn currentOrigin() ?Vec3d {
		if (game.Player.selectionPosition1 != null and game.Player.selectionPosition2 != null) {
			return @as(Vec3d, @floatFromInt(game.Player.selectionPosition1.?)) + @as(Vec3d, @splat(0.5));
		}
		switch (selection orelse return null) {
			.entity => |entityId| {
				main.client.entity_manager.mutex.lock();
				defer main.client.entity_manager.mutex.unlock();
				for (main.client.entity_manager.entities.items()) |ent| {
					if (ent.id == entityId) return ent.getRenderPosition();
				}
				return null;
			},
			.block => |pos| return @as(Vec3d, @floatFromInt(pos)) + @as(Vec3d, @splat(0.5)),
		}
	}

	/// The currently *clicked/committed* selection's location, for display in UI (unlike
	/// `currentOrigin()`, which adds a +0.5 block-center offset for gizmo-drawing purposes).
	/// Returns null if nothing is actively selected (hovering alone doesn't count).
	pub const DisplayInfo = union(enum) {
		block: Vec3i,
		entityPos: Vec3d,
	};
	pub fn selectedDisplayInfo() ?DisplayInfo {
		if (game.Player.selectionPosition1 != null and game.Player.selectionPosition2 != null) {
			return .{.block = game.Player.selectionPosition1.?};
		}
		switch (selection orelse return null) {
			.entity => |entityId| {
				main.client.entity_manager.mutex.lock();
				defer main.client.entity_manager.mutex.unlock();
				for (main.client.entity_manager.entities.items()) |ent| {
					if (ent.id == entityId) return .{.entityPos = ent.getRenderPosition()};
				}
				return null;
			},
			.block => |pos| return .{.block = pos},
		}
	}

	const axisDirections = [3]Vec3d{.{1, 0, 0}, .{0, 1, 0}, .{0, 0, 1}};
	const axisDirectionsI = [3]Vec3i{.{1, 0, 0}, .{0, 1, 0}, .{0, 0, 1}};

	fn updateVisualScale(gizmoOrigin: Vec3d, cameraPos: Vec3d) void {
		const distance = vec.length(gizmoOrigin - cameraPos);
		visualAxisLength = std.math.clamp(@as(f32, @floatCast(distance*0.22)), 1.75, 7.0);
		visualHalfWidth = std.math.clamp(@as(f32, @floatCast(distance*0.018)), 0.10, 0.40);
	}

	fn projectWorldPointToScreen(pointRelativeToCamera: Vec3d) ?Vec2f {
		const mvPos = game.camera.viewMatrix.mulVec(.{
			@floatCast(pointRelativeToCamera[0]),
			@floatCast(pointRelativeToCamera[1]),
			@floatCast(pointRelativeToCamera[2]),
			1.0,
		});
		const clip = game.projectionMatrix.mulVec(mvPos);
		if (@abs(clip[3]) < 1e-6) return null;
		const ndc = vec.xy(clip)/@as(Vec2f, @splat(clip[3]));
		return (ndc*@as(Vec2f, @splat(0.5)) + Vec2f{0.5, 0.5})*Vec2f{@floatFromInt(lastWidth), @floatFromInt(lastHeight)};
	}

	fn distancePointToSegment(point: Vec2f, segmentStart: Vec2f, segmentEnd: Vec2f) f64 {
		const seg = segmentEnd - segmentStart;
		const segLenSq: f32 = vec.lengthSquare(seg);
		if (segLenSq <= 1e-6) return @floatCast(vec.length(point - segmentStart));
		const tUnclamped = vec.dot(point - segmentStart, seg)/segLenSq;
		const t = std.math.clamp(tUnclamped, 0.0, 1.0);
		const closest = segmentStart + seg*@as(Vec2f, @splat(t));
		return @floatCast(vec.length(point - closest));
	}

	fn rayAabbIntersection(rayOrigin: Vec3d, rayDir: Vec3d, minCorner: Vec3d, maxCorner: Vec3d) ?f64 {
		var tMin: f64 = -std.math.inf(f64);
		var tMax: f64 = std.math.inf(f64);

		inline for (0..3) |axis| {
			const origin = rayOrigin[axis];
			const dir = rayDir[axis];
			const minV = minCorner[axis];
			const maxV = maxCorner[axis];
			if (@abs(dir) < 1e-9) {
				if (origin < minV or origin > maxV) return null;
			} else {
				const invDir = 1.0/dir;
				var t0 = (minV - origin)*invDir;
				var t1 = (maxV - origin)*invDir;
				if (t0 > t1) std.mem.swap(f64, &t0, &t1);
				tMin = @max(tMin, t0);
				tMax = @min(tMax, t1);
				if (tMax < tMin) return null;
			}
		}

		if (tMax < 0) return null;
		return if (tMin >= 0) tMin else tMax;
	}

	fn intersectRayPlane(rayOrigin: Vec3d, rayDir: Vec3d, planePoint: Vec3d, planeNormal: Vec3d) ?Vec3d {
		const denom = vec.dot(rayDir, planeNormal);
		if (@abs(denom) < 1e-6) return null;
		const t = vec.dot(planePoint - rayOrigin, planeNormal)/denom;
		if (t < 0) return null;
		return rayOrigin + rayDir*@as(Vec3d, @splat(t));
	}

	fn axisPickAabb(gizmoOrigin: Vec3d, axisIndex: usize) struct { minCorner: Vec3d, maxCorner: Vec3d } {
		const halfWidth = @max(@as(f64, @floatCast(visualHalfWidth*2.5)), 0.32);
		const length = @as(f64, @floatCast(visualAxisLength));
		const minCorner = gizmoOrigin - @as(Vec3d, @splat(halfWidth));
		var maxCorner = gizmoOrigin + @as(Vec3d, @splat(halfWidth));
		switch (axisIndex) {
			0 => maxCorner[0] += length,
			1 => maxCorner[1] += length,
			2 => maxCorner[2] += length,
			else => unreachable,
		}
		return .{ .minCorner = minCorner, .maxCorner = maxCorner };
	}

	/// Finds which gizmo axis (if any) the mouse ray intersects first.
	fn hitTestAxes(gizmoOrigin: Vec3d, rayOrigin: Vec3d, rayDir: Vec3d, mouseScreenCoord: Vec2f) ?u2 {
		var best: ?u2 = null;
		var bestT = std.math.inf(f64);
		for (axisDirections, 0..) |axis, i| {
			_ = axis;
			const bounds = axisPickAabb(gizmoOrigin, i);
			if (rayAabbIntersection(rayOrigin, rayDir, bounds.minCorner, bounds.maxCorner)) |hitT| {
				if (hitT < bestT) {
					bestT = hitT;
					best = @intCast(i);
				}
			}
		}

		if (best != null) return best;

		// Screen-space fallback for very shallow/edge-on rays.
		var bestScore = std.math.inf(f64);
		for (axisDirections, 0..) |axis, i| {
			const start = projectWorldPointToScreen(gizmoOrigin - rayOrigin) orelse continue;
			const end = projectWorldPointToScreen(gizmoOrigin + axis*@as(Vec3d, @splat(visualAxisLength)) - rayOrigin) orelse continue;
			const axisLenPixels: f64 = @floatCast(vec.length(end - start));
			const distLine = distancePointToSegment(mouseScreenCoord, start, end);
			const distTip = @as(f64, @floatCast(vec.length(mouseScreenCoord - end)));
			const score = @min(distLine, distTip*0.7);
			const threshold: f64 = if (axisLenPixels < 12.0) 34.0 else if (axisLenPixels < 24.0) 24.0 else 14.0;
			if (score <= threshold and score < bestScore) {
				bestScore = score;
				best = @intCast(i);
			}
		}
		return best;
	}

	/// Whether the mouse ray hits the rotate-mode Z ring — a flat annulus lying in the XY plane
	/// through the gizmo origin, radius visualAxisLength, half-thickness visualHalfWidth. Uses a
	/// generous world-space radial tolerance, plus a screen-space fallback (distance from mouse
	/// to the ring's on-screen projected circle) for when the ray-vs-plane hit is unreliable —
	/// near edge-on viewing angles, or just because clicking an exact 3D ring precisely is much
	/// harder than clicking a line/arrow, unlike hitTestAxes which already has this fallback.
	fn hitTestRing(gizmoOrigin: Vec3d, rayOrigin: Vec3d, rayDir: Vec3d) bool {
		if (@abs(rayDir[2]) >= 1e-9) {
			const t = (gizmoOrigin[2] - rayOrigin[2])/rayDir[2];
			if (t >= 0) {
				const hit = rayOrigin + rayDir*@as(Vec3d, @splat(t));
				const radial = vec.length(vec.xy(hit - gizmoOrigin));
				const innerR: f64 = @floatCast(visualAxisLength - visualHalfWidth*6.0);
				const outerR: f64 = @floatCast(visualAxisLength + visualHalfWidth*6.0);
				if (radial >= innerR and radial <= outerR) return true;
			}
		}

		// Screen-space fallback: sample points around the ring's world-space circle, project
		// each to screen space, and check whether the mouse is close to the nearest sampled point.
		const mouseScreenCoord = mouseScreenCoordForRenderTarget();
		const ringSampleCount = 24;
		var bestDist: f64 = std.math.inf(f64);
		var i: usize = 0;
		while (i < ringSampleCount) : (i += 1) {
			const angle = (@as(f32, @floatFromInt(i))/@as(f32, @floatFromInt(ringSampleCount)))*std.math.tau;
			const samplePoint = gizmoOrigin + Vec3d{@floatCast(@cos(angle)*visualAxisLength), @floatCast(@sin(angle)*visualAxisLength), 0} - rayOrigin;
			const screenPoint = projectWorldPointToScreen(samplePoint) orelse continue;
			bestDist = @min(bestDist, @as(f64, @floatCast(vec.length(mouseScreenCoord - screenPoint))));
		}
		return bestDist <= 26.0;
	}

	/// Called once per frame while in editor mode with the current camera-relative mouse ray,
	/// updating hover state and, if an axis is grabbed, dragging the selection along it.
	pub fn update(playerPos: Vec3d, mouseDirection: Vec3f, mouseScreenCoord: Vec2f) void {
		hoveredAxis = null;
		if (!game.Player.editorMode.load(.monotonic)) return;
		if (mode == .rotate) {
			// Rotate mode has no drag, just hover feedback on the ring — reuses hoveredAxis==2
			// (the same slot/blue color the Z arrow's hover highlight already uses) since the
			// fragment shader's hover/grab coloring is keyed off axisIndex, and the ring's
			// vertex shader hardcodes axisIndex=2 for itself (see editor_gizmo_vertex.vert).
			const gizmoOrigin = currentOrigin() orelse return;
			updateVisualScale(gizmoOrigin, playerPos);
			if (hitTestRing(gizmoOrigin, playerPos, @floatCast(mouseDirection))) {
				hoveredAxis = 2;
			}
			return;
		}
		if (mode != .move) return;
		const gizmoOrigin = currentOrigin() orelse return;
		updateVisualScale(gizmoOrigin, playerPos);
		const rayOrigin = playerPos;
		const rayDir: Vec3d = @floatCast(mouseDirection);

		if (grabbedAxis) |axisIndex| {
			const axis = axisDirections[axisIndex];
			const delta = blk: {
				if (grabHasPlaneSolver) {
					const hit = intersectRayPlane(rayOrigin, rayDir, grabOriginAtStart, grabPlaneNormal) orelse break :blk 0.0;
					break :blk vec.dot(hit - grabPlaneHitAtStart, axis);
				}
				const mouseDelta = mouseScreenCoord - grabMouseScreenAtStart;
				const axisPixelsRaw = vec.dot(mouseDelta, grabScreenAxisDir);
				break :blk @as(f64, @floatCast(axisPixelsRaw))/grabScreenPixelsPerAxisUnit;
			};
			const newPos = grabOriginAtStart + axis*@as(Vec3d, @splat(delta));

			switch (selection.?) {
				.entity => |entityId| {
					if (main.client.entity_manager.getEntity(entityId)) |ent| ent.pos = newPos;
					if (vec.lengthSquare(newPos - lastSentPos) > 0.0004) {
						lastSentPos = newPos;
						if (game.world) |world| main.network.protocols.genericUpdate.sendMoveEntity(world.conn, entityId, newPos);
					}
				},
				.block => {
					if (grabSelectionActive) {
						const mouseDelta = mouseScreenCoord - grabMouseScreenAtStart;
						const axisPixelsRaw = vec.dot(mouseDelta, grabScreenAxisDir);
						const targetStep: i32 = @intFromFloat(@round(@as(f64, @floatCast(axisPixelsRaw))/blockDragPixelsPerStep));
						const axisStep = axisDirectionsI[axisIndex];
						const deltaBlock = axisStep*@as(Vec3i, @splat(targetStep));
						const desiredPos1 = grabSelectionPos1AtStart + deltaBlock;
						const desiredPos2 = grabSelectionPos2AtStart + deltaBlock;
						if (@reduce(.And, desiredPos1 == grabSelectionPos1Current) and @reduce(.And, desiredPos2 == grabSelectionPos2Current)) return;
						const oldPos1 = grabSelectionPos1Current;
						const oldPos2 = grabSelectionPos2Current;
						grabSelectionPos1Current = desiredPos1;
						grabSelectionPos2Current = desiredPos2;
						game.Player.selectionPosition1 = desiredPos1;
						game.Player.selectionPosition2 = desiredPos2;
						if (game.world) |world| {
							main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos1, desiredPos1);
							main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos2, desiredPos2);
							main.network.protocols.genericUpdate.sendMoveSelection(world.conn, oldPos1, oldPos2, desiredPos1, desiredPos2);
						}
						return;
					}
					const mouseDelta = mouseScreenCoord - grabMouseScreenAtStart;
					const axisPixelsRaw = vec.dot(mouseDelta, grabScreenAxisDir);
					const targetStep: i32 = @intFromFloat(@round(@as(f64, @floatCast(axisPixelsRaw))/blockDragPixelsPerStep));
					const axisStep = axisDirectionsI[axisIndex];
					const desiredBlockPos = grabBlockPosAtStart + axisStep*@as(Vec3i, @splat(targetStep));
					if (@reduce(.And, desiredBlockPos == lastSentBlockPos)) return;
					const targetBlock = mesh_storage.getBlockFromRenderThread(desiredBlockPos[0], desiredBlockPos[1], desiredBlockPos[2]) orelse blocks.Block.air;
					if (targetBlock != blocks.Block.air) {
						grabErrorUntil = main.timestamp().addDuration(.fromMilliseconds(250));
						return;
					}
					const oldBlockPos = lastSentBlockPos;
					lastSentBlockPos = desiredBlockPos;
					selection = .{.block = desiredBlockPos};
					grabErrorUntil = null;
					if (game.world) |world| main.network.protocols.genericUpdate.sendMoveBlock(world.conn, oldBlockPos, desiredBlockPos, grabbedBlockType);
				},
			}
			return;
		}

		hoveredAxis = hitTestAxes(gizmoOrigin, rayOrigin, rayDir, mouseScreenCoord);

		// If the grab button is still held (e.g. the click that selected this block/entity also
		// landed near an axis, or the mouse settled onto an axis after the initial press) and we
		// haven't started a drag yet, start one now instead of requiring a fresh press.
		if (hoveredAxis != null and main.KeyBoard.key("editorGizmoGrab").pressed) {
			startGrab(hoveredAxis.?, gizmoOrigin, rayOrigin, mouseScreenCoord);
		}
	}

	fn startGrab(axisIndex: u2, gizmoOrigin: Vec3d, rayOrigin: Vec3d, mouseScreenCoord: Vec2f) void {
		updateVisualScale(gizmoOrigin, rayOrigin);
		grabOriginAtStart = gizmoOrigin;
		lastSentPos = gizmoOrigin;
		grabMouseScreenAtStart = mouseScreenCoord;
		grabSelectionActive = hasAreaSelection();
		if (grabSelectionActive) {
			grabSelectionPos1AtStart = game.Player.selectionPosition1.?;
			grabSelectionPos2AtStart = game.Player.selectionPosition2.?;
			grabSelectionPos1Current = grabSelectionPos1AtStart;
			grabSelectionPos2Current = grabSelectionPos2AtStart;
			selection = .{.block = grabSelectionPos1AtStart};
		}
		if (selection != null and selection.? == .block) {
			if (game.world) |world| main.network.protocols.genericUpdate.sendEditorDragStart(world.conn);
		}
		grabHasPlaneSolver = false;
		grabErrorUntil = null;

		const invRotationMatrix = game.camera.viewMatrix.transpose();
		const cameraForward: Vec3f = vec.xyz(invRotationMatrix.mulVec(Vec4f{0, 1, 0, 1}));
		const cameraRight: Vec3f = vec.xyz(invRotationMatrix.mulVec(Vec4f{1, 0, 0, 1}));
		const axisDirF: Vec3f = @floatCast(axisDirections[axisIndex]);

		var planeNormalF = vec.cross(axisDirF, cameraForward);
		if (vec.lengthSquare(planeNormalF) < 1e-6) {
			planeNormalF = vec.cross(axisDirF, cameraRight);
		}
		if (vec.lengthSquare(planeNormalF) < 1e-6) {
			planeNormalF = vec.cross(axisDirF, Vec3f{0, 0, 1});
		}
		if (vec.lengthSquare(planeNormalF) >= 1e-6) {
			grabPlaneNormal = @floatCast(vec.normalize(planeNormalF));
			if (intersectRayPlane(rayOrigin, @floatCast(screenPointDirection(game.camera.viewMatrix, lastFov, lastWidth, lastHeight, mouseScreenCoord)), grabOriginAtStart, grabPlaneNormal)) |hitStart| {
				grabPlaneHitAtStart = hitStart;
				grabHasPlaneSolver = true;
			}
		}

		if (projectWorldPointToScreen(gizmoOrigin - rayOrigin)) |screenStart| {
			if (projectWorldPointToScreen(gizmoOrigin + axisDirections[axisIndex]*@as(Vec3d, @splat(visualAxisLength)) - rayOrigin)) |screenEnd| {
				const screenAxis = screenEnd - screenStart;
				const screenAxisLen = vec.length(screenAxis);
				if (screenAxisLen > 1e-4) {
					grabScreenAxisDir = screenAxis/@as(Vec2f, @splat(screenAxisLen));
					grabScreenPixelsPerAxisUnit = @max(@as(f64, @floatCast(screenAxisLen))/visualAxisLength, 10.0);
				}
			}
		}
		if (!grabHasPlaneSolver and vec.lengthSquare(grabScreenAxisDir) < 1e-6) {
			grabScreenAxisDir = switch (axisIndex) {
				0 => .{1, 0},
				1 => .{0, -1},
				2 => .{0, -1},
				else => .{1, 0},
			};
		}
		grabScreenPixelsPerAxisUnit = @max(grabScreenPixelsPerAxisUnit, 10.0);
		grabbedAxis = axisIndex;
		if (selection.? == .block) {
			grabBlockPosAtStart = selection.?.block;
			lastSentBlockPos = selection.?.block;
			grabbedBlockType = mesh_storage.getBlockFromRenderThread(lastSentBlockPos[0], lastSentBlockPos[1], lastSentBlockPos[2]) orelse .{.typ = 0, .data = 0};
		}
	}

	fn pickUnderCursor() void {
		if (MeshSelection.selectedEntity) |entityId| {
			selection = .{.entity = entityId};
		} else if (MeshSelection.selectedBlockPos) |blockPos| {
			selection = .{.block = blockPos};
		} else {
			selection = null;
		}
	}

	/// Cumulative Z rotation applied to the current selection this session, purely for display
	/// in the details panel (shown as "Rotation: N°") — there's no single universal "orientation"
	/// value stored per block (each rotation mode encodes its own thing in Block.data), so this
	/// tracks the total *editor-applied* rotation instead. Reset whenever a new block/area
	/// becomes the selection anchor (see grabPress) so it doesn't carry over between selections.
	pub var cumulativeRotationDegrees: u16 = 0;

	/// Rotates the current selection 90° counterclockwise around Z. A single clicked block (only
	/// selectionPosition1 set) is treated as a 1x1x1 box, matching delete/copy's fallback.
	fn rotateSelection90() void {
		const pos1 = game.Player.selectionPosition1 orelse return;
		if (game.Player.selectionPosition2 == null) {
			game.Player.selectionPosition2 = pos1;
			if (game.world) |world| main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos2, pos1);
		}
		if (game.world) |world| main.network.protocols.genericUpdate.sendRotateSelection(world.conn, .@"90");
		cumulativeRotationDegrees = (cumulativeRotationDegrees + 90) % 360;
	}

	fn hasAreaSelection() bool {
		return game.Player.selectionPosition1 != null and game.Player.selectionPosition2 != null;
	}

	fn clearAreaSelection() void {
		game.Player.selectionPosition1 = null;
		game.Player.selectionPosition2 = null;
		cumulativeRotationDegrees = 0;
		if (game.world) |world| main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .clear, null);
	}

	var lastClickTime: ?std.Io.Timestamp = null;
	var lastClickBlockPos: ?Vec3i = null;
	const doubleClickWindow: std.Io.Duration = .fromMilliseconds(350);

	/// Detects a double-click on the same block (two plain clicks within doubleClickWindow,
	/// no shift) and fires /selectsimilar (flood-fill same-type blob, capped server-side) if so.
	/// Returns true if this click was consumed as the second half of a double-click.
	fn checkDoubleClick(mods: main.Window.Key.Modifiers, hoveredBlock: ?Vec3i) bool {
		defer {
			lastClickTime = main.timestamp();
			lastClickBlockPos = hoveredBlock;
		}
		if (mods.shift) return false;
		const blockPos = hoveredBlock orelse return false;
		const prevTime = lastClickTime orelse return false;
		const prevPos = lastClickBlockPos orelse return false;
		if (!@reduce(.And, blockPos == prevPos)) return false;
		if (prevTime.durationTo(main.timestamp()).toNanoseconds() > doubleClickWindow.toNanoseconds()) return false;

		game.Player.selectionPosition1 = blockPos;
		cumulativeRotationDegrees = 0;
		if (game.world) |world| {
			main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos1, blockPos);
			const command = main.globalAllocator.dupe(u8, "selectsimilar");
			main.sync.client.executeCommand(.{.chatCommand = .{.message = command}});
		}
		return true;
	}

	/// Area-selection semantics: a plain click on a block starts (or restarts) the selection
	/// anchor at that block. Shift+click while an anchor exists but has no second corner yet
	/// completes the area [pos1, pos2]. A plain click on any block other than the current
	/// anchor/second-corner clears the area and starts a new anchor at the clicked block.
	/// A second plain click on the same block within doubleClickWindow instead flood-selects
	/// all directly-connected same-type blocks (see checkDoubleClick).
	pub fn grabPress(mods: main.Window.Key.Modifiers) void {
		if (!game.Player.editorMode.load(.monotonic)) return;
		if (main.gui.hoveredAWindow) return;
		if (checkDoubleClick(mods, MeshSelection.selectedBlockPos)) return;
		if (mods.shift) {
			if (MeshSelection.selectedBlockPos) |blockPos| {
				if (game.Player.selectionPosition1 == null) {
					game.Player.selectionPosition1 = blockPos;
					cumulativeRotationDegrees = 0;
					if (game.world) |world| {
						main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos1, blockPos);
					}
				} else if (game.Player.selectionPosition2 == null) {
					game.Player.selectionPosition2 = blockPos;
					if (game.world) |world| {
						main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos2, blockPos);
					}
				}
			}
			return;
		}

		const rayOrigin = game.devCameraPos;
		const mouseScreenCoord = mouseScreenCoordForRenderTarget();
		const rayDir: Vec3d = @floatCast(screenPointDirection(game.camera.viewMatrix, lastFov, lastWidth, lastHeight, mouseScreenCoord));

		// If something is already selected and this click lands on its gizmo, act on it directly:
		// grab an axis to drag (move mode), or rotate 90° immediately (rotate mode — there's no
		// drag, since only discrete 90° Z rotation exists, see rotateSelection/Blueprint.rotateZ).
		if (currentOrigin()) |gizmoOrigin| {
			updateVisualScale(gizmoOrigin, rayOrigin);
			if (mode == .rotate) {
				if (hitTestRing(gizmoOrigin, rayOrigin, rayDir)) {
					rotateSelection90();
					return;
				}
			} else if (hitTestAxes(gizmoOrigin, rayOrigin, rayDir, mouseScreenCoord)) |axisIndex| {
				startGrab(axisIndex, gizmoOrigin, rayOrigin, mouseScreenCoord);
				return;
			}
		}

		// Otherwise pick whatever's under the cursor, then check if the *new* selection's gizmo
		// also happens to pass under this same click point — so select+drag can happen in one motion.
		pickUnderCursor();
		if (MeshSelection.selectedBlockPos) |hoveredBlock| {
			const isCurrentAnchor = if (game.Player.selectionPosition1) |pos1| @reduce(.And, hoveredBlock == pos1) else false;
			const isCurrentSecondCorner = if (game.Player.selectionPosition2) |pos2| @reduce(.And, hoveredBlock == pos2) else false;
			if (!isCurrentAnchor and !isCurrentSecondCorner) {
				clearAreaSelection();
				game.Player.selectionPosition1 = hoveredBlock;
				if (game.world) |world| {
					main.network.protocols.genericUpdate.sendWorldEditPos(world.conn, .selectedPos1, hoveredBlock);
				}
			}
		} else if (hasAreaSelection()) {
			clearAreaSelection();
		}
		const newOrigin = currentOrigin() orelse return;
		updateVisualScale(newOrigin, rayOrigin);
		if (mode == .rotate) {
			if (hitTestRing(newOrigin, rayOrigin, rayDir)) rotateSelection90();
		} else if (hitTestAxes(newOrigin, rayOrigin, rayDir, mouseScreenCoord)) |axisIndex| {
			startGrab(axisIndex, newOrigin, rayOrigin, mouseScreenCoord);
		}
	}

	pub fn grabRelease(_: main.Window.Key.Modifiers) void {
		if (grabbedAxis != null and selection != null and selection.? == .block) {
			if (game.world) |world| main.network.protocols.genericUpdate.sendEditorDragEnd(world.conn);
		}
		grabbedAxis = null;
	}

	pub fn render(playerPos: Vec3d) void {
		if (main.gui.hideGui) return;
		if (!game.Player.editorMode.load(.monotonic)) return;
		const pos = currentOrigin() orelse {
			selection = null;
			return;
		};

		pipeline.bind(null);
		const relativePosition: Vec3f = @floatCast(pos - playerPos);
		updateVisualScale(pos, playerPos);
		c.glUniform3f(uniforms.modelPosition, relativePosition[0], relativePosition[1], relativePosition[2]);
		c.glUniform1f(uniforms.axisLength, visualAxisLength);
		c.glUniform1f(uniforms.lineSize, visualHalfWidth);
		c.glUniform1i(uniforms.hoveredAxis, if (hoveredAxis) |axis| axis else -1);
		c.glUniform1i(uniforms.grabbedAxis, if (grabbedAxis) |axis| axis else -1);
		c.glUniform1i(uniforms.errorActive, if (grabErrorUntil) |until| @intFromBool(main.timestamp().durationTo(until).nanoseconds > 0) else 0);
		const flashPhase: f32 = @floatCast(@as(f64, @floatFromInt(@mod(main.timestamp().toNanoseconds(), 10_000_000_000)))*1e-9);
		c.glUniform1f(uniforms.flashPhase, flashPhase);
		c.glUniform1i(uniforms.gizmoMode, if (mode == .rotate) 1 else 0);

		main.renderer.chunk_meshing.vao.bind();
		switch (mode) {
			.move => c.glDrawArrays(c.GL_TRIANGLES, 0, 3*6),
			.rotate => c.glDrawArrays(c.GL_TRIANGLES, 0, ringSegments*6),
		}
	}
};
