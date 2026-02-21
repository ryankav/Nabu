const std = @import("std");
const Io = std.Io;
const av = @import("av");
const PacketQueue = @import("packet_queue.zig").PacketQueue(256);
const FrameQueue = @import("frame_queue.zig").FrameQueue;
const av_math = @import("av_math.zig");

/// Per-stream decoder thread: reads packets → sends to codec → pushes decoded frames.
pub const Decoder = struct {
    codec_ctx: *av.Codec.Context,
    pkt_queue: *PacketQueue,
    frame_queue: *FrameQueue,
    abort_request: *const std.atomic.Value(bool),
    thread: ?std.Thread = null,
    stream_index: c_int,
    time_base: av.Rational,
    io: Io,

    pub fn init(
        codec_ctx: *av.Codec.Context,
        pkt_queue: *PacketQueue,
        frame_queue: *FrameQueue,
        abort_request: *const std.atomic.Value(bool),
        stream_index: c_int,
        time_base: av.Rational,
        io: Io,
    ) Decoder {
        return .{
            .codec_ctx = codec_ctx,
            .pkt_queue = pkt_queue,
            .frame_queue = frame_queue,
            .abort_request = abort_request,
            .stream_index = stream_index,
            .time_base = time_base,
            .io = io,
        };
    }

    pub fn start(self: *Decoder) !void {
        self.thread = try std.Thread.spawn(.{}, decodeThread, .{self});
    }

    pub fn join(self: *Decoder) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn decodeThread(self: *Decoder) void {
        while (!self.abort_request.load(.acquire)) {
            // Get packet from queue
            const result = self.pkt_queue.get(self.io, true) catch |err| {
                switch (err) {
                    error.Aborted => break,
                }
            };
            const pkt = result[0];
            const serial = result[1];

            // Send packet to decoder
            self.codec_ctx.send_packet(pkt) catch |err| {
                switch (err) {
                    error.EndOfFile => {
                        self.codec_ctx.send_packet(null) catch {};
                    },
                    else => {},
                }
                pkt.unref();
                pkt.free();
                continue;
            };
            pkt.unref();
            pkt.free();

            // Receive all available decoded frames
            self.drainFrames(serial);
        }
    }

    fn drainFrames(self: *Decoder, serial: i32) void {
        while (!self.abort_request.load(.acquire)) {
            const entry = self.frame_queue.peekWritable(self.io) orelse return;

            self.codec_ctx.receive_frame(entry.frame) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.EndOfFile => {
                        self.codec_ctx.flush_buffers();
                        return;
                    },
                    else => return,
                }
            };

            // Compute PTS in seconds
            const frame = entry.frame;
            const tb = self.time_base.q2d();
            if (frame.pts != av.NOPTS_VALUE) {
                entry.pts = av_math.ptsToSeconds(frame.pts, tb);
            } else {
                entry.pts = 0;
            }

            if (frame.duration > 0) {
                entry.duration = av_math.ptsToSeconds(frame.duration, tb);
            } else {
                entry.duration = 0;
            }

            entry.serial = serial;
            entry.width = frame.width;
            entry.height = frame.height;
            entry.format = @intFromEnum(frame.format.pixel);

            self.frame_queue.push(self.io);
        }
    }
};
