
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

const Impl = WindowsImpl;

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
