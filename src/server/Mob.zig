const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const vec = main.vec;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

pub const MobType = enum(u8) {
	moffalo = 0,

	pub fn modelId(self: MobType) []const u8 {
		return switch (self) {
			.moffalo => "cubyz:moffalo",
		};
	}

	pub fn displayName(self: MobType) []const u8 {
		return switch (self) {
			.moffalo => "Moffalo",
		};
	}

	pub fn maxHealth(self: MobType) f32 {
		return switch (self) {
			.moffalo => 8,
		};
	}

	/// Item id dropped on death.
	pub fn dropItemId(self: MobType) []const u8 {
		return switch (self) {
			.moffalo => "cubyz:raw_meat",
		};
	}

	/// Inclusive [min, max] range for how many of dropItemId() drop on death.
	pub fn dropAmountRange(self: MobType) struct {min: u16, max: u16} {
		return switch (self) {
			.moffalo => .{.min = 3, .max = 4},
		};
	}
};

pub const AiState = enum(u8) {
	wander,
	pause,
	flee,
	attract,
	follow,
	shelter,

	pub fn label(self: AiState) []const u8 {
		return switch (self) {
			.wander => "wandering",
			.pause => "idle",
			.flee => "fleeing",
			.attract => "watching you",
			.follow => "following",
			.shelter => "sheltering from rain",
		};
	}
};

id: main.entity.Entity = .noValue,
mobType: MobType = .moffalo,

pos: Vec3d = .{0, 0, 0},
vel: Vec3d = .{0, 0, 0},
rot: Vec3f = .{0, 0, 0},
onGround: bool = false,

state: AiState = .wander,
stateTimer: f32 = 0,
wanderDir: Vec3f = .{0, 0, 0},
randState: u64 = 0,

stuckTimer: f32 = 0,
stuckAnchorPos: Vec3d = .{0, 0, 0},
jumpCooldown: f32 = 0,

health: f32 = 10,

/// The player who fed this mob (and thus its whole nearby herd) an apple; that
/// player no longer triggers flee. Stored as the player's persistent PlayerIndex
/// (stable across reconnects/restarts) rather than the ephemeral entity id, which
/// gets reallocated from scratch every server start. noTamer means untamed.
tamedBy: usize = noTamer,

/// Position under tree cover this mob is heading to / standing under while sheltering from rain.
shelterTarget: Vec3d = .{0, 0, 0},
shelterSearchCooldown: f32 = 0,

pub const noTamer = std.math.maxInt(usize);

pub fn toBytes(self: *const @This(), writer: *main.utils.BinaryWriter) void {
	writer.writeInt(u32, @intFromEnum(self.id));
	writer.writeInt(u8, @intFromEnum(self.mobType));
	writer.writeVec(Vec3d, self.pos);
	writer.writeVec(Vec3d, self.vel);
	writer.writeVec(Vec3f, self.rot);
	writer.writeInt(u8, @intFromEnum(self.state));
	writer.writeFloat(f32, self.stateTimer);
	writer.writeVec(Vec3f, self.wanderDir);
	writer.writeInt(u64, self.randState);
	writer.writeInt(u64, self.tamedBy);
	writer.writeFloat(f32, self.health);
}

fn enumFromIntChecked(comptime T: type, value: @typeInfo(T).@"enum".tag_type) !T {
	inline for (@typeInfo(T).@"enum".fields) |field| {
		if (field.value == value) return @enumFromInt(value);
	}
	return error.Invalid;
}

pub fn fromBytes(reader: *main.utils.BinaryReader) !@This() {
	var self: @This() = .{};
	self.id = @enumFromInt(try reader.readInt(u32));
	self.mobType = try enumFromIntChecked(MobType, try reader.readInt(u8));
	self.pos = try reader.readVec(Vec3d);
	self.vel = try reader.readVec(Vec3d);
	self.rot = try reader.readVec(Vec3f);
	self.state = try enumFromIntChecked(AiState, try reader.readInt(u8));
	self.stateTimer = try reader.readFloat(f32);
	self.wanderDir = try reader.readVec(Vec3f);
	self.randState = try reader.readInt(u64);
	self.tamedBy = try reader.readInt(u64);
	self.health = try reader.readFloat(f32);
	self.stuckAnchorPos = self.pos;
	return self;
}

pub fn save(self: *const @This(), allocator: NeverFailingAllocator) ZonElement {
	const zon = ZonElement.initObject(allocator);
	zon.put("id", @intFromEnum(self.id));
	zon.put("mobType", @intFromEnum(self.mobType));
	zon.put("position", self.pos);
	zon.put("velocity", self.vel);
	zon.put("rotation", self.rot);
	zon.put("randState", self.randState);
	zon.put("tamedBy", self.tamedBy);
	zon.put("health", self.health);

	const tamedSuffix: []const u8 = if (self.tamedBy != noTamer) ", tamed" else "";
	const name = allocator.print("{s} [{s}{s}] {d:.0}/{d:.0}HP", .{self.mobType.displayName(), self.state.label(), tamedSuffix, self.health, self.mobType.maxHealth()});
	defer allocator.free(name);
	zon.putOwnedString("name", name);

	var base64 = main.entity.server.componentsToBase64(allocator, self.id, .playerNearby);
	defer base64.deinit(allocator);
	zon.putOwnedString("components", base64.getEncodedMessage());

	return zon;
}
