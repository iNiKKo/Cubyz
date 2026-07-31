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

const cellSize: f32 = 0.50;

const gridRadius: f32 = 22.0;

const maxGridDim: u32 = 96;

const dropWidth: f32 = 0.08;
const dropHeight: f32 = 0.75;
const fallSpeed: f32 = 36.0;

const fallRangeAbovePlayer: f64 = 22.0;

const groundScanAboveMargin: f64 = 8.0;

const groundScanMaxDepth: f64 = 12.0;

const verticalAnchorSnap: f64 = 4.0;

const maxActiveDensity: f32 = 0.95;
const dropColor = Vec3f{0.6, 0.7, 0.9};
const dropAlpha: f32 = 0.40;

fn windDriftScale(isSnow: bool, isDust: bool) f32 {

	return if (isDust) 36.0 else if (isSnow) 4.0 else 10.0;
}

fn precipitationDensity(intensity: f32, isSnow: bool, isDust: bool) f32 {
	const multiplier: f32 = if (isDust) 0.78 else if (isSnow) 1.30 else 1.0;
	return std.math.clamp(intensity*maxActiveDensity*multiplier, 0.0, 0.985);
}

fn precipitationHalfHeight(wind: Vec2f, fallSpeedForType: f32, driftScale: f32, height: f32) Vec3f {
	const halfTravelSeconds = height*0.5/fallSpeedForType;
	return .{
		-wind[0]*driftScale*halfTravelSeconds,
		-wind[1]*driftScale*halfTravelSeconds,
		height*0.5,
	};
}

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

fn hashCell(gx: i64, gy: i64) f32 {
	const ux: u64 = @bitCast(gx);
	const uy: u64 = @bitCast(gy);
	var h: u64 = ux *% 0x9E3779B97F4A7C15 +% uy *% 0xC2B2AE3D27D4EB4F +% 0xA24BAED4963EE407;
	h ^= h >> 33;
	h *%= 0xFF51AFD7ED558CCD;
	h ^= h >> 33;
	return @as(f32, @floatFromInt(h & 0xFFFFFF))/@as(f32, @floatFromInt(@as(u32, 0xFFFFFF)));
}

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

