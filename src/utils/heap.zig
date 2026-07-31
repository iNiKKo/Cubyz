const std = @import("std");
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

const main = @import("main");

var testingErrorHandlingAllocator = ErrorHandlingAllocator.init(std.testing.allocator);
pub const testingAllocator = testingErrorHandlingAllocator.allocator();

pub const allocators = struct {
	pub var globalGpa = std.heap.DebugAllocator(.{.thread_safe = true}){};
	pub var handledGpa = ErrorHandlingAllocator.init(globalGpa.allocator());
	pub var globalArenaAllocator: NeverFailingArenaAllocator = .init(handledGpa.allocator());
	pub var worldArenaAllocator: NeverFailingArenaAllocator = undefined;
	var worldArenaOpenCount: usize = 0;
	var worldArenaMutex: main.utils.Mutex = .{};

	pub fn deinit() void {
		std.log.info("Clearing global arena with {} MiB", .{globalArenaAllocator.arena.queryCapacity() >> 20});
		globalArenaAllocator.deinit();
		globalArenaAllocator = undefined;
		if (globalGpa.deinit() == .leak) {
			std.log.err("Memory leak", .{});
		}
		globalGpa = undefined;
	}

	pub fn createWorldArena() void {
		worldArenaMutex.lock();
		defer worldArenaMutex.unlock();
		if (worldArenaOpenCount == 0) {
			worldArenaAllocator = .init(handledGpa.allocator());
		}
		worldArenaOpenCount += 1;
	}

	pub fn destroyWorldArena() void {
		worldArenaMutex.lock();
		defer worldArenaMutex.unlock();
		worldArenaOpenCount -= 1;
		if (worldArenaOpenCount == 0) {
			std.log.info("Clearing world arena with {} MiB", .{worldArenaAllocator.arena.queryCapacity() >> 20});
			worldArenaAllocator.deinit();
			worldArenaAllocator = undefined;
		}
	}
};

