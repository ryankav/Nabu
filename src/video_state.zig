const std = @import("std");
const Io = std.Io;
const av = @import("av");
const platform = @import("platform.zig");
const build_options = @import("build_options");
const pl = platform.getPlatform(build_options.backend);
const PacketQueue = @import("packet_queue.zig").PacketQueue(256);
const FrameQueue = @import("frame_queue.zig").FrameQueue;
const Decoder = @import("decoder.zig").Decoder;
const Clock = @import("clock.zig").Clock;
const AudioState = @import("audio.zig").AudioState;
const VideoDisplay = @import("video.zig").VideoDisplay;

/// Top-level state container for the media player.
/// Owns the format context, queues, decoders, and threads.
pub const VideoState = struct {
    allocator: std.mem.Allocator,
    io: Io,

    // Format context (demuxer)
    fmt_ctx: *av.FormatContext,

    // Stream indices
    video_stream_idx: c_int = -1,
    audio_stream_idx: c_int = -1,

    // Codec contexts
    video_codec_ctx: ?*av.Codec.Context = null,
    audio_codec_ctx: ?*av.Codec.Context = null,

    // Packet queues
    video_pkt_queue: PacketQueue,
    audio_pkt_queue: PacketQueue,

    // Frame queues
    video_frame_queue: FrameQueue,
    audio_frame_queue: FrameQueue,

    // Decoders
    video_decoder: ?Decoder = null,
    audio_decoder: ?Decoder = null,

    // Clocks
    video_clock: Clock,
    audio_clock: Clock,

    // Video display
    video_display: ?VideoDisplay = null,

    // Audio output
    audio_state: ?AudioState = null,

    // Control flags
    abort_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Seek state
    seek_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seek_pos: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Read thread
    read_thread: ?std.Thread = null,

    // Video dimensions
    width: c_int = 640,
    height: c_int = 480,

    // Serials for discontinuity tracking
    video_serial: i32 = 0,
    audio_serial: i32 = 0,

    /// Phase 1: Open the media file, find streams, open codecs.
    /// Returns a VideoState with basic fields set but NO self-referential
    /// pointers. You MUST call `open()` after this to set up internal
    /// pointers once the struct is at its final memory location.
    pub fn init(allocator: std.mem.Allocator, io: Io, filename: [*:0]const u8) !VideoState {
        // Open media file
        const fmt_ctx = try av.FormatContext.open_input(filename, null, null, null);
        errdefer fmt_ctx.close_input();

        // Find stream info
        try fmt_ctx.find_stream_info(null);

        // Dump format info to stderr
        fmt_ctx.dump(0, filename, .input);

        var vs = VideoState{
            .allocator = allocator,
            .io = io,
            .fmt_ctx = fmt_ctx,
            .video_pkt_queue = .{},
            .audio_pkt_queue = .{},
            .video_frame_queue = undefined,
            .audio_frame_queue = undefined,
            .video_clock = undefined,
            .audio_clock = undefined,
        };

        // Find and open video stream (codec contexts are heap-allocated, safe to store)
        if (fmt_ctx.find_best_stream(.VIDEO, -1, -1)) |result| {
            vs.video_stream_idx = @intCast(result[0]);
            const codec = result[1];
            vs.video_codec_ctx = try openCodec(fmt_ctx, @intCast(result[0]), codec);

            vs.width = vs.video_codec_ctx.?.width;
            vs.height = vs.video_codec_ctx.?.height;
            if (vs.width <= 0) vs.width = 640;
            if (vs.height <= 0) vs.height = 480;
        } else |_| {
            std.debug.print("No video stream found\n", .{});
        }

        // Find and open audio stream
        if (fmt_ctx.find_best_stream(.AUDIO, -1, -1)) |result| {
            vs.audio_stream_idx = @intCast(result[0]);
            const codec = result[1];
            vs.audio_codec_ctx = try openCodec(fmt_ctx, @intCast(result[0]), codec);
        } else |_| {
            std.debug.print("No audio stream found\n", .{});
        }

        if (vs.video_stream_idx < 0 and vs.audio_stream_idx < 0) {
            return error.NoStreamsFound;
        }

        return vs;
    }

    /// Phase 2: Set up self-referential pointers (clocks, frame queues, decoders).
    /// Must be called once the VideoState is at its final memory location.
    pub fn open(self: *VideoState) !void {
        // Initialize clocks with pointers into our own packet queues
        self.video_clock = Clock.init(&self.video_pkt_queue.serial);
        self.audio_clock = Clock.init(&self.audio_pkt_queue.serial);

        // Initialize frame queues with pointer to our abort_request
        self.video_frame_queue = try FrameQueue.init(FrameQueue.QUEUE_SIZE, &self.abort_request);
        self.audio_frame_queue = try FrameQueue.init(FrameQueue.QUEUE_SIZE, &self.abort_request);

        // Set up video decoder
        if (self.video_stream_idx >= 0) {
            const stream = self.fmt_ctx.streams[@intCast(self.video_stream_idx)];
            self.video_decoder = Decoder.init(
                self.video_codec_ctx.?,
                &self.video_pkt_queue,
                &self.video_frame_queue,
                &self.abort_request,
                self.video_stream_idx,
                stream.time_base,
                self.io,
            );
        }

        // Set up audio decoder
        if (self.audio_stream_idx >= 0) {
            const stream = self.fmt_ctx.streams[@intCast(self.audio_stream_idx)];
            self.audio_decoder = Decoder.init(
                self.audio_codec_ctx.?,
                &self.audio_pkt_queue,
                &self.audio_frame_queue,
                &self.abort_request,
                self.audio_stream_idx,
                stream.time_base,
                self.io,
            );
        }
    }

    fn openCodec(fmt_ctx: *av.FormatContext, stream_idx: c_uint, codec: *const av.Codec) !*av.Codec.Context {
        const stream = fmt_ctx.streams[stream_idx];
        const codec_ctx = try av.Codec.Context.alloc(codec);
        errdefer codec_ctx.free();

        try codec_ctx.parameters_to_context(stream.codecpar);
        try codec_ctx.open(codec, null);

        return codec_ctx;
    }

    /// Set up audio output (must be called after init, before start).
    pub fn setupAudio(self: *VideoState) !void {
        if (self.audio_codec_ctx) |codec_ctx| {
            self.audio_state = AudioState.init(
                &self.audio_frame_queue,
                &self.audio_clock,
                &self.abort_request,
                self.io,
            );
            try self.audio_state.?.open(codec_ctx);
        } else {
            return error.NoAudioStream;
        }
    }

    /// Start all playback threads.
    pub fn start(self: *VideoState) !void {
        // Start packet queues
        self.video_pkt_queue.start(self.io);
        self.audio_pkt_queue.start(self.io);

        // Initialize video display
        if (self.video_stream_idx >= 0) {
            self.video_display = VideoDisplay.init(
                &self.video_frame_queue,
                &self.video_clock,
                &self.audio_clock,
                &self.abort_request,
                &self.paused,
                self.width,
                self.height,
                self.io,
            );
        }

        // Start decoder threads
        if (self.video_decoder) |*dec| {
            try dec.start();
        }
        if (self.audio_decoder) |*dec| {
            try dec.start();
        }

        // Start read thread
        self.read_thread = try std.Thread.spawn(.{}, readThread, .{self});
    }

    /// Display a video frame (called from main thread).
    pub fn displayFrame(self: *VideoState, renderer: platform.Renderer, texture: platform.Texture) void {
        if (self.video_display) |*display| {
            display.displayFrame(renderer, texture);
        }
    }

    pub fn togglePause(self: *VideoState) void {
        const was_paused = self.paused.load(.acquire);
        self.paused.store(!was_paused, .release);
        self.video_clock.paused = !was_paused;
        self.audio_clock.paused = !was_paused;
        if (self.audio_state) |*audio| {
            audio.pause(!was_paused);
        }
    }

    pub fn seekRelative(self: *VideoState, offset_seconds: f64) void {
        // Get current position from audio clock (master)
        const pos = self.audio_clock.get();
        const target = pos + offset_seconds;
        const target_ts: i64 = @intFromFloat(target * 1_000_000.0); // AV_TIME_BASE units
        self.seek_pos.store(target_ts, .release);
        self.seek_request.store(true, .release);
    }

    fn readThread(self: *VideoState) void {
        while (!self.abort_request.load(.acquire)) {
            // Handle seek
            if (self.seek_request.load(.acquire)) {
                const seek_target = self.seek_pos.load(.acquire);
                self.fmt_ctx.seek_frame(-1, seek_target, 0) catch {};

                // Flush queues on seek
                self.video_pkt_queue.flush(self.io);
                self.audio_pkt_queue.flush(self.io);

                // Increment serials
                self.video_pkt_queue.start(self.io);
                self.audio_pkt_queue.start(self.io);

                self.seek_request.store(false, .release);
            }

            // Read a packet
            const pkt = av.Packet.alloc() catch continue;

            self.fmt_ctx.read_frame(pkt) catch |err| {
                switch (err) {
                    error.EndOfFile => {
                        pkt.free();
                        pl.delay(100);
                        continue;
                    },
                    else => {
                        pkt.free();
                        pl.delay(10);
                        continue;
                    },
                }
            };

            // Route packet to appropriate queue.
            // Sleep and retry on Full so the ring buffer capacity is the sole
            // backpressure gate — no separate byte-budget check needed.
            const queue: ?*PacketQueue =
                if (pkt.stream_index == self.video_stream_idx) &self.video_pkt_queue
                else if (pkt.stream_index == self.audio_stream_idx) &self.audio_pkt_queue
                else null;

            if (queue) |q| {
                put_loop: while (true) {
                    q.put(self.io, pkt) catch |err| switch (err) {
                        error.Aborted => { pkt.unref(); pkt.free(); break :put_loop; },
                        error.Full => { pl.delay(10); continue :put_loop; },
                    };
                    break :put_loop;
                }
            } else {
                pkt.unref();
                pkt.free();
            }
        }
    }

    pub fn deinit(self: *VideoState) void {
        // Signal abort
        self.abort_request.store(true, .release);

        // Abort queues to unblock threads
        self.video_pkt_queue.abort(self.io);
        self.audio_pkt_queue.abort(self.io);

        // Signal frame queues to wake blocked threads
        self.video_frame_queue.signalAll(self.io);
        self.audio_frame_queue.signalAll(self.io);

        // Join threads
        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.video_decoder) |*dec| dec.join();
        if (self.audio_decoder) |*dec| dec.join();

        // Clean up audio
        if (self.audio_state) |*audio| audio.deinit();

        // Clean up video display
        if (self.video_display) |*display| display.deinit();

        // Clean up queues
        self.video_pkt_queue.deinit(self.io);
        self.audio_pkt_queue.deinit(self.io);
        self.video_frame_queue.deinit();
        self.audio_frame_queue.deinit();

        // Clean up codec contexts
        if (self.video_codec_ctx) |ctx| ctx.free();
        if (self.audio_codec_ctx) |ctx| ctx.free();

        // Close format context
        self.fmt_ctx.close_input();
    }
};
