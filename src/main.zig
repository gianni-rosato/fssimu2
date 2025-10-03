const std = @import("std");
const io = @import("io.zig");
const linearlight = @import("linearlight.zig");
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
            if (i >= args.items.len)
                return usageExtra("--err-map requires a path argument");
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

    if (ref_image.width != dist_image.width or ref_image.height != dist_image.height)
        return fail("Input images must have identical dimensions (got {d}x{d} vs {d}x{d})", .{ ref_image.width, ref_image.height, dist_image.width, dist_image.height }, 2);

    const ref_has_alpha: bool = ref_image.channels != 3;
    const ref_rgb: []u8 = if (ref_has_alpha) try io.toRGB8(allocator, ref_image) else ref_image.data;
    defer if (ref_has_alpha) allocator.free(ref_rgb);

    const dst_has_alpha: bool = dist_image.channels != 3;
    const dist_rgb: []u8 = if (dst_has_alpha) try io.toRGB8(allocator, dist_image) else dist_image.data;
    defer if (dst_has_alpha) allocator.free(dist_rgb);

    var error_map_buffer: ?[]f32 = null;
    defer if (error_map_buffer) |buf| allocator.free(buf);

    if (error_map_path != null) {
        const pixel_count = @as(usize, @intCast(ref_image.width)) * @as(usize, @intCast(ref_image.height));
        error_map_buffer = try allocator.alloc(f32, pixel_count);
    }

    const ref_xyb = try rgbToXyb(allocator, ref_rgb, @intCast(ref_image.width), @intCast(ref_image.height));
    defer allocator.free(ref_xyb);
    const dist_xyb = try rgbToXyb(allocator, dist_rgb, @intCast(ref_image.width), @intCast(ref_image.height));
    defer allocator.free(dist_xyb);

    const result_x = calculateMSEAndPSNR(ref_xyb, dist_xyb, @intCast(ref_image.width), @intCast(ref_image.height), 0);
    const result_y = calculateMSEAndPSNR(ref_xyb, dist_xyb, @intCast(ref_image.width), @intCast(ref_image.height), 1);
    const result_b = calculateMSEAndPSNR(ref_xyb, dist_xyb, @intCast(ref_image.width), @intCast(ref_image.height), 2);

    const psnr_x = result_x.psnr;
    const psnr_y = result_y.psnr;
    const psnr_b = result_b.psnr;

    const w_avg_mse = (result_x.mse + (result_y.mse * 4) + result_b.mse) / 6.0;
    const w_avg_psnr = if (w_avg_mse == 0.0) 100.0 else blk: {
        const max_value: f64 = @max(@max(result_x.max_val, result_y.max_val), result_b.max_val);
        break :blk 10.0 * @log10((max_value * max_value) / w_avg_mse);
    };

    if (error_map_buffer) |buffer|
        generateErrorMap(ref_xyb, dist_xyb, buffer, @intCast(ref_image.width), @intCast(ref_image.height));

    if (error_map_path) |path|
        if (error_map_buffer) |buf| {
            try io.saveErrorMap(allocator, path, buf, @intCast(ref_image.width), @intCast(ref_image.height));
            if (!json_output) {
                print("Error map saved to: {s}\n", .{path});
            }
        };

    if (json_output) {
        print(
            "{{\"metric\":\"PSNR\",\"x\":{d:.8},\"y\":{d:.8},\"b\":{d:.8},\"w_avg\":{d:.8}}}\n",
            .{ psnr_x, psnr_y, psnr_b, w_avg_psnr },
        );
    } else print("X: {d:.8}\nY: {d:.8}\nB: {d:.8}\nWeighted Average: {d:.8}\n", .{ psnr_x, psnr_y, psnr_b, w_avg_psnr });
}