pub const StackAllocator = struct {
	const AllocationTrailer = packed struct { wasFreed: bool, previousAllocationTrailer: u31 };
	backingAllocator: NeverFailingAllocator,
	buffer: []align(4096) u8,
	index: usize,

	pub fn init(backingAllocator: NeverFailingAllocator, size: u31) StackAllocator {
		return .{
			.backingAllocator = backingAllocator,
			.buffer = backingAllocator.alignedAlloc(u8, .fromByteUnits(4096), size),
			.index = 0,
		};
	}

	pub fn deinit(self: StackAllocator) void {
		if (self.index != 0) {
			std.log.err("Memory leak in Stack Allocator", .{});
		}
		self.backingAllocator.free(self.buffer);
	}

	pub fn allocator(self: *StackAllocator) NeverFailingAllocator {
		return .{
			.allocator = .{
				.vtable = &.{
					.alloc = &alloc,
					.resize = &resize,
					.remap = &remap,
					.free = &free,
				},
				.ptr = self,
			},
			.IAssertThatTheProvidedAllocatorCantFail = {},
		};
	}

	fn isInsideBuffer(self: *StackAllocator, buf: []u8) bool {
		const bufferStart = @intFromPtr(self.buffer.ptr);
		const bufferEnd = bufferStart + self.buffer.len;
		const compare = @intFromPtr(buf.ptr);
		return compare >= bufferStart and compare < bufferEnd;
	}

	fn indexInBuffer(self: *StackAllocator, buf: []u8) usize {
		const bufferStart = @intFromPtr(self.buffer.ptr);
		const compare = @intFromPtr(buf.ptr);
		return compare - bufferStart;
	}

	fn getTrueAllocationEnd(start: usize, len: usize) usize {
		const trailerStart = std.mem.alignForward(usize, start + len, @alignOf(AllocationTrailer));
		return trailerStart + @sizeOf(AllocationTrailer);
	}

	fn getTrailerBefore(self: *StackAllocator, end: usize) *AllocationTrailer {
		const trailerStart = end - @sizeOf(AllocationTrailer);
		return @ptrCast(@alignCast(self.buffer[trailerStart..].ptr));
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
		const self: *StackAllocator = @ptrCast(@alignCast(ctx));
		const start = std.mem.alignForward(usize, self.index, @as(usize, 1) << @intCast(@intFromEnum(alignment)));
		const end = getTrueAllocationEnd(start, len);
		if (end >= self.buffer.len) return self.backingAllocator.rawAlloc(len, alignment, ret_addr);
		const trailer = self.getTrailerBefore(end);
		trailer.* = .{.wasFreed = false, .previousAllocationTrailer = @intCast(self.index)};
		self.index = end;
		return self.buffer.ptr + start;
	}

	fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
		const self: *StackAllocator = @ptrCast(@alignCast(ctx));
		if (self.isInsideBuffer(memory)) {
			const start = self.indexInBuffer(memory);
			const end = getTrueAllocationEnd(start, memory.len);
			if (end != self.index) return false;
			const newEnd = getTrueAllocationEnd(start, new_len);
			if (newEnd >= self.buffer.len) return false;

			const trailer = self.getTrailerBefore(end);
			std.debug.assert(!trailer.wasFreed);
			const newTrailer = self.getTrailerBefore(newEnd);

			newTrailer.* = .{.wasFreed = false, .previousAllocationTrailer = trailer.previousAllocationTrailer};
			self.index = newEnd;
			return true;
		} else {
			return self.backingAllocator.rawResize(memory, alignment, new_len, ret_addr);
		}
	}

	fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
		return null;
	}

	fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
		const self: *StackAllocator = @ptrCast(@alignCast(ctx));
		if (self.isInsideBuffer(memory)) {
			const start = self.indexInBuffer(memory);
			const end = getTrueAllocationEnd(start, memory.len);
			const trailer = self.getTrailerBefore(end);
			std.debug.assert(!trailer.wasFreed);

			if (end == self.index) {
				self.index = trailer.previousAllocationTrailer;
				if (self.index != 0) {
					var previousTrailer = self.getTrailerBefore(trailer.previousAllocationTrailer);
					while (previousTrailer.wasFreed) {
						self.index = previousTrailer.previousAllocationTrailer;
						if (self.index == 0) break;
						previousTrailer = self.getTrailerBefore(previousTrailer.previousAllocationTrailer);
					}
				}
			}
			trailer.wasFreed = true;
		} else {
			self.backingAllocator.rawFree(memory, alignment, ret_addr);
		}
	}
};

pub const ErrorHandlingAllocator = struct {
	backingAllocator: Allocator,

	pub fn init(backingAllocator: Allocator) ErrorHandlingAllocator {
		return .{
			.backingAllocator = backingAllocator,
		};
	}

	pub fn allocator(self: *ErrorHandlingAllocator) NeverFailingAllocator {
		return .{
			.allocator = .{
				.vtable = &.{
					.alloc = &alloc,
					.resize = &resize,
					.remap = &remap,
					.free = &free,
				},
				.ptr = self,
			},
			.IAssertThatTheProvidedAllocatorCantFail = {},
		};
	}

	fn handleError() noreturn {
		@panic("Out Of Memory. Please download more RAM, reduce the render distance, or close some of your 100 browser tabs.");
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
		const self: *ErrorHandlingAllocator = @ptrCast(@alignCast(ctx));
		return self.backingAllocator.rawAlloc(len, alignment, ret_addr) orelse handleError();
	}

	fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
		const self: *ErrorHandlingAllocator = @ptrCast(@alignCast(ctx));
		return self.backingAllocator.rawResize(memory, alignment, new_len, ret_addr);
	}

	fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		const self: *ErrorHandlingAllocator = @ptrCast(@alignCast(ctx));
		return self.backingAllocator.rawRemap(memory, alignment, new_len, ret_addr);
	}

	fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
		const self: *ErrorHandlingAllocator = @ptrCast(@alignCast(ctx));
		self.backingAllocator.rawFree(memory, alignment, ret_addr);
	}
};

