const std = @import("std");

const main = @import("main");
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
//
// Unlike clouds.zig's per-cell coverage decisions, this doesn't need any CPU-side data at all: the quad
// is always exactly centered on the player (see planeHalfSize below), and the wispy pattern itself is
// computed procedurally straight in the fragment shader from world position + a wind-scrolled offset —
// there's nothing here for the CPU to precompute per frame beyond a couple of uniforms.

/// Always centered on the player (no per-frame recentering math needed — see the module doc comment),
/// so this only needs to reach comfortably past the far draw/fog distance.
const planeHalfSize: f32 = 4096.0;
/// World Z — above clouds.zig's cloudBaseHeight (288), so this reads as a higher, thinner layer above
/// the main clouds rather than intersecting them.
const planeHeight: f32 = 480.0;
const maxAlpha: f32 = 0.25; // much thinner than clouds.zig's baseAlpha (0.65) — a wisp, not a blanket.
/// blocks/second, deliberately different from clouds.zig's windVelocity (2.0, 0.8) so the two layers
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
		.{.attachments = &.{.alphaBlending}},
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

/// Drawn after clouds.draw() in renderer.zig — visually layers this thin wispy plane over the main
/// chunky clouds, matching "add those on top of the existing clouds."
pub fn draw(ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void {
	if (!settings.clouds) return;

	pipeline.bind(null);

	const neutralWhite = Vec3f{0.98, 0.98, 1.0};
	const tint = @min(Vec3f{1, 1, 1}, neutralWhite*@as(Vec3f, @splat(0.7)) + skyColor*@as(Vec3f, @splat(0.3)))*ambientLight;
	c.glUniform3fv(uniforms.tint, 1, @ptrCast(&tint));

	const planeHeightRelative: f32 = @floatCast(@as(f64, planeHeight) - playerPos[2]);
	c.glUniform1f(uniforms.planeHeightRelative, planeHeightRelative);

	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));
	// The quad's local XY *is* player-relative XY directly (see planeHalfSize's doc comment), so the
	// fragment shader only needs to add true world XY (playerPos.xy) to recover an absolute noise
	// coordinate — anchors the wispy pattern to real world position (stable as the player moves) rather
	// than just drifting with wind, same idea as clouds.zig's coverage field.
	const playerXY = Vec2f{@floatCast(playerPos[0]), @floatCast(playerPos[1])};
	const noiseOrigin = playerXY + windOffset;
	c.glUniform2fv(uniforms.noiseOrigin, 1, @ptrCast(&noiseOrigin));

	vao.bind();
	c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null);
}
