const std = @import("std");

const main = @import("main");
const utils = main.utils;

const c = @import("c");

const StbVorbisErrorEnum = enum(c_int) {
	unknown_error = -1,
	no_error = 0,
	need_more_data = 1,
	invalid_api_mixing = 2,
	outofmem = 3,
	feature_not_supported = 4,
	too_many_channels = 5,
	file_open_failure = 6,
	seek_without_length = 7,
	unexpected_eof = 10,
	seek_invalid = 11,
	invalid_setup = 20,
	invalid_stream = 21,
	missing_capture_pattern = 30,
	invalid_stream_structure_version = 31,
	continued_packet_flag_invalid = 32,
	incorrect_stream_serial_number = 33,
	invalid_first_page = 34,
	bad_packet_type = 35,
	cant_find_last_page = 36,
	seek_failed = 37,
	ogg_skeleton_not_supported = 38,
};

pub fn getStbVorbisError(result: c_int) StbVorbisErrorEnum {
	const resultEnum = std.enums.fromInt(StbVorbisErrorEnum, result) orelse {
		std.log.err("Encountered an STB Vorbis error with unknown error code {}", .{result});
		return .unknown_error;
	};

	return resultEnum;
}

fn handleError(miniaudioError: c.ma_result) !void {
	if (miniaudioError != c.MA_SUCCESS) {
		std.log.err("miniaudio error: {s}", .{c.ma_result_description(miniaudioError)});
		return error.miniaudioError;
	}
}

const AudioData = struct {
	audioId: []const u8,
	data: []f32 = &.{},
	channelType: enum { mono, stereo } = .stereo,

	fn open_vorbis_file_by_id(id: []const u8, subPath: []const u8) ?*c.stb_vorbis {
		const colonIndex = std.mem.indexOfScalar(u8, id, ':') orelse {
			std.log.err("Invalid music id: {s}. Must be addon:file_name", .{id});
			return null;
		};
		const addon = id[0..colonIndex];
		const fileName = id[colonIndex + 1 ..];
		const path1 = main.stackAllocator.printSentinel("assets/{s}/{s}/{s}.ogg", .{addon, subPath, fileName}, 0);
		defer main.stackAllocator.free(path1);
		var err1: c_int = 0;
		if (c.stb_vorbis_open_filename(path1.ptr, &err1, null)) |ogg_stream| return ogg_stream;

		const path2 = main.stackAllocator.printSentinel("{s}/serverAssets/{s}/{s}/{s}.ogg", .{main.files.cubyzDirStr(), addon, subPath, fileName}, 0);
		defer main.stackAllocator.free(path2);
		var err2: c_int = 0;
		if (c.stb_vorbis_open_filename(path2.ptr, &err2, null)) |ogg_stream| return ogg_stream;
		std.log.err("Couldn't handle or find audio file. ID: \"{s}\". Searched path: \"{s}\" (error: {any}) and \"{s}\" (error: {any})", .{id, path1, getStbVorbisError(err1), path2, getStbVorbisError(err2)});
		return null;
	}

	fn init(musicId: []const u8, subPath: []const u8) *AudioData {
		const self = main.globalAllocator.create(AudioData);
		self.* = .{.audioId = main.globalAllocator.dupe(u8, musicId)};

		const channels = 2;
		if (open_vorbis_file_by_id(musicId, subPath)) |ogg_stream| {
			defer c.stb_vorbis_close(ogg_stream);
			const ogg_info: c.stb_vorbis_info = c.stb_vorbis_get_info(ogg_stream);
			const samples = c.stb_vorbis_stream_length_in_samples(ogg_stream);
			if (sampleRate != @as(f32, @floatFromInt(ogg_info.sample_rate))) {
				const tempData = main.stackAllocator.alloc(f32, samples*channels);
				defer main.stackAllocator.free(tempData);
				self.channelType = if (ogg_info.channels == 2) .stereo else .mono;
				_ = c.stb_vorbis_get_samples_float_interleaved(ogg_stream, channels, tempData.ptr, @as(c_int, @intCast(samples))*ogg_info.channels);
				var stepWidth = @as(f32, @floatFromInt(ogg_info.sample_rate))/sampleRate;
				const newSamples: usize = @trunc(@as(f32, @floatFromInt(tempData.len/2))/stepWidth);
				stepWidth = @as(f32, @floatFromInt(samples))/@as(f32, @floatFromInt(newSamples));
				self.data = main.globalAllocator.alloc(f32, newSamples*channels);
				for (0..newSamples) |s| {
					const samplePosition = @as(f32, @floatFromInt(s))*stepWidth;
					const firstSample: usize = @floor(samplePosition);
					const interpolation = samplePosition - @floor(samplePosition);
					for (0..channels) |ch| {
						if (firstSample >= samples - 1) {
							self.data[s*channels + ch] = tempData[(samples - 1)*channels + ch];
						} else {
							self.data[s*channels + ch] = tempData[firstSample*channels + ch]*(1 - interpolation) + tempData[(firstSample + 1)*channels + ch]*interpolation;
						}
					}
				}
			} else {
				self.channelType = if (ogg_info.channels == 2) .stereo else .mono;
				self.data = main.globalAllocator.alloc(f32, samples*channels);
				_ = c.stb_vorbis_get_samples_float_interleaved(ogg_stream, channels, self.data.ptr, @as(c_int, @intCast(samples))*channels);
			}
		} else {
			self.data = main.globalAllocator.alloc(f32, channels);
			@memset(self.data, 0);
		}
		return self;
	}

	fn deinit(self: *const AudioData) void {
		main.globalAllocator.free(self.data);
		main.globalAllocator.free(self.audioId);
		main.globalAllocator.destroy(self);
	}

	pub fn hashCode(self: *const AudioData) u32 {
		var result: u32 = 0;
		for (self.audioId) |char| {
			result = result + char;
		}
		return result;
	}

	pub fn equals(self: *const AudioData, _other: ?*const AudioData) bool {
		if (_other) |other| {
			return std.mem.eql(u8, self.audioId, other.audioId);
		} else return false;
	}
};

