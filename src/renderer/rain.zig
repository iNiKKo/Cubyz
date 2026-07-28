const std = @import("std");

const main = @import("main");
const settings = main.settings;
const graphics = main.graphics;
const game = main.game;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const Vec3i = vec.Vec3i;
const Mat4f = vec.Mat4f;

const c = @import("c");

const mesh_storage = @import("mesh_storage.zig");

// MARK: Rain — see settings.rain's doc comment: a first, deliberately simple pass, not a full weather
// system. Real falling raindrop quads (unlike the god-ray glow, which is a screen-space fake — clouds.zig
// established the pattern of using actual geometry instead), spawned only in a small AOE grid around the
// player rather than across the whole loaded world.
//
// Each grid cell either has one falling drop or doesn't (a per-cell hash decides, fixed for that cell —
// same "coverage never flip-flops, only the animation moves" idea clouds.zig uses for wind). An active
// cell's drop falls in a continuous loop from a height above the player down to that *column's actual
// ground* (see findGroundZ — not a fixed height below the player, so rain over a cliff edge keeps
// falling past where the player is standing instead of stopping level with their feet), wrapping back to
// the top the instant it reaches the ground, with a per-cell phase offset so drops don't all reset in
// unison. Every drop is a small thin quad billboarded around the vertical axis only (built CPU-side each
// frame from one shared camera-derived horizontal "right" vector, not a full per-drop billboard), which
// reads as a rectangle from any horizontal viewing angle without needing per-vertex billboard math.

/// World-space size of one grid cell, along both horizontal axes.
const cellSize: f32 = 0.50;
/// Half-extent (blocks) of the square AOE grid around the player.
const gridRadius: f32 = 22.0;
/// Upper bound on cells per side.
const maxGridDim: u32 = 96;

const dropWidth: f32 = 0.08;
const dropHeight: f32 = 0.75;
const fallSpeed: f32 = 36.0; // blocks/second
/// How far above the player each column's fall starts. Raised so rain visibly falls from well overhead
/// rather than seeming to start right at head height, especially now that the fall can extend much
/// further down than this near a cliff edge (see findGroundZ).
const fallRangeAbovePlayer: f64 = 22.0;
/// How far above the player to start searching for the actual ground below each drop (see findGroundZ) —
/// not the fall's start height, just a margin covering slopes/small rises so the search doesn't have to
/// begin all the way up at fallRangeAbovePlayer.
const groundScanAboveMargin: f64 = 8.0;
/// How far below the player findGroundZ gives up looking for solid ground (a deep cliff/ravine/void) and
/// just lets the drop fall that far before looping — keeps the worst case bounded instead of scanning
/// indefinitely into open air.
const groundScanMaxDepth: f64 = 12.0;
/// The player's *eye* Z (what playerPos below actually is — see main.zig's `render(game.Player.
/// getEyePosBlocking(), ...)`) bobs with crouch (Player.eye.desiredPos shifts smoothly but with no
/// change to the player's real world position at all) and rises through a jump's arc. Using it directly
/// as the vertical anchor for the fall range made the *entire* rain pattern visibly shift on both —
/// topZ/groundZ's search window would recompute every frame relative to whatever the eye happened to be
/// doing, rather than staying anchored to the world. Instead, the anchor is the player's true physics
/// position (`game.Player.getPosBlocking()`, unaffected by crouch's eye-only offset) snapped down to the
/// nearest verticalAnchorSnap — so small, continuous vertical motion (crouch bob entirely, and a normal
/// jump's ~1.25-block arc in all but the rare case of already sitting right at a snap boundary) doesn't
/// shift the rain pattern at all, while a real sustained elevation change (climbing, falling, teleporting)
/// still eventually moves it once it crosses a snap boundary.
const verticalAnchorSnap: f64 = 4.0;
/// Fraction of grid cells that actually contain a falling drop, at full (1.0) rain intensity — scaled
/// down linearly by the current rainIntensity in update() so light drizzle looks sparser than a downpour.
const maxActiveDensity: f32 = 0.95;
const dropColor = Vec3f{0.6, 0.7, 0.9};
const dropAlpha: f32 = 0.40; // Translucent liquid raindrops

const RainVertex = extern struct {
	pos: [3]f32,
	color: [3]f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{.location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(@This(), "pos")},
		.{.location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(@This(), "color")},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	alpha: c_int,
} = undefined;
var vao: graphics.VertexArray = undefined;

var indexCount: u32 = 0;

var startTimestamp: std.Io.Timestamp = undefined;

pub fn init() void {
	startTimestamp = main.timestamp();
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/rain_vertex.vert",
		"assets/cubyz/shaders/rain_fragment.frag",
		"",
		&uniforms,
		RainVertex,
		&.{},
		.{.cullMode = .none},
		.{.depthTest = true, .depthWrite = false},
		.{.attachments = &.{.alphaBlending}},
	);
	vao = .init(RainVertex, &.{}, &.{});
}

