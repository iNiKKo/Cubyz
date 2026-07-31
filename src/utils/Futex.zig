
const std = @import("std");
const main = @import("main");
const builtin = @import("builtin");
const windows = std.os.windows;
const linux = std.os.linux;
const c = std.c;

const assert = std.debug.assert;
const testing = std.testing;
const atomic = std.atomic;

const Futex = @This();

pub fn wait(ptr: *const atomic.Value(u32), expect: u32) void {
	@branchHint(.cold);

	Impl.wait(ptr, expect, null) catch |err| switch (err) {
		error.Timeout => unreachable,
	};
}

pub fn timedWait(ptr: *const atomic.Value(u32), expect: u32, timeout_ns: u64) error{Timeout}!void {
	@branchHint(.cold);

	if (timeout_ns == 0) {
		if (ptr.load(.seq_cst) != expect) return;
		return error.Timeout;
	}

	return Impl.wait(ptr, expect, timeout_ns);
}

pub fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
	@branchHint(.cold);

	if (max_waiters == 0) {
		return;
	}

	Impl.wake(ptr, max_waiters);
}

const Impl = if (builtin.single_threaded) SingleThreadedImpl else if (builtin.os.tag == .windows) WindowsImpl else if (builtin.os.tag.isDarwin()) DarwinImpl else if (builtin.os.tag == .linux) LinuxImpl else if (builtin.os.tag == .freebsd) FreebsdImpl else if (builtin.os.tag == .openbsd) OpenbsdImpl else if (builtin.target.cpu.arch.isWasm()) WasmImpl else if (std.Thread.use_pthreads) PosixImpl else UnsupportedImpl;

const UnsupportedImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		return unsupported(.{ptr, expect, timeout});
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		return unsupported(.{ptr, max_waiters});
	}

	fn unsupported(unused: anytype) noreturn {
		_ = unused;
		@compileError("Unsupported operating system " ++ @tagName(builtin.target.os.tag));
	}
};

const SingleThreadedImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		if (ptr.raw != expect) {
			return;
		}

		const delay = timeout orelse {
			unreachable;
		};

		_ = delay;
		return error.Timeout;
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {

		_ = ptr;
		_ = max_waiters;
	}
};

const WindowsImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		var timeout_value: windows.LARGE_INTEGER = undefined;
		var timeout_ptr: ?*const windows.LARGE_INTEGER = null;

		if (timeout) |delay| {
			timeout_value = @as(windows.LARGE_INTEGER, @intCast(delay/100));
			timeout_value = -timeout_value;
			timeout_ptr = &timeout_value;
		}

		const rc = windows.ntdll.RtlWaitOnAddress(
			ptr,
			&expect,
			@sizeOf(@TypeOf(expect)),
			timeout_ptr,
		);

		switch (rc) {
			.SUCCESS => {},
			.TIMEOUT => {
				assert(timeout != null);
				return error.Timeout;
			},
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const address: ?*const anyopaque = ptr;
		assert(max_waiters != 0);

		switch (max_waiters) {
			1 => windows.ntdll.RtlWakeAddressSingle(address),
			else => windows.ntdll.RtlWakeAddressAll(address),
		}
	}
};

const DarwinImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {

		const supports_ulock_wait2 = builtin.target.os.version_range.semver.min.major >= 11;

		var timeout_ns: u64 = 0;
		if (timeout) |delay| {
			assert(delay != 0);
			timeout_ns = delay;
		}

		var timeout_overflowed = false;

		const addr: *const anyopaque = ptr;
		const flags: c.UL = .{
			.op = .COMPARE_AND_WAIT,
			.NO_ERRNO = true,
		};
		const status = blk: {
			if (supports_ulock_wait2) {
				break :blk c.__ulock_wait2(flags, addr, expect, timeout_ns, 0);
			}

			const timeout_us = std.math.cast(u32, timeout_ns/std.time.ns_per_us) orelse overflow: {
				timeout_overflowed = true;
				break :overflow std.math.maxInt(u32);
			};

			break :blk c.__ulock_wait(flags, addr, expect, timeout_us);
		};

		if (status >= 0) return;
		switch (@as(c.E, @enumFromInt(-status))) {

			.INTR => {},

			.FAULT => {},

			.TIMEDOUT => {
				assert(timeout != null);
				if (!timeout_overflowed) return error.Timeout;
			},
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const flags: c.UL = .{
			.op = .COMPARE_AND_WAIT,
			.NO_ERRNO = true,
			.WAKE_ALL = max_waiters > 1,
		};

		while (true) {
			const addr: *const anyopaque = ptr;
			const status = c.__ulock_wake(flags, addr, 0);

			if (status >= 0) return;
			switch (@as(c.E, @enumFromInt(-status))) {
				.INTR => continue,
				.FAULT => unreachable,
				.NOENT => return,
				.ALREADY => unreachable,
				else => unreachable,
			}
		}
	}
};

const LinuxImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		var ts: linux.timespec = undefined;
		if (timeout) |timeout_ns| {
			ts.sec = @as(@TypeOf(ts.sec), @intCast(timeout_ns/std.time.ns_per_s));
			ts.nsec = @as(@TypeOf(ts.nsec), @intCast(timeout_ns%std.time.ns_per_s));
		}

		const rc = linux.futex_4arg(
			&ptr.raw,
			.{.cmd = .WAIT, .private = true},
			expect,
			if (timeout != null) &ts else null,
		);

		switch (linux.errno(rc)) {
			.SUCCESS => {},
			.INTR => {},
			.AGAIN => {},
			.TIMEDOUT => {
				assert(timeout != null);
				return error.Timeout;
			},
			.INVAL => {},
			.FAULT => unreachable,
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const rc = linux.futex_3arg(
			&ptr.raw,
			.{.cmd = .WAKE, .private = true},
			@min(max_waiters, std.math.maxInt(i32)),
		);

		switch (linux.errno(rc)) {
			.SUCCESS => {},
			.INVAL => {},
			.FAULT => {},
			else => unreachable,
		}
	}
};

const FreebsdImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		var tm_size: usize = 0;
		var tm: c._umtx_time = undefined;
		var tm_ptr: ?*const c._umtx_time = null;

		if (timeout) |timeout_ns| {
			tm_ptr = &tm;
			tm_size = @sizeOf(@TypeOf(tm));

			tm.flags = 0;
			tm.clockid = .MONOTONIC;
			tm.timeout.sec = @as(@TypeOf(tm.timeout.sec), @intCast(timeout_ns/std.time.ns_per_s));
			tm.timeout.nsec = @as(@TypeOf(tm.timeout.nsec), @intCast(timeout_ns%std.time.ns_per_s));
		}

		const rc = c._umtx_op(
			@intFromPtr(&ptr.raw),
			@intFromEnum(c.UMTX_OP.WAIT_UINT_PRIVATE),
			@as(c_ulong, expect),
			tm_size,
			@intFromPtr(tm_ptr),
		);

		switch (std.posix.errno(rc)) {
			.SUCCESS => {},
			.FAULT => unreachable,
			.INVAL => unreachable,
			.TIMEDOUT => {
				assert(timeout != null);
				return error.Timeout;
			},
			.INTR => {},
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const rc = c._umtx_op(
			@intFromPtr(&ptr.raw),
			@intFromEnum(c.UMTX_OP.WAKE_PRIVATE),
			@as(c_ulong, max_waiters),
			0,
			0,
		);

		switch (std.posix.errno(rc)) {
			.SUCCESS => {},
			.FAULT => {},
			.INVAL => unreachable,
			else => unreachable,
		}
	}
};

const OpenbsdImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		var ts: c.timespec = undefined;
		if (timeout) |timeout_ns| {
			ts.sec = @as(@TypeOf(ts.sec), @intCast(timeout_ns/std.time.ns_per_s));
			ts.nsec = @as(@TypeOf(ts.nsec), @intCast(timeout_ns%std.time.ns_per_s));
		}

		const rc = c.futex(
			@as(*const volatile u32, @ptrCast(&ptr.raw)),
			c.FUTEX.WAIT | c.FUTEX.PRIVATE_FLAG,
			@as(c_int, @bitCast(expect)),
			if (timeout != null) &ts else null,
			null,
		);

		switch (std.posix.errno(rc)) {
			.SUCCESS => {},
			.NOSYS => unreachable,
			.FAULT => unreachable,
			.AGAIN => {},
			.INVAL => unreachable,
			.TIMEDOUT => {
				assert(timeout != null);
				return error.Timeout;
			},
			.INTR => {},
			.CANCELED => {},
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const rc = c.futex(
			@as(*const volatile u32, @ptrCast(&ptr.raw)),
			c.FUTEX.WAKE | c.FUTEX.PRIVATE_FLAG,
			std.math.cast(c_int, max_waiters) orelse std.math.maxInt(c_int),
			null,
			null,
		);

		assert(rc >= 0);
	}
};

const WasmImpl = struct {
	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		if (!comptime builtin.cpu.has(.wasm, .atomics)) @compileError("WASI target missing cpu feature 'atomics'");

		const to: i64 = if (timeout) |to| @intCast(to) else -1;
		const result = asm volatile (
			\\local.get %[ptr]
			\\local.get %[expected]
			\\local.get %[timeout]
			\\memory.atomic.wait32 0
			\\local.set %[ret]
			: [ret] "=r" (-> u32),
			: [ptr] "r" (&ptr.raw),
				[expected] "r" (@as(i32, @bitCast(expect))),
				[timeout] "r" (to),
		);
		switch (result) {
			0 => {},
			1 => {},
			2 => return error.Timeout,
			else => unreachable,
		}
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		if (!comptime builtin.cpu.has(.wasm, .atomics)) @compileError("WASI target missing cpu feature 'atomics'");

		assert(max_waiters != 0);
		const woken_count = asm volatile (
			\\local.get %[ptr]
			\\local.get %[waiters]
			\\memory.atomic.notify 0
			\\local.set %[ret]
			: [ret] "=r" (-> u32),
			: [ptr] "r" (&ptr.raw),
				[waiters] "r" (max_waiters),
		);
		_ = woken_count;
	}
};

