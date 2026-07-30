const std = @import("std");

const main = @import("main");
const game = main.game;
const settings = main.settings;
const graphics = main.graphics;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;

const c = @import("c");

// A thin, wispy, high-altitude cloud plane layered on top of the main chunky cloud layer (see
// clouds.zig) — the old flat/planar look brought back as an *additional* layer rather than a
// replacement, per user request. Deliberately its own file/pipeline/shaders: this is a much simpler,
// cheaper effect (one static quad, no greedy-meshed 3D geometry, no CPU-side coverage grid) and keeping
// it separate means it can't tangle with clouds.zig's own state or accidentally regress it.

/// World-space size of one grid cell, along both horizontal axes.
const planeHalfSize: f32 = 4096.0;
/// World Z — Layer 3: high-altitude thin cloud plane above the raised 3D cloud deck.
const planeHeight: f32 = 640.0;
/// World Z — Layer 4: top of all cloud layers.
const stormPlaneHeight: f32 = 680.0;

/// blocks/second, deliberately different from clouds.zig's windVelocity (2.0, 0.8) so the layers
/// visibly drift apart instead of moving in lockstep.
const windVelocity = Vec2f{3.0, 1.4};

const Vertex = extern struct {
	pos: [2]f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{.location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(@This(), "pos")},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	tint: c_int,
	planeHeightRelative: c_int,
	noiseOrigin: c_int,
	coverageThreshold: c_int,
	maxAlpha: c_int,
	fogColor: c_int,
	fogDensity: c_int,
	weatherFogStrength: c_int,
} = undefined;
var vao: graphics.VertexArray = undefined;

/// Reference point for wind animation — see clouds.zig's identical field for why this uses real elapsed
/// time rather than the (coarser, tick-based) game-time clock.
var startTimestamp: std.Io.Timestamp = undefined;

pub fn init() void {
	startTimestamp = main.timestamp();
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/thin_clouds_vertex.vert",
		"assets/cubyz/shaders/thin_clouds_fragment.frag",
		"",
		&uniforms,
		Vertex,
		&.{},
		.{.cullMode = .none},
		.{.depthTest = true, .depthWrite = false},
		.{.attachments = &.{.premultipliedAlphaBlending}},
	);

	const verts = [_]Vertex{
		.{.pos = .{-planeHalfSize, -planeHalfSize}},
		.{.pos = .{planeHalfSize, -planeHalfSize}},
		.{.pos = .{planeHalfSize, planeHalfSize}},
		.{.pos = .{-planeHalfSize, planeHalfSize}},
	};
	const indices = [_]u32{0, 1, 2, 0, 2, 3};
	vao = .init(Vertex, &verts, &indices);
}

pub fn deinit() void {
	pipeline.deinit();
	vao.deinit();
}

pub fn draw(ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void {
	if (!settings.clouds) return;
	const aerialFade = 1.0 - std.math.clamp(@as(f32, @floatCast((playerPos[2] - 2000.0)/4000.0)), 0.0, 1.0);
	if (aerialFade <= 0.001) return;

	pipeline.bind(null);

	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));
	const playerXY = Vec2f{@floatCast(playerPos[0]), @floatCast(playerPos[1])};
	const noiseOrigin = playerXY + windOffset;

	const neutralWhite = Vec3f{0.98, 0.98, 1.0};
	// Match the volumetric deck's atmosphere lighting: thin clouds should remain muted blue-grey at
	// night and should not turn into a solid white sheet in full daylight.
	const cloudLight = @min(Vec3f{0.86, 0.89, 0.93}, ambientLight*@as(Vec3f, @splat(0.55)) + Vec3f{0.30, 0.33, 0.38});
	const localWeather = if (game.world) |world| world.weatherGrid.sampleAt(playerPos[0], playerPos[1]) else game.WeatherGrid.Sample{};
	const weatherFogStrength: f32 = if (game.world) |world| world.dayTime.weatherVisibility else 0.0;
	const weatherCloudDarkening: f32 = if (localWeather.kind == 1) std.math.lerp(1.0, 0.58, weatherFogStrength) else 1.0;
	const tint = @min(Vec3f{1, 1, 1}, neutralWhite*@as(Vec3f, @splat(0.7)) + skyColor*@as(Vec3f, @splat(0.3)))*cloudLight*@as(Vec3f, @splat(weatherCloudDarkening));
	var fogColor: Vec3f = if (game.world) |world| world.dayTime.fog.fogColor else Vec3f{0.7, 0.75, 0.8};
	if (localWeather.kind == 1) {
		const rainCloudHaze = Vec3f{0.30, 0.36, 0.44};
		fogColor += (rainCloudHaze - fogColor)*@as(Vec3f, @splat(std.math.clamp(weatherFogStrength*0.9, 0.0, 0.8)));
	}
	const fogDensity: f32 = if (weatherFogStrength > 0.001) weatherFogStrength / (if (game.world) |world| world.dayTime.weatherFogRange else 96.0) else 0.0;

	// Layer 3: High-altitude 2D thin cloud layer (Z = 480)
	{
		const planeHeightRelative: f32 = @floatCast(@as(f64, planeHeight) - playerPos[2]);
		c.glUniform1f(uniforms.planeHeightRelative, planeHeightRelative);
		c.glUniform3fv(uniforms.tint, 1, @ptrCast(&tint));
		c.glUniform1f(uniforms.coverageThreshold, 0.55);
		c.glUniform1f(uniforms.maxAlpha, 0.25*aerialFade);
		c.glUniform2fv(uniforms.noiseOrigin, 1, @ptrCast(&noiseOrigin));
		c.glUniform3fv(uniforms.fogColor, 1, @ptrCast(&fogColor));
		c.glUniform1f(uniforms.fogDensity, fogDensity);
		c.glUniform1f(uniforms.weatherFogStrength, weatherFogStrength);

		vao.bind();
		c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null);
	}

	// Layer 4: Top-of-all-layers Storm 2D Planar Cloud Layer — darker, heavy sky coverage, spawns during rain (Z = 520)
	const rainIntensity: f32 = if (game.world) |w| w.dayTime.rainIntensity else 0.0;
	if (rainIntensity > 0.02) {
		const stormAlpha = rainIntensity * 0.85*aerialFade;
		if (stormAlpha > 0.01) {
			const stormPlaneHeightRelative: f32 = @floatCast(@as(f64, stormPlaneHeight) - playerPos[2]);
			c.glUniform1f(uniforms.planeHeightRelative, stormPlaneHeightRelative);

			const darkStormTint = tint * @as(Vec3f, @splat(0.35)); // Dark stormy tint
			c.glUniform3fv(uniforms.tint, 1, @ptrCast(&darkStormTint));
			c.glUniform1f(uniforms.coverageThreshold, 0.20); // Heavy overcast coverage across sky
			c.glUniform1f(uniforms.maxAlpha, stormAlpha);

			const stormNoiseOrigin = noiseOrigin * @as(Vec2f, @splat(1.15));
		c.glUniform2fv(uniforms.noiseOrigin, 1, @ptrCast(&stormNoiseOrigin));
		c.glUniform3fv(uniforms.fogColor, 1, @ptrCast(&fogColor));
		c.glUniform1f(uniforms.fogDensity, fogDensity);
		c.glUniform1f(uniforms.weatherFogStrength, weatherFogStrength);

			vao.bind();
			c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null);
		}
	}
}
