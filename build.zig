const std = @import("std");

const Backend = enum {
    sdl2,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(Backend, "backend", "Platform backend (default: sdl2)") orelse .sdl2;

    const ffmpeg_dep = b.dependency("ffmpeg", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "nabu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "av", .module = ffmpeg_dep.module("av") },
            },
        }),
    });

    exe.root_module.addOptions("build_options", blk: {
        const options = b.addOptions();
        options.addOption(Backend, "backend", backend);
        break :blk options;
    });

    exe.root_module.linkLibrary(ffmpeg_dep.artifact("ffmpeg"));

    // Link platform-specific libraries
    switch (backend) {
        .sdl2 => {
            exe.root_module.linkSystemLibrary("SDL2", .{});
        },
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Nabu media player");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (no C deps)");
    test_step.dependOn(&run_unit_tests.step);
}
