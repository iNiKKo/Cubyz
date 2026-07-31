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
const cloudBaseHeight: f32 = 448.0;
const cloudThickness: f32 = 10.0;
const cloudScale: f32 = 160.0;
const detailScale: f32 = 103.0;
const detailWeight: f32 = 0.14;

const coverageThreshold: f32 = 0.65;

const baseAlpha: f32 = 0.65;
const minClusterCells: u32 = 8;
const windVelocity = Vec2f{2.0, 0.8};
const cloudSeed: u64 = 0x63756279_7a636c64;
const detailSeed: u64 = cloudSeed ^ 0x9e3779b97f4a7c15;

const stormCloudSeed: u64 = cloudSeed ^ 0x51ed270a4b204d29;
const stormDetailSeed: u64 = stormCloudSeed ^ 0x9e3779b97f4a7c15;

const stormGap: f32 = cloudThickness;
const stormThickness: f32 = 10.0;
const stormAlphaFullRain: f32 = 0.65;
const stormCoverageThreshold: f32 = 0.60;
const stormMaxClusterCells: u32 = 25;
const stormMaxClusterDim: u32 = 4;
const stormTintFactor: f32 = 0.78;

const topBrightness: f32 = 1.0;
const sideBrightness: f32 = 0.9;
const bottomBrightness: f32 = 0.8;

const CloudVertex = extern struct {
	pos: [3]f32,
	brightness: f32,

	edgeFade: f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{.location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(@This(), "pos")},
		.{.location = 1, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(@This(), "brightness")},
		.{.location = 2, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(@This(), "edgeFade")},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	tint: c_int,
	baseAlpha: c_int,
	meshOriginRelative: c_int,
	fogColor: c_int,
	fogDensity: c_int,
	weatherFogStrength: c_int,
} = undefined;
var vao: graphics.VertexArray = undefined;

var stormVao: graphics.VertexArray = undefined;

var indexCount: u32 = 0;
pub var stormIndexCount: u32 = 0;

var coverage: [maxGridDim*maxGridDim]u8 = undefined;

var stormCoverage: [maxGridDim*maxGridDim]u8 = undefined;

var shadowCoverage: [maxGridDim*maxGridDim]u8 = undefined;
var coverageTextureId: c_uint = 0;

pub var coverageOriginRelative: Vec2f = .{0, 0};
pub var coverageWorldSize: f32 = 0;

pub var cloudHeightRelative: f32 = 0;
pub var coverageTexture: c_uint = 0;

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
		.{.attachments = &.{.premultipliedAlphaBlending}},
	);
	vao = .init(CloudVertex, &.{}, &.{});
	stormVao = .init(CloudVertex, &.{}, &.{});

	c.glGenTextures(1, &coverageTextureId);
	c.glBindTexture(c.GL_TEXTURE_2D, coverageTextureId);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_BORDER);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_BORDER);
	const borderColor = [4]f32{0, 0, 0, 0};
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

fn sampleCoverage(worldX: f64, worldY: f64) bool {
	return sampleCoverageWithSeeds(worldX, worldY, cloudSeed, detailSeed, coverageThreshold);
}

var lastOriginCellX: i64 = 0;
var lastOriginCellY: i64 = 0;
var lastGridDim: u32 = 0;
var lastWeatherRevision: u64 = 0;

pub fn isPlayerInsideCloud(playerPos: Vec3d) bool {
	if (!settings.clouds) return false;
	const z = playerPos[2];
	if (z < cloudBaseHeight or z > cloudBaseHeight + cloudThickness) return false;

	const windOffset = Vec2f{0, 0};
	const effectivePosX: f64 = playerPos[0] - @as(f64, windOffset[0]);
	const effectivePosY: f64 = playerPos[1] - @as(f64, windOffset[1]);

	const playerCellX: i64 = @intFromFloat(@floor(effectivePosX / cellSizeD));
	const playerCellY: i64 = @intFromFloat(@floor(effectivePosY / cellSizeD));

	const localX = playerCellX - lastOriginCellX;
	const localY = playerCellY - lastOriginCellY;

	if (localX >= 0 and localY >= 0 and localX < lastGridDim and localY < lastGridDim) {
		const idx: usize = @intCast(localY * @as(i64, @intCast(lastGridDim)) + localX);
		return coverage[idx] > 0;
	}
	return false;
}

