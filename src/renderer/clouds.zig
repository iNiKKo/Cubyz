const std = @import("std");

const main = @import("main");
const settings = main.settings;
const game = main.game;
const graphics = main.graphics;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const ValueNoise = main.server.terrain.noise.ValueNoise;

const c = @import("c");

const cellSize: f32 = 40.0;
const cellSizeD: f64 = cellSize;
const maxGridDim: u32 = 208;
const cloudBaseHeight: f32 = 288.0;
const cloudThickness: f32 = 10.0;
const cloudScale: f32 = 160.0;
const detailScale: f32 = 103.0;
const detailWeight: f32 = 0.14;
// REGRESSION, FIXED (2026-07-28): coverageThreshold was made a per-frame var here, lerped by rain
// intensity, on the theory that easing the threshold smoothly would make cloud cover fade in/out smoothly
// too. It doesn't: coverage (see sampleCoverage/the `coverage[]` mask built in update()) is a *binary*
// per-cell mask — `value > coverageThreshold` — so as the threshold drifts, individual cells flip from
// air to cloud (or back) at the exact instant their fixed noise value crosses it, discretely, not
// gradually. Worse, the morphological cleanup passes (minClusterCells pruning, neck severing) mean a
// single cell flipping can complete or break a whole cluster's connectivity, so an entire cloud shape can
// pop into or out of existence in one frame — reported in-game as "something vanished and reappeared
// close to it." A boolean mask cannot fade smoothly no matter how smoothly the threshold controlling it
// changes. coverageThreshold is back to its original fixed constant — cloud *shape*/placement is always
// pure spatial noise, never touched by weather (both cloud layers below reuse this exact same coverage
// grid/shape; weather fades the storm layer's alpha in on top, see stormLayer* below).
const coverageThreshold: f32 = 0.65;
// REGRESSION, FIXED (2026-07-28): the base cloud layer's alpha was also made weather-dependent
// (0.12 clear -> 0.65 full rain), which made normal/dry-weather clouds render almost invisible — reported
// as "the clouds are now very sky coloured, they lost their original look." baseAlpha is back to its
// original fixed 0.65, completely unaffected by weather, restoring the pre-weather-system look exactly.
// Weather is now represented by a *second*, independent cloud layer instead — see stormLayer below and
// the player's own suggestion ("spawn a second thicker cloud layer... make it thicker and darker" rather
// than distorting the existing layer's look).
const baseAlpha: f32 = 0.65;
const minClusterCells: u32 = 8;
const windVelocity = Vec2f{2.0, 0.8};
const cloudSeed: u64 = 0x63756279_7a636c64;
const detailSeed: u64 = cloudSeed ^ 0x9e3779b97f4a7c15;
/// Storm layer's own independent noise seeds — a genuinely separate cloud formation, not derived from the
/// base layer's shape at all (see stormGap's doc comment for why "derived from" approaches kept failing).
const stormCloudSeed: u64 = cloudSeed ^ 0x51ed270a4b204d29;
const stormDetailSeed: u64 = stormCloudSeed ^ 0x9e3779b97f4a7c15;