var activeTasks: main.List([]const u8) = .empty;
var taskMutex: main.utils.Mutex = .{};

var musicCache: utils.Cache(AudioData, 4, 4, AudioData.deinit) = .{};

fn findMusic(musicId: []const u8) ?[]f32 {
	{
		taskMutex.lock();
		defer taskMutex.unlock();
		if (musicCache.find(AudioData{.audioId = musicId}, null)) |musicData| {
			return musicData.data;
		}
		for (activeTasks.items) |taskFileName| {
			if (std.mem.eql(u8, musicId, taskFileName)) {
				return null;
			}
		}
	}
	MusicLoadTask.schedule(musicId);
	return null;
}

const MusicLoadTask = struct {
	musicId: []const u8,

	const vtable = utils.ThreadPool.VTable{
		.getPriority = main.meta.castFunctionSelfToAnyopaque(getPriority),
		.isStillNeeded = main.meta.castFunctionSelfToAnyopaque(isStillNeeded),
		.run = main.meta.castFunctionSelfToAnyopaque(run),
		.clean = main.meta.castFunctionSelfToAnyopaque(clean),
		.taskType = .misc,
	};

	pub fn schedule(musicId: []const u8) void {
		const task = main.globalAllocator.create(MusicLoadTask);
		task.* = MusicLoadTask{
			.musicId = main.globalAllocator.dupe(u8, musicId),
		};
		main.threadPool.addTask(task, &vtable);
		taskMutex.lock();
		defer taskMutex.unlock();
		activeTasks.append(main.globalAllocator, task.musicId);
	}

	pub fn getPriority(_: *MusicLoadTask) f32 {
		return std.math.floatMax(f32);
	}

	pub fn isStillNeeded(_: *MusicLoadTask) bool {
		return true;
	}

	pub fn run(self: *MusicLoadTask) void {
		defer self.clean();
		const data = AudioData.init(self.musicId, "music");
		const hasOld = musicCache.addToCache(data, data.hashCode());
		if (hasOld) |old| {
			old.deinit();
		}
	}

	pub fn clean(self: *MusicLoadTask) void {
		taskMutex.lock();
		var index: usize = 0;
		while (index < activeTasks.items.len) : (index += 1) {
			if (activeTasks.items[index].ptr == self.musicId.ptr) break;
		}
		_ = activeTasks.swapRemove(index);
		taskMutex.unlock();
		main.globalAllocator.free(self.musicId);
		main.globalAllocator.destroy(self);
	}
};