const edgeFadeStartFrac: f32 = 0.75;

fn edgeFadeForCell(cx: u32, cy: u32, gridDim: u32) f32 {
	const halfDim: f32 = @as(f32, @floatFromInt(gridDim))/2.0;
	const dx = @abs(@as(f32, @floatFromInt(cx)) + 0.5 - halfDim);
	const dy = @abs(@as(f32, @floatFromInt(cy)) + 0.5 - halfDim);
	const distNorm = @max(dx, dy)/halfDim;
	return 1.0 - std.math.clamp((distNorm - edgeFadeStartFrac)/(1.0 - edgeFadeStartFrac), 0.0, 1.0);
}

fn buildLayerMesh(
	layerCoverage: []const u8,
	vertices: *main.ListManaged(CloudVertex),
	indices: *main.ListManaged(u32),
	gridDim: u32,
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

			const x0 = relCoordAt(gx0);
			const y0 = relCoordAt(gy0);
			const x1 = relCoordAt(gx1);
			const y1 = relCoordAt(gy1);

			const fade = edgeFadeForCell(@intCast(cx + w/2), @intCast(cy + h/2), gridDim);

			addQuad(vertices, indices, .{x0, y0, relZTop}, .{x0, y1, relZTop}, .{x1, y1, relZTop}, .{x1, y0, relZTop}, layerTopBrightness, fade);
			addQuad(vertices, indices, .{x0, y1, relZBase}, .{x0, y0, relZBase}, .{x1, y0, relZBase}, .{x1, y1, relZBase}, layerBottomBrightness, fade);
		}
	}

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			if (layerCoverage[cy * gridDim + cx] == 0) continue;
			const fade = edgeFadeForCell(@intCast(cx), @intCast(cy), gridDim);

			const gx0: i64 = @intCast(cx);
			const gy0: i64 = @intCast(cy);
			const gx1: i64 = gx0 + 1;
			const gy1: i64 = gy0 + 1;

			const wallX0 = relCoordAt(gx0);
			const wallY0 = relCoordAt(gy0);
			const wallX1 = relCoordAt(gx1);
			const wallY1 = relCoordAt(gy1);

			const hasLeft = cx > 0 and layerCoverage[cy * gridDim + cx - 1] != 0;
			const hasRight = cx + 1 < gridDim and layerCoverage[cy * gridDim + cx + 1] != 0;
			const hasUp = cy > 0 and layerCoverage[(cy - 1) * gridDim + cx] != 0;
			const hasDown = cy + 1 < gridDim and layerCoverage[(cy + 1) * gridDim + cx] != 0;

			if (!hasLeft) addQuad(vertices, indices, .{wallX0, wallY1, relZTop}, .{wallX0, wallY0, relZTop}, .{wallX0, wallY0, relZBase}, .{wallX0, wallY1, relZBase}, layerSideBrightness, fade);
			if (!hasRight) addQuad(vertices, indices, .{wallX1, wallY0, relZTop}, .{wallX1, wallY1, relZTop}, .{wallX1, wallY1, relZBase}, .{wallX1, wallY0, relZBase}, layerSideBrightness, fade);
			if (!hasUp) addQuad(vertices, indices, .{wallX0, wallY0, relZTop}, .{wallX1, wallY0, relZTop}, .{wallX1, wallY0, relZBase}, .{wallX0, wallY0, relZBase}, layerSideBrightness, fade);
			if (!hasDown) addQuad(vertices, indices, .{wallX1, wallY1, relZTop}, .{wallX0, wallY1, relZTop}, .{wallX0, wallY1, relZBase}, .{wallX1, wallY1, relZBase}, layerSideBrightness, fade);
		}
	}
}

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

				if (clusterLen < minClusterCells) {
					for (clusterCells[0..clusterLen]) |index| outCoverage[index] = 0;
				}

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
	var atten: f32 = 1.0;

	const relZ = cloudBaseHeight - playerPos[2];
	if (relZ > 0) {
		const t = relZ / dir[2];

		const hitX = playerPos[0] + @as(f64, dir[0])*@as(f64, t);
		const hitY = playerPos[1] + @as(f64, dir[1])*@as(f64, t);

		if (sampleCoverage(hitX, hitY)) {
			atten *= 0.30;
		}
		const weatherSnapshot = if (game.world) |world| world.weatherGrid.snapshot() else game.WeatherGrid.Snapshot{};
		const weather = game.WeatherGrid.sampleSnapshot(weatherSnapshot, hitX, hitY);
		if (weather.precipitation > 0.01) {

			atten *= std.math.lerp(1.0, 0.30, weather.precipitation);
		}
	}
	return atten;
}

