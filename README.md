# Nabu

A simple FFplay clone written in Zig, using FFmpeg for demuxing/decoding and SDL2 for display and audio output. This project is based on FFplay and serves as an experiment in seeing what can be achieved by collaborating with Claude.

## Usage

```bash
zig build run -- <media_file>
```

For example:

```bash
zig build run -- video.mp4
```

### Controls

| Key | Action |
|-----|--------|
| `q` / `ESC` | Quit |
| `Space` | Pause / resume |
| `Left arrow` | Seek backwards 10 seconds |
| `Right arrow` | Seek forwards 10 seconds |

## Building

### Prerequisites

The project requires Zig 0.16 (dev), FFmpeg libraries, and SDL2. A Nix flake is provided to set up the full environment, primarily to pin a specific Zig nightly version and provide the required system libraries (SDL2, X11, audio drivers, etc.) without manual installation. This is something I want to look into more to see if there's a better approach.

1. Install Nix with flakes enabled: https://nixos.org/download
2. Install direnv (optional but recommended): https://direnv.net/

### Getting Started

**With direnv (recommended):**
```bash
direnv allow
```
The toolchain will automatically activate when you enter the directory.

**Without direnv:**
```bash
nix develop
```

Then build and run:
```bash
zig build            # build only
zig build run -- file.mp4   # build and run
zig build test       # run tests
```

The compiled binary is placed at `zig-out/bin/nabu`.

### Updating Zig

To update to the latest nightly Zig build:
```bash
nix flake update
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for details on the threading model, data flow, module responsibilities, and design decisions.

## License

Nabu is licensed under the [MIT License](LICENSE).

This software uses libraries from the [FFmpeg](https://ffmpeg.org/) project, licensed under the [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). FFmpeg source code is available at https://ffmpeg.org/download.html.

This software uses [SDL2](https://www.libsdl.org/), licensed under the [zlib license](https://www.libsdl.org/license.php).
