const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libspng
    const spng = b.addStaticLibrary(.{
        .name = "spng",
        .target = target,
        .optimize = optimize,
    });
    const spng_sources = [_][]const u8{
        "third-party/libspng/spng.c",
        "third-party/libminiz/miniz.c",
    };
    spng.linkLibC();
    spng.linkSystemLibrary("m");
    spng.addCSourceFiles(.{ .files = &spng_sources });
    spng.addIncludePath(b.path("third-party/"));

    // Executable: ssimu2
    const exe = b.addExecutable(.{
        .name = "ssimu2",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addIncludePath(b.path("."));
    exe.linkLibC();
    exe.linkLibrary(spng);

    // Install step
    b.installArtifact(exe);

    // `zig build run -- <args>` convenience
    // const run_cmd = b.addRunArtifact(exe);
    // if (b.args) |args| run_cmd.addArgs(args);
    // const run_step = b.step("run", "Run the ssimu2 tool");
    // run_step.dependOn(&run_cmd.step);

    // // Unit tests (none yet; placeholder for future)
    // const unit_tests = b.addTest(.{
    //     .root_source_file = .{ .path = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const test_run = b.addRunArtifact(unit_tests);
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&test_run.step);
}
