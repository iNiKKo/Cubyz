const std = @import("std");

const main = @import("main");
const terrain = main.server.terrain;
const Biome = terrain.biomes.Biome;
const ValueNoise = terrain.noise.ValueNoise;

pub const PrecipitationKind = enum(u8) { none, rain, snow, dust };

pub const WeatherSample = struct {
	cloudCover: f32,
	precipitation: f32,
	dust: f32,
	wind: @Vector(2, f32),
	kind: PrecipitationKind,
};

const cloudScale: f32 = 720.0;
const detailScale: f32 = 180.0;
const windEpochMillis: i64 = 900_000;
const windSpeed: f32 = 0.85;

pub fn deinit() void {}

fn windForEpoch(worldSeed: u64, epoch: i64) @Vector(2, f32) {
	var seed = worldSeed ^ @as(u64, @bitCast(epoch)) ^ 0x4f1bbcdcaa6f8f43;
	const angle = main.random.nextFloat(&seed)*2.0*std.math.pi;
	const speed = windSpeed + main.random.nextFloatSigned(&seed)*0.25;
	return .{@cos(angle)*speed, @sin(angle)*speed};
}

fn smoothstep(x: f32) f32 {
	const t = std.math.clamp(x, 0.0, 1.0);
	return t*t*(3.0 - 2.0*t);
}

pub fn windAt(worldSeed: u64, nowMillis: i64) @Vector(2, f32) {
	const epoch = @divFloor(nowMillis, windEpochMillis);
	const epochStart = epoch*windEpochMillis;
	const transition = smoothstep(@as(f32, @floatFromInt(nowMillis - epochStart))/@as(f32, @floatFromInt(windEpochMillis)));
	return windForEpoch(worldSeed, epoch)*@as(@Vector(2, f32), @splat(1.0 - transition)) + windForEpoch(worldSeed, epoch + 1)*@as(@Vector(2, f32), @splat(transition));
}

pub fn sampleWithWind(worldSeed: u64, biome: *const Biome, wx: i32, wy: i32, nowMillis: i64, wind: @Vector(2, f32)) WeatherSample {
	const elapsedSeconds: f32 = @as(f32, @floatFromInt(nowMillis))*0.001;
	const advectedX = @as(f32, @floatFromInt(wx)) - wind[0]*elapsedSeconds;
	const advectedY = @as(f32, @floatFromInt(wy)) - wind[1]*elapsedSeconds;
	const broad = ValueNoise.samplePoint2D(advectedX/cloudScale, advectedY/cloudScale, worldSeed ^ 0x2e0f9b14d83ca761);
	const detail = ValueNoise.samplePoint2D(advectedX/detailScale, advectedY/detailScale, worldSeed ^ 0x76a6ce159d4b202f);
	const moisture = std.math.clamp(broad*0.75 + detail*0.25, 0.0, 1.0);
	var cloudCover = smoothstep((moisture - 0.42)/0.34);
	var precipitation = smoothstep((moisture - 0.64)/0.24);
	var dust: f32 = 0;
	var kind: PrecipitationKind = .rain;

	const profile = switch (biome.weatherProfile) {
		.automatic => blk: {
			if (biome.properties.cold) break :blk Biome.WeatherProfile.frost;
			if (biome.properties.wet) break :blk Biome.WeatherProfile.humid;
			if (biome.properties.dry) break :blk Biome.WeatherProfile.arid;
			break :blk Biome.WeatherProfile.temperate;
		},
		else => biome.weatherProfile,
	};

	switch (profile) {
		.humid => precipitation *= 1.0,
		.temperate => precipitation *= 0.65,
		.snow => {
			precipitation *= 0.75;
			kind = .snow;
		},
		.frost => {

			precipitation = 0;
			kind = .none;
		},
		.arid => {
			cloudCover *= 0.55;
			precipitation *= 0.12;
		},
		.desert => {

			cloudCover *= 0.20;
			precipitation = 0;
			dust = smoothstep((@sqrt(wind[0]*wind[0] + wind[1]*wind[1]) - 0.70)/0.35)*smoothstep((moisture - 0.38)/0.35);
			if (dust > 0.01) kind = .dust else kind = .none;
		},
		.automatic => unreachable,
	}

	if (precipitation <= 0.01 and kind != .dust) kind = .none;
	return .{.cloudCover = cloudCover, .precipitation = precipitation, .dust = dust, .wind = wind, .kind = kind};
}

pub fn sample(worldSeed: u64, biome: *const Biome, wx: i32, wy: i32, nowMillis: i64) WeatherSample {
	return sampleWithWind(worldSeed, biome, wx, wy, nowMillis, windAt(worldSeed, nowMillis));
}