fn relCoordAt(gridIndex: i64) f32 {
	const rel: f32 = @floatCast(@as(f64, @floatFromInt(gridIndex))*cellSizeD);
	return rel;
}

fn addQuad(vertices: *main.ListManaged(CloudVertex), indices: *main.ListManaged(u32), p0: Vec3f, p1: Vec3f, p2: Vec3f, p3: Vec3f, brightness: f32, edgeFade: f32) void {
	const base: u32 = @intCast(vertices.items.len);
	vertices.append(.{.pos = p0, .brightness = brightness, .edgeFade = edgeFade});
	vertices.append(.{.pos = p1, .brightness = brightness, .edgeFade = edgeFade});
	vertices.append(.{.pos = p2, .brightness = brightness, .edgeFade = edgeFade});
	vertices.append(.{.pos = p3, .brightness = brightness, .edgeFade = edgeFade});
	indices.append(base + 0);
	indices.append(base + 1);
	indices.append(base + 2);
	indices.append(base + 0);
	indices.append(base + 2);
	indices.append(base + 3);
}

pub fn update(playerPos: Vec3d) void {
	if (!settings.clouds) {
		indexCount = 0;
		stormIndexCount = 0;
		return;
	}

	const desiredGridDim: u32 = @intFromFloat(@ceil(2*settings.cloudDistance/cellSize));
	const gridDim: u32 = std.math.clamp(desiredGridDim, 4, maxGridDim);
	const gridDimD: f64 = @floatFromInt(gridDim);

	const weatherSnapshot = if (game.world) |world| world.weatherGrid.snapshot() else game.WeatherGrid.Snapshot{};

	const windOffset = Vec2f{0, 0};

	const effectivePosX: f64 = playerPos[0] - @as(f64, windOffset[0]);
	const effectivePosY: f64 = playerPos[1] - @as(f64, windOffset[1]);

	const originCellX: i64 = @intFromFloat(@floor(effectivePosX/cellSizeD) - gridDimD/2);
	const originCellY: i64 = @intFromFloat(@floor(effectivePosY/cellSizeD) - gridDimD/2);

	const cloudMidHeightD: f64 = @as(f64, cloudBaseHeight) + @as(f64, cloudThickness)/2;
	const originX: f64 = @as(f64, @floatFromInt(originCellX))*cellSizeD;
	const originY: f64 = @as(f64, @floatFromInt(originCellY))*cellSizeD;
	coverageOriginRelative = Vec2f{@floatCast(originX - playerPos[0]), @floatCast(originY - playerPos[1])} + windOffset;
	coverageWorldSize = @floatCast(gridDimD*cellSizeD);
	cloudHeightRelative = @floatCast(cloudMidHeightD - playerPos[2]);
	if (originCellX == lastOriginCellX and originCellY == lastOriginCellY and gridDim == lastGridDim and lastWeatherRevision == weatherSnapshot.revision and indexCount > 0) {
		return;
	}

	lastOriginCellX = originCellX;
	lastOriginCellY = originCellY;
	lastGridDim = gridDim;
	lastWeatherRevision = weatherSnapshot.revision;

	computeCloudCoverage(&coverage, gridDim, originCellX, originCellY, cloudSeed, detailSeed, coverageThreshold, 25, 4, null);
	computeCloudCoverage(&stormCoverage, gridDim, originCellX, originCellY, stormCloudSeed, stormDetailSeed, stormCoverageThreshold, stormMaxClusterCells, stormMaxClusterDim, &coverage);

	for (0..gridDim) |cy| {
		for (0..gridDim) |cx| {
			const worldX: f64 = @as(f64, @floatFromInt(originCellX + @as(i64, @intCast(cx))))*cellSizeD + cellSizeD/2;
			const worldY: f64 = @as(f64, @floatFromInt(originCellY + @as(i64, @intCast(cy))))*cellSizeD + cellSizeD/2;
			const weather = game.WeatherGrid.sampleSnapshot(weatherSnapshot, worldX, worldY);
			const idx = cy*gridDim + cx;

			if (coverage[idx] != 0 or weather.cloud_cover <= 0.15) {
				stormCoverage[idx] = 0;
			} else if (stormCoverage[idx] == 0) {

				const localThreshold = std.math.lerp(0.78, 0.42, weather.cloud_cover);
				stormCoverage[idx] = if (sampleCoverageWithSeeds(worldX, worldY, stormCloudSeed, stormDetailSeed, localThreshold)) 255 else 0;
			}
		}
	}

	for (0..gridDim*gridDim) |i| shadowCoverage[i] = @max(coverage[i], stormCoverage[i]);
	c.glActiveTexture(c.GL_TEXTURE9);
	c.glBindTexture(c.GL_TEXTURE_2D, coverageTextureId);
	c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, @intCast(gridDim), @intCast(gridDim), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &shadowCoverage);

	var vertices: main.ListManaged(CloudVertex) = .init(main.stackAllocator);
	defer vertices.deinit();
	var indices: main.ListManaged(u32) = .init(main.stackAllocator);
	defer indices.deinit();

	buildLayerMesh(&coverage, &vertices, &indices, gridDim, 0.0, cloudThickness, topBrightness, sideBrightness, bottomBrightness);

	indexCount = @intCast(indices.items.len);
	vao.update(CloudVertex, vertices.items, indices.items);

	var stormVertices: main.ListManaged(CloudVertex) = .init(main.stackAllocator);
	defer stormVertices.deinit();
	var stormIndices: main.ListManaged(u32) = .init(main.stackAllocator);
	defer stormIndices.deinit();

	buildLayerMesh(&stormCoverage, &stormVertices, &stormIndices, gridDim, 0.0, stormThickness, topBrightness, sideBrightness, bottomBrightness);

	stormIndexCount = @intCast(stormIndices.items.len);
	stormVao.update(CloudVertex, stormVertices.items, stormIndices.items);
}

