const std = @import("std");

const main = @import("main");
const random = main.random;
const terrain = main.server.terrain;
const Biome = terrain.biomes.Biome;

// Per-biome-patch weather state, keyed by the same stable per-patch seed already used elsewhere for
// biome-position-specific randomness (see CaveBiomeMap.zig's getBiomeAndSeed doc comment: "a seed that
// is unique for the corresponding biome position"). This reuses existing biome placement identity rather
// than inventing a separate weather grid — every patch of, say, jungle gets its own independent weather
// state, while re-entering the exact same patch later finds its state exactly where it was left.
//
// Design (see memory.md's weather system entry for the full plan): a player standing in a patch for
// `entryDelayMillis` starts the dice rolling; every `rerollIntervalMillis` after that while still
// occupied, a new rainTarget is rolled based on the biome's hot/wet/temperate/dry properties. The
// rendered/synced value (rainCurrent) always eases toward rainTarget exponentially rather than snapping,
// so crossing a biome boundary never causes an instant visible change — only entering a *new* patch
// changes which patch's (slowly-moving) value you're now reading.

const WeatherPatchState = struct {
	rainTarget: f32 = 0,
	rainCurrent: f32 = 0,
	/// Milliseconds timestamp of when a player first (re-)entered this patch after it was unoccupied, or
	/// null while unoccupied. Used to gate the initial roll behind entryDelayMillis.
	occupiedSinceMillis: ?i64 = null,
	/// Milliseconds timestamp of the next scheduled reroll.
	nextRerollMillis: i64 = 0,
};

/// How long a patch must be continuously occupied before its first weather roll happens. Cut from 2.5
/// minutes to 30 seconds (2026-07-28) at the player's request — still long enough that briefly passing
/// through a biome doesn't trigger a roll, but noticeably faster to see the system react at all.
const entryDelayMillis: i64 = 30_000; // 30 seconds
/// How often an occupied patch rerolls afterward.
const rerollIntervalMillis: i64 = 450_000; // 7.5 minutes
/// How quickly the synced/rendered value eases toward the rolled target — same exponential-approach
/// technique game.zig's DayTime.update() already uses for biome fog color, so a fresh roll never pops.
const easeRatePerSecond: f32 = 0.15;

var mutex: main.utils.Mutex = .{};
var patches: std.AutoHashMapUnmanaged(u64, WeatherPatchState) = .{};

pub fn deinit() void {
	mutex.lock();
	defer mutex.unlock();
	patches.deinit(main.globalAllocator.allocator);
	patches = .{};
}

/// Rolls a new rain target for a patch based on its biome's climate properties. Hot biomes almost never
/// get rain and even then only lightly; wet biomes (swamp/jungle) roll high most of the time; temperate/
/// neitherWetNorDry average out; dry further dampens whatever hot/temperate/cold contributes.
fn rollRainTarget(biome: *const Biome, seed: *u64) f32 {
	const props = biome.properties;
	// Desert biomes (dry & hot) never get rain
	if (props.dry and props.hot) return 0;

	var chance: f32 = 0.35; // baseline for temperate/unspecified
	var maxIntensity: f32 = 0.6;
	if (props.hot) {
		chance = 0.03;
		maxIntensity = 0.25;
	}
	if (props.cold) {
		chance = 0.4;
		maxIntensity = 0.7;
	}
	if (props.wet) {
		chance = 0.75;
		maxIntensity = 1.0;
	}
	if (props.dry) {
		chance *= 0.4;
		maxIntensity *= 0.5;
	}

	if (random.nextFloat(seed) > chance) return 0;
	return random.nextFloat(seed)*maxIntensity;
}

/// Called once per server tick per online player (see server.zig's update(), right after the existing
/// per-user biome-change check). `patchSeed` identifies which biome patch the player currently occupies
/// (ServerWorld.getBiomeAndSeed); `biome` is that patch's resolved biome, used only when a roll actually
/// happens. Returns the patch's current (smoothly-eased) rain intensity in [0, 1], to be sent to the
/// client whenever it has moved meaningfully since the last value that was sent to that player.
pub fn tick(patchSeed: u64, biome: *const Biome, nowMillis: i64, deltaSeconds: f32) f32 {
	mutex.lock();
	defer mutex.unlock();

	const entry = patches.getOrPutValue(main.globalAllocator.allocator, patchSeed, .{}) catch unreachable;
	const state = entry.value_ptr;

	if (state.occupiedSinceMillis == null) {
		state.occupiedSinceMillis = nowMillis;
		state.nextRerollMillis = nowMillis + entryDelayMillis;
	} else if (nowMillis >= state.nextRerollMillis) {
		var seed = patchSeed ^ @as(u64, @bitCast(nowMillis)) ^ 0x9e3779b97f4a7c15;
		state.rainTarget = rollRainTarget(biome, &seed);
		state.nextRerollMillis = nowMillis + rerollIntervalMillis;
	}

	const t = 1 - @exp(-easeRatePerSecond*deltaSeconds);
	state.rainCurrent += (state.rainTarget - state.rainCurrent)*t;
	return state.rainCurrent;
}
