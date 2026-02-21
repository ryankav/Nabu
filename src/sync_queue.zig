const std = @import("std");
const testing = std.testing;

/// Lock-free ring buffer mechanics, intended to be used inside an externally-locked scope.
/// All methods must be called while holding the caller's external lock.
///
/// `capacity` must be a power of two so that wrap-around is a cheap bitwise AND
/// instead of a modulo.  `rindex` and `windex` grow monotonically; only the
/// buffer index is masked.  This avoids the `rindex == windex` ambiguity between
/// the full and empty states.
pub fn BoundedSyncQueue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    const mask = capacity - 1;

    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        rindex: usize = 0,
        windex: usize = 0,
        count: usize = 0,

        pub fn isFull(self: *const Self) bool {
            return self.count >= capacity;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        // ── Value-based API (for PacketQueue) ─────────────────────────────────

        /// Write an item. Caller must hold the external lock.
        /// Returns `error.Full` if the buffer has no free slots.
        pub fn putLocked(self: *Self, item: T) error{Full}!void {
            if (self.count >= capacity) return error.Full;
            self.buf[self.windex & mask] = item;
            self.windex += 1;
            self.count += 1;
        }

        /// Remove and return the front item. Caller must hold the external lock.
        /// Returns `null` if the buffer is empty.
        pub fn getLocked(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.buf[self.rindex & mask];
            self.rindex += 1;
            self.count -= 1;
            return item;
        }

        // ── Pointer-based API (for FrameQueue) ────────────────────────────────

        /// Return a pointer to the next write slot without advancing windex.
        /// Returns `null` if the buffer is full. Caller must hold the external lock.
        /// Call `advanceWriteLocked` after writing to the slot.
        pub fn peekWriteLocked(self: *Self) ?*T {
            if (self.count >= capacity) return null;
            return &self.buf[self.windex & mask];
        }

        /// Advance windex after writing to the slot from `peekWriteLocked`.
        /// Caller must hold the external lock.
        pub fn advanceWriteLocked(self: *Self) void {
            self.windex += 1;
            self.count += 1;
        }

        /// Return a pointer to the front read slot without consuming it.
        /// Returns `null` if the buffer is empty. Caller must hold the external lock.
        pub fn peekReadLocked(self: *Self) ?*T {
            if (self.count == 0) return null;
            return &self.buf[self.rindex & mask];
        }

        /// Return a pointer to the read slot `offset` positions from the front.
        /// Returns `null` if fewer than `offset + 1` items are available.
        /// Caller must hold the external lock.
        pub fn peekReadAtLocked(self: *Self, offset: usize) ?*T {
            if (self.count <= offset) return null;
            return &self.buf[(self.rindex + offset) & mask];
        }

        /// Consume the front item by advancing rindex.
        /// Asserts the buffer is non-empty. Caller must hold the external lock.
        pub fn advanceReadLocked(self: *Self) void {
            std.debug.assert(self.count > 0);
            self.rindex += 1;
            self.count -= 1;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "BoundedSyncQueue: starts empty" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try testing.expect(q.isEmpty());
    try testing.expect(!q.isFull());
    try testing.expectEqual(@as(usize, 0), q.count);
}

test "BoundedSyncQueue: put and get round-trip" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try q.putLocked(42);
    try testing.expectEqual(@as(usize, 1), q.count);
    try testing.expect(!q.isEmpty());
    try testing.expectEqual(@as(?u32, 42), q.getLocked());
    try testing.expect(q.isEmpty());
}

test "BoundedSyncQueue: FIFO ordering" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try q.putLocked(1);
    try q.putLocked(2);
    try q.putLocked(3);
    try testing.expectEqual(@as(?u32, 1), q.getLocked());
    try testing.expectEqual(@as(?u32, 2), q.getLocked());
    try testing.expectEqual(@as(?u32, 3), q.getLocked());
    try testing.expect(q.isEmpty());
}

test "BoundedSyncQueue: returns error.Full at capacity" {
    var q: BoundedSyncQueue(u32, 2) = .{};
    try q.putLocked(1);
    try q.putLocked(2);
    try testing.expect(q.isFull());
    try testing.expectError(error.Full, q.putLocked(3));
}

test "BoundedSyncQueue: getLocked returns null when empty" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try testing.expectEqual(@as(?u32, null), q.getLocked());
}

test "BoundedSyncQueue: indices wrap correctly after fill-drain cycle" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    // First cycle: fill then drain (indices advance to 4)
    for (0..4) |i| try q.putLocked(@intCast(i));
    for (0..4) |_| _ = q.getLocked();
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(usize, 4), q.rindex);
    try testing.expectEqual(@as(usize, 4), q.windex);
    // Second cycle: buffer slots are reused via the mask
    for (10..14) |i| try q.putLocked(@intCast(i));
    try testing.expectEqual(@as(?u32, 10), q.getLocked());
    try testing.expectEqual(@as(?u32, 11), q.getLocked());
    try testing.expectEqual(@as(?u32, 12), q.getLocked());
    try testing.expectEqual(@as(?u32, 13), q.getLocked());
    try testing.expect(q.isEmpty());
}

test "BoundedSyncQueue: pointer-based write API" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    const slot = q.peekWriteLocked() orelse return error.TestUnexpectedNull;
    slot.* = 99;
    q.advanceWriteLocked();
    try testing.expectEqual(@as(usize, 1), q.count);
    try testing.expectEqual(@as(?u32, 99), q.getLocked());
}

test "BoundedSyncQueue: pointer-based read API" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try q.putLocked(10);
    try q.putLocked(20);

    const front = q.peekReadLocked() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 10), front.*);
    // Peek does not consume.
    try testing.expectEqual(@as(usize, 2), q.count);

    q.advanceReadLocked();
    try testing.expectEqual(@as(usize, 1), q.count);

    const next = q.peekReadLocked() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 20), next.*);
}

test "BoundedSyncQueue: peekReadAtLocked" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try q.putLocked(1);
    try q.putLocked(2);
    try q.putLocked(3);

    try testing.expectEqual(@as(u32, 1), (q.peekReadAtLocked(0) orelse return error.TestUnexpectedNull).*);
    try testing.expectEqual(@as(u32, 2), (q.peekReadAtLocked(1) orelse return error.TestUnexpectedNull).*);
    try testing.expectEqual(@as(u32, 3), (q.peekReadAtLocked(2) orelse return error.TestUnexpectedNull).*);
    // One past the last element returns null.
    try testing.expectEqual(@as(?*u32, null), q.peekReadAtLocked(3));
}

test "BoundedSyncQueue: peekWriteLocked returns null when full" {
    var q: BoundedSyncQueue(u32, 2) = .{};
    try q.putLocked(1);
    try q.putLocked(2);
    try testing.expectEqual(@as(?*u32, null), q.peekWriteLocked());
}

test "BoundedSyncQueue: peekReadLocked returns null when empty" {
    var q: BoundedSyncQueue(u32, 4) = .{};
    try testing.expectEqual(@as(?*u32, null), q.peekReadLocked());
}