/// A second slab of cloud geometry with its *own independent noise sample* (stormCloudSeed/
/// stormDetailSeed) run through the exact same morphological cleanup as the base layer (see
/// computeCloudCoverage) — a genuinely separate cloud formation, not derived from the base layer's shape.
/// Fades in via alpha as rain intensity rises. Continuous by construction (alpha blending), so it
/// structurally can't pop the way toggling coverage cells would.
//
// Two things were tried here and failed before landing on "independent noise sample":
// REGRESSION 1: reused the *same* coverage as the base layer, just offset a few blocks higher. Since the
// two shapes were identical and directly adjacent, they visually merged into what looked like one taller,
// darker cloud mass — reported as "why is the second layer on top of the first? it should be where the
// first layer is not."
// REGRESSION 2: switched to the literal *complement* of the base coverage (every cell the base layer
// doesn't occupy). Since the base layer's clouds only cover a modest fraction of the sky, their complement
// is one enormous, mostly-connected region — the greedy mesh-merger turned that into one or a few giant
// rectangular slabs, reported as "covers more than just the biome, it's like a big dark box all around
// rather than actual clouds," and that same dominant slab (sitting almost coplanar with the base layer)
// is very likely what made the base layer read as "gone" too.
// FIX: storm coverage is its own independent noise sample (computeCloudCoverage(..., excludeMask =
// &coverage)) — naturally sparse and cloud-shaped like the base layer (same sampleCoverage/threshold/
// morphological-cleanup machinery, just a different seed), with excludeMask zeroing out any cell the base
// layer already claimed *before* cleanup runs, so storm clusters form their own compact shapes in the
// remaining space rather than either merging with or engulfing the base layer's clouds.
//
// Also fixed: the storm layer was darkened *twice* — once via a `tint * 0.6` uniform multiplier, again
// via separately-tuned darker per-vertex brightness constants — the two multiply together into a much
// bigger, inconsistent drop than either alone, which read as "different colour... different technique for
// colouring in." Now uses the *same* topBrightness/sideBrightness/bottomBrightness constants as the base
// layer (one shared per-vertex mechanism) and only stormTintFactor (a single multiplier in draw()) as the
// one, sole darkening knob.
const stormGap: f32 = 1.0;
const stormThickness: f32 = 10.0;
const stormAlphaFullRain: f32 = 0.65; // Same opacity (baseAlpha = 0.65) as the first cloud layer
const stormCoverageThreshold: f32 = 0.60; // Puffy cloud coverage in sky gaps, not a giant block
const stormMaxClusterCells: u32 = 25; // Compact puffy cloud clusters matching base layer
const stormMaxClusterDim: u32 = 4; // Max 4x4 cells (~160x160 blocks) matching base layer
const stormTintFactor: f32 = 1.0; // 100% exact same color as the first cloud layer

const topBrightness: f32 = 1.0;
const sideBrightness: f32 = 0.9;
const bottomBrightness: f32 = 0.8;

const CloudVertex = extern struct {
	pos: [3]f32,
	brightness: f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{.location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(@This(), "pos")},
		.{.location = 1, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(@This(), "brightness")},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	tint: c_int,
	baseAlpha: c_int,
} = undefined;
var vao: graphics.VertexArray = undefined;
/// Storm layer's own VAO — same pipeline/shader/vertex format as the base layer (no need for a second
/// graphics.Pipeline, just a second buffer bound before its own draw call with different uniform values).
var stormVao: graphics.VertexArray = undefined;

var indexCount: u32 = 0;
var stormIndexCount: u32 = 0;

/// One coverage byte (0 or 255) per grid cell, uploaded as a small texture purely so shadow.glsl's
/// sampleCloudShadow can test against the *exact* same per-cell coverage the visible mesh was built
/// from — sharing this array is what keeps the shadow shape from ever drifting out of sync with the
/// mesh above it. Sized to maxGridDim (the worst case); only the [0, gridDim) sub-range update() computes
/// each frame is meaningful.
var coverage: [maxGridDim*maxGridDim]u8 = undefined;
/// Storm layer's coverage — the *complement* of `coverage` (only cells the base layer's clouds don't
/// occupy), computed once per frame in update() by a plain per-cell inversion, no separate noise/
/// morphology pass needed. This is what makes the storm layer fill in the gaps between existing clouds
/// rather than sit directly on top of them (see stormGap's doc comment for why that changed).
var stormCoverage: [maxGridDim*maxGridDim]u8 = undefined;
var coverageTextureId: c_uint = 0;

/// Player-relative XY origin (world-space, minus playerPos.xy) of the coverage grid this frame.
pub var coverageOriginRelative: Vec2f = .{0, 0};
pub var coverageWorldSize: f32 = 0;
/// Height of the middle of the cloud layer, relative to the player's current Z — for the
/// shadow ray/plane test in shadow.glsl.
pub var cloudHeightRelative: f32 = 0;
pub var coverageTexture: c_uint = 0;

/// Reference point for wind animation. gameTime (used elsewhere for the day/night cycle) only
/// advances once per 100ms simulation tick — sampling it once per *render* frame would make the
/// clouds visibly stair-step at normal framerates, since it doesn't change most frames. Real elapsed
/// time gives smooth per-frame motion instead.
var startTimestamp: std.Io.Timestamp = undefined;

