# TODO

FFplay features not yet supported by Nabu.

## Playback controls

- [ ] Volume control (keyboard `9`/`0` or `/`/`*`, `-volume` flag)
- [ ] Mute toggle (`m`)
- [ ] Frame stepping (`s` to step one frame while paused)
- [ ] Auto-exit on playback finish (`-autoexit`)
- [ ] Loop/repeat (`-loop N`, 0 for infinite)
- [ ] Start position (`-ss pos`)
- [ ] Duration limit (`-t duration`)

## Seeking & navigation

- [ ] 1-minute seek with Up/Down arrows
- [ ] Chapter / 10-minute seek with Page Up/Down
- [ ] Mouse seek (right-click to jump to position)
- [ ] Byte-based seeking (`-bytes`)
- [ ] Configurable seek interval (`-seek_interval`)

## Stream selection

- [ ] Manual audio stream selection (`-ast`)
- [ ] Manual video stream selection (`-vst`)
- [ ] Manual subtitle stream selection (`-sst`)
- [ ] Cycle audio tracks at runtime (`a`)
- [ ] Cycle video tracks at runtime (`v`)
- [ ] Disable audio (`-an`) or video (`-vn`)

## Subtitles

- [ ] Subtitle decoding and rendering
- [ ] Subtitle stream selection and cycling (`t`)
- [ ] External subtitle file support

## Display

- [ ] Fullscreen mode (`-fs`, toggle with `f` or double-click)
- [ ] Custom window size (`-x`, `-y`)
- [ ] Custom window position (`-left`, `-top`)
- [ ] Borderless window (`-noborder`)
- [ ] Always on top (`-alwaysontop`)
- [ ] Audio-only mode / no display (`-nodisp`)
- [ ] Audio waveform visualisation (cycle with `w`)
- [ ] RDFT spectral display (cycle with `w`)
- [ ] Auto-rotation from metadata (`-autorotate`)

## Filters

- [ ] Video filter graphs (`-vf`)
- [ ] Audio filter graphs (`-af`)

## Synchronization

- [ ] Selectable sync master (`-sync audio|video|ext`)
- [ ] Frame dropping control (`-framedrop` / `-noframedrop`)

## Codec & format options

- [ ] Force input format (`-f fmt`)
- [ ] Force audio codec (`-acodec`)
- [ ] Force video codec (`-vcodec`)
- [ ] Hardware acceleration (`-hwaccel`)

## Diagnostics

- [ ] On-screen statistics (`-stats`)
- [ ] Configurable log level (`-loglevel`)

## Network streaming

- [ ] HTTP/HTTPS, RTSP, HLS, RTMP playback
- [ ] Infinite input buffering (`-infbuf`)
