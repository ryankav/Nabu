/// SDL2 backend implementation for the Platform interface.
const std = @import("std");
const platform = @import("../platform.zig");

pub const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});

// ── Init / Deinit ──────────────────────────────────────────────────

pub fn init() !void {
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_TIMER) < 0) {
        return error.SDLInitFailed;
    }
}

pub fn deinit() void {
    sdl.SDL_Quit();
}

pub fn getError() [*:0]const u8 {
    return sdl.SDL_GetError();
}

// ── Window ─────────────────────────────────────────────────────────

pub fn createWindow(title: [*:0]const u8, w: c_int, h: c_int) !platform.Window {
    return @ptrCast(sdl.SDL_CreateWindow(
        title,
        sdl.SDL_WINDOWPOS_UNDEFINED,
        sdl.SDL_WINDOWPOS_UNDEFINED,
        w,
        h,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse return error.WindowCreateFailed);
}

pub fn destroyWindow(window: platform.Window) void {
    sdl.SDL_DestroyWindow(@ptrCast(@alignCast(window)));
}

// ── Renderer ───────────────────────────────────────────────────────

pub fn createRenderer(window: platform.Window) !platform.Renderer {
    return @ptrCast(sdl.SDL_CreateRenderer(
        @ptrCast(@alignCast(window)),
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse return error.RendererCreateFailed);
}

pub fn destroyRenderer(renderer: platform.Renderer) void {
    sdl.SDL_DestroyRenderer(@ptrCast(@alignCast(renderer)));
}

// ── Texture ────────────────────────────────────────────────────────

pub fn createTexture(renderer: platform.Renderer, w: c_int, h: c_int) !platform.Texture {
    return @ptrCast(sdl.SDL_CreateTexture(
        @ptrCast(@alignCast(renderer)),
        sdl.SDL_PIXELFORMAT_IYUV,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        w,
        h,
    ) orelse return error.TextureCreateFailed);
}

pub fn destroyTexture(texture: platform.Texture) void {
    sdl.SDL_DestroyTexture(@ptrCast(@alignCast(texture)));
}

// ── Rendering ──────────────────────────────────────────────────────

pub fn renderClear(renderer: platform.Renderer) void {
    _ = sdl.SDL_RenderClear(@ptrCast(@alignCast(renderer)));
}

pub fn renderCopy(renderer: platform.Renderer, texture: platform.Texture) void {
    _ = sdl.SDL_RenderCopy(@ptrCast(@alignCast(renderer)), @ptrCast(@alignCast(texture)), null, null);
}

pub fn renderPresent(renderer: platform.Renderer) void {
    sdl.SDL_RenderPresent(@ptrCast(@alignCast(renderer)));
}

// ── Texture upload ─────────────────────────────────────────────────

pub fn updateYUVTexture(
    texture: platform.Texture,
    y_data: [*]const u8,
    y_pitch: c_int,
    u_data: [*]const u8,
    u_pitch: c_int,
    v_data: [*]const u8,
    v_pitch: c_int,
) void {
    _ = sdl.SDL_UpdateYUVTexture(
        @ptrCast(@alignCast(texture)),
        null,
        y_data,
        y_pitch,
        u_data,
        u_pitch,
        v_data,
        v_pitch,
    );
}

pub const LockResult = struct {
    pixels: [*]u8,
    pitch: c_int,
};

pub fn lockTexture(texture: platform.Texture) ?LockResult {
    var pixels: ?*anyopaque = null;
    var pitch: c_int = 0;
    if (sdl.SDL_LockTexture(@ptrCast(@alignCast(texture)), null, &pixels, &pitch) == 0) {
        return .{
            .pixels = @ptrCast(pixels.?),
            .pitch = pitch,
        };
    }
    return null;
}

pub fn unlockTexture(texture: platform.Texture) void {
    sdl.SDL_UnlockTexture(@ptrCast(@alignCast(texture)));
}

// ── Audio ──────────────────────────────────────────────────────────

pub fn openAudioDevice(desired: *const platform.AudioSpec, obtained: *platform.AudioSpec) !platform.AudioDevice {
    var sdl_wanted: sdl.SDL_AudioSpec = .{
        .freq = desired.freq,
        .format = sdl.AUDIO_S16SYS,
        .channels = desired.channels,
        .silence = 0,
        .samples = desired.samples,
        .padding = 0,
        .size = 0,
        .callback = @ptrCast(desired.callback),
        .userdata = desired.userdata,
    };
    var sdl_obtained: sdl.SDL_AudioSpec = undefined;
    const dev = sdl.SDL_OpenAudioDevice(null, 0, &sdl_wanted, &sdl_obtained, 0);
    if (dev == 0) {
        return error.AudioDeviceFailed;
    }
    obtained.freq = sdl_obtained.freq;
    obtained.channels = @intCast(sdl_obtained.channels);
    obtained.samples = sdl_obtained.samples;
    return dev;
}

pub fn closeAudioDevice(dev: platform.AudioDevice) void {
    sdl.SDL_CloseAudioDevice(dev);
}

pub fn pauseAudioDevice(dev: platform.AudioDevice, pause: bool) void {
    sdl.SDL_PauseAudioDevice(dev, if (pause) 1 else 0);
}

// ── Events ─────────────────────────────────────────────────────────

pub fn pollEvent(out: *platform.Event) bool {
    var ev: sdl.SDL_Event = undefined;
    if (sdl.SDL_PollEvent(&ev) == 0) {
        out.* = .none;
        return false;
    }
    switch (ev.type) {
        sdl.SDL_QUIT => {
            out.* = .quit;
        },
        sdl.SDL_KEYDOWN => {
            const key = ev.key.keysym.sym;
            out.* = .{ .key_down = translateKey(key) };
        },
        else => {
            out.* = .none;
        },
    }
    return true;
}

fn translateKey(sym: i32) platform.Key {
    return switch (sym) {
        sdl.SDLK_q => .q,
        sdl.SDLK_ESCAPE => .escape,
        sdl.SDLK_SPACE => .space,
        sdl.SDLK_LEFT => .left,
        sdl.SDLK_RIGHT => .right,
        else => .unknown,
    };
}

// ── Timing ─────────────────────────────────────────────────────────

pub fn getTime() f64 {
    const counter = sdl.SDL_GetPerformanceCounter();
    const freq = sdl.SDL_GetPerformanceFrequency();
    return @as(f64, @floatFromInt(counter)) / @as(f64, @floatFromInt(freq));
}

pub fn delay(ms: u32) void {
    sdl.SDL_Delay(ms);
}
