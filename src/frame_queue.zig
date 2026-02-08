const std = @import("std");
const Io = std.Io;
const av = @import("av");

/// Fixed-size ring buffer of decoded frames.
/// Pre-allocates frame slots to avoid allocation in the real-time path.
pub const FrameQueue = struct {
    pub const QUEUE_SIZE = 16;

    pub const Entry = struct {
        frame: *av.Frame,
        pts: f64 = 0,
        duration: f64 = 0,
        serial: i32 = 0,
        width: c_int = 0,
        height: c_int = 0,
        format: c_int = 0,
    };

    queue: [QUEUE_SIZE]Entry = undefined,
    rindex: u32 = 0,
    windex: u32 = 0,
    size: u32 = 0,
    max_size: u32,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    abort_request: *const std.atomic.Value(bool),

    pub fn init(max_size: u32, abort_request: *const std.atomic.Value(bool)) !FrameQueue {
        var fq = FrameQueue{
            .max_size = @min(max_size, QUEUE_SIZE),
            .abort_request = abort_request,
        };
        for (&fq.queue) |*entry| {
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

    pub fn deinit(self: *FrameQueue) void {
        for (&self.queue) |*entry| {
            entry.frame.unref();
            entry.frame.free();
        }
    }

    /// Get a writable frame slot (blocks until space available).
    pub fn peekWritable(self: *FrameQueue, io: Io) ?*Entry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.size >= self.max_size) {
            if (self.abort_request.load(.acquire)) return null;
            self.cond.waitUncancelable(io, &self.mutex);
        }
        if (self.abort_request.load(.acquire)) return null;
        return &self.queue[self.windex];
    }

    /// Commit a written frame.
    pub fn push(self: *FrameQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.windex = (self.windex + 1) % QUEUE_SIZE;
        self.size += 1;
        self.cond.signal(io);
    }

    /// Peek at the next readable frame without consuming it.
    pub fn peekReadable(self: *FrameQueue, io: Io) ?*Entry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.size == 0) {
            if (self.abort_request.load(.acquire)) return null;
            self.cond.waitUncancelable(io, &self.mutex);
        }
        if (self.abort_request.load(.acquire)) return null;
        return &self.queue[self.rindex];
    }

    /// Non-blocking peek at the next readable frame.
    pub fn peekReadableNonblock(self: *FrameQueue, io: Io) ?*Entry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.size == 0) return null;
        return &self.queue[self.rindex];
    }

    /// Peek at the frame after the current readable one.
    pub fn peekNext(self: *FrameQueue, io: Io) ?*Entry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.size < 2) return null;
        return &self.queue[(self.rindex + 1) % QUEUE_SIZE];
    }

    /// Consume the current readable frame.
    pub fn next(self: *FrameQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.queue[self.rindex].frame.unref();
        self.rindex = (self.rindex + 1) % QUEUE_SIZE;
        self.size -= 1;
        self.cond.signal(io);
    }

    /// Number of frames available for reading.
    pub fn remaining(self: *FrameQueue, io: Io) u32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.size;
    }

    /// Signal all waiters (used during abort).
    pub fn signalAll(self: *FrameQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cond.broadcast(io);
    }
};
