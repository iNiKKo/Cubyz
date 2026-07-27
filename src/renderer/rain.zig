const std = @import("std");

const main = @import("main");
const settings = main.settings;
const graphics = main.graphics;
const game = main.game;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
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
const cellSize: f32 = 1.8;
/// Half-extent (blocks) of the square AOE grid around the player — rain only ever spawns within this
/// area, deliberately small and independent of render/shadow distance (see the request this answers:
/// "3D AOE rain... that only actually spawn around the player").
const gridRadius: f32 = 20.0;
/// Upper bound on cells per side, sized generously above gridRadius*2/cellSize so the fixed-size backing
/// arrays never need runtime allocation even if gridRadius is raised later.
const maxGridDim: u32 = 32;

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
const groundScanMaxDepth: f64 = 48.0;
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
/// Fraction of grid cells that actually contain a falling drop.
const activeDensity: f32 = 0.85;
const dropColor = Vec3f{0.6, 0.7, 0.9};
const dropAlpha: f32 = 0.75;

const RainVertex = extern struct {
	pos: [3]f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{.location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(@This(), "pos")},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	tint: c_int,
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
/// the first solid block found scanning downward from groundScanAboveMargin above the player. Without
/// this, every column looped between the same fixed height above/below the *player's* Z regardless of
/// what's actually underneath — so standing at the edge of a cliff, rain over the drop-off stopped at
/// the same height as rain over solid ground next to it, instead of continuing down until it actually
/// hit something. Gives up and returns the bottom of the scanned range if nothing solid turns up within
/// groundScanMaxDepth (an open void/very deep drop), rather than scanning indefinitely.
fn findGroundZ(worldX: f64, worldY: f64, anchorZ: f64) f64 {
	const blockX: i32 = @intFromFloat(@floor(worldX));
	const blockY: i32 = @intFromFloat(@floor(worldY));
	const scanTop: i32 = @intFromFloat(@floor(anchorZ + groundScanAboveMargin));
	const scanBottom: i32 = @intFromFloat(@floor(anchorZ - groundScanMaxDepth));
	var z = scanTop;
	while (z >= scanBottom) : (z -= 1) {
		const block = mesh_storage.getBlockFromRenderThread(blockX, blockY, z) orelse continue;
		if (block.typ != 0) return @floatFromInt(z + 1);
	}
	return @floatFromInt(scanBottom);
}

/// Rebuilds the raindrop-quad mesh every frame — cheap enough (at most maxGridDim² small quads, and the
/// grid itself is intentionally small per gridRadius) that there's no need for clouds.zig's
/// coverage-texture-sharing trick; rain doesn't cast shadows and nothing else needs to sample its shape.
pub fn update(playerPos: Vec3d, viewMatrix: Mat4f) void {
	if (!settings.rain) {
		indexCount = 0;
		return;
	}

	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);

	// See verticalAnchorSnap's doc comment: deliberately not playerPos[2] (the eye position, which bobs
	// with crouch and rises through a jump) — the true physics position, snapped to a coarse grid, so the
	// fall range doesn't visibly shift with either.
	const anchorZ: f64 = @floor(game.Player.getPosBlocking()[2]/verticalAnchorSnap)*verticalAnchorSnap;

	// Camera's world-space right vector, flattened to the horizontal plane — shared by every drop this
	// frame so each quad reads as an upright rectangle facing the camera in yaw, without needing a
	// per-drop billboard basis (drops are small/thin enough that the shared approximation is unnoticeable).
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
			if (hashCell(worldCellX, worldCellY) > activeDensity) continue;

			const jitterX = (hashCell(worldCellX +% 91, worldCellY) - 0.5)*cellSize*0.8;
			const jitterY = (hashCell(worldCellX, worldCellY +% 91) - 0.5)*cellSize*0.8;
			const phase = hashCell(worldCellX +% 173, worldCellY +% 271);

			const worldX: f64 = (@as(f64, @floatFromInt(worldCellX)) + 0.5)*cellSize + jitterX;
			const worldY: f64 = (@as(f64, @floatFromInt(worldCellY)) + 0.5)*cellSize + jitterY;

			// Distance-from-player fade so drops don't just pop in/out at the AOE grid's square edge.
			const dx: f32 = @floatCast(worldX - playerPos[0]);
			const dy: f32 = @floatCast(worldY - playerPos[1]);
			const edgeDist = @sqrt(dx*dx + dy*dy)/gridRadius;
			if (edgeDist >= 1.0) continue;

			// Continuous downward loop from fallRangeAbovePlayer down to this column's actual ground
			// height (not a fixed offset below the player — see findGroundZ), staggered per-cell by
			// `phase` so drops don't all reset to the top in unison. fallSpeed stays constant regardless
			// of the column's range, so a drop over a cliff edge visibly falls further before looping,
			// rather than looping faster/slower to fit a fixed distance.
			const topZ: f64 = anchorZ + fallRangeAbovePlayer;
			const groundZ: f64 = findGroundZ(worldX, worldY, anchorZ);
			const range: f32 = @max(@as(f32, @floatCast(topZ - groundZ)), 1.0);
			const loopFrac = @mod(elapsedSeconds*fallSpeed/range + phase, 1.0);
			const dropZ: f64 = topZ - @as(f64, loopFrac*range);

			const center = Vec3f{
				@floatCast(worldX - playerPos[0]),
				@floatCast(worldY - playerPos[1]),
				@floatCast(dropZ - playerPos[2]),
			};

			const halfWidth: Vec3f = @as(Vec3f, @splat(dropWidth*0.5))*camRight;
			const halfHeight: Vec3f = @as(Vec3f, @splat(dropHeight*0.5))*up;

			const base: u32 = @intCast(vertices.items.len);
			vertices.append(.{.pos = center - halfWidth - halfHeight});
			vertices.append(.{.pos = center + halfWidth - halfHeight});
			vertices.append(.{.pos = center + halfWidth + halfHeight});
			vertices.append(.{.pos = center - halfWidth + halfHeight});
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

	c.glUniform3fv(uniforms.tint, 1, @ptrCast(&dropColor));
	c.glUniform1f(uniforms.alpha, dropAlpha);

	c.glDrawElements(c.GL_TRIANGLES, @intCast(indexCount), c.GL_UNSIGNED_INT, null);
}