// MARK: Sound effects
//
// General-purpose positional one-shot SFX, layered on top of AudioData's existing cache/decode
// machinery (same lazy-load-via-threadPool pattern as music, just pointed at assets/<addon>/sounds/
// instead of assets/<addon>/music/). Unlike music there is no single "active track" - many sound
// effects can be playing at once (footsteps, block breaks, ...), so this keeps a small fixed-size
// pool of concurrently-playing instances instead of one global `currentMusic`-style slot.
//
// Positional attenuation is linear distance falloff only for now (no stereo panning) - AudioData
// always upmixes mono source files to interleaved stereo at load time (see AudioData.init), so doing
// real per-instance panning would need the original mono signal kept separately. Fine for a first
// pass; real panning can be added later once actual SFX assets exist to tune it against.
//
// Trigger call sites (block break/place, footsteps, ...) are expected to pass ids like
// "cubyz:block_break/stone" or "cubyz:mob/moffalo/hurt" - see playSound's doc comment. Until real
// files exist at those paths, AudioData.init's existing missing-file fallback (silence, logged once
// via the same err path music already uses) makes every call here a safe no-op.

// 32 buckets x 8 slots = 256 cached sounds - each distinct "<id>_NNN" variant is its own cache entry
// (playSoundVariant picks a different suffix per call), so the real working set is (number of sound
// families) x (variants per family), not just the number of families - a too-small cache here meant
// almost every play was a cache miss (silent this call, loads in the background for next time),
// which read as "sounds are quiet/don't play the first time" / "no sound until the block breaks".
var soundCache: utils.Cache(AudioData, 32, 8, AudioData.deinit) = .{};
var soundTaskMutex: main.utils.Mutex = .{};
var activeSoundTasks: main.List([]const u8) = .empty;

fn findSound(soundId: []const u8) ?[]const f32 {
	{
		soundTaskMutex.lock();
		defer soundTaskMutex.unlock();
		if (soundCache.find(AudioData{.audioId = soundId}, null)) |soundData| {
			return soundData.data;
		}
		for (activeSoundTasks.items) |taskId| {
			if (std.mem.eql(u8, soundId, taskId)) return null;
		}
	}
	SoundLoadTask.schedule(soundId);
	return null;
}

const SoundLoadTask = struct {
	soundId: []const u8,

	const vtable = utils.ThreadPool.VTable{
		.getPriority = main.meta.castFunctionSelfToAnyopaque(getPriority),
		.isStillNeeded = main.meta.castFunctionSelfToAnyopaque(isStillNeeded),
		.run = main.meta.castFunctionSelfToAnyopaque(run),
		.clean = main.meta.castFunctionSelfToAnyopaque(clean),
		.taskType = .misc,
	};

	pub fn schedule(soundId: []const u8) void {
		const task = main.globalAllocator.create(SoundLoadTask);
		task.* = SoundLoadTask{.soundId = main.globalAllocator.dupe(u8, soundId)};
		main.threadPool.addTask(task, &vtable);
		soundTaskMutex.lock();
		defer soundTaskMutex.unlock();
		activeSoundTasks.append(main.globalAllocator, task.soundId);
	}

	pub fn getPriority(_: *SoundLoadTask) f32 {
		return std.math.floatMax(f32);
	}

	pub fn isStillNeeded(_: *SoundLoadTask) bool {
		return true;
	}

	pub fn run(self: *SoundLoadTask) void {
		defer self.clean();
		const data = AudioData.init(self.soundId, "sounds");
		const hasOld = soundCache.addToCache(data, data.hashCode());
		if (hasOld) |old| old.deinit();
	}

	pub fn clean(self: *SoundLoadTask) void {
		soundTaskMutex.lock();
		var index: usize = 0;
		while (index < activeSoundTasks.items.len) : (index += 1) {
			if (activeSoundTasks.items[index].ptr == self.soundId.ptr) break;
		}
		_ = activeSoundTasks.swapRemove(index);
		soundTaskMutex.unlock();
		main.globalAllocator.free(self.soundId);
		main.globalAllocator.destroy(self);
	}
};