pub const NeverFailingAllocator = struct {
	allocator: Allocator,
	IAssertThatTheProvidedAllocatorCantFail: void,

	const Alignment = std.mem.Alignment;
	const math = std.math;

	pub inline fn rawAlloc(a: NeverFailingAllocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
		return a.allocator.vtable.alloc(a.allocator.ptr, len, alignment, ret_addr);
	}

	pub inline fn rawResize(a: NeverFailingAllocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
		return a.allocator.vtable.resize(a.allocator.ptr, memory, alignment, new_len, ret_addr);
	}

	pub inline fn rawRemap(a: NeverFailingAllocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		return a.allocator.vtable.remap(a.allocator.ptr, memory, alignment, new_len, ret_addr);
	}

	pub inline fn rawFree(a: NeverFailingAllocator, memory: []u8, alignment: Alignment, ret_addr: usize) void {
		return a.allocator.vtable.free(a.allocator.ptr, memory, alignment, ret_addr);
	}

	pub fn create(self: NeverFailingAllocator, comptime T: type) *T {
		return self.allocator.create(T) catch unreachable;
	}

	pub fn destroy(self: NeverFailingAllocator, ptr: anytype) void {
		self.allocator.destroy(ptr);
	}

	pub fn alloc(self: NeverFailingAllocator, comptime T: type, n: usize) []T {
		return self.allocator.alloc(T, n) catch unreachable;
	}

	pub fn allocWithOptions(
		self: NeverFailingAllocator,
		comptime Elem: type,
		n: usize,

		comptime optional_alignment: ?u29,
		comptime optional_sentinel: ?Elem,
	) AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
		return self.allocator.allocWithOptions(Elem, n, optional_alignment, optional_sentinel) catch unreachable;
	}

	pub fn allocWithOptionsRetAddr(
		self: NeverFailingAllocator,
		comptime Elem: type,
		n: usize,

		comptime optional_alignment: ?u29,
		comptime optional_sentinel: ?Elem,
		return_address: usize,
	) AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
		return self.allocator.allocWithOptionsRetAddr(Elem, n, optional_alignment, optional_sentinel, return_address) catch unreachable;
	}

	fn AllocWithOptionsPayload(comptime Elem: type, comptime alignment: ?u29, comptime sentinel: ?Elem) type {
		if (sentinel) |s| {
			return [:s]align(alignment orelse @alignOf(Elem)) Elem;
		} else {
			return []align(alignment orelse @alignOf(Elem)) Elem;
		}
	}

	pub fn allocSentinel(
		self: NeverFailingAllocator,
		comptime Elem: type,
		n: usize,
		comptime sentinel: Elem,
	) [:sentinel]Elem {
		return self.allocator.allocSentinel(Elem, n, sentinel) catch unreachable;
	}

	pub fn alignedAlloc(
		self: NeverFailingAllocator,
		comptime T: type,

		comptime alignment: ?Alignment,
		n: usize,
	) []align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
		return self.allocator.alignedAlloc(T, alignment, n) catch unreachable;
	}

	pub inline fn allocAdvancedWithRetAddr(
		self: NeverFailingAllocator,
		comptime T: type,

		comptime alignment: ?Alignment,
		n: usize,
		return_address: usize,
	) []align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
		return self.allocator.allocAdvancedWithRetAddr(T, alignment, n, return_address) catch unreachable;
	}

	fn allocWithSizeAndAlignment(self: NeverFailingAllocator, comptime size: usize, comptime alignment: u29, n: usize, return_address: usize) [*]align(alignment) u8 {
		return self.allocator.allocWithSizeAndAlignment(alignment, size, alignment, n, return_address) catch unreachable;
	}

	fn allocBytesWithAlignment(self: NeverFailingAllocator, comptime alignment: u29, byte_count: usize, return_address: usize) [*]align(alignment) u8 {
		return self.allocator.allocBytesWithAlignment(alignment, byte_count, return_address) catch unreachable;
	}

	pub fn resize(self: NeverFailingAllocator, allocation: anytype, new_len: usize) bool {
		return self.allocator.resize(allocation, new_len);
	}

	pub fn remap(self: NeverFailingAllocator, allocation: anytype, new_len: usize) t: {
		const Slice = @typeInfo(@TypeOf(allocation)).pointer;
		break :t ?[]align(Slice.alignment) Slice.child;
	} {
		return self.allocator.remap(allocation, new_len);
	}

	pub fn realloc(self: NeverFailingAllocator, old_mem: anytype, new_n: usize) t: {
		const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
		break :t []align(Slice.alignment orelse @alignOf(Slice.child)) Slice.child;
	} {
		return self.allocator.realloc(old_mem, new_n) catch unreachable;
	}

	pub fn reallocAdvanced(
		self: NeverFailingAllocator,
		old_mem: anytype,
		new_n: usize,
		return_address: usize,
	) t: {
		const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
		break :t []align(Slice.alignment) Slice.child;
	} {
		return self.allocator.reallocAdvanced(old_mem, new_n, return_address) catch unreachable;
	}

	pub fn free(self: NeverFailingAllocator, memory: anytype) void {
		self.allocator.free(memory);
	}

	pub fn dupe(self: NeverFailingAllocator, comptime T: type, m: []const T) []T {
		return self.allocator.dupe(T, m) catch unreachable;
	}

	pub fn dupeZ(self: NeverFailingAllocator, comptime T: type, m: []const T) [:0]T {
		return self.allocator.dupeZ(T, m) catch unreachable;
	}

	pub fn print(a: NeverFailingAllocator, comptime format: []const u8, args: anytype) []u8 {
		return std.fmt.allocPrint(a.allocator, format, args) catch unreachable;
	}

	pub fn printSentinel(
		a: NeverFailingAllocator,
		comptime format: []const u8,
		args: anytype,
		comptime sentinel: u8,
	) [:sentinel]u8 {
		return std.fmt.allocPrintSentinel(a.allocator, format, args, sentinel) catch unreachable;
	}

	pub fn createArena(self: NeverFailingAllocator) NeverFailingAllocator {
		const arenaPtr = self.create(NeverFailingArenaAllocator);
		arenaPtr.* = NeverFailingArenaAllocator.init(self);
		return arenaPtr.allocator();
	}

	pub fn destroyArena(self: NeverFailingAllocator, arena: NeverFailingAllocator) void {
		const arenaAllocatorPtr: *NeverFailingArenaAllocator = @ptrCast(@alignCast(arena.allocator.ptr));
		arenaAllocatorPtr.deinit();
		self.destroy(arenaAllocatorPtr);
	}
};