pub fn deinit() void {
	pipeline.deinit();
	vao.deinit();
}

/// Cheap deterministic per-cell hash, purely for "does this cell have a drop"/"what's its phase" — not
/// used for anything requiring real randomness quality.
fn hashCell(gx: i64, gy: i64) f32 {
	const ux: u64 = @bitCast(gx);
	const uy: u64 = @bitCast(gy);
	var h: u64 = ux *% 0x9E3779B97F4A7C15 +% uy *% 0xC2B2AE3D27D4EB4F +% 0xA24BAED4963EE407;
	h ^= h >> 33;
	h *%= 0xFF51AFD7ED558CCD;
	h ^= h >> 33;
	return @as(f32, @floatFromInt(h & 0xFFFFFF))/@as(f32, @floatFromInt(@as(u32, 0xFFFFFF)));
}

/// Height (world Z) a drop falling straight down through this column actually lands at, i.e. the top of
/// the first solid block found scanning downward from above the fall range top. Starts scanning from
/// above fallRangeAbovePlayer so tree canopies, leaves, and roofs above head height are properly hit.
fn findGroundZ(worldX: f64, worldY: f64, anchorZ: f64) f64 {
	const blockX: i32 = @intFromFloat(@floor(worldX));
	const blockY: i32 = @intFromFloat(@floor(worldY));
	const scanTop: i32 = @intFromFloat(@floor(anchorZ + fallRangeAbovePlayer + 4.0));
	const scanBottom: i32 = @intFromFloat(@floor(anchorZ - groundScanMaxDepth));
	var z = scanTop;
	while (z >= scanBottom) : (z -= 1) {
		const block = mesh_storage.getBlockFromRenderThread(blockX, blockY, z) orelse continue;
		if (block.typ != 0) return @floatFromInt(z + 1);
	}
	return anchorZ - 4.0;
}

const ValueNoise = main.server.terrain.noise.ValueNoise;
const rainNoiseScale: f32 = 64.0;
const rainWorldSeed: u64 = 0x5a4b3c2d1e0f9887;

/// Evaluates fixed world-position rain noise. Uses a sharp edge transition (edgeWidth = 0.02) to produce
/// a distinct, visible vertical rain curtain/wall where rain starts and stops in the world.
fn getSpatialRainIntensity(worldX: f64, worldY: f64, globalRainIntensity: f32) f32 {
	if (globalRainIntensity <= 0.01) return 0.0;
	const nx: f32 = @floatCast(worldX / rainNoiseScale);
	const ny: f32 = @floatCast(worldY / rainNoiseScale);
	const n = ValueNoise.samplePoint2D(nx, ny, rainWorldSeed);
	
	const threshold: f32 = 0.46;
	const edgeWidth: f32 = 0.02;
	
	const factor = std.math.clamp((n - (threshold - edgeWidth)) / (2.0 * edgeWidth), 0.0, 1.0);
	return globalRainIntensity * factor;
}

