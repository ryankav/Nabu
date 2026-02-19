const std = @import("std");
const Io = std.Io;
const av = @import("av");
const BoundedSyncQueue = @import("sync_queue.zig").BoundedSyncQueue;

fn FrameQueueImpl(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const Self = @This();

        pub const QUEUE_SIZE = capacity;

        pub const Entry = struct {
            frame: *av.Frame,
            pts: f64 = 0,
            duration: f64 = 0,
            serial: i32 = 0,
            width: c_int = 0,
            height: c_int = 0,
            format: c_int = 0,
        };

        const Ring = BoundedSyncQueue(Entry, capacity);

        ring: Ring = .{},
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        abort_request: *const std.atomic.Value(bool),

        pub fn init(abort_request: *const std.atomic.Value(bool)) !Self {
            var fq = Self{ .abort_request = abort_request };
            for (&fq.ring.buf) |*entry| {
                entry.frame = try av.Frame.alloc();
                entry.pts = 0;
                entry.duration = 0;
                entry.serial = 0;
                entry.width = 0;
                entry.height = 0;
                entry.format = 0;
            }
            return fq;
        }

        pub fn deinit(self: *Self) void {
            for (&self.ring.buf) |*entry| {
                entry.frame.unref();
                entry.frame.free();
            }
        }

        /// Get a writable frame slot (blocks until space available).
        pub fn peekWritable(self: *Self, io: Io) ?*Entry {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.ring.isFull()) {
                if (self.abort_request.load(.acquire)) return null;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            if (self.abort_request.load(.acquire)) return null;
            return self.ring.peekWriteLocked();
        }

        /// Commit a written frame.
        pub fn push(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.ring.advanceWriteLocked();
            self.cond.signal(io);
        }

        /// Peek at the next readable frame without consuming it (blocking).
        pub fn peekReadable(self: *Self, io: Io) ?*Entry {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.ring.isEmpty()) {
                if (self.abort_request.load(.acquire)) return null;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            if (self.abort_request.load(.acquire)) return null;
            return self.ring.peekReadLocked();
        }

        /// Non-blocking peek at the next readable frame.
        pub fn peekReadableNonblock(self: *Self, io: Io) ?*Entry {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.ring.peekReadLocked();
        }

        /// Peek at the frame after the current readable one.
        pub fn peekNext(self: *Self, io: Io) ?*Entry {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.ring.peekReadAtLocked(1);
        }

        /// Consume the current readable frame.
        pub fn next(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.ring.peekReadLocked()) |entry| {
                entry.frame.unref();
                self.ring.advanceReadLocked();
            }
            self.cond.signal(io);
        }

        /// Number of frames available for reading.
        pub fn remaining(self: *Self, io: Io) u32 {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return @intCast(self.ring.count);
        }

        /// Signal all waiters (used during abort).
        pub fn signalAll(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.cond.broadcast(io);
        }
    };
}

/// Fixed-size ring buffer of decoded frames.
/// Pre-allocates frame slots to avoid allocation in the real-time path.
pub const FrameQueue = FrameQueueImpl(16);
