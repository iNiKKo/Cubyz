const std = @import("std");

const main = @import("main");
const settings = main.settings;
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
const coverageThreshold: f32 = 0.65;
const minClusterCells: u32 = 8;
const windVelocity = Vec2f{2.0, 0.8};
const cloudSeed: u64 = 0x63756279_7a636c64;
const detailSeed: u64 = cloudSeed ^ 0x9e3779b97f4a7c15;

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

var indexCount: u32 = 0;

/// One coverage byte (0 or 255) per grid cell, uploaded as a small texture purely so shadow.glsl's
/// sampleCloudShadow can test against the *exact* same per-cell coverage the visible mesh was built
/// from — sharing this array is what keeps the shadow shape from ever drifting out of sync with the
/// mesh above it. Sized to maxGridDim (the worst case); only the [0, gridDim) sub-range update() computes
/// each frame is meaningful.
var coverage: [maxGridDim*maxGridDim]u8 = undefined;
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
	c.glDeleteTextures(1, &coverageTextureId);
}

fn sampleCoverage(worldX: f64, worldY: f64) bool {
	const baseX: f32 = @floatCast(worldX/cloudScale);
	const baseY: f32 = @floatCast(worldY/cloudScale);
	const detailX: f32 = @floatCast(worldX/detailScale);
	const detailY: f32 = @floatCast(worldY/detailScale);
	const base = ValueNoise.samplePoint2D(baseX, baseY, cloudSeed);
	const detail = ValueNoise.samplePoint2D(detailX, detailY, detailSeed);
	const value = base*(1 - detailWeight) + detail*detailWeight;
	return value > coverageThreshold;
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

pub fn getCloudAttenuationForDirection(playerPos: Vec3d, dir: Vec3f) f32 {
	if (!settings.clouds) return 1.0;
	if (dir[2] <= 0.001) return 1.0;
	const relZ = cloudBaseHeight - playerPos[2];
	if (relZ <= 0) return 1.0;
	const t = relZ / dir[2];
	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const windOffset = windVelocity*@as(Vec2f, @splat(elapsedSeconds));
	const hitX = playerPos[0] + @as(f64, dir[0])*@as(f64, t) - @as(f64, windOffset[0]);
	const hitY = playerPos[1] + @as(f64, dir[1])*@as(f64, t) - @as(f64, windOffset[1]);
	if (sampleCoverage(hitX, hitY)) {
		return 0.30;
	}
	return 1.0;
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

	const cloudsEnabled = settings.clouds;

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			const worldX: f64 = @as(f64, @floatFromInt(originCellX + @as(i64, @intCast(cx))))*cellSizeD + cellSizeD/2;
			const worldY: f64 = @as(f64, @floatFromInt(originCellY + @as(i64, @intCast(cy))))*cellSizeD + cellSizeD/2;
			const isCovered = cloudsEnabled and sampleCoverage(worldX, worldY);
			coverage[cy*gridDim + cx] = if (isCovered) 255 else 0;
		}
	}

	{
		const snapshot = coverage;
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
					coverage[idx] = 0;
				}
			}
		}
	}

	// Pass 2: Erode thin protrusions — remove cells that touch only 1 covered neighbor (dead-end
	// fingers/peninsulas). Run twice to catch 2-cell-long stubs.
	for (0..2) |_| {
		const snapshot = coverage;
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
					coverage[idx] = 0;
				}
			}
		}
	}

	// Pass 3: Flood-fill prune — remove clusters smaller than minClusterCells, and split clusters
	// larger than maxClusterCells by zeroing them and letting the noise re-form smaller pieces.
	{
		const maxClusterCells: u32 = 25;
		var ccVisited: [maxGridDim*maxGridDim]bool = @splat(false);
		var stack: [maxGridDim*maxGridDim]u32 = undefined;
		var clusterCells: [maxGridDim*maxGridDim]u32 = undefined;
		for (0..gridDim) |cy| {
			for (0..gridDim) |cx| {
				const startIndex: u32 = @intCast(cy*gridDim + cx);
				if (coverage[startIndex] == 0 or ccVisited[startIndex]) continue;

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
						if (coverage[nIndex] == 0 or ccVisited[nIndex]) continue;
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
					for (clusterCells[0..clusterLen]) |index| coverage[index] = 0;
				}
				// Too large or elongated — split down the middle of its longest axis to maintain compact chunky shapes:
				else if (clusterLen > maxClusterCells or width > 4 or height > 4) {
					if (width >= height) {
						const midX = (minX + maxX) / 2;
						for (clusterCells[0..clusterLen]) |index| {
							if ((index % gridDim) == midX) {
								coverage[index] = 0;
							}
						}
					} else {
						const midY = (minY + maxY) / 2;
						for (clusterCells[0..clusterLen]) |index| {
							if ((index / gridDim) == midY) {
								coverage[index] = 0;
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
				if (coverage[startIndex] == 0 or spacingVisited[startIndex]) continue;

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
						if (coverage[nIndex] == 0 or spacingVisited[nIndex]) continue;
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
					for (clusterCells[0..clusterLen]) |index| coverage[index] = 0;
				} else {
					for (clusterCells[0..clusterLen]) |index| acceptedMask[index] = true;
				}
			}
		}
	}

	// Pass 4: Fill 1-cell hollow pockets (surrounded on 3+ sides) so greedy merge works cleanly.
	{
		const snapshot = coverage;
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
					coverage[idx] = 255;
				}
			}
		}
	}

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

	var visitedTop: [maxGridDim * maxGridDim]bool = @splat(false);
	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			if (coverage[cy * gridDim + cx] == 0 or visitedTop[cy * gridDim + cx]) continue;

			var w: u32 = 1;
			while (cx + w < gridDim and coverage[cy * gridDim + cx + w] != 0 and !visitedTop[cy * gridDim + cx + w]) : (w += 1) {}

			var h: u32 = 1;
			expandY: while (cy + h < gridDim) : (h += 1) {
				for (0..w) |dx| {
					const checkIdx = (cy + h) * gridDim + cx + dx;
					if (coverage[checkIdx] == 0 or visitedTop[checkIdx]) break :expandY;
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

			addQuad(&vertices, &indices, .{x0, y0, relZTop}, .{x0, y1, relZTop}, .{x1, y1, relZTop}, .{x1, y0, relZTop}, topBrightness);
			addQuad(&vertices, &indices, .{x0, y1, relZBase}, .{x0, y0, relZBase}, .{x1, y0, relZBase}, .{x1, y1, relZBase}, bottomBrightness);
		}
	}

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			if (coverage[cy * gridDim + cx] == 0) continue;

			const gx0: i64 = @intCast(cx);
			const gy0: i64 = @intCast(cy);
			const gx1: i64 = gx0 + 1;
			const gy1: i64 = gy0 + 1;

			const wallX0 = relCoordAt(gx0, originX, playerPos[0], windOffset[0]);
			const wallY0 = relCoordAt(gy0, originY, playerPos[1], windOffset[1]);
			const wallX1 = relCoordAt(gx1, originX, playerPos[0], windOffset[0]);
			const wallY1 = relCoordAt(gy1, originY, playerPos[1], windOffset[1]);

			const hasLeft = cx > 0 and coverage[cy * gridDim + cx - 1] != 0;
			const hasRight = cx + 1 < gridDim and coverage[cy * gridDim + cx + 1] != 0;
			const hasUp = cy > 0 and coverage[(cy - 1) * gridDim + cx] != 0;
			const hasDown = cy + 1 < gridDim and coverage[(cy + 1) * gridDim + cx] != 0;

			if (!hasLeft) addQuad(&vertices, &indices, .{wallX0, wallY1, relZTop}, .{wallX0, wallY0, relZTop}, .{wallX0, wallY0, relZBase}, .{wallX0, wallY1, relZBase}, sideBrightness);
			if (!hasRight) addQuad(&vertices, &indices, .{wallX1, wallY0, relZTop}, .{wallX1, wallY1, relZTop}, .{wallX1, wallY1, relZBase}, .{wallX1, wallY0, relZBase}, sideBrightness);
			if (!hasUp) addQuad(&vertices, &indices, .{wallX0, wallY0, relZTop}, .{wallX1, wallY0, relZTop}, .{wallX1, wallY0, relZBase}, .{wallX0, wallY0, relZBase}, sideBrightness);
			if (!hasDown) addQuad(&vertices, &indices, .{wallX1, wallY1, relZTop}, .{wallX0, wallY1, relZTop}, .{wallX0, wallY1, relZBase}, .{wallX1, wallY1, relZBase}, sideBrightness);
		}
	}

	indexCount = @intCast(indices.items.len);
	vao.update(CloudVertex, vertices.items, indices.items);
}