pub fn init() void {
	startTimestamp = main.timestamp();
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/clouds_vertex.vert",
		"assets/cubyz/shaders/clouds_fragment.frag",
		"",
		&uniforms,
		CloudVertex,
		&.{},
		.{.cullMode = .none},
		.{.depthTest = true, .depthWrite = false},
		.{.attachments = &.{.alphaBlending}},
	);
	vao = .init(CloudVertex, &.{}, &.{});
	stormVao = .init(CloudVertex, &.{}, &.{});

	c.glGenTextures(1, &coverageTextureId);
	c.glBindTexture(c.GL_TEXTURE_2D, coverageTextureId);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_BORDER);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_BORDER);
	const borderColor = [4]f32{0, 0, 0, 0}; // No cloud data outside the grid => no cloud, no cloud shadow.
	c.glTexParameterfv(c.GL_TEXTURE_2D, c.GL_TEXTURE_BORDER_COLOR, &borderColor);
	c.glBindTexture(c.GL_TEXTURE_2D, 0);

	coverageTexture = coverageTextureId;
}

pub fn deinit() void {
	pipeline.deinit();
	vao.deinit();
	stormVao.deinit();
	c.glDeleteTextures(1, &coverageTextureId);
}

fn sampleCoverageWithSeeds(worldX: f64, worldY: f64, layerCloudSeed: u64, layerDetailSeed: u64, layerCoverageThreshold: f32) bool {
	const baseX: f32 = @floatCast(worldX/cloudScale);
	const baseY: f32 = @floatCast(worldY/cloudScale);
	const detailX: f32 = @floatCast(worldX/detailScale);
	const detailY: f32 = @floatCast(worldY/detailScale);
	const base = ValueNoise.samplePoint2D(baseX, baseY, layerCloudSeed);
	const detail = ValueNoise.samplePoint2D(detailX, detailY, layerDetailSeed);
	const value = base*(1 - detailWeight) + detail*detailWeight;
	return value > layerCoverageThreshold;
}

/// isPlayerInsideCloud/getCloudAttenuationForDirection deliberately only ever test the *base* cloud
/// layer, not the storm layer — "is the player inside a cloud" is a gameplay/visibility concept tied to
/// the visible base clouds, not a weather-specific overlay.
fn sampleCoverage(worldX: f64, worldY: f64) bool {
	return sampleCoverageWithSeeds(worldX, worldY, cloudSeed, detailSeed, coverageThreshold);
}

pub fn isPlayerInsideCloud(playerPos: Vec3d) bool {
	if (!settings.clouds) return false;
	const z = playerPos[2];
	if (z < cloudBaseHeight or z > cloudBaseHeight + cloudThickness) return false;
	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));
	const worldX = playerPos[0] - @as(f64, windOffset[0]);
	const worldY = playerPos[1] - @as(f64, windOffset[1]);
	return sampleCoverage(worldX, worldY);
}