pub const NeverFailingArenaAllocator = struct {
	arena: std.heap.ArenaAllocator,

	pub fn init(childAllocator: NeverFailingAllocator) NeverFailingArenaAllocator {
		return .{
			.arena = .init(childAllocator.allocator),
		};
	}

	pub fn deinit(self: NeverFailingArenaAllocator) void {
		self.arena.deinit();
	}

	pub fn allocator(self: *NeverFailingArenaAllocator) NeverFailingAllocator {
		return .{
			.allocator = self.arena.allocator(),
			.IAssertThatTheProvidedAllocatorCantFail = {},
		};
	}

	pub fn reset(self: *NeverFailingArenaAllocator, mode: std.heap.ArenaAllocator.ResetMode) bool {
		return self.arena.reset(mode);
	}

	pub fn shrinkAndFree(self: *NeverFailingArenaAllocator) void {
		if (true) return;
		const node = self.arena.state.buffer_list.first orelse return;
		const allocBuf = @as([*]u8, @ptrCast(node))[0..node.data];
		const dataSize = std.mem.alignForward(usize, @sizeOf(std.SinglyLinkedList(usize).Node) + self.arena.state.end_index, @alignOf(std.SinglyLinkedList(usize).Node));
		if (self.arena.childAllocator.rawResize(allocBuf, @enumFromInt(std.math.log2(@alignOf(std.SinglyLinkedList(usize).Node))), dataSize, @returnAddress())) {
			node.data = dataSize;
		}
	}
};