fn drawLayer(vaoToDraw: *graphics.VertexArray, layerIndexCount: u32, tint: Vec3f, alpha: f32, meshOriginRelative: Vec3f, writeDepth: bool, fogColor: Vec3f, fogDensity: f32, weatherFogStrength: f32) void {
	if (layerIndexCount == 0) return;
	vaoToDraw.bind();
	c.glUniform3fv(uniforms.tint, 1, @ptrCast(&tint));
	c.glUniform1f(uniforms.baseAlpha, alpha);
	c.glUniform3fv(uniforms.meshOriginRelative, 1, @ptrCast(&meshOriginRelative));
	c.glUniform3fv(uniforms.fogColor, 1, @ptrCast(&fogColor));
	c.glUniform1f(uniforms.fogDensity, fogDensity);
	c.glUniform1f(uniforms.weatherFogStrength, weatherFogStrength);

	if (writeDepth) {
		c.glColorMask(c.GL_FALSE, c.GL_FALSE, c.GL_FALSE, c.GL_FALSE);
		c.glDepthMask(c.GL_TRUE);
		c.glDepthFunc(c.GL_LEQUAL);
		c.glDrawElements(c.GL_TRIANGLES, @intCast(layerIndexCount), c.GL_UNSIGNED_INT, null);
	}

	c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
	c.glDepthMask(c.GL_FALSE);

	c.glDepthFunc(if (writeDepth) c.GL_EQUAL else c.GL_LEQUAL);
	c.glDrawElements(c.GL_TRIANGLES, @intCast(layerIndexCount), c.GL_UNSIGNED_INT, null);
}