/// Builds one slab's worth of cloud mesh (greedy-merged top/bottom rectangles + per-cell side walls) from
/// the shared `coverage` grid, at the given Z range and brightness. Used for both the base layer and the
/// storm layer — same shape/coverage, different height/thickness/tint, so weather never needs its own
/// noise or morphological cleanup pass.
fn buildLayerMesh(
	layerCoverage: []const u8,
	vertices: *main.ListManaged(CloudVertex),
	indices: *main.ListManaged(u32),
	gridDim: u32,
	originX: f64,
	originY: f64,
	playerPos: Vec3d,
	windOffset: Vec2f,
	relZBase: f32,
	relZTop: f32,
	layerTopBrightness: f32,
	layerSideBrightness: f32,
	layerBottomBrightness: f32,
) void {
	var visitedTop: [maxGridDim * maxGridDim]bool = @splat(false);
	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			if (layerCoverage[cy * gridDim + cx] == 0 or visitedTop[cy * gridDim + cx]) continue;

			var w: u32 = 1;
			while (cx + w < gridDim and layerCoverage[cy * gridDim + cx + w] != 0 and !visitedTop[cy * gridDim + cx + w]) : (w += 1) {}

			var h: u32 = 1;
			expandY: while (cy + h < gridDim) : (h += 1) {
				for (0..w) |dx| {
					const checkIdx = (cy + h) * gridDim + cx + dx;
					if (layerCoverage[checkIdx] == 0 or visitedTop[checkIdx]) break :expandY;
				}
			}

			for (0..h) |dy| {
				for (0..w) |dx| {
					visitedTop[(cy + dy) * gridDim + cx + dx] = true;
				}
			}

			const gx0: i64 = @intCast(cx);
			const gy0: i64 = @intCast(cy);
			const gx1: i64 = @intCast(cx + w);
			const gy1: i64 = @intCast(cy + h);

			const x0 = relCoordAt(gx0, originX, playerPos[0], windOffset[0]);
			const y0 = relCoordAt(gy0, originY, playerPos[1], windOffset[1]);
			const x1 = relCoordAt(gx1, originX, playerPos[0], windOffset[0]);
			const y1 = relCoordAt(gy1, originY, playerPos[1], windOffset[1]);

			addQuad(vertices, indices, .{x0, y0, relZTop}, .{x0, y1, relZTop}, .{x1, y1, relZTop}, .{x1, y0, relZTop}, layerTopBrightness);
			addQuad(vertices, indices, .{x0, y1, relZBase}, .{x0, y0, relZBase}, .{x1, y0, relZBase}, .{x1, y1, relZBase}, layerBottomBrightness);
		}
	}

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			if (layerCoverage[cy * gridDim + cx] == 0) continue;

			const gx0: i64 = @intCast(cx);
			const gy0: i64 = @intCast(cy);
			const gx1: i64 = gx0 + 1;
			const gy1: i64 = gy0 + 1;

			const wallX0 = relCoordAt(gx0, originX, playerPos[0], windOffset[0]);
			const wallY0 = relCoordAt(gy0, originY, playerPos[1], windOffset[1]);
			const wallX1 = relCoordAt(gx1, originX, playerPos[0], windOffset[0]);
			const wallY1 = relCoordAt(gy1, originY, playerPos[1], windOffset[1]);

			const hasLeft = cx > 0 and layerCoverage[cy * gridDim + cx - 1] != 0;
			const hasRight = cx + 1 < gridDim and layerCoverage[cy * gridDim + cx + 1] != 0;
			const hasUp = cy > 0 and layerCoverage[(cy - 1) * gridDim + cx] != 0;
			const hasDown = cy + 1 < gridDim and layerCoverage[(cy + 1) * gridDim + cx] != 0;

			if (!hasLeft) addQuad(vertices, indices, .{wallX0, wallY1, relZTop}, .{wallX0, wallY0, relZTop}, .{wallX0, wallY0, relZBase}, .{wallX0, wallY1, relZBase}, layerSideBrightness);
			if (!hasRight) addQuad(vertices, indices, .{wallX1, wallY0, relZTop}, .{wallX1, wallY1, relZTop}, .{wallX1, wallY1, relZBase}, .{wallX1, wallY0, relZBase}, layerSideBrightness);
			if (!hasUp) addQuad(vertices, indices, .{wallX0, wallY0, relZTop}, .{wallX1, wallY0, relZTop}, .{wallX1, wallY0, relZBase}, .{wallX0, wallY0, relZBase}, layerSideBrightness);
			if (!hasDown) addQuad(vertices, indices, .{wallX1, wallY1, relZTop}, .{wallX0, wallY1, relZTop}, .{wallX0, wallY1, relZBase}, .{wallX1, wallY1, relZBase}, layerSideBrightness);
		}
	}
}