pub fn draw(ambientLight: Vec3f, skyColor: Vec3f) void {
	if (indexCount == 0) return;

	pipeline.bind(null);
	vao.bind();

	const neutralWhite: Vec3f = .{1, 1, 1};
	const cloudBase = neutralWhite * @as(Vec3f, @splat(0.875)) + skyColor * @as(Vec3f, @splat(0.125));
	const tint = @min(Vec3f{1, 1, 1}, cloudBase * (@as(Vec3f, @splat(0.7)) + skyColor * @as(Vec3f, @splat(0.3)))) * ambientLight;
	c.glUniform3fv(uniforms.tint, 1, @ptrCast(&tint));
	c.glUniform1f(uniforms.baseAlpha, 0.65);

	c.glEnable(c.GL_POLYGON_OFFSET_FILL);
	c.glPolygonOffset(-1.0, -2.0);

	c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);
	c.glDepthMask(c.GL_TRUE);
	c.glDepthFunc(c.GL_LEQUAL);
	c.glDrawElements(c.GL_TRIANGLES, @intCast(indexCount), c.GL_UNSIGNED_INT, null);

	c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
	c.glDepthMask(c.GL_FALSE);
	c.glDepthFunc(c.GL_EQUAL);
	c.glDrawElements(c.GL_TRIANGLES, @intCast(indexCount), c.GL_UNSIGNED_INT, null);

	c.glDisable(c.GL_POLYGON_OFFSET_FILL);
	c.glDepthFunc(c.GL_LESS);
}