const maxConcurrentSounds = 32;
/// Sounds fall off to silence at this many blocks away, scaled by each call's `maxDistance` param.
const defaultSoundMaxDistance: f32 = 24.0;

const PlayingSound = struct {
	buffer: []const f32 = &.{},
	pos: usize = 0,
	volume: f32 = 0,
	/// null = non-positional (always full volume, e.g. UI sounds) - see playSoundFlat.
	worldPos: ?main.vec.Vec3d = null,
	maxDistance: f32 = defaultSoundMaxDistance,
	active: bool = false,
};

var playingSounds: [maxConcurrentSounds]PlayingSound = @splat(.{});
var soundMutex: main.utils.Mutex = .{};

fn startSoundInstance(buffer: []const f32, volume: f32, worldPos: ?main.vec.Vec3d, maxDistance: f32) void {
	soundMutex.lock();
	defer soundMutex.unlock();
	for (&playingSounds) |*slot| {
		if (!slot.active) {
			slot.* = .{.buffer = buffer, .pos = 0, .volume = volume, .worldPos = worldPos, .maxDistance = maxDistance, .active = true};
			return;
		}
	}
	// Pool exhausted - drop the new sound rather than cutting off one already playing.
}

const knownSoundMaterials = [_][]const u8{"wood", "stone", "dirt", "snow", "plant", "leaves", "mushroom", "generic"};
const knownSoundActions = [_][]const u8{"footstep", "block_break", "block_place"};
const knownSoundVariants = 5;
const knownUiClickVariants = 5;

/// How many "<action>/<material>_NNN" variants actually exist on disk - almost everything ships the
/// full knownSoundVariants (5), but footstep/dirt and footstep/snow were trimmed to 3 (user found
/// dirt_001/dirt_002 too high-pitched and snow_000/snow_001 too loud relative to the others) - the
/// files were renumbered contiguously (0..2) rather than left with gaps, since playSoundVariant always
/// assumes a contiguous [0, variantCount) range. Centralized here instead of hardcoding "5" at every
/// call site so trimming a family's variant count in the future only needs one change, not one per
/// trigger site (game.zig, sync.zig, renderer.zig) plus preloadAll below.
pub fn soundVariantCount(action: []const u8, material: []const u8) u32 {
	if (std.mem.eql(u8, action, "footstep") and (std.mem.eql(u8, material, "dirt") or std.mem.eql(u8, material, "snow"))) {
		return 3;
	}
	return knownSoundVariants;
}

/// Eagerly schedules every sound effect this build ships (assets/cubyz/sounds/**) to load into
/// soundCache, so the *first* real play of each one isn't a silent cache-miss (findSound returning
/// null while the async load is still in flight) - previously the only way a sound got loaded was a
/// real gameplay trigger, so e.g. the first-ever stone footstep in a session played nothing. Call
/// once at startup (see main.zig), not per-world - these are static asset-pack sounds, not
/// world-specific data, and preloading them again on every world entry would just re-schedule loads
/// for ids already sitting in the cache (harmless, since findSound short-circuits, but pointless).
/// If you add a new sound material/action/variant count, update the lists above to match or the new
/// files won't get this eager-load treatment (they'll still work, just fall back to the old
/// silent-on-first-play behavior until something else triggers a load).
pub fn preloadAll() void {
	for (knownSoundActions) |action| {
		for (knownSoundMaterials) |material| {
			for (0..soundVariantCount(action, material)) |variant| {
				const id = main.stackAllocator.print("cubyz:{s}/{s}_{:0>3}", .{action, material, variant});
				defer main.stackAllocator.free(id);
				_ = findSound(id);
			}
		}
	}
	for (0..knownUiClickVariants) |variant| {
		const id = main.stackAllocator.print("cubyz:ui/click_{:0>3}", .{variant});
		defer main.stackAllocator.free(id);
		_ = findSound(id);
	}
}