/// Samples a coverage grid from scratch (a layer's own noise seed pair) and runs it through the full
/// morphological cleanup pipeline (neck severing, thin-protrusion erosion, size-based flood-fill pruning/
/// splitting, minimum inter-cluster spacing, hollow-pocket filling) that keeps cloud shapes compact and
/// chunky rather than a raw noisy blob. Used for both the base and storm layers — same machinery, just a
/// different seed pair — see stormGap's doc comment for why the storm layer needs its own independent
/// sample rather than being derived from the base layer's shape.
///
/// `excludeMask`, when given, zeros out any cell already claimed there *before* cleanup runs, so this
/// layer's own clusters form naturally in the remaining space instead of overlapping or engulfing
/// whatever the mask represents.
///
/// `layerCoverageThreshold`/`layerMaxClusterCells`/`layerMaxClusterDim` let the storm layer use much
/// looser values than the base layer: the base layer deliberately stays sparse/chunky (small, discrete
/// puffy clouds), but "heavy rain = mostly overcast sky" needs the storm layer able to form much larger,
/// more continuous masses instead of being capped to the same small chunk size.
fn computeCloudCoverage(outCoverage: []u8, gridDim: u32, originCellX: i64, originCellY: i64, layerCloudSeed: u64, layerDetailSeed: u64, layerCoverageThreshold: f32, layerMaxClusterCells: u32, layerMaxClusterDim: u32, excludeMask: ?[]const u8) void {
	const cloudsEnabled = settings.clouds;

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			const worldX: f64 = @as(f64, @floatFromInt(originCellX + @as(i64, @intCast(cx))))*cellSizeD + cellSizeD/2;
			const worldY: f64 = @as(f64, @floatFromInt(originCellY + @as(i64, @intCast(cy))))*cellSizeD + cellSizeD/2;
			const isCovered = cloudsEnabled and sampleCoverageWithSeeds(worldX, worldY, layerCloudSeed, layerDetailSeed, layerCoverageThreshold);
			outCoverage[cy*gridDim + cx] = if (isCovered) 255 else 0;
		}
	}

	if (excludeMask) |mask| {
		for (0..gridDim*gridDim) |i| {
			if (mask[i] != 0) outCoverage[i] = 0;
		}
	}

	{
		const snapshot = outCoverage;
		for (0..gridDim) |cy| {
			for (0..gridDim) |cx| {
				const idx = cy * gridDim + cx;
				if (snapshot[idx] == 0) continue;
				const hasUp = cy > 0 and snapshot[idx - gridDim] != 0;
				const hasDown = cy + 1 < gridDim and snapshot[idx + gridDim] != 0;
				const hasLeft = cx > 0 and snapshot[idx - 1] != 0;
				const hasRight = cx + 1 < gridDim and snapshot[idx + 1] != 0;
				const isHorizontalNeck = hasLeft and hasRight and !hasUp and !hasDown;
				const isVerticalNeck = hasUp and hasDown and !hasLeft and !hasRight;
				if (isHorizontalNeck or isVerticalNeck) {
					outCoverage[idx] = 0;
				}
			}
		}
	}

	// Pass 2: Erode thin protrusions — remove cells that touch only 1 covered neighbor (dead-end
	// fingers/peninsulas). Run twice to catch 2-cell-long stubs.
	for (0..2) |_| {
		const snapshot = outCoverage;
		for (0..gridDim) |cy| {
			for (0..gridDim) |cx| {
				const idx = cy * gridDim + cx;
				if (snapshot[idx] == 0) continue;
				var neighbors: u32 = 0;
				if (cy > 0 and snapshot[idx - gridDim] != 0) neighbors += 1;
				if (cy + 1 < gridDim and snapshot[idx + gridDim] != 0) neighbors += 1;
				if (cx > 0 and snapshot[idx - 1] != 0) neighbors += 1;
				if (cx + 1 < gridDim and snapshot[idx + 1] != 0) neighbors += 1;
				if (neighbors <= 1) {
					outCoverage[idx] = 0;
				}
			}
		}
	}

	// Pass 3: Flood-fill prune — remove clusters smaller than minClusterCells, and split clusters
	// larger than layerMaxClusterCells by zeroing them and letting the noise re-form smaller pieces.
	{
		var ccVisited: [maxGridDim*maxGridDim]bool = @splat(false);
		var stack: [maxGridDim*maxGridDim]u32 = undefined;
		var clusterCells: [maxGridDim*maxGridDim]u32 = undefined;
		for (0..gridDim) |cy| {
			for (0..gridDim) |cx| {
				const startIndex: u32 = @intCast(cy*gridDim + cx);
				if (outCoverage[startIndex] == 0 or ccVisited[startIndex]) continue;

				var stackLen: u32 = 1;
				stack[0] = startIndex;
				ccVisited[startIndex] = true;
				var clusterLen: u32 = 0;
				while (stackLen > 0) {
					stackLen -= 1;
					const index = stack[stackLen];
					clusterCells[clusterLen] = index;
					clusterLen += 1;

					const ix: i64 = @intCast(index % gridDim);
					const iy: i64 = @intCast(index / gridDim);
					const nbrs = [4][2]i64{ .{ ix - 1, iy }, .{ ix + 1, iy }, .{ ix, iy - 1 }, .{ ix, iy + 1 } };
					for (nbrs) |n| {
						if (n[0] < 0 or n[1] < 0 or n[0] >= gridDim or n[1] >= gridDim) continue;
						const nIndex: u32 = @intCast(n[1]*@as(i64, @intCast(gridDim)) + n[0]);
						if (outCoverage[nIndex] == 0 or ccVisited[nIndex]) continue;
						ccVisited[nIndex] = true;
						stack[stackLen] = nIndex;
						stackLen += 1;
					}
				}

				var minX: u32 = gridDim;
				var maxX: u32 = 0;
				var minY: u32 = gridDim;
				var maxY: u32 = 0;
				for (clusterCells[0..clusterLen]) |index| {
					const ix2: u32 = index % gridDim;
					const iy2: u32 = index / gridDim;
					if (ix2 < minX) minX = ix2;
					if (ix2 > maxX) maxX = ix2;
					if (iy2 < minY) minY = iy2;
					if (iy2 > maxY) maxY = iy2;
				}

				const width = maxX - minX + 1;
				const height = maxY - minY + 1;

				// Too small — remove entirely.
				if (clusterLen < minClusterCells) {
					for (clusterCells[0..clusterLen]) |index| outCoverage[index] = 0;
				}
				// Too large or elongated — split down the middle of its longest axis to maintain compact chunky shapes:
				else if (clusterLen > layerMaxClusterCells or width > layerMaxClusterDim or height > layerMaxClusterDim) {
					if (width >= height) {
						const midX = (minX + maxX) / 2;
						for (clusterCells[0..clusterLen]) |index| {
							if ((index % gridDim) == midX) {
								outCoverage[index] = 0;
							}
						}
					} else {
						const midY = (minY + maxY) / 2;
						for (clusterCells[0..clusterLen]) |index| {
							if ((index / gridDim) == midY) {
								outCoverage[index] = 0;
							}
						}
					}
				}
			}
		}
	}

	// Pass 3.5: Enforce minimum 2-cell gap spacing between cloud clusters.
	// If two separate cloud clusters are closer than 2 cells (Chebyshev distance <= 2),
	// prune the second cluster to guarantee clean, even spacing across the sky.
	{
		var spacingVisited: [maxGridDim * maxGridDim]bool = @splat(false);
		var acceptedMask: [maxGridDim * maxGridDim]bool = @splat(false);
		var stack: [maxGridDim * maxGridDim]u32 = undefined;
		var clusterCells: [maxGridDim * maxGridDim]u32 = undefined;

		for (0..gridDim) |cy| {
			for (0..gridDim) |cx| {
				const startIndex: u32 = @intCast(cy * gridDim + cx);
				if (outCoverage[startIndex] == 0 or spacingVisited[startIndex]) continue;

				var stackLen: u32 = 1;
				stack[0] = startIndex;
				spacingVisited[startIndex] = true;
				var clusterLen: u32 = 0;
				while (stackLen > 0) {
					stackLen -= 1;
					const index = stack[stackLen];
					clusterCells[clusterLen] = index;
					clusterLen += 1;

					const ix: i64 = @intCast(index % gridDim);
					const iy: i64 = @intCast(index / gridDim);
					const nbrs = [4][2]i64{ .{ ix - 1, iy }, .{ ix + 1, iy }, .{ ix, iy - 1 }, .{ ix, iy + 1 } };
					for (nbrs) |n| {
						if (n[0] < 0 or n[1] < 0 or n[0] >= gridDim or n[1] >= gridDim) continue;
						const nIndex: u32 = @intCast(n[1] * @as(i64, @intCast(gridDim)) + n[0]);
						if (outCoverage[nIndex] == 0 or spacingVisited[nIndex]) continue;
						spacingVisited[nIndex] = true;
						stack[stackLen] = nIndex;
						stackLen += 1;
					}
				}

				var tooClose: bool = false;
				checkProximity: for (clusterCells[0..clusterLen]) |index| {
					const ix: i64 = @intCast(index % gridDim);
					const iy: i64 = @intCast(index / gridDim);
					var dy: i64 = -2;
					while (dy <= 2) : (dy += 1) {
						var dx: i64 = -2;
						while (dx <= 2) : (dx += 1) {
							if (dx == 0 and dy == 0) continue;
							const nx = ix + dx;
							const ny = iy + dy;
							if (nx >= 0 and ny >= 0 and nx < gridDim and ny < gridDim) {
								const nIdx: u32 = @intCast(ny * @as(i64, @intCast(gridDim)) + nx);
								if (acceptedMask[nIdx]) {
									tooClose = true;
									break :checkProximity;
								}
							}
						}
					}
				}

				if (tooClose) {
					for (clusterCells[0..clusterLen]) |index| outCoverage[index] = 0;
				} else {
					for (clusterCells[0..clusterLen]) |index| acceptedMask[index] = true;
				}
			}
		}
	}

	// Pass 4: Fill 1-cell hollow pockets (surrounded on 3+ sides) so greedy merge works cleanly.
	{
		const snapshot = outCoverage;
		for (1..gridDim - 1) |cy| {
			for (1..gridDim - 1) |cx| {
				const idx = cy * gridDim + cx;
				if (snapshot[idx] != 0) continue;
				var coveredNeighbors: u32 = 0;
				if (snapshot[idx - gridDim] != 0) coveredNeighbors += 1;
				if (snapshot[idx + gridDim] != 0) coveredNeighbors += 1;
				if (snapshot[idx - 1] != 0) coveredNeighbors += 1;
				if (snapshot[idx + 1] != 0) coveredNeighbors += 1;
				if (coveredNeighbors >= 3) {
					outCoverage[idx] = 255;
				}
			}
		}
	}
}

