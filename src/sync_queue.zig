const std = @import("std");

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
