
const std = @import("std");
const main = @import("main");
const builtin = @import("builtin");
const Mutex = main.utils.Mutex;

const os = std.os;
const assert = std.debug.assert;
const testing = std.testing;
const Futex = main.utils.Futex;

const Condition = @This();

impl: Impl = .{},

pub fn wait(self: *Condition, mutex: *Mutex) void {
	self.impl.wait(mutex, null) catch |err| switch (err) {
		error.Timeout => unreachable,
	};
}

pub fn timedWait(self: *Condition, mutex: *Mutex, timeout: std.Io.Duration) error{Timeout}!void {
	return self.impl.wait(mutex, @intCast(timeout.nanoseconds));
}

pub fn signal(self: *Condition) void {
	self.impl.wake(.one);
}

pub fn broadcast(self: *Condition) void {
	self.impl.wake(.all);
}

const Impl = if (builtin.single_threaded) SingleThreadedImpl else if (builtin.os.tag == .windows) WindowsImpl else FutexImpl;

const Notify = enum {
	one,
	all,
};

const SingleThreadedImpl = struct {
	fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
		_ = self;
		_ = mutex;

		assert(timeout != null);
		return error.Timeout;
	}

	fn wake(self: *Impl, comptime notify: Notify) void {

		_ = self;
		_ = notify;
	}
};

const WindowsImpl = struct {
	condition: c.CONDITION_VARIABLE = .{},

	const c = @cImport({
		@cInclude("windows.h");
	});

	pub extern "ntdll" fn RtlWakeConditionVariable(
		ConditionVariable: *c.CONDITION_VARIABLE,
	) callconv(.winapi) void;
	pub extern "ntdll" fn RtlWakeAllConditionVariable(
		ConditionVariable: *c.CONDITION_VARIABLE,
	) callconv(.winapi) void;

	fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
		var timeout_overflowed = false;
		var timeout_ms: os.windows.DWORD = c.INFINITE;

		if (timeout) |timeout_ns| {

			const ms = (timeout_ns +| (std.time.ns_per_ms / 2)) / std.time.ns_per_ms;
			timeout_ms = std.math.cast(os.windows.DWORD, ms) orelse std.math.maxInt(os.windows.DWORD);

			if (timeout_ms == c.INFINITE) {
				timeout_overflowed = true;
				timeout_ms -= 1;
			}
		}

		const rc = c.SleepConditionVariableSRW(
			&self.condition,
			@ptrCast(&mutex.super.impl.srwlock),
			timeout_ms,
			0,
		);

		if (rc == c.FALSE) {
			assert(os.windows.GetLastError() == .TIMEOUT);
			if (!timeout_overflowed) return error.Timeout;
		}
	}

	fn wake(self: *Impl, comptime notify: Notify) void {
		switch (notify) {
			.one => RtlWakeConditionVariable(&self.condition),
			.all => RtlWakeAllConditionVariable(&self.condition),
		}
	}
};

const FutexImpl = struct {
	state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
	epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

	const one_waiter = 1;
	const waiter_mask = 0xffff;

	const one_signal = 1 << 16;
	const signal_mask = 0xffff << 16;

	fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {

		var epoch = self.epoch.load(.acquire);
		var state = self.state.fetchAdd(one_waiter, .monotonic);
		assert(state & waiter_mask != waiter_mask);
		state += one_waiter;

		mutex.unlock();
		defer mutex.lock();

		var futex_deadline = Futex.Deadline.init(timeout);

		while (true) {
			futex_deadline.wait(&self.epoch, epoch) catch |err| switch (err) {

				error.Timeout => {
					while (true) {

						while (state & signal_mask != 0) {
							const new_state = state - one_waiter - one_signal;
							state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
						}

						const new_state = state - one_waiter;
						state = self.state.cmpxchgWeak(state, new_state, .monotonic, .monotonic) orelse return err;
					}
				},
			};

			epoch = self.epoch.load(.acquire);
			state = self.state.load(.monotonic);

			while (state & signal_mask != 0) {
				const new_state = state - one_waiter - one_signal;
				state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
			}
		}
	}

	fn wake(self: *Impl, comptime notify: Notify) void {
		var state = self.state.load(.monotonic);
		while (true) {
			const waiters = (state & waiter_mask) / one_waiter;
			const signals = (state & signal_mask) / one_signal;

			const wakeable = waiters - signals;
			if (wakeable == 0) {
				return;
			}

			const to_wake = switch (notify) {
				.one => 1,
				.all => wakeable,
			};

			const new_state = state + (one_signal * to_wake);
			state = self.state.cmpxchgWeak(state, new_state, .release, .monotonic) orelse {

				_ = self.epoch.fetchAdd(1, .release);
				Futex.wake(&self.epoch, to_wake);
				return;
			};
		}
	}
};