pub fn getCloudAttenuationForDirection(playerPos: Vec3d, dir: Vec3f) f32 {
	if (!settings.clouds) return 1.0;
	if (dir[2] <= 0.001) return 1.0;
	const rainIntensity: f32 = if (game.world) |w| w.dayTime.rainIntensity else 0.0;
	var atten: f32 = 1.0;

	// Rain overall atmospheric sun attenuation
	atten *= std.math.lerp(1.0, 0.35, rainIntensity);

	const relZ = cloudBaseHeight - playerPos[2];
	if (relZ > 0) {
		const t = relZ / dir[2];
		const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
		const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
		const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));
		const hitX = playerPos[0] + @as(f64, dir[0])*@as(f64, t) - @as(f64, windOffset[0]);
		const hitY = playerPos[1] + @as(f64, dir[1])*@as(f64, t) - @as(f64, windOffset[1]);
		
		if (sampleCoverage(hitX, hitY)) {
			atten *= 0.30;
		}
		if (rainIntensity > 0.02 and sampleCoverageWithSeeds(hitX, hitY, stormCloudSeed, stormDetailSeed, stormCoverageThreshold)) {
			atten *= std.math.lerp(1.0, 0.30, rainIntensity);
		}
	}
	return atten;
}

fn relCoordAt(gridIndex: i64, gridOrigin: f64, playerCoord: f64, windOffsetComponent: f32) f32 {
	const worldCoord: f64 = gridOrigin + @as(f64, @floatFromInt(gridIndex))*cellSizeD;
	const rel: f32 = @floatCast(worldCoord - playerCoord);
	return rel + windOffsetComponent;
}

