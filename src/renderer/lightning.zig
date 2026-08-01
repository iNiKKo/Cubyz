const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const game = main.game;
const vec = main.vec;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const c = @import("c");

const Vertex = extern struct {
	position: Vec3f,

	pub const attributeDescriptions = &[_]c.VkVertexInputAttributeDescription{.{
		.binding = 0,
		.location = 0,
		.format = c.VK_FORMAT_R32G32B32_SFLOAT,
		.offset = @offsetOf(Vertex, "position"),
	}};
};

var pipeline: graphics.Pipeline = undefined;
var vao: graphics.VertexArray = undefined;

pub fn init() void {
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/lightning.vert",
		"assets/cubyz/shaders/lightning.frag",
		"",
		&.{},
		Vertex,
		&.{},
		.{.cullMode = .none, .lineWidth = 1.0},
		.{.depthTest = true, .depthWrite = false},
		.{.attachments = &.{.alphaBlending}},
	);
	vao = .init(Vertex, &[_]Vertex{.{.position = .{0, 0, 0}}}, null);
}

pub fn deinit() void {
	pipeline.deinit();
	vao.deinit();
}

pub fn draw(playerPos: Vec3d) void {
	const world = game.world orelse return;
	const event = world.weatherLightning.snapshot();
	const elapsed = @as(f32, @floatFromInt(event.time.durationTo(main.timestamp()).toNanoseconds()))*1e-9;
	if (elapsed < 0.0 or elapsed >= 0.28 or world.dayTime.lightningFlash <= 0.01) return;

	const pointsPerStrand = 13;
	const strandOffsets = [_][2]f32{ .{0, 0}, .{-0.55, 0.25}, .{0.55, -0.25}, .{-0.2, -0.55}, .{0.2, 0.55} };
	var vertices: [pointsPerStrand*strandOffsets.len]Vertex = undefined;
	var seed: u64 = @intCast(event.time.toMilliseconds());
	for (strandOffsets, 0..) |offset, strand| {
		for (0..pointsPerStrand) |point| {
			const t = @as(f32, @floatFromInt(point))/@as(f32, @floatFromInt(pointsPerStrand - 1));
			seed = seed *% 6364136223846793005 +% 1442695040888963407;
			const jitterX: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(seed >> 32))))))/32768.0*9.0;
			seed = seed *% 6364136223846793005 +% 1442695040888963407;
			const jitterY: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(seed >> 32))))))/32768.0*9.0;
			vertices[strand*pointsPerStrand + point].position = .{
				@floatCast(event.position[0] - playerPos[0] + @as(f64, jitterX + offset[0])),
				@floatCast(event.position[1] - playerPos[1] + @as(f64, jitterY + offset[1])),
				@floatCast(event.position[2] - playerPos[2] - @as(f64, t)*720.0),
			};
		}
	}
	vao.update(Vertex, &vertices, null);
	pipeline.bind(null);
	vao.bind();
	for (0..strandOffsets.len) |strand| {
		c.glDrawArrays(c.GL_LINE_STRIP, @intCast(strand*pointsPerStrand), pointsPerStrand);
	}
}
