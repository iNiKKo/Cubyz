
const std = @import("std");
const builtin = @import("builtin");
const Mutex = @This();

impl: Impl = .{},

pub const init: Mutex = .{};

pub fn tryLock(self: *Mutex) bool {
	return self.impl.tryLock();
}

pub fn lock(self: *Mutex) void {
	self.impl.lock();
}

pub fn unlock(self: *Mutex) void {
	self.impl.unlock();
}

const Impl = if (builtin.os.tag == .windows) WindowsImpl else PosixImpl;

const WindowsImpl = struct {
	srwlock: windows.SRWLOCK = .{},

	fn tryLock(self: *@This()) bool {
		return windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.srwlock) != .FALSE;
	}

	fn lock(self: *@This()) void {
		windows.ntdll.RtlAcquireSRWLockExclusive(&self.srwlock);
	}

	fn unlock(self: *@This()) void {
		windows.ntdll.RtlReleaseSRWLockExclusive(&self.srwlock);
	}

	const windows = std.os.windows;
};

// Real, kernel-backed pthread mutex rather than std.Io.Mutex - the latter is a lock-free userspace
// state machine (see compiler/zig/lib/std/Io.zig's Mutex, state: unlocked/locked_once/contended)
// that was observed to reach an inconsistent state (state.swap(.unlocked, ...) hitting the
// `.unlocked => unreachable` arm, i.e. a double-unlock) under real cross-thread contention in this
// codebase - reproduced independently in two unrelated places (ConnectionManager.finishCurrentReceive/
// broadcast, and ConnectionManager.addConnection racing the network thread's startup in @"continue"()).
// pthread_mutex_t is the same primitive utils/Futex.zig's PosixImpl already uses for its condition
// variable's associated mutex, so this isn't introducing a new dependency.
const PosixImpl = struct {
	mutex: c.pthread_mutex_t = .{},

	fn tryLock(self: *@This()) bool {
		return c.pthread_mutex_trylock(&self.mutex) == .SUCCESS;
	}

	fn lock(self: *@This()) void {
		std.debug.assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
	}

	fn unlock(self: *@This()) void {
		std.debug.assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
	}

	// std.c (Zig's own libc bindings), not this project's raw @cImport("c") - matches
	// utils/Futex.zig's PosixImpl, which already uses std.c.pthread_mutex_t the same way. The
	// project's @cImport type is a real C union (no zero-init via .{}) with plain c_int returns,
	// not the E error-set enum std.c exposes.
	const c = std.c;
};