pub fn MemoryPool(Item: type) type {
	return struct {
		const Pool = @This();

		pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));

		const node_alignment = @alignOf(*anyopaque);

		pub const item_alignment = @max(node_alignment, @alignOf(Item));

		const Node = struct {
			next: ?*align(item_alignment) @This(),
		};
		const NodePtr = *align(item_alignment) Node;
		const ItemPtr = *align(item_alignment) Item;

		arena: NeverFailingAllocator,
		free_list: ?NodePtr = null,
		freeAllocations: usize = 0,
		totalAllocations: usize = 0,
		mutex: main.utils.Mutex = .{},

		pub fn init(arena: NeverFailingAllocator) Pool {
			std.debug.assert(arena.allocator.vtable.alloc == comptime NeverFailingArenaAllocator.allocator(@ptrFromInt(1024)).allocator.vtable.alloc);
			return .{.arena = arena};
		}

		pub fn deinit(pool: *Pool) void {
			if (pool.freeAllocations != pool.totalAllocations) {
				std.log.err("Memory pool of type {s} leaked {} elements", .{@typeName(Item), pool.totalAllocations - pool.freeAllocations});
			} else if (pool.totalAllocations != 0) {
				std.log.info("{} MiB ({} elements) in {s} Memory pool", .{pool.totalAllocations*item_size >> 20, pool.totalAllocations, @typeName(Item)});
			}
			pool.* = undefined;
		}

		pub fn create(pool: *Pool) ItemPtr {
			pool.mutex.lock();
			defer pool.mutex.unlock();
			const node = if (pool.free_list) |item| blk: {
				pool.free_list = item.next;
				break :blk item;
			} else @as(NodePtr, @ptrCast(pool.allocNew()));

			pool.freeAllocations -= 1;
			const ptr = @as(ItemPtr, @ptrCast(node));
			ptr.* = undefined;
			return ptr;
		}

		pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
			pool.mutex.lock();
			defer pool.mutex.unlock();
			ptr.* = undefined;

			const node = @as(NodePtr, @ptrCast(ptr));
			node.* = Node{
				.next = pool.free_list,
			};
			pool.free_list = node;
			pool.freeAllocations += 1;
		}

		fn allocNew(pool: *Pool) *align(item_alignment) [item_size]u8 {
			pool.mutex.assertLocked();
			pool.totalAllocations += 1;
			pool.freeAllocations += 1;
			const mem = pool.arena.alignedAlloc(u8, .fromByteUnits(item_alignment), item_size);
			return mem[0..item_size];
		}
	};
}

