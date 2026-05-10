const std = @import("std");

fn getVersionString(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    const command = [_][]const u8{ "git", "describe", "--tags", "--always" };
    const result = std.process.run(allocator, b.graph.io, .{
        .argv = &command,
    }) catch |err| {
        std.log.warn("Failed to get git version: {s}", .{@errorName(err)});
        return "unknown";
    };
    switch (result.term) {
        .exited => |code| if (code != 0) return "unknown",
        else => return "unknown",
    }
    const version = std.mem.trimEnd(u8, result.stdout, "\r\n");
    return allocator.dupe(u8, version);
}

fn replaceAllOwned(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (true) {
        const idx_opt = std.mem.findPos(u8, haystack, i, needle);
        if (idx_opt) |idx| {
            try out.appendSlice(allocator, haystack[i..idx]);
            try out.appendSlice(allocator, replacement);
            i = idx + needle.len;
        } else {
            try out.appendSlice(allocator, haystack[i..]);
            break;
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const version = getVersionString(b) catch "unknown";
    options.addOption([]const u8, "version", version);
    const strip: bool = if (optimize == std.builtin.OptimizeMode.ReleaseFast) true else false;

    // simpleimgio
    const simpleimgio = b.dependency("simpleimgio", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("fssimu2", .{
        .root_source_file = b.path("src/ssimulacra2.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libspng
    const spng = b.addLibrary(.{
        .name = "spng",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const spng_sources = [_][]const u8{
        "third-party/libspng/spng.c",
        "third-party/libminiz/miniz.c",
    };
    spng.root_module.linkSystemLibrary("c", .{});
    spng.root_module.linkSystemLibrary("m", .{});
    spng.root_module.addCSourceFiles(.{ .files = &spng_sources });
    spng.root_module.addIncludePath(b.path("third-party/"));

    const c_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = target,
        .optimize = optimize,
    });
    c_headers.addIncludePath(b.path("."));
    c_headers.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    c_headers.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
    const c_module = c_headers.createModule();

    // fssimu2 binary
    const bin = b.addExecutable(.{
        .name = "fssimu2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    bin.root_module.addImport("c", c_module);
    bin.root_module.addImport("simpleimgio", simpleimgio.module("simpleimgio"));
    bin.root_module.addOptions("build_opts", options);
    bin.root_module.addIncludePath(b.path("."));
    bin.root_module.linkSystemLibrary("c", .{});
    bin.root_module.linkLibrary(spng);

    // system decoder libs
    bin.root_module.linkSystemLibrary("jpeg", .{});
    bin.root_module.linkSystemLibrary("webp", .{});
    bin.root_module.linkSystemLibrary("avif", .{});

    b.installArtifact(bin);

    // ssimu2 lib
    const lib = b.addLibrary(.{
        .name = "ssimu2",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_abi.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    lib.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(lib);

    b.installFile("src/include/ssimu2.h", "include/ssimu2.h");

    // pkg-config
    const pc_contents =
        \\prefix=@prefix@
        \\exec_prefix=${prefix}
        \\libdir=@libdir@
        \\includedir=@includedir@
        \\
        \\Name: ssimu2
        \\Description: Fast SSIMULACRA2 implementation
        \\Version: @version@
        \\URL: https://github.com/gianni-rosato/fssimu2
        \\License: Apache-2.0
        \\
        \\Cflags: -I${includedir}
        \\Libs: -L${libdir} -lssimu2
        \\
        \\Requires:
        \\
    ;

    const prefix = b.install_prefix;
    const libdir = b.fmt("{s}/lib", .{prefix});
    const includedir = b.fmt("{s}/include", .{prefix});

    const pc_1 = replaceAllOwned(b.allocator, pc_contents, "@prefix@", prefix) catch pc_contents;
    const pc_2 = replaceAllOwned(b.allocator, pc_1, "@libdir@", libdir) catch pc_1;
    const pc_3 = replaceAllOwned(b.allocator, pc_2, "@includedir@", includedir) catch pc_2;
    const pc_out = replaceAllOwned(b.allocator, pc_3, "@version@", version) catch pc_3;

    const write_pc = std.Build.Step.WriteFile.create(b);
    _ = std.Build.Step.WriteFile.add(write_pc, "ssimu2.pc", pc_out);

    b.installDirectory(.{
        .source_dir = write_pc.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "lib/pkgconfig",
    });
}