fn usage() void {
    print("\x1b[34mpsnr_diff\x1b[0m | {s}\n\n", .{VERSION});
    print(
        \\usage:
        \\  psnr_diff [options] <reference> <distorted>
        \\
        \\options:
        \\  --json               output result as json
        \\  --err-map <out>      save error map to .png/.tga
        \\  -h, --help           show this help
        \\  -v, --version        show version information
        \\
        \\Computes PSNR for X, Y, and B channels (XYB color space) and generates a per-pixel error map.
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
    print("psnr_diff {s}\n", .{VERSION});
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

fn rgbToXyb(allocator: std.mem.Allocator, rgb: []const u8, width: u32, height: u32) ![]f32 {
    const pixel_count = @as(usize, width) * @as(usize, height);

    // Allocate planar buffers for linear RGB
    const linear_r = try allocator.alloc(f32, pixel_count);
    defer allocator.free(linear_r);
    const linear_g = try allocator.alloc(f32, pixel_count);
    defer allocator.free(linear_g);
    const linear_b = try allocator.alloc(f32, pixel_count);
    defer allocator.free(linear_b);

    // Convert sRGB to linear light using LUT
    const planes = [3][]f32{ linear_r, linear_g, linear_b };
    linearlight.sRGBInterleavedToPlanarLinear(rgb, planes, width, height, 3);

    // Allocate output XYB buffer
    const xyb = try allocator.alloc(f32, pixel_count * 3);

    const K_M02 = 0.078;
    const K_M00 = 0.30;
    const K_M01 = 1.0 - K_M02 - K_M00;
    const K_M12 = 0.078;
    const K_M10 = 0.23;
    const K_M11 = 1.0 - K_M12 - K_M10;
    const K_M20 = 0.24342269;
    const K_M21 = 0.20476745;
    const K_M22 = 1.0 - K_M20 - K_M21;

    const K_D0: f32 = 0.0037930734;
    const K_D1: f32 = std.math.lossyCast(f32, std.math.cbrt(@as(f32, K_D0)));

    // Apply XYB transformation on linear RGB
    for (0..pixel_count) |i| {
        const r = linear_r[i];
        const g = linear_g[i];
        const b = linear_b[i];

        var mixed0 = @mulAdd(f32, K_M00, r, @mulAdd(f32, K_M01, g, @mulAdd(f32, K_M02, b, K_D0)));
        var mixed1 = @mulAdd(f32, K_M10, r, @mulAdd(f32, K_M11, g, @mulAdd(f32, K_M12, b, K_D0)));
        var mixed2 = @mulAdd(f32, K_M20, r, @mulAdd(f32, K_M21, g, @mulAdd(f32, K_M22, b, K_D0)));

        if (mixed0 < 0.0) mixed0 = 0.0;
        if (mixed1 < 0.0) mixed1 = 0.0;
        if (mixed2 < 0.0) mixed2 = 0.0;

        mixed0 = std.math.lossyCast(f32, std.math.cbrt(@as(f32, mixed0))) + K_D1;
        mixed1 = std.math.lossyCast(f32, std.math.cbrt(@as(f32, mixed1))) + K_D1;
        mixed2 = std.math.lossyCast(f32, std.math.cbrt(@as(f32, mixed2))) + K_D1;

        var x = 0.5 * (mixed0 - mixed1);
        var y = 0.5 * (mixed0 + mixed1);
        var z = mixed2;

        z = (z - y) + 0.55;
        x = x * 14.0 + 0.42;
        y = y + 0.01;

        xyb[i * 3 + 0] = x;
        xyb[i * 3 + 1] = y;
        xyb[i * 3 + 2] = z;
    }

    return xyb;
}

const PSNRResult = struct {
    mse: f64,
    psnr: f64,
    max_val: f64,
};

// Calculate MSE and PSNR for a specific channel
fn calculateMSEAndPSNR(ref: []const f32, dist: []const f32, width: u32, height: u32, channel: usize) PSNRResult {
    const pixel_count = @as(usize, width) * @as(usize, height);
    var mse: f64 = 0.0;

    for (0..pixel_count) |i| {
        const diff = @as(f64, ref[i * 3 + channel]) - @as(f64, dist[i * 3 + channel]);
        mse += diff * diff;
    }

    mse /= @as(f64, @floatFromInt(pixel_count));

    // XYB values have different ranges, but we'll use a normalized approach
    // Find max value for this channel to determine range
    var max_val: f32 = 0.0;
    for (0..pixel_count) |i| {
        const val = @max(@abs(ref[i * 3 + channel]), @abs(dist[i * 3 + channel]));
        if (val > max_val) max_val = val;
    }

    const max_value: f64 = if (max_val > 1.0) @as(f64, max_val) else 1.0;
    const psnr = if (mse == 0.0) 100.0 else 10.0 * @log10((max_value * max_value) / mse);

    return .{
        .mse = mse,
        .psnr = psnr,
        .max_val = max_value,
    };
}

fn generateErrorMap(ref: []const f32, dist: []const f32, error_map: []f32, width: u32, height: u32) void {
    const pixel_count = @as(usize, width) * @as(usize, height);

    var min_diff: f32 = std.math.floatMax(f32);
    var max_diff: f32 = std.math.floatMin(f32);

    for (0..pixel_count) |i| {
        const diff_r = ref[i * 3 + 0] - dist[i * 3 + 0];
        const diff_g = ref[i * 3 + 1] - dist[i * 3 + 1];
        const diff_b = ref[i * 3 + 2] - dist[i * 3 + 2];

        const diff = @sqrt(diff_r * diff_r + diff_g * diff_g + diff_b * diff_b);

        if (diff < min_diff) min_diff = diff;
        if (diff > max_diff) max_diff = diff;
    }

    const range = max_diff - min_diff;

    for (0..pixel_count) |i| {
        const diff_r = ref[i * 3 + 0] - dist[i * 3 + 0];
        const diff_g = ref[i * 3 + 1] - dist[i * 3 + 1];
        const diff_b = ref[i * 3 + 2] - dist[i * 3 + 2];
        const diff = @sqrt(diff_r * diff_r + diff_g * diff_g + diff_b * diff_b);
        if (range > 0.0)
            error_map[i] = (diff - min_diff) / range
        else
            error_map[i] = 0.0;
    }
}
