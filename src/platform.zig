/// Platform abstraction layer.
/// Defines the interface that backends (SDL2, GLFW, etc.) must implement.
/// The backend is selected at comptime via build options, so all calls are direct
/// with zero function-pointer overhead.

/// Keyboard keys used by the application.
pub const Key = enum {
    q,
    escape,
    space,
    left,
    right,
    unknown,
};

/// Events the application handles.
pub const Event = union(enum) {
    quit,
    key_down: Key,
    none,
};

/// Opaque handle types — each backend defines the actual pointer inside.
pub const Window = *anyopaque;
pub const Renderer = *anyopaque;
pub const Texture = *anyopaque;
pub const AudioDevice = u32;

/// Audio callback function type.
pub const AudioCallback = *const fn (userdata: ?*anyopaque, stream: [*]u8, len: c_int) callconv(std.builtin.CallingConvention.c) void;

/// Audio specification for opening a device.
pub const AudioSpec = struct {
    freq: c_int = 0,
    channels: u8 = 2,
    samples: u16 = 0,
    callback: ?AudioCallback = null,
    userdata: ?*anyopaque = null,
};

const std = @import("std");

/// Returns the Platform implementation for the given backend.
/// Accepts any enum with matching tag names (e.g. from build_options).
pub fn getPlatform(comptime backend: anytype) type {
    const tag = @tagName(backend);
    const resolved: Backend = @field(Backend, tag);
    return switch (resolved) {
        .sdl2 => @import("backends/sdl2.zig"),
    };
}

pub const Backend = enum {
    sdl2,
};
