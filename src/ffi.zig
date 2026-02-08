pub const swr = @cImport({
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libswresample/swresample.h");
});
