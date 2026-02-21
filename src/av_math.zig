const std = @import("std");

// A/V sync thresholds — mirror of ffplay's constants.
pub const AV_SYNC_THRESHOLD_MIN: f64 = 0.04; // 40 ms
pub const AV_SYNC_THRESHOLD_MAX: f64 = 0.1; // 100 ms
pub const AV_SYNC_FRAMEDUP_THRESHOLD: f64 = 0.1; // 100 ms
pub const AV_NOSYNC_THRESHOLD: f64 = 10.0; // 10 s

/// Convert a raw PTS or duration value to seconds.
///
/// Pass the stream's time base as a float: `time_base.q2d()`.
/// Returns 0.0 when `pts` is 0; callers are responsible for filtering
/// `av.NOPTS_VALUE` before calling this function.
pub fn ptsToSeconds(pts: i64, time_base: f64) f64 {
    return @as(f64, @floatFromInt(pts)) * time_base;
}

/// Given a normalised inter-frame delay and the A/V clock difference
/// (video_pts − audio_clock), return the adjusted display delay.
///
/// `delay` must already be sanitised by the caller (invalid values ≤ 0 or
/// ≥ 1.0 should be replaced with the previous frame's delay before calling).
/// This function encodes ffplay's three-branch sync logic:
///   1. Video behind audio  → shorten delay
///   2. Video ahead, long delay  → lengthen delay by diff
///   3. Video ahead, short delay → double delay
/// Large desync (|diff| ≥ AV_NOSYNC_THRESHOLD) is left uncorrected.
pub fn adjustDelay(delay: f64, diff: f64) f64 {
    const sync_threshold = @max(AV_SYNC_THRESHOLD_MIN, @min(AV_SYNC_THRESHOLD_MAX, delay));

    if (@abs(diff) < AV_NOSYNC_THRESHOLD) {
        if (diff <= -sync_threshold) {
            // Video is behind audio: speed up by reducing delay.
            return @max(0, delay + diff);
        } else if (diff >= sync_threshold and delay > AV_SYNC_FRAMEDUP_THRESHOLD) {
            // Video is well ahead and the frame has a long duration: slow down.
            return delay + diff;
        } else if (diff >= sync_threshold) {
            // Video is slightly ahead and the frame is short: double the hold time.
            return 2.0 * delay;
        }
    }

    return delay;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "ptsToSeconds: zero pts" {
    try std.testing.expectEqual(@as(f64, 0.0), ptsToSeconds(0, 1.0 / 90000.0));
}

test "ptsToSeconds: 90 kHz time base" {
    // 90000 ticks at 1/90000 s each = 1.0 s
    try std.testing.expectApproxEqAbs(1.0, ptsToSeconds(90000, 1.0 / 90000.0), 1e-9);
    try std.testing.expectApproxEqAbs(0.5, ptsToSeconds(45000, 1.0 / 90000.0), 1e-9);
}

test "ptsToSeconds: frame-rate time bases" {
    // 25 fps: one frame = 1.0 s
    try std.testing.expectApproxEqAbs(1.0, ptsToSeconds(25, 1.0 / 25.0), 1e-9);
    // 30 fps: 60 frames = 2.0 s
    try std.testing.expectApproxEqAbs(2.0, ptsToSeconds(60, 1.0 / 30.0), 1e-9);
}

test "ptsToSeconds: millisecond time base" {
    try std.testing.expectApproxEqAbs(1.0, ptsToSeconds(1000, 0.001), 1e-9);
    try std.testing.expectApproxEqAbs(1.5, ptsToSeconds(1500, 0.001), 1e-9);
}

test "adjustDelay: no change when diff is within sync threshold" {
    // diff = 0: nothing to correct
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, 0.0));
    // diff = 0.01 < sync_threshold(0.04): no branch taken
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, 0.01));
    // diff = -0.01 > -sync_threshold(-0.04): no branch taken
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, -0.01));
}

test "adjustDelay: video behind audio shortens delay" {
    // delay=0.04, diff=-0.2 → max(0, 0.04 - 0.2) = 0
    try std.testing.expectApproxEqAbs(0.0, adjustDelay(0.04, -0.2), 1e-9);
    // delay=0.1, diff=-0.2 → max(0, 0.1 - 0.2) = 0
    try std.testing.expectApproxEqAbs(0.0, adjustDelay(0.1, -0.2), 1e-9);
    // delay=0.2, sync_threshold=0.1, diff=-0.1 (equal to -threshold) → max(0, 0.1) = 0.1
    try std.testing.expectApproxEqAbs(0.1, adjustDelay(0.2, -0.1), 1e-9);
}

test "adjustDelay: video ahead with long delay adds diff" {
    // delay=0.15 > FRAMEDUP(0.1), sync_threshold=0.1, diff=0.1 → 0.15 + 0.1 = 0.25
    try std.testing.expectApproxEqAbs(0.25, adjustDelay(0.15, 0.1), 1e-9);
    // delay=0.2, sync_threshold=0.1, diff=0.15 → 0.2 + 0.15 = 0.35
    try std.testing.expectApproxEqAbs(0.35, adjustDelay(0.2, 0.15), 1e-9);
}

test "adjustDelay: video slightly ahead with short delay doubles it" {
    // delay=0.04 <= FRAMEDUP(0.1), sync_threshold=0.04, diff=0.05 >= 0.04 → 2 * 0.04 = 0.08
    try std.testing.expectApproxEqAbs(0.08, adjustDelay(0.04, 0.05), 1e-9);
    // delay=0.06 <= FRAMEDUP(0.1), sync_threshold=0.06, diff=0.07 >= 0.06 → 2 * 0.06 = 0.12
    try std.testing.expectApproxEqAbs(0.12, adjustDelay(0.06, 0.07), 1e-9);
}

test "adjustDelay: ignores desync larger than AV_NOSYNC_THRESHOLD" {
    // |diff| = 15.0 > 10.0: no adjustment
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, 15.0));
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, -15.0));
    // Exactly at threshold: |10.0| is not < 10.0, so no adjustment
    try std.testing.expectEqual(@as(f64, 0.04), adjustDelay(0.04, 10.0));
}
