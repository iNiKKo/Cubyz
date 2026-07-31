const std = @import("std");

const main = @import("main");
const BlockPos = main.chunk.BlockPos;
const ZonElement = main.ZonElement;
const vec = main.vec;
const Vec3i = vec.Vec3i;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

pub const DelayedBlockUpdate = struct {
	pos: BlockPos,
	targetTime: i64,
};

list: main.List(DelayedBlockUpdate) = .empty,
mutex: main.utils.Mutex = .{},

pub fn init() @This() {
	return .{};
}
pub fn deinit(self: *@This()) void {
	self.mutex = undefined;
	self.list.deinit(main.globalAllocator);
}
pub fn add(self: *@This(), position: BlockPos) void {
	self.addWithDelay(position, 0);
}
pub fn addWithDelay(self: *@This(), position: BlockPos, delayMs: i64) void {
	self.mutex.lock();
	defer self.mutex.unlock();
	const targetTime = main.timestamp().toMilliseconds() + delayMs;

	for (self.list.items) |*item| {
		if (item.pos.x == position.x and item.pos.y == position.y and item.pos.z == position.z) {
			if (targetTime < item.targetTime) {
				item.targetTime = targetTime;
			}
			return;
		}
	}

	self.list.append(main.globalAllocator, .{ .pos = position, .targetTime = targetTime });
}
pub fn update(self: *@This(), ch: *main.chunk.ServerChunk) void {
	self.mutex.lock();
	if (self.list.items.len == 0) {
		self.mutex.unlock();
		return;
	}
	const now = main.timestamp().toMilliseconds();

	var readyList: main.List(DelayedBlockUpdate) = .empty;
	var keepList: main.List(DelayedBlockUpdate) = .empty;

	for (self.list.items) |item| {
		if (item.targetTime <= now) {
			readyList.append(main.globalAllocator, item);
		} else {
			keepList.append(main.globalAllocator, item);
		}
	}

	self.list.deinit(main.globalAllocator);
	self.list = keepList;
	self.mutex.unlock();

	defer readyList.deinit(main.globalAllocator);

	for (readyList.items) |event| {
		ch.mutex.lock();
		const block = ch.getBlock(event.pos.x, event.pos.y, event.pos.z);
		ch.mutex.unlock();

		_ = block.onUpdate().run(.{
			.block = block,
			.chunk = ch,
			.blockPos = event.pos,
		});
	}
}