/// Plays a one-shot sound effect at a world position, attenuated by distance from the listener
/// (the local player's eye position) down to silence at `maxDistance` blocks. `soundId` follows the
/// same "addon:file_name" convention as music ids, loaded from assets/<addon>/sounds/<file_name>.ogg
/// (or the server-assets override path) - see AudioData.open_vorbis_file_by_id. Safe to call for a
/// sound file that doesn't exist yet: it resolves to silence (logged once) rather than erroring,
/// same fallback behavior main.audio's music loading already has.
pub fn playSound(soundId: []const u8, worldPos: main.vec.Vec3d, volume: f32, maxDistance: f32) void {
	const buffer = findSound(soundId) orelse return;
	if (buffer.len == 0) return;
	startSoundInstance(buffer, volume, worldPos, maxDistance);
}

/// Plays a one-shot sound effect with no positional attenuation (always full volume) - for UI clicks
/// and other sounds that aren't tied to a place in the world.
pub fn playSoundFlat(soundId: []const u8, volume: f32) void {
	const buffer = findSound(soundId) orelse return;
	if (buffer.len == 0) return;
	startSoundInstance(buffer, volume, null, 0);
}

/// Picks a random variant N in [0, variantCount) and plays "<baseId>_NNN" (zero-padded to 3 digits,
/// matching Kenney's own asset naming e.g. footstep_wood_000.ogg..footstep_wood_004.ogg) so the same
/// trigger doesn't play the exact same sample every time - avoids the "on loop" repetitiveness of a
/// single fixed sound. variantCount must be >= 1; asserts otherwise since 0 would mean "no sound
/// exists at all", which should be expressed by not calling this rather than passing 0.
pub fn playSoundVariant(baseId: []const u8, variantCount: u32, worldPos: main.vec.Vec3d, volume: f32, maxDistance: f32) void {
	std.debug.assert(variantCount >= 1);
	const variant = main.random.nextIntBounded(u32, &main.seed, variantCount);
	const soundId = main.stackAllocator.print("{s}_{:0>3}", .{baseId, variant});
	defer main.stackAllocator.free(soundId);
	playSound(soundId, worldPos, volume, maxDistance);
}

/// Non-positional counterpart to playSoundVariant - see its doc comment.
pub fn playSoundVariantFlat(baseId: []const u8, variantCount: u32, volume: f32) void {
	std.debug.assert(variantCount >= 1);
	const variant = main.random.nextIntBounded(u32, &main.seed, variantCount);
	const soundId = main.stackAllocator.print("{s}_{:0>3}", .{baseId, variant});
	defer main.stackAllocator.free(soundId);
	playSoundFlat(soundId, volume);
}

fn mixSoundEffects(buffer: []f32) void {
	soundMutex.lock();
	defer soundMutex.unlock();
	const listenerPos = if (main.game.world != null) main.game.Player.getEyePosBlocking() else main.vec.Vec3d{0, 0, 0};
	for (&playingSounds) |*slot| {
		if (!slot.active) continue;

		var distanceGain: f32 = 1.0;
		if (slot.worldPos) |soundPos| {
			const diff = soundPos - listenerPos;
			const dist: f32 = @floatCast(main.vec.length(diff));
			if (dist >= slot.maxDistance) {
				slot.active = false;
				continue;
			}
			distanceGain = std.math.clamp(1.0 - dist/slot.maxDistance, 0.0, 1.0);
		}
		const amplitude = slot.volume*distanceGain*main.settings.soundVolume;

		var i: usize = 0;
		while (i < buffer.len) : (i += 2) {
			if (slot.pos + 1 >= slot.buffer.len) {
				slot.active = false;
				break;
			}
			buffer[i] += amplitude*slot.buffer[slot.pos];
			buffer[i + 1] += amplitude*slot.buffer[slot.pos + 1];
			slot.pos += 2;
		}
	}
}

