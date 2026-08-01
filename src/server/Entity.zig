const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const vec = main.vec;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

pos: Vec3d = .{0, 0, 0},
vel: Vec3d = .{0, 0, 0},
rot: Vec3f = .{0, 0, 0},

prefix: ?[]const u8 = null,
homePositions: [3]?Vec3d = .{ null, null, null },
homeNames: [3]?[]const u8 = .{ null, null, null },
respawnHome: ?u2 = null,
backPosition: ?Vec3d = null,
playtimeSeconds: u64 = 0,
sessionStartSeconds: i64 = 0,

	health: f32 = 8,
	maxHealth: f32 = 8,
	hunger: f32 = 8,
	maxHunger: f32 = 8,
	energy: f32 = 8,
maxEnergy: f32 = 8,
name: ?[]const u8 = null,
id: main.entity.Entity = .noValue,

pub fn loadFrom(self: *@This(), id: main.entity.Entity, zon: ZonElement, comptime side: main.sync.Side) !void {
	self.id = id;
	self.pos = zon.get(Vec3d, "position") orelse .{0, 0, 0};
	self.vel = zon.get(Vec3d, "velocity") orelse .{0, 0, 0};
	self.rot = zon.get(Vec3f, "rotation") orelse .{0, 0, 0};
	self.health = zon.get(f32, "health") orelse self.maxHealth;
	self.hunger = std.math.clamp(zon.get(f32, "hunger") orelse self.maxHunger, 0, self.maxHunger);
	self.energy = zon.get(f32, "energy") orelse self.maxEnergy;
	self.playtimeSeconds = zon.get(u64, "playtimeSeconds") orelse 0;
	self.sessionStartSeconds = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1_000_000_000));
	self.backPosition = zon.get(Vec3d, "backPosition");
	self.respawnHome = zon.get(u2, "respawnHome");
	inline for (0..3) |i| {
		var positionKey: [32]u8 = undefined;
		var nameKey: [32]u8 = undefined;
		const positionName = std.fmt.bufPrint(&positionKey, "homePosition{}", .{i}) catch unreachable;
		const nameName = std.fmt.bufPrint(&nameKey, "homeName{}", .{i}) catch unreachable;
		self.homePositions[i] = zon.get(Vec3d, positionName);
		if (zon.get([]const u8, nameName)) |homeName| {
			self.homeNames[i] = main.globalAllocator.dupe(u8, homeName);
		}
	}
	if (zon.get([]const u8, "prefix")) |value| {
		self.prefix = main.globalAllocator.dupe(u8, value);
	}
	if (zon.getChildOrNull("components")) |components| {
		try main.entity.loadComponentsFromBase64(components.as([]const u8) orelse "", self.id, side);
	}

	if (zon.getChildOrNull("name")) |name| {
		if (self.name) |oldname| {
			main.globalAllocator.free(oldname);
		}
		self.name = main.globalAllocator.dupe(u8, name.as([]const u8) orelse "invalid name");
	}
}
pub fn clone(self: *@This(), copy: *@This()) void {
	const originalID = copy.id;
	std.debug.assert(copy.name == null);
	copy.* = self.*;
	copy.name = if (self.name) |name| main.globalAllocator.dupe(u8, name) else null;
	copy.prefix = if (self.prefix) |value| main.globalAllocator.dupe(u8, value) else null;
	inline for (0..3) |i| {
		copy.homeNames[i] = if (self.homeNames[i]) |value| main.globalAllocator.dupe(u8, value) else null;
	}
	copy.id = originalID;
}

pub fn save(self: *const @This(), allocator: NeverFailingAllocator, audience: main.entity.AudienceInfo) ZonElement {
	const zon = ZonElement.initObject(allocator);
	zon.put("position", self.pos);
	zon.put("velocity", self.vel);
	zon.put("rotation", self.rot);
	zon.put("health", self.health);
	zon.put("hunger", self.hunger);
	zon.put("energy", self.energy);
	zon.put("id", @intFromEnum(self.id));
	if (audience == .disk) {
		const nowSeconds: i64 = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1_000_000_000));
		const sessionSeconds: u64 = @intCast(@max(nowSeconds - self.sessionStartSeconds, 0));
		zon.put("playtimeSeconds", self.playtimeSeconds + sessionSeconds);
		if (self.backPosition) |position| zon.put("backPosition", position);
		if (self.respawnHome) |index| zon.put("respawnHome", index);
		if (self.prefix) |value| zon.put("prefix", value);
		inline for (0..3) |i| {
			var positionKey: [32]u8 = undefined;
			var nameKey: [32]u8 = undefined;
			const positionName = std.fmt.bufPrint(&positionKey, "homePosition{}", .{i}) catch unreachable;
			const nameName = std.fmt.bufPrint(&nameKey, "homeName{}", .{i}) catch unreachable;
			if (self.homePositions[i]) |position| zon.put(positionName, position);
			if (self.homeNames[i]) |name| zon.put(nameName, name);
		}
	}

	var base64 = main.entity.server.componentsToBase64(allocator, self.id, audience);
	defer base64.deinit(allocator);
	zon.putOwnedString("components", base64.getEncodedMessage());

	if (self.name) |name| {
		zon.put("name", name);
	}
	return zon;
}
pub fn deinit(self: *@This(), comptime side: main.sync.Side) void {
	if (self.prefix) |value| {
		main.globalAllocator.free(value);
		self.prefix = null;
	}
	for (&self.homeNames) |*value| {
		if (value.*) |name| main.globalAllocator.free(name);
		value.* = null;
	}
	if (self.name) |name| {
		main.globalAllocator.free(name);
		self.name = null;
	}
	if (side == .server) {
		main.entity.server.removeAllComponents(self.id);
	} else {
		main.entity.client.removeAllComponents(self.id);
	}
}
