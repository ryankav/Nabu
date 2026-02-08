const std = @import("std");
const Io = std.Io;
const av = @import("av");
const ffi = @import("ffi.zig");
const swr = ffi.swr;
const platform = @import("platform.zig");
const build_options = @import("build_options");
const pl = platform.getPlatform(build_options.backend);
const Clock = @import("clock.zig").Clock;
const FrameQueue = @import("frame_queue.zig").FrameQueue;

/// Audio output state: handles audio callback and resampling.
pub const AudioState = struct {
    frame_queue: *FrameQueue,
    audio_clock: *Clock,
    abort_request: *const std.atomic.Value(bool),
    io: Io,

    // Resampling context (C API)
    swr_ctx: ?*swr.SwrContext = null,

    // Audio buffer for callback
    audio_buf: [192000]u8 = undefined,
    audio_buf_size: u32 = 0,
    audio_buf_index: u32 = 0,

    // Audio stream parameters
    sample_rate: c_int = 0,
    channels: c_int = 2,

    // Audio device
    audio_dev: platform.AudioDevice = 0,

    pub fn init(
        frame_queue: *FrameQueue,
        audio_clock: *Clock,
        abort_request: *const std.atomic.Value(bool),
        io: Io,
    ) AudioState {
        return .{
            .frame_queue = frame_queue,
            .audio_clock = audio_clock,
            .abort_request = abort_request,
            .io = io,
        };
    }

    /// Open audio device and set up resampling.
    pub fn open(self: *AudioState, codec_ctx: *av.Codec.Context) !void {
        var desired = platform.AudioSpec{
            .freq = codec_ctx.sample_rate,
            .channels = @intCast(codec_ctx.ch_layout.nb_channels),
            .samples = @intCast(@max(512, @as(u32, 2) << std.math.log2_int(u32, @intCast(@as(u32, @intCast(codec_ctx.sample_rate)) / 30)))),
            .callback = audioCallback,
            .userdata = self,
        };

        var obtained = platform.AudioSpec{};
        self.audio_dev = try pl.openAudioDevice(&desired, &obtained);

        self.sample_rate = obtained.freq;
        self.channels = obtained.channels;

        // Set up SwrContext for resampling to S16 stereo
        self.swr_ctx = swr.swr_alloc();
        if (self.swr_ctx == null) return error.OutOfMemory;

        // Configure input format from codec
        _ = swr.av_opt_set_chlayout(self.swr_ctx, "in_chlayout", @ptrCast(&codec_ctx.ch_layout), 0);
        _ = swr.av_opt_set_int(self.swr_ctx, "in_sample_rate", codec_ctx.sample_rate, 0);
        _ = swr.av_opt_set_sample_fmt(self.swr_ctx, "in_sample_fmt", @intFromEnum(codec_ctx.sample_fmt), 0);

        // Configure output format (stereo)
        var out_layout: swr.AVChannelLayout = undefined;
        swr.av_channel_layout_default(&out_layout, 2);
        _ = swr.av_opt_set_chlayout(self.swr_ctx, "out_chlayout", &out_layout, 0);
        _ = swr.av_opt_set_int(self.swr_ctx, "out_sample_rate", obtained.freq, 0);
        _ = swr.av_opt_set_sample_fmt(self.swr_ctx, "out_sample_fmt", swr.AV_SAMPLE_FMT_S16, 0);

        if (swr.swr_init(self.swr_ctx) < 0) {
            std.debug.print("swr_init failed\n", .{});
            return error.SwrInitFailed;
        }

        // Start audio playback
        pl.pauseAudioDevice(self.audio_dev, false);
    }

    pub fn deinit(self: *AudioState) void {
        if (self.audio_dev != 0) {
            pl.closeAudioDevice(self.audio_dev);
            self.audio_dev = 0;
        }
        if (self.swr_ctx) |ctx| {
            swr.swr_free(@constCast(@ptrCast(&@as(?*swr.SwrContext, ctx))));
            self.swr_ctx = null;
        }
    }

    pub fn pause(self: *AudioState, paused: bool) void {
        if (self.audio_dev != 0) {
            pl.pauseAudioDevice(self.audio_dev, paused);
        }
    }

    fn audioCallback(userdata: ?*anyopaque, stream: [*]u8, len_i: c_int) callconv(std.builtin.CallingConvention.c) void {
        const self: *AudioState = @ptrCast(@alignCast(userdata));
        var len: u32 = @intCast(len_i);
        var offset: u32 = 0;

        while (len > 0) {
            if (self.audio_buf_index >= self.audio_buf_size) {
                // Need to decode more audio
                self.audio_buf_size = self.decodeAudioFrame() catch 0;
                self.audio_buf_index = 0;
            }

            if (self.audio_buf_size == 0) {
                // Silence if no audio available
                @memset(stream[offset .. offset + len], 0);
                break;
            }

            var copy_len = self.audio_buf_size - self.audio_buf_index;
            if (copy_len > len) copy_len = len;

            @memcpy(stream[offset .. offset + copy_len], self.audio_buf[self.audio_buf_index .. self.audio_buf_index + copy_len]);
            offset += copy_len;
            len -= copy_len;
            self.audio_buf_index += copy_len;
        }
    }

    fn decodeAudioFrame(self: *AudioState) !u32 {
        // Use non-blocking peek since we're in the audio callback thread.
        // We don't want to block the audio thread waiting for frames.
        const entry = self.frame_queue.peekReadableNonblock(self.io) orelse return error.NoFrame;
        defer self.frame_queue.next(self.io);

        const frame = entry.frame;

        // Update audio clock
        if (entry.pts != 0) {
            self.audio_clock.set(entry.pts, entry.serial);
        }

        if (self.swr_ctx) |swr_ctx| {
            // Resample
            const out_samples = swr.swr_get_out_samples(swr_ctx, frame.nb_samples);
            if (out_samples < 0) return error.SwrError;

            const max_bytes: u32 = @intCast(out_samples * self.channels * 2); // S16 = 2 bytes
            if (max_bytes > self.audio_buf.len) return error.BufferTooSmall;

            var out_ptr: [*]u8 = &self.audio_buf;
            const converted = swr.swr_convert(
                swr_ctx,
                @ptrCast(&out_ptr),
                out_samples,
                @ptrCast(&frame.extended_data[0]),
                frame.nb_samples,
            );
            if (converted < 0) return error.SwrError;

            return @intCast(converted * self.channels * 2);
        }

        return 0;
    }
};