var device: c.ma_device = undefined;

var sampleRate: f32 = 0;

pub fn init() error{miniaudioError}!void {
	var config = c.ma_device_config_init(c.ma_device_type_playback);
	config.playback.format = c.ma_format_f32;
	config.playback.channels = 2;
	config.sampleRate = 44100;
	config.dataCallback = &miniaudioCallback;
	config.pUserData = undefined;

	try handleError(c.ma_device_init(null, &config, &device));
	errdefer c.ma_device_uninit(&device);

	try handleError(c.ma_device_start(&device));

	sampleRate = 44100;
}

pub fn deinit() void {
	handleError(c.ma_device_stop(&device)) catch {};
	c.ma_device_uninit(&device);
	mutex.lock();
	defer mutex.unlock();
	main.threadPool.closeAllTasksOfType(&MusicLoadTask.vtable);
	musicCache.clear();
	activeTasks.deinit(main.globalAllocator);
	main.globalAllocator.free(preferredMusic);
	preferredMusic.len = 0;
	main.globalAllocator.free(activeMusicId);
	activeMusicId.len = 0;

	main.threadPool.closeAllTasksOfType(&SoundLoadTask.vtable);
	soundCache.clear();
	activeSoundTasks.deinit(main.globalAllocator);
}

const currentMusic = struct {
	var buffer: []const f32 = undefined;
	var animationAmplitude: f32 = undefined;
	var animationVelocity: f32 = undefined;
	var animationDecaying: bool = undefined;
	var animationProgress: f32 = undefined;
	var interpolationPolynomial: [4]f32 = undefined;
	var pos: u32 = undefined;

	fn init(musicBuffer: []const f32) void {
		buffer = musicBuffer;
		animationAmplitude = 0;
		animationVelocity = 0;
		animationDecaying = false;
		animationProgress = 0;
		interpolationPolynomial = utils.unitIntervalSpline(f32, animationAmplitude, animationVelocity, 1, 0);
		pos = 0;
	}

	fn evaluatePolynomial() void {
		const t = animationProgress;
		const t2 = t*t;
		const t3 = t2*t;
		const a = interpolationPolynomial;
		animationAmplitude = a[0] + a[1]*t + a[2]*t2 + a[3]*t3;
		animationVelocity = a[1] + 2*a[2]*t + 3*a[3]*t2;
	}
};

const thunder = struct {
	var delaySamples: u64 = 0;
	var samplesPlayed: u64 = 0;
	var strength: f32 = 0;
	var seed: u64 = 0;
	var lowFrequencyNoise: f32 = 0;
};

var activeMusicId: []const u8 = &.{};
const animationLengthInSeconds = 5.0;

var mutex: main.utils.Mutex = .{};
var preferredMusic: []const u8 = "";

pub fn setMusic(music: []const u8) void {
	mutex.lock();
	defer mutex.unlock();
	if (std.mem.eql(u8, music, preferredMusic)) return;
	main.globalAllocator.free(preferredMusic);
	preferredMusic = main.globalAllocator.dupe(u8, music);
}

pub fn playThunder(delaySeconds: f32, strength: f32) void {
	mutex.lock();
	defer mutex.unlock();
	if (thunder.strength > 0.0) return;
	thunder.delaySamples = @intFromFloat(@max(0.0, delaySeconds)*sampleRate);
	thunder.samplesPlayed = 0;
	thunder.strength = std.math.clamp(strength, 0.0, 1.0);
	thunder.seed = @intCast(main.timestamp().toMilliseconds());
	thunder.lowFrequencyNoise = 0;
}