pub const GarbageCollection = struct {
	var sharedState: std.atomic.Value(u32) = .init(0);
	threadlocal var threadCycle: u2 = undefined;
	threadlocal var lastSyncPointTime: std.Io.Timestamp = undefined;
	const FreeItem = struct {
		ptr: *anyopaque,
		freeFunction: *const fn (*anyopaque) void,
	};
	threadlocal var lists: [4]main.List(FreeItem) = undefined;

	const State = packed struct {
		waitingThreads: u15 = 0,
		totalThreads: u15 = 0,
		cycle: u2 = 0,
	};

	pub fn addThread() void {
		const old: State = @bitCast(sharedState.fetchAdd(@bitCast(State{.totalThreads = 1}), .monotonic));
		_ = old.totalThreads + 1;
		threadCycle = old.cycle;
		lastSyncPointTime = main.timestamp();
		for (&lists) |*list| {
			list.* = .initCapacity(main.globalAllocator, 1024);
		}
		if (old.waitingThreads == 0) {
			startNewCycle();
		}
	}

	fn freeItemsFromList(list: *main.List(FreeItem)) void {
		while (list.popOrNull()) |item| {
			item.freeFunction(item.ptr);
		}
	}

	pub fn removeThread() void {
		const old: State = @bitCast(sharedState.fetchSub(@bitCast(State{.totalThreads = 1}), .monotonic));
		_ = old.totalThreads - 1;
		if (old.cycle != threadCycle) removeThreadFromWaiting();
		const newTime = main.timestamp();
		if (lastSyncPointTime.durationTo(newTime).toSeconds() > 20) {
			if (!build_options.isTaggedRelease) {
				std.log.err("No sync point executed in {} ms for thread. Did you forget to add a sync point in the thread's main loop?", .{lastSyncPointTime.durationTo(newTime).toMilliseconds()});
				std.debug.dumpCurrentStackTrace(.{});
			}
		}
		for (&lists) |*list| {
			freeItemsFromList(list);
			list.deinit(main.globalAllocator);
		}
	}

	pub fn assertAllThreadsStopped() void {
		std.debug.assert(sharedState.load(.monotonic) & 0x3fffffff == 0);
	}

	fn startNewCycle() void {
		var cur = sharedState.load(.monotonic);
		while (true) {
			var new: State = @bitCast(cur);
			new.waitingThreads = new.totalThreads;
			new.cycle +%= 1;
			cur = sharedState.cmpxchgWeak(cur, @bitCast(new), .monotonic, .monotonic) orelse break;
		}
	}

	fn removeThreadFromWaiting() void {
		const old: State = @bitCast(sharedState.fetchSub(@bitCast(State{.waitingThreads = 1}), .acq_rel));
		_ = old.waitingThreads - 1;
		threadCycle = old.cycle;

		if (old.waitingThreads == 1) startNewCycle();
	}

	pub fn syncPoint() void {
		const newTime = main.timestamp();
		if (lastSyncPointTime.durationTo(newTime).toSeconds() > 20) {
			std.log.err("No sync point executed in {} ms. Did you forget to add a sync point in the thread's main loop", .{lastSyncPointTime.durationTo(newTime).toMilliseconds()});
			std.debug.dumpCurrentStackTrace(.{});
		}
		lastSyncPointTime = newTime;

		const old: State = @bitCast(sharedState.load(.monotonic));
		if (old.cycle == threadCycle) return;
		removeThreadFromWaiting();
		freeItemsFromList(&lists[threadCycle]);

	}

	pub fn deferredFree(item: FreeItem) void {
		lists[threadCycle].append(main.globalAllocator, item);
	}

	pub fn waitForFreeCompletion() void {
		const startCycle = threadCycle;
		while (threadCycle == startCycle) {
			syncPoint();
			main.io.sleep(.fromMilliseconds(1), .awake) catch {};
		}
		while (threadCycle != startCycle) {
			syncPoint();
			main.io.sleep(.fromMilliseconds(1), .awake) catch {};
		}
	}
};

