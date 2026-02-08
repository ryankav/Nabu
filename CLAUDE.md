# Nabu - Claude Code Guidelines

## Session Continuity

At the **start of every conversation**, check if `PLAN.md` exists. If it does, read it in full and resume from where it left off — do not ask the user to re-explain the task.

When working on a multi-step task, maintain `PLAN.md` in the project root as a living document:

### 1. Initial Plan (written before any code changes)

- **Goal**: One-sentence summary of what we're building/fixing and why.
- **User requirements & preferences**: Anything the user specified about approach, style, constraints, or things to avoid. Quote them where helpful.
- **Steps**: Numbered checklist with markdown checkboxes (`- [ ]` / `- [x]`). Each step should be specific enough that reading it cold tells you exactly what to do (which files to touch, what to add/change, what the expected outcome is).
- **Architectural decisions**: Why we chose this approach over alternatives, and any trade-offs acknowledged.

### 2. Progress Tracking (updated as you work)

Keep a `## Current Step` section that contains:

- **Step number and description** from the checklist.
- **Files modified so far** in this step, with a brief note on what changed in each.
- **What you tried**: Approaches attempted, in order, with outcomes.
- **Errors & debug output**: Verbatim compiler errors, runtime logs, or test failures in fenced code blocks. Include the full error, not a summary.
- **Key code context**: Short snippets of the relevant code you're working with (with file path and line numbers), so you don't need to re-read files to pick up context.
- **Root cause analysis**: What you believe is going wrong and why.
- **Next action**: The specific thing you were about to do. This is critical for resumability — it should be concrete enough to execute immediately (e.g., "change the return type of `foo()` in `src/bar.zig:42` from `?*Frame` to `!*Frame`").

### 3. Step Completion

When a step is done:
- Check off the step in the checklist.
- Remove the debug logs, error output, and scratch notes from `## Current Step`.
- Keep a one-line summary of what was done and any gotchas discovered (these help with later steps).
- Update `## Current Step` to point to the next unchecked step.

### 4. Task Completion

When all steps are checked off and the task is verified working, delete `PLAN.md`.

## Build & Test

- Build: `nix develop -c zig build`
- Run: `nix develop -c zig build run -- test_video.mp4`
- Zig version: 0.16 (dev), via nix zig-overlay

## Project Structure

- `src/main.zig` - Entry point
- `src/video_state.zig` - Top-level state management
- `src/packet_queue.zig` - Packet queue
- `src/frame_queue.zig` - Frame queue
- `src/decoder.zig` - Decoder
- `src/clock.zig` - Clock/sync
- `src/audio.zig` - Audio output
- `src/video.zig` - Video display
- `src/ffi.zig` - FFmpeg/SDL C bindings