fn addQuad(vertices: *main.ListManaged(CloudVertex), indices: *main.ListManaged(u32), p0: Vec3f, p1: Vec3f, p2: Vec3f, p3: Vec3f, brightness: f32) void {
	const base: u32 = @intCast(vertices.items.len);
	vertices.append(.{.pos = p0, .brightness = brightness});
	vertices.append(.{.pos = p1, .brightness = brightness});
	vertices.append(.{.pos = p2, .brightness = brightness});
	vertices.append(.{.pos = p3, .brightness = brightness});
	indices.append(base + 0);
	indices.append(base + 1);
	indices.append(base + 2);
	indices.append(base + 0);
	indices.append(base + 2);
	indices.append(base + 3);
}

pub fn update(playerPos: Vec3d) void {
	const desiredGridDim: u32 = @intFromFloat(@ceil(2*settings.cloudDistance/cellSize));
	const gridDim: u32 = std.math.clamp(desiredGridDim, 4, maxGridDim);
	const gridDimD: f64 = @floatFromInt(gridDim);

	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));

	const effectivePosX: f64 = playerPos[0] - @as(f64, windOffset[0]);
	const effectivePosY: f64 = playerPos[1] - @as(f64, windOffset[1]);

	const originCellX: i64 = @intFromFloat(@floor(effectivePosX/cellSizeD) - gridDimD/2);
	const originCellY: i64 = @intFromFloat(@floor(effectivePosY/cellSizeD) - gridDimD/2);

	const cloudMidHeightD: f64 = @as(f64, cloudBaseHeight) + @as(f64, cloudThickness)/2;

	computeCloudCoverage(&coverage, gridDim, originCellX, originCellY, cloudSeed, detailSeed, coverageThreshold, 25, 4, null);

	computeCloudCoverage(&stormCoverage, gridDim, originCellX, originCellY, stormCloudSeed, stormDetailSeed, stormCoverageThreshold, stormMaxClusterCells, stormMaxClusterDim, &coverage);

	const originX: f64 = @as(f64, @floatFromInt(originCellX))*cellSizeD;
	const originY: f64 = @as(f64, @floatFromInt(originCellY))*cellSizeD;
	coverageOriginRelative = Vec2f{@floatCast(originX - playerPos[0]), @floatCast(originY - playerPos[1])} + windOffset;
	coverageWorldSize = @floatCast(gridDimD*cellSizeD);
	cloudHeightRelative = @floatCast(cloudMidHeightD - playerPos[2]);

	c.glActiveTexture(c.GL_TEXTURE9);
	c.glBindTexture(c.GL_TEXTURE_2D, coverageTextureId);
	c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, @intCast(gridDim), @intCast(gridDim), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &coverage);

	var vertices: main.ListManaged(CloudVertex) = .init(main.stackAllocator);
	defer vertices.deinit();
	var indices: main.ListManaged(u32) = .init(main.stackAllocator);
	defer indices.deinit();

	const relZBase: f32 = @floatCast(@as(f64, cloudBaseHeight) - playerPos[2]);
	const relZTop: f32 = relZBase + cloudThickness;
	buildLayerMesh(&coverage, &vertices, &indices, gridDim, originX, originY, playerPos, windOffset, relZBase, relZTop, topBrightness, sideBrightness, bottomBrightness);

	indexCount = @intCast(indices.items.len);
	vao.update(CloudVertex, vertices.items, indices.items);

	// Storm layer's coverage mesh
	var stormVertices: main.ListManaged(CloudVertex) = .init(main.stackAllocator);
	defer stormVertices.deinit();
	var stormIndices: main.ListManaged(u32) = .init(main.stackAllocator);
	defer stormIndices.deinit();

	const stormRelZBase: f32 = relZBase + stormGap;
	const stormRelZTop: f32 = stormRelZBase + stormThickness;
	buildLayerMesh(&stormCoverage, &stormVertices, &stormIndices, gridDim, originX, originY, playerPos, windOffset, stormRelZBase, stormRelZTop, topBrightness, sideBrightness, bottomBrightness);

	stormIndexCount = @intCast(stormIndices.items.len);
	stormVao.update(CloudVertex, stormVertices.items, stormIndices.items);
}