/// Rebuilds the raindrop-quad mesh every frame with per-voxel light sampling.
pub fn update(playerPos: Vec3d, viewMatrix: Mat4f, ambientLight: Vec3f) void {
	const cloudBaseHeight: f64 = 288.0;
	// Hard cap: If player is standing at or above clouds (Z >= 286), no rain spawns!
	if (!settings.rain or playerPos[2] >= cloudBaseHeight - 2.0) {
		indexCount = 0;
		return;
	}
	const globalRainIntensity = game.world.?.dayTime.rainIntensity;
	if (globalRainIntensity <= 0.01) {
		indexCount = 0;
		return;
	}
	// Desert biomes (dry & hot) never get rain
	const playerBiome = game.world.?.playerBiome.load(.monotonic);
	if (playerBiome.properties.dry and playerBiome.properties.hot) {
		indexCount = 0;
		return;
	}

	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);

	const anchorZ: f64 = @floor(game.Player.getPosBlocking()[2]/verticalAnchorSnap)*verticalAnchorSnap;

	var camRight = Vec3f{viewMatrix.rows[0][0], viewMatrix.rows[0][1], 0};
	if (vec.dot(camRight, camRight) < 1e-8) camRight = Vec3f{1, 0, 0};
	camRight = vec.normalize(camRight);
	const up = Vec3f{0, 0, 1};

	const gridDim: u32 = std.math.clamp(@as(u32, @intFromFloat(@ceil(2*gridRadius/cellSize))), 4, maxGridDim);
	const originCellX: i64 = @intFromFloat(@floor(playerPos[0]/cellSize) - @as(f64, @floatFromInt(gridDim))/2);
	const originCellY: i64 = @intFromFloat(@floor(playerPos[1]/cellSize) - @as(f64, @floatFromInt(gridDim))/2);

	var vertices: main.ListManaged(RainVertex) = .init(main.stackAllocator);
	defer vertices.deinit();
	var indices: main.ListManaged(u32) = .init(main.stackAllocator);
	defer indices.deinit();

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			const worldCellX = originCellX + @as(i64, @intCast(cx));
			const worldCellY = originCellY + @as(i64, @intCast(cy));

			const jitterX = (hashCell(worldCellX +% 91, worldCellY) - 0.5)*cellSize*0.8;
			const jitterY = (hashCell(worldCellX, worldCellY +% 91) - 0.5)*cellSize*0.8;
			const phase = hashCell(worldCellX +% 173, worldCellY +% 271);

			const worldX: f64 = (@as(f64, @floatFromInt(worldCellX)) + 0.5)*cellSize + jitterX;
			const worldY: f64 = (@as(f64, @floatFromInt(worldCellY)) + 0.5)*cellSize + jitterY;

			const cellRainIntensity = getSpatialRainIntensity(worldX, worldY, globalRainIntensity);
			if (cellRainIntensity <= 0.01) continue;
			const activeDensity = cellRainIntensity * maxActiveDensity;
			if (hashCell(worldCellX, worldCellY) > activeDensity) continue;

			// Distance-from-player fade so drops don't just pop in/out at the AOE grid's square edge.
			const dx: f32 = @floatCast(worldX - playerPos[0]);
			const dy: f32 = @floatCast(worldY - playerPos[1]);
			const edgeDist = @sqrt(dx*dx + dy*dy)/gridRadius;
			if (edgeDist >= 1.0) continue;

			// Hard cap topZ under cloudBaseHeight (288.0)
			const topZ: f64 = @min(anchorZ + fallRangeAbovePlayer, cloudBaseHeight - 1.0);
			const groundZ: f64 = findGroundZ(worldX, worldY, anchorZ);
			if (topZ <= groundZ) continue;
			const range: f32 = @max(@as(f32, @floatCast(topZ - groundZ)), 1.0);
			const loopFrac = @mod(elapsedSeconds*fallSpeed/range + phase, 1.0);
			const dropZ: f64 = topZ - @as(f64, loopFrac*range);

			const center = Vec3f{
				@floatCast(worldX - playerPos[0]),
				@floatCast(worldY - playerPos[1]),
				@floatCast(dropZ - playerPos[2]),
			};

			// Real-time voxel light sampling at the drop's world position
			const dropBlockX: i32 = @intFromFloat(@floor(worldX));
			const dropBlockY: i32 = @intFromFloat(@floor(worldY));
			const dropBlockZ: i32 = @intFromFloat(@floor(dropZ));
			const light: [6]u8 = mesh_storage.getLight(dropBlockX, dropBlockY, dropBlockZ) orelse [6]u8{255, 255, 255, 0, 0, 0};
			const sunLight: Vec3f = ambientLight * @as(Vec3f, @floatFromInt(Vec3i{light[0], light[1], light[2]})) / @as(Vec3f, @splat(255.0));
			const blockLight: Vec3f = @as(Vec3f, @floatFromInt(Vec3i{light[3], light[4], light[5]})) / @as(Vec3f, @splat(255.0));
			const lightFactor = @min(@as(Vec3f, @splat(1.0)), @sqrt(sunLight*sunLight + blockLight*blockLight) + @as(Vec3f, @splat(0.04)));
			const vertexColor: Vec3f = dropColor * lightFactor;
			const colorArray: [3]f32 = .{vertexColor[0], vertexColor[1], vertexColor[2]};

			const halfWidth: Vec3f = @as(Vec3f, @splat(dropWidth*0.5))*camRight;
			const halfHeight: Vec3f = @as(Vec3f, @splat(dropHeight*0.5))*up;

			const base: u32 = @intCast(vertices.items.len);
			vertices.append(.{.pos = center - halfWidth - halfHeight, .color = colorArray});
			vertices.append(.{.pos = center + halfWidth - halfHeight, .color = colorArray});
			vertices.append(.{.pos = center + halfWidth + halfHeight, .color = colorArray});
			vertices.append(.{.pos = center - halfWidth + halfHeight, .color = colorArray});
			indices.append(base + 0);
			indices.append(base + 1);
			indices.append(base + 2);
			indices.append(base + 0);
			indices.append(base + 2);
			indices.append(base + 3);
		}
	}

	indexCount = @intCast(indices.items.len);
	vao.update(RainVertex, vertices.items, indices.items);
}

pub fn draw() void {
	if (indexCount == 0) return;

	pipeline.bind(null);
	vao.bind();

	c.glUniform1f(uniforms.alpha, dropAlpha);

	c.glDrawElements(c.GL_TRIANGLES, @intCast(indexCount), c.GL_UNSIGNED_INT, null);
}
