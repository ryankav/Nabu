const std = @import("std");
const av = @import("av");
const platform = @import("platform.zig");
const build_options = @import("build_options");
const pl = platform.getPlatform(build_options.backend);

/// A/V sync clock tracking.
/// Follows ffplay's Clock design: tracks pts + drift relative to system time.
pub const Clock = struct {
    pts: f64 = 0,
    pts_drift: f64 = 0,
    last_updated: f64 = 0,
    paused: bool = false,
    serial: i32 = 0,
    queue_serial: *i32,

    pub fn init(queue_serial: *i32) Clock {
        return .{
            .queue_serial = queue_serial,
        };
    }

    pub fn set(self: *Clock, pts: f64, serial: i32) void {
        const time = getTime();
        self.pts = pts;
        self.last_updated = time;
        self.pts_drift = pts - time;
        self.serial = serial;
    }

    pub fn get(self: *const Clock) f64 {
        if (self.paused) {
            return self.pts;
        }
        const time = getTime();
        return self.pts_drift + time;
    }

    pub fn getTime() f64 {
        return pl.getTime();
    }
};
