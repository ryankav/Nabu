const std = @import("std");
const Io = std.Io;
const av = @import("av");

/// Thread-safe FIFO queue for compressed packets backed by a fixed ring buffer.
/// Mirrors ffplay's PacketQueue.
pub fn PacketQueue(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    const mask = capacity - 1;

    return struct {
        const Self = @This();
        const Entry = struct { pkt: *av.Packet, serial: i32 };

        buf: [capacity]Entry = undefined,
        rindex: usize = 0,
        windex: usize = 0,
        nb_packets: u32 = 0,
        size: usize = 0,
        duration: i64 = 0,
        serial: i32 = 0,
        abort_request: bool = true,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,

        pub fn start(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.abort_request = false;
            self.serial += 1;
        }

        pub fn abort(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.abort_request = true;
            self.cond.broadcast(io);
        }

        pub fn put(self: *Self, io: Io, pkt: *av.Packet) error{ Aborted, Full }!void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.abort_request) return error.Aborted;
            if (self.nb_packets >= capacity) return error.Full;
            self.buf[self.windex & mask] = .{ .pkt = pkt, .serial = self.serial };
            self.windex += 1;
            self.nb_packets += 1;
            self.size += @intCast(pkt.size);
            self.duration += pkt.duration;
            self.cond.signal(io);
        }

        pub fn get(self: *Self, io: Io, block: bool) error{ Aborted, WouldBlock }!struct { *av.Packet, i32 } {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (true) {
                if (self.abort_request) return error.Aborted;
                if (self.nb_packets > 0) {
                    const entry = self.buf[self.rindex & mask];
                    self.rindex += 1;
                    self.nb_packets -= 1;
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
            while (self.nb_packets > 0) {
                const entry = self.buf[self.rindex & mask];
                self.rindex += 1;
                self.nb_packets -= 1;
                entry.pkt.unref();
                entry.pkt.free();
            }
            self.windex = self.rindex;
            self.size = 0;
            self.duration = 0;
            self.serial += 1;
        }

        pub fn deinit(self: *Self, io: Io) void {
            self.flush(io);
        }
    };
}