pub fn PowerOfTwoPoolAllocator(minSize: comptime_int, maxSize: comptime_int, maxAlignment: comptime_int) type {
	std.debug.assert(std.math.isPowerOfTwo(minSize));
	std.debug.assert(std.math.isPowerOfTwo(maxSize));
	std.debug.assert(maxSize > minSize);
	std.debug.assert(minSize >= maxAlignment);
	std.debug.assert(minSize >= @sizeOf(usize));

	const alignment = @max(maxAlignment, @sizeOf(usize));

	const baseShift = std.math.log2_int(usize, minSize);
	const bucketCount = std.math.log2_int(usize, maxSize) - baseShift + 1;
	return struct {
		const Self = @This();

		const Node = struct {
			next: ?*align(alignment) @This(),
		};
		const NodePtr = *align(alignment) Node;

		const Bucket = struct {
			freeLists: ?*align(alignment) Node = null,
			freeAllocations: usize = 0,
			totalAllocations: usize = 0,

			pub fn deinit(self: *Bucket, size: usize) void {
				if (self.freeAllocations != self.totalAllocations) {
					std.log.err("PowerOfTwoPoolAllocator bucket of size {} leaked {} elements", .{size, self.totalAllocations - self.freeAllocations});
				} else if (self.totalAllocations != 0) {
					std.log.info("{} MiB ({} elements) in size {} PowerOfTwoPoolAllocator bucket", .{self.totalAllocations*size >> 20, self.totalAllocations, size});
				}
				self.* = undefined;
			}

			pub fn create(self: *Bucket, arena: NeverFailingAllocator, size: usize) [*]u8 {
				const node = if (self.freeLists) |item| blk: {
					self.freeLists = item.next;
					break :blk item;
				} else @as(NodePtr, @ptrCast(self.allocNew(arena, size)));

				self.freeAllocations -= 1;
				return @ptrCast(node);
			}

			pub fn destroy(self: *Bucket, ptr: [*]u8) void {
				const node = @as(NodePtr, @ptrCast(@alignCast(ptr)));
				node.* = Node{
					.next = self.freeLists,
				};
				self.freeLists = node;
				self.freeAllocations += 1;
			}

			fn allocNew(self: *Bucket, arena: NeverFailingAllocator, size: usize) [*]align(alignment) u8 {
				self.totalAllocations += 1;
				self.freeAllocations += 1;
				return arena.alignedAlloc(u8, .fromByteUnits(alignment), size).ptr;
			}
		};

		arena: NeverFailingArenaAllocator,
		buckets: [bucketCount]Bucket = @splat(.{}),
		mutex: main.utils.Mutex = .{},

		pub fn init(backingAllocator: NeverFailingAllocator) Self {
			return .{.arena = .init(backingAllocator)};
		}

		pub fn deinit(self: *Self) void {
			for (&self.buckets, 0..) |*bucket, i| {
				bucket.deinit(@as(usize, minSize) << @intCast(i));
			}
			self.arena.deinit();
		}

		pub fn allocator(self: *Self) NeverFailingAllocator {
			return .{
				.allocator = .{
					.vtable = &.{
						.alloc = &alloc,
						.resize = &resize,
						.remap = &remap,
						.free = &free,
					},
					.ptr = self,
				},
				.IAssertThatTheProvidedAllocatorCantFail = {},
			};
		}

		fn alloc(ctx: *anyopaque, len: usize, _alignment: std.mem.Alignment, _: usize) ?[*]u8 {
			std.debug.assert(@as(usize, 1) << @intFromEnum(_alignment) <= maxAlignment);
			std.debug.assert(std.math.isPowerOfTwo(len));
			std.debug.assert(len >= minSize);
			std.debug.assert(len <= maxSize);
			const self: *Self = @ptrCast(@alignCast(ctx));
			const bucket = @ctz(len) - baseShift;
			self.mutex.lock();
			defer self.mutex.unlock();
			return self.buckets[bucket].create(self.arena.allocator(), len);
		}

		fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
			return false;
		}

		fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
			return null;
		}

		fn free(ctx: *anyopaque, memory: []u8, _alignment: std.mem.Alignment, _: usize) void {
			std.debug.assert(@as(usize, 1) << @intFromEnum(_alignment) <= maxAlignment);
			std.debug.assert(std.math.isPowerOfTwo(memory.len));
			const self: *Self = @ptrCast(@alignCast(ctx));
			const bucket = @ctz(memory.len) - baseShift;
			self.mutex.lock();
			defer self.mutex.unlock();
			self.buckets[bucket].destroy(memory.ptr);
		}
	};
}