pub fn update(playerPos: Vec3d, viewMatrix: Mat4f, ambientLight: Vec3f) void {

	if (!settings.rain or game.weatherExposureAtPosition(playerPos) <= 0.0) {
		indexCount = 0;
		return;
	}
	const elapsedNanoseconds = startTimestamp.durationTo(main.timestamp()).toNanoseconds();
	const elapsedSeconds: f32 = @floatCast(@as(f64, @floatFromInt(elapsedNanoseconds))*1e-9);
	const weatherSnapshot = game.world.?.weatherGrid.snapshot();

	const anchorZ: f64 = @floor(game.Player.getPosBlocking()[2]/verticalAnchorSnap)*verticalAnchorSnap;

	var camRight = Vec3f{viewMatrix.rows[0][0], viewMatrix.rows[0][1], 0};
	if (vec.dot(camRight, camRight) < 1e-8) camRight = Vec3f{1, 0, 0};
	camRight = vec.normalize(camRight);

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

			const weather = game.world.?.weatherGrid.sampleAt(worldX, worldY);

			if (weather.kind != 1 and weather.kind != 2 and weather.kind != 3) continue;
			const isSnow = weather.kind == 2;
			const isDust = weather.kind == 3;
			const cellRainIntensity = if (isDust) weather.dust else weather.precipitation;
			if (cellRainIntensity <= 0.01) continue;
			const activeDensity = precipitationDensity(cellRainIntensity, isSnow, isDust);
			if (hashCell(worldCellX, worldCellY) > activeDensity) continue;

			const dx: f32 = @floatCast(worldX - playerPos[0]);
			const dy: f32 = @floatCast(worldY - playerPos[1]);
			const edgeDist = @sqrt(dx*dx + dy*dy)/gridRadius;
			if (edgeDist >= 1.0) continue;

			const groundZ: f64 = findGroundZ(worldX, worldY, anchorZ);

			const dustHeight = 0.15 + hashCell(worldCellX +% 401, worldCellY +% 809)*5.0;
			const topZ: f64 = if (isDust)
				groundZ + @as(f64, dustHeight)
			else
				@min(anchorZ + fallRangeAbovePlayer, game.weatherCloudBaseHeight - 1.0);
			if (topZ <= groundZ) continue;
			const range: f32 = @max(@as(f32, @floatCast(topZ - groundZ)), 1.0);
			const cellFallSpeed = if (isSnow) 8.5 else if (isDust) 5.0 else fallSpeed;
			const loopFrac = @mod(elapsedSeconds*cellFallSpeed/range + phase, 1.0);
			const dropZ: f64 = if (isDust)
				groundZ + @as(f64, dustHeight)
			else
				topZ - @as(f64, loopFrac*range);

			const fallSeconds: f32 = if (isDust)

				@mod(elapsedSeconds*0.125 + phase, 1.0)
			else
				@as(f32, @floatCast(topZ - dropZ))/cellFallSpeed;
			const windScale = windDriftScale(isSnow, isDust);

			const center = Vec3f{
				@floatCast(worldX + @as(f64, weatherSnapshot.wind[0]*fallSeconds*windScale) - playerPos[0]),
				@floatCast(worldY + @as(f64, weatherSnapshot.wind[1]*fallSeconds*windScale) - playerPos[1]),
				@floatCast(dropZ - playerPos[2]),
			};

			const dropBlockX: i32 = @intFromFloat(@floor(worldX));
			const dropBlockY: i32 = @intFromFloat(@floor(worldY));
			const dropBlockZ: i32 = @intFromFloat(@floor(dropZ));
			const light: [6]u8 = mesh_storage.getLight(dropBlockX, dropBlockY, dropBlockZ) orelse [6]u8{255, 255, 255, 0, 0, 0};
			const sunLight: Vec3f = ambientLight * @as(Vec3f, @floatFromInt(Vec3i{light[0], light[1], light[2]})) / @as(Vec3f, @splat(255.0));
			const blockLight: Vec3f = @as(Vec3f, @floatFromInt(Vec3i{light[3], light[4], light[5]})) / @as(Vec3f, @splat(255.0));
			const lightFactor = @min(@as(Vec3f, @splat(1.0)), @sqrt(sunLight*sunLight + blockLight*blockLight) + @as(Vec3f, @splat(0.04)));
			const precipitationColor: Vec3f = if (isSnow) .{0.92, 0.95, 1.0} else if (isDust) .{0.72, 0.55, 0.32} else dropColor;
			const vertexColor: Vec3f = precipitationColor * lightFactor;
			const colorArray: [3]f32 = .{vertexColor[0], vertexColor[1], vertexColor[2]};

			const cellWidth: f32 = if (isSnow) 0.24 else if (isDust) 0.20 else dropWidth;
			const cellHeight: f32 = if (isSnow) 0.24 else if (isDust) 0.07 else dropHeight;
			const halfWidth: Vec3f = @as(Vec3f, @splat(cellWidth*0.5))*camRight;
			const halfHeight = precipitationHalfHeight(weatherSnapshot.wind, cellFallSpeed, windScale, cellHeight);

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

	const farTopZ: f64 = @min(anchorZ + fallRangeAbovePlayer, game.weatherCloudBaseHeight - 1.0);
	const farGroundZ: f64 = anchorZ - 4.0;
	const farRange: f32 = @max(@as(f32, @floatCast(farTopZ - farGroundZ)), 1.0);
	for (weatherSnapshot.cells, 0..) |weatherCell, weatherIndex| {
		if (weatherCell.kind != 1 and weatherCell.kind != 2 and weatherCell.kind != 3) continue;
		const wxCell = weatherSnapshot.origin_cell[0] + @as(i32, @intCast(weatherIndex % game.WeatherGrid.dimension));
		const wyCell = weatherSnapshot.origin_cell[1] + @as(i32, @intCast(weatherIndex / game.WeatherGrid.dimension));
		const isSnow = weatherCell.kind == 2;
		const isDust = weatherCell.kind == 3;

		if (isDust) continue;
		const weatherStrength = if (isDust) weatherCell.dust else weatherCell.precipitation;
		if (weatherStrength == 0) continue;
		const intensity = @as(f32, @floatFromInt(weatherStrength))/255.0;
		const farCount: usize = @intFromFloat(6.0 + intensity*18.0);
		for (0..farCount) |i| {
			const hx: i64 = @as(i64, wxCell)*31 + @as(i64, @intCast(i));
			const hy: i64 = @as(i64, wyCell)*47 + @as(i64, @intCast(i))*7;
			const worldX = (@as(f64, @floatFromInt(wxCell)) + @as(f64, hashCell(hx, hy)))*@as(f64, @floatFromInt(game.WeatherGrid.cell_size));
			const worldY = (@as(f64, @floatFromInt(wyCell)) + @as(f64, hashCell(hy, hx)))*@as(f64, @floatFromInt(game.WeatherGrid.cell_size));
			const dx: f32 = @floatCast(worldX - playerPos[0]);
			const dy: f32 = @floatCast(worldY - playerPos[1]);
			const distance = @sqrt(dx*dx + dy*dy);
			if (distance < gridRadius*1.2) continue;
			const phase = hashCell(hx +% 173, hy +% 271);
			const speed = if (isSnow) 8.5 else if (isDust) 5.0 else fallSpeed;
			const dropZ = farTopZ - @as(f64, @mod(elapsedSeconds*speed/farRange + phase, 1.0)*farRange);
			const fallSeconds = @as(f32, @floatCast(farTopZ - dropZ))/speed;
			const windScale = windDriftScale(isSnow, isDust);
			const center = Vec3f{
				@floatCast(worldX + @as(f64, weatherSnapshot.wind[0]*fallSeconds*windScale) - playerPos[0]),
				@floatCast(worldY + @as(f64, weatherSnapshot.wind[1]*fallSeconds*windScale) - playerPos[1]),
				@floatCast(dropZ - playerPos[2]),
			};
			const fade = std.math.clamp(1.0 - distance/(@as(f32, @floatFromInt(game.WeatherGrid.dimension*game.WeatherGrid.cell_size))/2.0), 0.15, 0.55);
			const color = (if (isSnow) Vec3f{0.92, 0.95, 1.0} else if (isDust) Vec3f{0.72, 0.55, 0.32} else dropColor) * @as(Vec3f, @splat(fade));
			const farWidth: f32 = if (isSnow) 0.16 else if (isDust) 0.28 else 0.05;
			const farHeight: f32 = if (isSnow) 0.16 else if (isDust) 0.10 else 0.8;
			const halfWidth: Vec3f = @as(Vec3f, @splat(farWidth))*camRight;
			const halfHeight = precipitationHalfHeight(weatherSnapshot.wind, speed, windScale, farHeight*2.0);
			const base: u32 = @intCast(vertices.items.len);
			vertices.append(.{.pos = center - halfWidth - halfHeight, .color = .{color[0], color[1], color[2]}});
			vertices.append(.{.pos = center + halfWidth - halfHeight, .color = .{color[0], color[1], color[2]}});
			vertices.append(.{.pos = center + halfWidth + halfHeight, .color = .{color[0], color[1], color[2]}});
			vertices.append(.{.pos = center - halfWidth + halfHeight, .color = .{color[0], color[1], color[2]}});
			indices.appendSlice(&.{base, base + 1, base + 2, base, base + 2, base + 3});
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