fn mixThunder(buffer: []f32) void {
	if (thunder.strength <= 0.0) return;
	const durationSeconds: f32 = 3.5;
	var i: usize = 0;
	while (i < buffer.len) : (i += 2) {
		if (thunder.delaySamples != 0) {
			thunder.delaySamples -= 1;
			continue;
		}
		const t = @as(f32, @floatFromInt(thunder.samplesPlayed))/sampleRate;
		if (t >= durationSeconds) {
			thunder.strength = 0;
			return;
		}
		thunder.seed = thunder.seed *% 6364136223846793005 +% 1442695040888963407;
		const randomBits: u16 = @truncate(thunder.seed >> 32);
		const random: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(randomBits))))/32768.0;
		thunder.lowFrequencyNoise += (random - thunder.lowFrequencyNoise)*0.012;
		const onset = std.math.clamp(t*18.0, 0.0, 1.0);
		const envelope = onset*@exp(-t*0.78);
		const rumble = (thunder.lowFrequencyNoise*0.92 + random*0.08)*envelope*thunder.strength*1.2*main.settings.soundVolume;
		buffer[i] += rumble;
		buffer[i + 1] += rumble;
		thunder.samplesPlayed += 1;
	}
}

fn mixMusic(buffer: []f32) void {
	mutex.lock();
	defer mutex.unlock();
	if (!std.mem.eql(u8, preferredMusic, activeMusicId)) {
		if (activeMusicId.len == 0) {
			if (findMusic(preferredMusic)) |musicBuffer| {
				currentMusic.init(musicBuffer);
				main.globalAllocator.free(activeMusicId);
				activeMusicId = main.globalAllocator.dupe(u8, preferredMusic);
			}
		} else if (!currentMusic.animationDecaying) {
			_ = findMusic(preferredMusic);
			currentMusic.animationDecaying = true;
			currentMusic.animationProgress = 0;
			currentMusic.interpolationPolynomial = utils.unitIntervalSpline(f32, currentMusic.animationAmplitude, currentMusic.animationVelocity, 0, 0);
		}
	} else if (currentMusic.animationDecaying) {
		currentMusic.animationDecaying = false;
		currentMusic.animationProgress = 0;
		currentMusic.interpolationPolynomial = utils.unitIntervalSpline(f32, currentMusic.animationAmplitude, currentMusic.animationVelocity, 1, 0);
	}
	if (activeMusicId.len == 0) return;

	var i: usize = 0;
	while (i < buffer.len) : (i += 2) {
		currentMusic.animationProgress += 1.0/(animationLengthInSeconds*sampleRate);
		var amplitude: f32 = main.settings.musicVolume;
		if (currentMusic.animationProgress > 1) {
			if (currentMusic.animationDecaying) {
				main.globalAllocator.free(activeMusicId);
				activeMusicId = &.{};
				amplitude = 0;
			}
		} else {
			currentMusic.evaluatePolynomial();
			amplitude *= currentMusic.animationAmplitude;
		}
		buffer[i] += amplitude*currentMusic.buffer[currentMusic.pos];
		buffer[i + 1] += amplitude*currentMusic.buffer[currentMusic.pos + 1];
		currentMusic.pos += 2;
		if (currentMusic.pos >= currentMusic.buffer.len) {
			currentMusic.pos = 0;
		}
	}
}

fn miniaudioCallback(
	maDevice: ?*anyopaque,
	output: ?*anyopaque,
	input: ?*const anyopaque,
	frameCount: u32,
) callconv(.c) void {
	_ = input;
	_ = maDevice;
	const valuesPerBuffer = 2*frameCount;
	const buffer = @as([*]f32, @ptrCast(@alignCast(output)))[0..valuesPerBuffer];
	@memset(buffer, 0);
	mixMusic(buffer);
	mixThunder(buffer);
	mixSoundEffects(buffer);
}
