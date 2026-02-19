const std = @import("std");
const Io = std.Io;
const av = @import("av");
const BoundedSyncQueue = @import("sync_queue.zig").BoundedSyncQueue;

/// Thread-safe FIFO queue for compressed packets backed by a fixed ring buffer.
/// Mirrors ffplay's PacketQueue.
pub fn PacketQueue(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const Self = @This();
        const Entry = struct { pkt: *av.Packet, serial: i32 };
        const Ring = BoundedSyncQueue(Entry, capacity);

        ring: Ring = .{},
        size: usize = 0,
        duration: i64 = 0,
        serial: i32 = 0,
        abort_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,

        pub fn start(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.abort_request.store(false, .release);
            self.serial += 1;
        }

        pub fn abort(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.abort_request.store(true, .release);
            self.cond.broadcast(io);
        }

        pub fn put(self: *Self, io: Io, pkt: *av.Packet) error{ Aborted, Full }!void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.abort_request.load(.acquire)) return error.Aborted;
            try self.ring.putLocked(.{ .pkt = pkt, .serial = self.serial });
            self.size += @intCast(pkt.size);
            self.duration += pkt.duration;
            self.cond.signal(io);
        }

        pub fn get(
            self: *Self,
            io: Io,
            comptime block: bool,
        ) (if (block) error{Aborted} else error{ Aborted, WouldBlock })!struct { *av.Packet, i32 } {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (true) {
                if (self.abort_request.load(.acquire)) return error.Aborted;
                if (self.ring.getLocked()) |entry| {
                    self.size -= @intCast(entry.pkt.size);
                    self.duration -= entry.pkt.duration;
                    return .{ entry.pkt, entry.serial };
                } else if (!block) {
                    return error.WouldBlock;
                } else {
                    self.cond.waitUncancelable(io, &self.mutex);
                }
            }
        }

        pub fn flush(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.ring.getLocked()) |entry| {
                entry.pkt.unref();
                entry.pkt.free();
            }
            self.size = 0;
            self.duration = 0;
            self.serial += 1;
        }

        pub fn deinit(self: *Self, io: Io) void {
            self.flush(io);
        }
    };
}
