const std = @import("std");
const Io = std.Io;
const av = @import("av");
const platform = @import("platform.zig");
const build_options = @import("build_options");
const pl = platform.getPlatform(build_options.backend);
const Clock = @import("clock.zig").Clock;
const FrameQueue = @import("frame_queue.zig").FrameQueue;
const av_math = @import("av_math.zig");

/// Video display: frame timing and texture upload.
pub const VideoDisplay = struct {
    frame_queue: *FrameQueue,
    video_clock: *Clock,
    audio_clock: *Clock,
    abort_request: *const std.atomic.Value(bool),
    paused: *const std.atomic.Value(bool),
    io: Io,

    // SWS context for pixel format conversion
    sws_ctx: ?*av.sws.Context = null,

    // Frame timing state
    frame_timer: f64 = 0,
    last_pts: f64 = 0,
    last_delay: f64 = 0.04, // Initial guess: 25fps

    // Video dimensions
    width: c_int,
    height: c_int,

    // A/V sync thresholds — sourced from av_math to keep them in one place.

    pub fn init(
        frame_queue: *FrameQueue,
        video_clock: *Clock,
        audio_clock: *Clock,
        abort_request: *const std.atomic.Value(bool),
        paused: *const std.atomic.Value(bool),
        width: c_int,
        height: c_int,
        io: Io,
    ) VideoDisplay {
        return .{
            .frame_queue = frame_queue,
            .video_clock = video_clock,
            .audio_clock = audio_clock,
            .abort_request = abort_request,
            .paused = paused,
            .width = width,
            .height = height,
            .frame_timer = Clock.getTime(),
            .io = io,
        };
    }

    pub fn deinit(self: *VideoDisplay) void {
        if (self.sws_ctx) |ctx| {
            ctx.free();
            self.sws_ctx = null;
        }
    }

    /// Display a video frame, handling timing and A/V sync.
    /// Called from the main thread event loop.
    pub fn displayFrame(self: *VideoDisplay, renderer: platform.Renderer, texture: platform.Texture) void {
        if (self.paused.load(.acquire)) return;

        const entry = self.frame_queue.peekReadableNonblock(self.io) orelse return;

        // A/V sync: compute how long to display this frame
        const delay = self.computeDelay(entry);
        const time = Clock.getTime();

        if (time < self.frame_timer + delay) {
            // Not yet time to display this frame
            return;
        }

        self.frame_timer += delay;
        // If we're behind by more than AV_SYNC_THRESHOLD_MAX, reset timer
        if (time - self.frame_timer > av_math.AV_SYNC_THRESHOLD_MAX) {
            self.frame_timer = time;
        }

        // Update video clock
        self.video_clock.set(entry.pts, entry.serial);

        // Check if we should skip this frame (if next frame is also late)
        if (self.frame_queue.peekNext(self.io)) |next_entry| {
            const next_delay = next_entry.pts - entry.pts;
            if (time > self.frame_timer + next_delay) {
                // Skip this frame - we're too late
                self.frame_queue.next(self.io);
                return;
            }
        }

        // Upload frame to texture
        self.uploadFrame(entry.frame, texture);

        // Consume the frame
        self.frame_queue.next(self.io);

        // Render
        pl.renderClear(renderer);
        pl.renderCopy(renderer, texture);
        pl.renderPresent(renderer);
    }

    fn computeDelay(self: *VideoDisplay, entry: *const FrameQueue.Entry) f64 {
        var delay = entry.pts - self.last_pts;

        if (delay <= 0 or delay >= 1.0) {
            // Invalid delay, use previous
            delay = self.last_delay;
        }

        self.last_delay = delay;
        self.last_pts = entry.pts;

        // A/V sync against audio master clock
        const diff = entry.pts - self.audio_clock.get();
        return av_math.adjustDelay(delay, diff);
    }

    fn uploadFrame(self: *VideoDisplay, frame: *av.Frame, texture: platform.Texture) void {
        // If already YUV420P, upload directly
        if (frame.format.pixel == .YUV420P) {
            pl.updateYUVTexture(
                texture,
                frame.data[0],
                frame.linesize[0],
                frame.data[1],
                frame.linesize[1],
                frame.data[2],
                frame.linesize[2],
            );
        } else {
            // Need to convert pixel format
            if (self.sws_ctx == null) {
                self.sws_ctx = av.sws_getContext(
                    self.width,
                    self.height,
                    frame.format.pixel,
                    self.width,
                    self.height,
                    .YUV420P,
                    .{ .BICUBIC = true },
                    null,
                    null,
                    null,
                );
            }

            if (self.sws_ctx) |sws_ctx| {
                if (pl.lockTexture(texture)) |lock| {
                    var dst_data: [4][*]u8 = undefined;
                    var dst_linesize: [4]c_int = undefined;

                    dst_data[0] = lock.pixels;
                    dst_linesize[0] = lock.pitch;
                    // U and V planes follow Y
                    const y_size: usize = @intCast(lock.pitch * self.height);
                    const uv_pitch: c_int = @divTrunc(lock.pitch, 2);
                    dst_data[1] = dst_data[0] + y_size;
                    dst_linesize[1] = uv_pitch;
                    const uv_size: usize = @intCast(uv_pitch * @divTrunc(self.height, 2));
                    dst_data[2] = dst_data[1] + uv_size;
                    dst_linesize[2] = uv_pitch;

                    _ = av.sws_scale(
                        sws_ctx,
                        @ptrCast(&frame.data),
                        @ptrCast(&frame.linesize),
                        0,
                        self.height,
                        @ptrCast(&dst_data),
                        @ptrCast(&dst_linesize),
                    );

                    pl.unlockTexture(texture);
                }
            }
        }
    }
};