const PosixImpl = struct {
	const Event = struct {
		cond: c.pthread_cond_t,
		mutex: c.pthread_mutex_t,
		state: enum { empty, waiting, notified },

		fn init(self: *Event) void {

			self.cond = .{};
			self.mutex = .{};
			self.state = .empty;
		}

		fn deinit(self: *Event) void {

			const rc = c.pthread_cond_destroy(&self.cond);
			assert(rc == .SUCCESS or rc == .INVAL);

			const rm = c.pthread_mutex_destroy(&self.mutex);
			assert(rm == .SUCCESS or rm == .INVAL);

			self.* = undefined;
		}

		fn wait(self: *Event, timeout: ?u64) error{Timeout}!void {
			assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
			defer assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

			if (self.state == .notified) {
				return;
			}

			var ts: c.timespec = undefined;
			if (timeout) |timeout_ns| {
				ts = std.posix.clock_gettime(c.CLOCK.REALTIME) catch unreachable;
				ts.sec +|= @as(@TypeOf(ts.sec), @intCast(timeout_ns/std.time.ns_per_s));
				ts.nsec += @as(@TypeOf(ts.nsec), @intCast(timeout_ns%std.time.ns_per_s));

				if (ts.nsec >= std.time.ns_per_s) {
					ts.sec +|= 1;
					ts.nsec -= std.time.ns_per_s;
				}
			}

			assert(self.state == .empty);
			self.state = .waiting;

			while (true) {

				const rc = blk: {
					if (timeout == null) break :blk c.pthread_cond_wait(&self.cond, &self.mutex);
					break :blk c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
				};

				if (self.state == .notified) {
					return;
				}

				assert(self.state == .waiting);
				switch (rc) {
					.SUCCESS => {},
					.TIMEDOUT => {

						self.state = .empty;
						return error.Timeout;
					},
					.INVAL => unreachable,
					.PERM => unreachable,
					else => unreachable,
				}
			}
		}

		fn set(self: *Event) void {
			assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
			defer assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

			const old_state = self.state;
			assert(old_state != .notified);

			self.state = .notified;
			if (old_state == .waiting) {
				assert(c.pthread_cond_signal(&self.cond) == .SUCCESS);
			}
		}
	};

	const Treap = std.Treap(usize, std.math.order);
	const Waiter = struct {
		node: Treap.Node,
		prev: ?*Waiter,
		next: ?*Waiter,
		tail: ?*Waiter,
		is_queued: bool,
		event: Event,
	};

	const WaitList = struct {
		top: ?*Waiter = null,
		len: usize = 0,

		fn push(self: *WaitList, waiter: *Waiter) void {
			waiter.next = self.top;
			self.top = waiter;
			self.len += 1;
		}

		fn pop(self: *WaitList) ?*Waiter {
			const waiter = self.top orelse return null;
			self.top = waiter.next;
			self.len -= 1;
			return waiter;
		}
	};

	const WaitQueue = struct {
		fn insert(treap: *Treap, address: usize, waiter: *Waiter) void {

			waiter.next = null;
			waiter.is_queued = true;

			var entry = treap.getEntryFor(address);
			const entry_node = entry.node orelse {
				waiter.prev = null;
				waiter.tail = waiter;
				entry.set(&waiter.node);
				return;
			};

			const head: *Waiter = @fieldParentPtr("node", entry_node);
			const tail = head.tail.?;

			head.tail = waiter;
			tail.next = waiter;
			waiter.prev = tail;
		}

		fn remove(treap: *Treap, address: usize, max_waiters: usize) WaitList {

			var entry = treap.getEntryFor(address);
			var queue_head: ?*Waiter = if (entry.node) |node| @fieldParentPtr("node", node) else null;
			const queue_tail = if (queue_head) |head| head.tail else null;

			defer entry.set(blk: {
				const new_head = queue_head orelse break :blk null;
				new_head.tail = queue_tail;
				break :blk &new_head.node;
			});

			var removed = WaitList{};
			while (removed.len < max_waiters) {

				const waiter = queue_head orelse break;
				queue_head = waiter.next;
				removed.push(waiter);

				assert(waiter.is_queued);
				waiter.is_queued = false;
			}

			return removed;
		}

		fn tryRemove(treap: *Treap, address: usize, waiter: *Waiter) bool {
			if (!waiter.is_queued) {
				return false;
			}

			queue_remove: {

				var entry = blk: {

					if (waiter.prev == null) {
						assert(waiter.node.key == address);
						break :blk treap.getEntryForExisting(&waiter.node);
					}
					break :blk treap.getEntryFor(address);
				};

				const head: *Waiter = @fieldParentPtr("node", entry.node.?);
				const tail = head.tail.?;

				if (waiter.prev) |prev| {
					assert(waiter != head);
					prev.next = waiter.next;

					if (waiter.next) |next| {
						assert(waiter != tail);
						next.prev = waiter.prev;
						break :queue_remove;
					}

					assert(waiter == tail);
					head.tail = waiter.prev;
					break :queue_remove;
				}

				assert(waiter == head);
				entry.set(blk: {
					const new_head = waiter.next orelse break :blk null;
					new_head.tail = head.tail;
					break :blk &new_head.node;
				});
			}

			waiter.is_queued = false;
			return true;
		}
	};

	const Bucket = struct {
		mutex: c.pthread_mutex_t align(atomic.cache_line) = .{},
		pending: atomic.Value(usize) = atomic.Value(usize).init(0),
		treap: Treap = .{},

		var buckets = [_]Bucket{.{}} ** @bitSizeOf(usize);

		fn from(address: usize) *Bucket {

			const max_multiplier_bits = @bitSizeOf(usize);
			const fibonacci_multiplier = 0x9E3779B97F4A7C15 >> (64 - max_multiplier_bits);

			const max_bucket_bits = @ctz(buckets.len);
			comptime assert(std.math.isPowerOfTwo(buckets.len));

			const index = (address*%fibonacci_multiplier) >> (max_multiplier_bits - max_bucket_bits);
			return &buckets[index];
		}
	};

	const Address = struct {
		fn from(ptr: *const atomic.Value(u32)) usize {

			const alignment = @alignOf(atomic.Value(u32));
			comptime assert(std.math.isPowerOfTwo(alignment));

			const addr = @intFromPtr(ptr);
			assert(addr & (alignment - 1) == 0);
			return addr >> @ctz(@as(usize, alignment));
		}
	};

	fn wait(ptr: *const atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
		const address = Address.from(ptr);
		const bucket = Bucket.from(address);

		var pending = bucket.pending.fetchAdd(1, .acquire);
		assert(pending < std.math.maxInt(usize));

		var canceled = false;
		defer if (canceled) {
			pending = bucket.pending.fetchSub(1, .monotonic);
			assert(pending > 0);
		};

		var waiter: Waiter = undefined;
		{
			assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
			defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

			canceled = ptr.load(.monotonic) != expect;
			if (canceled) {
				return;
			}

			waiter.event.init();
			WaitQueue.insert(&bucket.treap, address, &waiter);
		}

		defer {
			assert(!waiter.is_queued);
			waiter.event.deinit();
		}

		waiter.event.wait(timeout) catch {

			defer if (!canceled) waiter.event.wait(null) catch unreachable;

			assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
			defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

			canceled = WaitQueue.tryRemove(&bucket.treap, address, &waiter);
			if (canceled) {
				return error.Timeout;
			}
		};
	}

	fn wake(ptr: *const atomic.Value(u32), max_waiters: u32) void {
		const address = Address.from(ptr);
		const bucket = Bucket.from(address);

		if (bucket.pending.fetchAdd(0, .release) == 0) {
			return;
		}

		var notified = WaitList{};
		defer if (notified.len > 0) {
			const pending = bucket.pending.fetchSub(notified.len, .monotonic);
			assert(pending >= notified.len);

			while (notified.pop()) |waiter| {
				assert(!waiter.is_queued);
				waiter.event.set();
			}
		};

		assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
		defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

		if (bucket.pending.load(.monotonic) > 0) {
			notified = WaitQueue.remove(&bucket.treap, address, max_waiters);
		}
	}
};

pub const Deadline = struct {
	timeout: ?u64,
	started: std.Io.Timestamp,

	pub fn init(expires_in_ns: ?u64) Deadline {
		var deadline: Deadline = undefined;
		deadline.timeout = expires_in_ns;

		if (deadline.timeout != null) {
			deadline.started = main.timestamp();
		}

		return deadline;
	}

	pub fn wait(self: *Deadline, ptr: *const atomic.Value(u32), expect: u32) error{Timeout}!void {
		@branchHint(.cold);

		const timeout_ns = self.timeout orelse {
			return Futex.wait(ptr, expect);
		};

		const elapsed_ns: u64 = @intCast(self.started.durationTo(main.timestamp()).nanoseconds);
		const until_timeout_ns = std.math.sub(u64, timeout_ns, elapsed_ns) catch 0;
		return Futex.timedWait(ptr, expect, until_timeout_ns);
	}
};
