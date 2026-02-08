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
| `src/packet_queue.zig` | Thread-safe FIFO for compressed packets |
| `src/frame_queue.zig` | Pre-allocated ring buffer for decoded frames |
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

- **Frame queues are pre-allocated** (16 slots each) to avoid heap allocation during playback.
- **Two-phase initialization** for `VideoState`: `init()` opens the file and codecs, then `open()` wires up internal pointers once the struct is at its final memory location.
- **Platform abstraction layer** (`platform.zig` + `backends/`) decouples the player from SDL2. The backend is selected at comptime via build options, so all calls are direct with zero function-pointer overhead. Currently only SDL2 is implemented.
- **System SDL2** is used (via Nix) rather than the Zig package, to avoid linker issues with system shared libraries. FFmpeg is pulled from the allyourcodebase Zig package.
