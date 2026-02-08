const std = @import("std");
const Io = std.Io;
const av = @import("av");
const Allocator = std.mem.Allocator;

/// Thread-safe FIFO queue for compressed packets.
/// Mirrors ffplay's PacketQueue.
pub const PacketQueue = struct {
    const Node = struct {
        pkt: *av.Packet,
        serial: i32,
        next: ?*Node,
    };

    first: ?*Node = null,
    last: ?*Node = null,
    nb_packets: i32 = 0,
    size: i32 = 0,
    serial: i32 = 0,
    abort_request: bool = true,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PacketQueue {
        return .{
            .allocator = allocator,
        };
    }

    pub fn start(self: *PacketQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.abort_request = false;
        self.serial += 1;
        self.cond.signal(io);
    }

    pub fn abort(self: *PacketQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.abort_request = true;
        self.cond.broadcast(io);
    }

    pub fn put(self: *PacketQueue, io: Io, pkt: *av.Packet) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.abort_request) return error.Aborted;

        const node = try self.allocator.create(Node);
        node.* = .{
            .pkt = pkt,
            .serial = self.serial,
            .next = null,
        };

        if (self.last) |last| {
            last.next = node;
        } else {
            self.first = node;
        }
        self.last = node;
        self.nb_packets += 1;
        self.size += pkt.size;
        self.cond.signal(io);
    }

    /// Get a packet from the queue. Blocks until available or aborted.
    /// Returns the packet and its serial number.
    pub fn get(self: *PacketQueue, io: Io, block: bool) !struct { *av.Packet, i32 } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (true) {
            if (self.abort_request) return error.Aborted;

            if (self.first) |node| {
                self.first = node.next;
                if (self.first == null) self.last = null;
                self.nb_packets -= 1;
                self.size -= node.pkt.size;
                const pkt = node.pkt;
                const serial = node.serial;
                self.allocator.destroy(node);
                return .{ pkt, serial };
            } else if (!block) {
                return error.WouldBlock;
            } else {
                self.cond.waitUncancelable(io, &self.mutex);
            }
        }
    }

    pub fn flush(self: *PacketQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var node = self.first;
        while (node) |n| {
            const next = n.next;
            n.pkt.unref();
            n.pkt.free();
            self.allocator.destroy(n);
            node = next;
        }
        self.first = null;
        self.last = null;
        self.nb_packets = 0;
        self.size = 0;
    }

    pub fn deinit(self: *PacketQueue, io: Io) void {
        self.flush(io);
    }
};