pub fn draw(ambientLight: Vec3f, skyColor: Vec3f, playerPos: Vec3d) void {
	if (!settings.clouds) return;
	if (indexCount == 0 and stormIndexCount == 0) return;

	const aerialFade = 1.0 - std.math.clamp(@as(f32, @floatCast((playerPos[2] - 2000.0)/4000.0)), 0.0, 1.0);
	if (aerialFade <= 0.001) return;

	pipeline.bind(null);

	const neutralWhite: Vec3f = .{1, 1, 1};

	const cloudBase = neutralWhite * @as(Vec3f, @splat(0.65)) + skyColor * @as(Vec3f, @splat(0.35));

	const cloudLight = @min(Vec3f{0.86, 0.89, 0.93}, ambientLight * @as(Vec3f, @splat(0.55)) + Vec3f{0.30, 0.33, 0.38});
	const localWeather = if (game.world) |world| world.weatherGrid.sampleAt(playerPos[0], playerPos[1]) else game.WeatherGrid.Sample{};
	const weatherFogActive = if (game.world) |world| world.dayTime.weatherVisibility > 0.001 else false;
	const weatherFogStrength: f32 = if (game.world) |world| world.dayTime.weatherVisibility else 0.0;
	const weatherCloudDarkening: f32 = if (localWeather.kind == 1) std.math.lerp(1.0, 0.58, weatherFogStrength) else 1.0;
	const tint = @min(Vec3f{1, 1, 1}, cloudBase) * cloudLight * @as(Vec3f, @splat(weatherCloudDarkening));
	var fogColor: Vec3f = if (game.world) |world| world.dayTime.fog.fogColor else Vec3f{0.7, 0.75, 0.8};
	if (localWeather.kind == 1) {

		const rainCloudHaze = Vec3f{0.30, 0.36, 0.44};
		fogColor += (rainCloudHaze - fogColor)*@as(Vec3f, @splat(std.math.clamp(weatherFogStrength*0.9, 0.0, 0.8)));
	}
	const fogDensity: f32 = if (weatherFogActive) weatherFogStrength / (if (game.world) |world| world.dayTime.weatherFogRange else 96.0) else 0.0;
	const windOffset = Vec2f{0, 0};

	const desiredGridDim: u32 = @intFromFloat(@ceil(2*settings.cloudDistance/cellSize));
	const gridDim: u32 = std.math.clamp(desiredGridDim, 4, maxGridDim);
	const gridDimD: f64 = @floatFromInt(gridDim);

	const effectivePosX: f64 = playerPos[0] - @as(f64, windOffset[0]);
	const effectivePosY: f64 = playerPos[1] - @as(f64, windOffset[1]);
	const originCellX: i64 = @intFromFloat(@floor(effectivePosX/cellSizeD) - gridDimD/2);
	const originCellY: i64 = @intFromFloat(@floor(effectivePosY/cellSizeD) - gridDimD/2);

	const originX: f64 = @as(f64, @floatFromInt(originCellX))*cellSizeD;
	const originY: f64 = @as(f64, @floatFromInt(originCellY))*cellSizeD;

	const baseMeshOriginRel = Vec3f{
		@floatCast(originX - playerPos[0] + @as(f64, windOffset[0])),
		@floatCast(originY - playerPos[1] + @as(f64, windOffset[1])),
		@floatCast(@as(f64, cloudBaseHeight) - playerPos[2]),
	};

	c.glEnable(c.GL_POLYGON_OFFSET_FILL);
	c.glPolygonOffset(-1.0, -2.0);

	drawLayer(&vao, indexCount, tint, baseAlpha*aerialFade, baseMeshOriginRel, true, fogColor, fogDensity, weatherFogStrength);

	if (stormIndexCount > 0) {
		const stormTint = tint * @as(Vec3f, @splat(stormTintFactor));
		const stormMeshOriginRel = Vec3f{
			@floatCast(originX - playerPos[0] + @as(f64, windOffset[0])),
			@floatCast(originY - playerPos[1] + @as(f64, windOffset[1])),
			@floatCast(@as(f64, cloudBaseHeight + stormGap) - playerPos[2]),
		};
		drawLayer(&stormVao, stormIndexCount, stormTint, baseAlpha*aerialFade, stormMeshOriginRel, true, fogColor, fogDensity, weatherFogStrength);
	}

	c.glDisable(c.GL_POLYGON_OFFSET_FILL);
	c.glDepthFunc(c.GL_LESS);
}
