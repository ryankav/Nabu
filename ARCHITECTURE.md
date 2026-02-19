# Architecture

Nabu follows a classic multi-threaded media player design. A read thread demuxes the input file into compressed packets, per-stream decoder threads decode those packets into raw frames, and the main thread (video) and an SDL callback (audio) consume the decoded frames for presentation.

## Threading model

```
Main Thread              SDL event loop, video frame display
Read Thread              Demuxes file, routes packets to queues
Video Decoder Thread     Decodes video packets into frames
Audio Decoder Thread     Decodes audio packets into frames
SDL Audio Thread         Pulls decoded audio for playback (callback)
```

## Data flow

```
Media File
    |
    v
FormatContext (demuxer)        [Read Thread]
    |               |
    v               v
VideoPacketQueue   AudioPacketQueue        (thread-safe FIFOs)
    |               |
    v               v
Video Decoder      Audio Decoder           [Decoder Threads]
    |               |
    v               v
VideoFrameQueue    AudioFrameQueue         (pre-allocated ring buffers)
    |               |
    v               v
SDL Texture        SDL Audio Device        [Main Thread / SDL Audio Thread]
```

## Source files

| File | Purpose |
|------|---------|
| `src/main.zig` | Entry point, window/renderer setup via platform layer, event loop |
| `src/video_state.zig` | Top-level state container, read thread, seek handling |
| `src/platform.zig` | Platform abstraction layer: defines backend-agnostic types and interface |
| `src/backends/sdl2.zig` | SDL2 backend: window, renderer, audio, events, timing |
| `src/sync_queue.zig` | Generic lock-free ring buffer (`BoundedSyncQueue(T, capacity)`) used by both queue types |
| `src/packet_queue.zig` | Thread-safe FIFO for compressed packets; wraps `BoundedSyncQueue` with mutex, cond, and metadata |
| `src/frame_queue.zig` | Pre-allocated ring buffer for decoded frames; wraps `BoundedSyncQueue` with blocking peek API |
| `src/decoder.zig` | Per-stream decode thread (packets to frames) |
| `src/clock.zig` | PTS tracking with drift compensation for A/V sync |
| `src/audio.zig` | Audio device management and sample resampling |
| `src/video.zig` | Frame timing, A/V sync, pixel format conversion, display |
| `src/ffi.zig` | C FFI bindings (libswresample) |

## A/V synchronization

Audio is the master clock. The video display thread computes the delay between consecutive video frames and adjusts it based on the difference between the video PTS and the audio clock:

- **Video behind audio**: delay is reduced to catch up.
- **Video ahead of audio**: delay is increased.
- **Large desync (>10s)**: no correction is applied (assumes a seek or discontinuity).

Serial numbers on packets and frames track discontinuities across seeks, preventing stale data from affecting sync.

## Key design decisions

- **Shared ring buffer core** (`BoundedSyncQueue`): both `PacketQueue` and `FrameQueue` delegate their `buf`/`rindex`/`windex`/`count` mechanics to the same generic type in `sync_queue.zig`. The capacity must be a power of two so wrap-around is a single bitwise AND; indices grow monotonically and are never reset, which cleanly separates the full-vs-empty states. `BoundedSyncQueue` itself holds no mutex — synchronisation lives in the outer queue types.
- **Two queue APIs over one backing type**: `PacketQueue` uses the value-based `putLocked`/`getLocked` API (ownership transfer); `FrameQueue` uses the pointer-based `peekWriteLocked`/`advanceWriteLocked`/`peekReadLocked`/`peekReadAtLocked`/`advanceReadLocked` API (in-place frame filling without copying).
- **Comptime capacity and generics**: both `PacketQueue(N)` and `FrameQueue` encode their capacity as a comptime parameter. The power-of-two assertion fires at compile time. `video_state.zig` instantiates `PacketQueue(256)` and `FrameQueue` (fixed at 16 slots) by value — no heap allocation for the queues themselves.
- **Comptime-typed error sets on `get`**: `PacketQueue.get` takes `comptime block: bool`. When `block = true` the return type is `error{Aborted}!…`; when `block = false` it is `error{Aborted, WouldBlock}!…`. A caller that passes a comptime-known value gets an error set that only contains reachable errors, so the compiler rejects dead match arms and missing arms alike.
- **Atomic `abort_request`** on both queue types: `PacketQueue.abort_request` and `FrameQueue.abort_request` are both `std.atomic.Value(bool)`. Reads use `.load(.acquire)` and writes use `.store(value, .release)`, consistent across the codebase and enabling future lock-free fast-path checks before acquiring the mutex.
- **Frame queues are pre-allocated** (16 slots each) to avoid heap allocation during playback.
- **Two-phase initialization** for `VideoState`: `init()` opens the file and codecs, then `open()` wires up internal pointers once the struct is at its final memory location.
- **Platform abstraction layer** (`platform.zig` + `backends/`) decouples the player from SDL2. The backend is selected at comptime via build options, so all calls are direct with zero function-pointer overhead. Currently only SDL2 is implemented.
- **System SDL2** is used (via Nix) rather than the Zig package, to avoid linker issues with system shared libraries. FFmpeg is pulled from the allyourcodebase Zig package.
