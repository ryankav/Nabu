const std = @import("std");
const av = @import("av");
const platform = @import("platform.zig");
const build_options = @import("build_options");
const pl = platform.getPlatform(build_options.backend);

const VideoState = @import("video_state.zig").VideoState;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // Parse command line args
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("Usage: nabu <media_file>\n", .{});
        return;
    }

    const filename = args[1];

    // Initialize platform
    pl.init() catch {
        std.debug.print("Platform init failed: {s}\n", .{pl.getError()});
        return error.PlatformInitFailed;
    };
    defer pl.deinit();

    // Create VideoState and open file
    var vs = VideoState.init(allocator, io, filename) catch |err| {
        std.debug.print("Failed to open media: {}\n", .{err});
        return err;
    };
    defer vs.deinit();

    // Set up self-referential pointers now that vs is at its final location
    vs.open() catch |err| {
        std.debug.print("Failed to set up playback: {}\n", .{err});
        return err;
    };

    // Create window
    const window = pl.createWindow("Nabu", @intCast(vs.width), @intCast(vs.height)) catch {
        std.debug.print("Window creation failed: {s}\n", .{pl.getError()});
        return error.WindowFailed;
    };
    defer pl.destroyWindow(window);

    const renderer = pl.createRenderer(window) catch {
        std.debug.print("Renderer creation failed: {s}\n", .{pl.getError()});
        return error.RendererFailed;
    };
    defer pl.destroyRenderer(renderer);

    // Create YUV texture for video display
    const texture = pl.createTexture(renderer, @intCast(vs.width), @intCast(vs.height)) catch {
        std.debug.print("Texture creation failed: {s}\n", .{pl.getError()});
        return error.TextureFailed;
    };
    defer pl.destroyTexture(texture);

    // Set up audio
    vs.setupAudio() catch |err| {
        std.debug.print("Warning: audio setup failed: {}, continuing without audio\n", .{err});
    };

    // Start demuxing and decoding threads
    vs.start() catch |err| {
        std.debug.print("Failed to start playback: {}\n", .{err});
        return err;
    };

    std.debug.print("Nabu: Playing {s}. Press 'q' to quit, space to pause, left/right to seek.\n", .{filename});

    // Main event loop
    var event: platform.Event = .none;
    mainLoop: while (!vs.abort_request.load(.acquire)) {
        while (pl.pollEvent(&event)) {
            switch (event) {
                .quit => {
                    vs.abort_request.store(true, .release);
                    break :mainLoop;
                },
                .key_down => |key| {
                    switch (key) {
                        .q, .escape => {
                            vs.abort_request.store(true, .release);
                            break :mainLoop;
                        },
                        .space => vs.togglePause(),
                        .left => vs.seekRelative(-10.0),
                        .right => vs.seekRelative(10.0),
                        .unknown => {},
                    }
                },
                .none => {},
            }
        }

        // Display video frame
        vs.displayFrame(renderer, texture);

        // Small delay to avoid busy-waiting
        pl.delay(1);
    }
}
