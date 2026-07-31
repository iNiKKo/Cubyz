
const std = @import("std");
const main = @import("main");
const Mutex = main.utils.Mutex;
const Condition = main.utils.Condition;

const Semaphore = @This();

mutex: Mutex = .{},
cond: Condition = .{},

permits: usize = 0,

pub fn wait(sem: *Semaphore) void {
	sem.mutex.lock();
	defer sem.mutex.unlock();

	while (sem.permits == 0) {
		sem.cond.wait(&sem.mutex);
	}

	sem.permits -= 1;
	if (sem.permits > 0) {
		sem.cond.signal();
	}
}

pub fn timedWait(sem: *Semaphore, timeout: std.Io.Duration) error{Timeout}!void {
	const start = main.timestamp();

	sem.mutex.lock();
	defer sem.mutex.unlock();

	while (sem.permits == 0) {
		const elapsed = start.durationTo(main.timestamp());
		if (elapsed.nanoseconds > timeout.nanoseconds) {
			return error.Timeout;
		}

		const local_timeout_ns = timeout.nanoseconds - elapsed.nanoseconds;
		try sem.cond.timedWait(&sem.mutex, .fromNanoseconds(local_timeout_ns));
	}

	sem.permits -= 1;
	if (sem.permits > 0) {
		sem.cond.signal();
	}
}

pub fn post(sem: *Semaphore) void {
	sem.mutex.lock();
	defer sem.mutex.unlock();

	sem.permits += 1;
	sem.cond.signal();
}
