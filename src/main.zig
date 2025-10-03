const std = @import("std");
const ssim = @import("ssimulacra2.zig");
const io = @import("io.zig");
const print = std.debug.print;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("jpeglib.h");
    @cInclude("webp/decode.h");
    @cInclude("avif/avif.h");
});

const VERSION = @import("build_opts").version;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (args_iter.next()) |a| try args.append(allocator, a);

    var json_output = false;
    var error_map_path: ?[]const u8 = null;
    var positional: [2]?[]const u8 = .{ null, null };
    var pos_index: usize = 0;

    var show_help = false;
    var show_version = false;

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--err-map")) {
            i += 1;
            if (i >= args.items.len) {
                return usageExtra("--err-map requires a path argument");
            }
            error_map_path = args.items[i];
        } else {
            if (pos_index >= 2)
                return usageExtra("Too many positional arguments provided.");
            positional[pos_index] = arg;
            pos_index += 1;
        }
    }

    if (show_help) return usage();
    if (show_version) return printVersion();

    if (pos_index != 2)
        return usageExtra("Two image paths required: reference distorted");

    const ref_path = positional[0].?;
    const dist_path = positional[1].?;

    var ref_image = try io.loadImage(allocator, ref_path);
    defer ref_image.deinit(allocator);

    var dist_image = try io.loadImage(allocator, dist_path);
    defer dist_image.deinit(allocator);

    // Enforce matching original dimensions
    if (ref_image.width != dist_image.width or ref_image.height != dist_image.height)
        return fail("Input images must have identical dimensions (got {d}x{d} vs {d}x{d})", .{ ref_image.width, ref_image.height, dist_image.width, dist_image.height }, 2);

    // Convert both to 3-channel RGB ignoring alpha (if present)
    const ref_has_alpha: bool = ref_image.channels != 3;
    const ref_rgb: []u8 = if (ref_has_alpha) try io.toRGB8(allocator, ref_image) else ref_image.data;
    defer if (ref_has_alpha) allocator.free(ref_rgb);

    const dst_has_alpha: bool = dist_image.channels != 3;
    const dist_rgb: []u8 = if (dst_has_alpha) try io.toRGB8(allocator, dist_image) else dist_image.data;
    defer if (dst_has_alpha) allocator.free(dist_rgb);

    // Allocate error map buffer if requested
    var error_map_buffer: ?[]u32 = null;
    defer if (error_map_buffer) |buf| allocator.free(buf);

    if (error_map_path != null) {
        const pixel_count = @as(usize, @intCast(ref_image.width)) * @as(usize, @intCast(ref_image.height));
        error_map_buffer = try allocator.alloc(u32, pixel_count);
    }

    const score = ssim.computeSsimu2(
        allocator,
        ref_rgb,
        dist_rgb,
        @intCast(ref_image.width),
        @intCast(ref_image.height),
        3,
        error_map_buffer,
    ) catch |e| {
        switch (e) {
            ssim.Ssimu2Error.InvalidChannelCount => {
                return fail("Invalid channel count encountered.", .{}, 3);
            },
            ssim.Ssimu2Error.OutOfMemory => {
                return fail("Out of memory allocating working buffers.", .{}, 3);
            },
        }
    };

    // Save error map if requested
    if (error_map_path) |path| {
        if (error_map_buffer) |buf| {
            try io.saveErrorMap(allocator, path, buf, @intCast(ref_image.width), @intCast(ref_image.height));
            if (!json_output) {
                print("Error map saved to: {s}\n", .{path});
            }
        }
    }

    if (json_output) {
        print(
            "{{\"metric\":\"SSIMULACRA2\",\"score\":{d:.8}}}\n",
            .{score},
        );
    } else print("{d:.8}\n", .{score});
    return;
}

fn usage() void {
    print("\x1b[34mfssimu2\x1b[0m | {s}\n\n", .{VERSION});
    print(
        \\usage:
        \\  fssimu2 [options] <reference> <distorted>
        \\
        \\options:
        \\  --json               output result as json
        \\  --err-map <out>      save error map to .png/.tga
        \\  -h, --help           show this help
        \\  -v, --version        show version information
    , .{});
    print("\n\n\x1b[37msRGB PNG, PAM, JPEG, WebP, or AVIF input expected\x1b[0m\n", .{});
}

fn printVersion() void {
    const jpeg_version = c.LIBJPEG_TURBO_VERSION_NUMBER;
    const jpeg_major: comptime_int = jpeg_version / 1_000_000;
    const jpeg_minor: comptime_int = (jpeg_version / 1_000) % 1_000;
    const jpeg_patch: comptime_int = jpeg_version % 1_000;
    const jpeg_simd: bool = c.WITH_SIMD != 0;

    const webp_version = c.WebPGetDecoderVersion();
    const webp_major = webp_version >> 16;
    const webp_minor = (webp_version >> 8) & 0xFF;
    const webp_patch = webp_version & 0xFF;

    const avif_major: comptime_int = c.AVIF_VERSION_MAJOR;
    const avif_minor: comptime_int = c.AVIF_VERSION_MINOR;
    const avif_patch: comptime_int = c.AVIF_VERSION_PATCH;
    print("fssimu2 {s}\n", .{VERSION});
    print("libjpeg-turbo {d}.{d}.{d} ", .{ jpeg_major, jpeg_minor, jpeg_patch });
    print("[simd: {}]\n", .{jpeg_simd});
    print("libwebp {d}.{d}.{d}\n", .{ webp_major, webp_minor, webp_patch });
    print("libavif {d}.{d}.{d}\n", .{ avif_major, avif_minor, avif_patch });
}

fn usageExtra(msg: []const u8) void {
    print("Error: {s}\n\n", .{msg});
    usage();
}

fn fail(comptime fmt: []const u8, args: anytype, code: u8) void {
    print("Error: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}
