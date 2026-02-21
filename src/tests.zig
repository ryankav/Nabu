// Unit test entrypoint.
// Imports every pure-Zig module so their inline `test` blocks are discovered
// by `zig build test`. Nothing here may transitively import `av` (FFmpeg) or
// `build_options` (SDL2 backend selection).
test {
    _ = @import("sync_queue.zig");
    _ = @import("av_math.zig");
}