fn drawLayer(vaoToDraw: *graphics.VertexArray, layerIndexCount: u32, tint: Vec3f, alpha: f32) void {
	if (layerIndexCount == 0) return;
	vaoToDraw.bind();
	c.glUniform3fv(uniforms.tint, 1, @ptrCast(&tint));
	c.glUniform1f(uniforms.baseAlpha, alpha);

	c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);
	c.glDepthMask(c.GL_TRUE);
	c.glDepthFunc(c.GL_LEQUAL);
	c.glDrawElements(c.GL_TRIANGLES, @intCast(layerIndexCount), c.GL_UNSIGNED_INT, null);

	c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
	c.glDepthMask(c.GL_FALSE);
	c.glDepthFunc(c.GL_EQUAL);
	c.glDrawElements(c.GL_TRIANGLES, @intCast(layerIndexCount), c.GL_UNSIGNED_INT, null);
}

pub fn draw(ambientLight: Vec3f, skyColor: Vec3f) void {
	if (indexCount == 0 and stormIndexCount == 0) return;

	pipeline.bind(null);

	const neutralWhite: Vec3f = .{1, 1, 1};
	const cloudBase = neutralWhite * @as(Vec3f, @splat(0.875)) + skyColor * @as(Vec3f, @splat(0.125));
	const tint = @min(Vec3f{1, 1, 1}, cloudBase * (@as(Vec3f, @splat(0.7)) + skyColor * @as(Vec3f, @splat(0.3)))) * ambientLight;

	c.glEnable(c.GL_POLYGON_OFFSET_FILL);
	c.glPolygonOffset(-1.0, -2.0);

	// Base layer: fixed alpha, completely unaffected by weather.
	drawLayer(&vao, indexCount, tint, baseAlpha);

	// Storm layer: smoothly fades in/out via alpha as rainIntensity changes.
	// Uses exact same tint formula as base clouds to match color perfectly.
	const rainIntensity = game.world.?.dayTime.rainIntensity;
	const stormAlpha = rainIntensity * baseAlpha;
	if (stormAlpha > 0.01 and stormIndexCount > 0) {
		const stormTint = tint * @as(Vec3f, @splat(stormTintFactor));
		drawLayer(&stormVao, stormIndexCount, stormTint, stormAlpha);
	}

	c.glDisable(c.GL_POLYGON_OFFSET_FILL);
	c.glDepthFunc(c.GL_LESS);
}
