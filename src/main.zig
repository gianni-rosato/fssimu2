const std = @import("std");
const ssim = @import("ssimulacra2.zig");
const print = std.debug.print;

const c = @cImport({
    @cInclude("third-party/libspng/spng.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Collect args
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    while (args_iter.next()) |a| try args.append(a);

    if (args.items.len < 3)
        return usage();

    var json_output = false;
    var positional: [2]?[]const u8 = .{ null, null };
    var pos_index: usize = 0;

    for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            if (pos_index >= 2)
                return usageExtra("Too many positional arguments provided.");
            positional[pos_index] = arg;
            pos_index += 1;
        }
    }

    if (pos_index != 2)
        return usageExtra("Two PNG paths required: reference distorted");

    const ref_path = positional[0].?;
    const dist_path = positional[1].?;

    var ref_image = try loadPNG(allocator, ref_path);
    defer ref_image.deinit(allocator);

    var dist_image = try loadPNG(allocator, dist_path);
    defer dist_image.deinit(allocator);

    // Enforce matching original dimensions
    if (ref_image.width != dist_image.width or ref_image.height != dist_image.height)
        return fail("Input images must have identical dimensions (got {d}x{d} vs {d}x{d})", .{ ref_image.width, ref_image.height, dist_image.width, dist_image.height }, 2);

    // Convert both to 3-channel RGB ignoring alpha (if present)
    const ref_rgb = try toRGB8(allocator, ref_image);
    defer allocator.free(ref_rgb);
    const dist_rgb = try toRGB8(allocator, dist_image);
    defer allocator.free(dist_rgb);

    var width = ref_image.width;
    const height = ref_image.height;

    // If width not multiple of 16, pad both horizontally (replicate last pixel)
    var padded_ref = ref_rgb;
    var padded_dist = dist_rgb;
    if (width % 16 != 0) {
        const padded_width = ((width + 15) / 16) * 16;
        padded_ref = try padWidth(allocator, ref_rgb, width, height, padded_width);
        defer if (padded_ref.ptr != ref_rgb.ptr) allocator.free(padded_ref);
        padded_dist = try padWidth(allocator, dist_rgb, width, height, padded_width);
        defer if (padded_dist.ptr != dist_rgb.ptr) allocator.free(padded_dist);
        width = padded_width;
    }

    const score = ssim.computeSSIMULACRA2(
        allocator,
        padded_ref,
        padded_dist,
        @intCast(width),
        @intCast(height),
        3,
    ) catch |e| {
        switch (e) {
            ssim.Ssimu2Error.WidthNotMultipleOf16 => {
                return fail("Width not multiple of 16 even after padding attempt.", .{}, 3);
            },
            ssim.Ssimu2Error.InvalidChannelCount => {
                return fail("Invalid channel count encountered.", .{}, 3);
            },
            ssim.Ssimu2Error.OutOfMemory => {
                return fail("Out of memory allocating working buffers.", .{}, 3);
            },
        }
    };

    if (json_output) {
        try std.io.getStdOut().writer().print(
            "{{\"metric\":\"SSIMULACRA2\",\"score\":{d:.10}}}\n",
            .{score},
        );
    } else print("SSIMULACRA2: {d:.10}\n", .{score});
    return;
}

fn usage() void {
    print(
        \\ssimu2 - Standalone SSIMULACRA2 metric tool
        \\
        \\Usage:
        \\  ssimu2 [--json] reference.png distorted.png
        \\
        \\Options:
        \\  --json     Output result as JSON object.
        \\  -h, --help Show this help.
        \\
        \\Notes:
        \\  * Images are decoded via libspng (RGB/RGBA 8-bit sRGB expected).
        \\  * If width is not a multiple of 16, rows are padded by replicating
        \\    the last pixel to the next multiple of 16 for computation.
        \\  * Alpha channel (if present) is ignored.
        \\
    , .{});
}

fn usageExtra(msg: []const u8) void {
    const w = std.io.getStdErr().writer();
    w.print("Error: {s}\n\n", .{msg}) catch {};
    usage();
}

fn fail(comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    std.io.getStdErr().writer().print("Error: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

const PNGImage = struct {
    width: usize,
    height: usize,
    channels: u8,
    data: []u8, // Interleaved

    fn deinit(self: *PNGImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

fn loadPNG(allocator: std.mem.Allocator, path: []const u8) !PNGImage {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try file.readAll(buf);

    const ctx = c.spng_ctx_new(0);
    if (ctx == null) return error.FailedCreateContext;
    defer c.spng_ctx_free(ctx);

    if (c.spng_set_png_buffer(ctx, buf.ptr, buf.len) != 0) return error.SetBufferFailed;

    var ihdr: c.struct_spng_ihdr = undefined;
    if (c.spng_get_ihdr(ctx, &ihdr) != 0) return error.GetHeaderFailed;

    // Choose decode format: prefer RGB8 (ignore alpha) but if alpha present decode RGBA8 then strip later.
    const fmt: c_int = switch (ihdr.color_type) {
        c.SPNG_COLOR_TYPE_TRUECOLOR => c.SPNG_FMT_RGB8,
        c.SPNG_COLOR_TYPE_TRUECOLOR_ALPHA => c.SPNG_FMT_RGBA8,
        c.SPNG_COLOR_TYPE_GRAYSCALE => c.SPNG_FMT_RGBA8, // force expand later (libspng can do transforms)
        c.SPNG_COLOR_TYPE_GRAYSCALE_ALPHA => c.SPNG_FMT_RGBA8,
        c.SPNG_COLOR_TYPE_INDEXED => c.SPNG_FMT_RGBA8,
        else => c.SPNG_FMT_RGBA8,
    };

    var out_size: usize = 0;
    if (c.spng_decoded_image_size(ctx, fmt, &out_size) != 0) return error.ImageSizeFailed;

    const out_buf = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out_buf);

    if (c.spng_decode_image(ctx, out_buf.ptr, out_size, fmt, 0) != 0) return error.DecodeFailed;

    const channels: u8 = switch (fmt) {
        c.SPNG_FMT_RGB8 => 3,
        else => 4,
    };

    return PNGImage{
        .width = ihdr.width,
        .height = ihdr.height,
        .channels = channels,
        .data = out_buf,
    };
}

fn toRGB8(allocator: std.mem.Allocator, img: PNGImage) ![]u8 {
    // Always allocate a fresh RGB buffer (avoid ownership ambiguity / double free)
    // Strip alpha

    const pixels = img.width * img.height;
    const rgb = try allocator.alloc(u8, pixels * 3);
    var i: usize = 0;
    if (img.channels == 3) {
        while (i < pixels) : (i += 1) {
            rgb[i * 3 + 0] = img.data[i * 3 + 0];
            rgb[i * 3 + 1] = img.data[i * 3 + 1];
            rgb[i * 3 + 2] = img.data[i * 3 + 2];
        }
    } else { // channels == 4 (RGBA) - drop alpha
        while (i < pixels) : (i += 1) {
            rgb[i * 3 + 0] = img.data[i * 4 + 0];
            rgb[i * 3 + 1] = img.data[i * 4 + 1];
            rgb[i * 3 + 2] = img.data[i * 4 + 2];
        }
    }
    return rgb;
}

fn padWidth(
    allocator: std.mem.Allocator,
    original: []const u8,
    width: usize,
    height: usize,
    new_width: usize,
) ![]u8 {
    if (new_width == width) return @constCast(original);
    const channels: usize = 3;
    const old_row_bytes = width * channels;
    const new_row_bytes = new_width * channels;
    var out = try allocator.alloc(u8, height * new_row_bytes);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = original[y * old_row_bytes .. (y + 1) * old_row_bytes];
        const dst_row = out[y * new_row_bytes .. (y + 1) * new_row_bytes];
        // Copy existing
        @memcpy(dst_row[0..old_row_bytes], src_row);
        // Pad by replicating last pixel
        const last_px_offset = old_row_bytes - channels;
        var x_bytes: usize = old_row_bytes;
        while (x_bytes < new_row_bytes) : (x_bytes += channels) {
            @memcpy(dst_row[x_bytes .. x_bytes + channels], src_row[last_px_offset .. last_px_offset + channels]);
        }
    }
    return out;
}

test "padding works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const width: usize = 5;
    const height: usize = 2;
    var buf = try a.alloc(u8, width * height * 3);
    for (buf, 0..) |*b, i| b.* = @as(u8, @intCast(i));
    const padded = try padWidth(a, buf, width, height, 16);
    try std.testing.expectEqual(@as(usize, height * 16 * 3), padded.len);
    // Last 3 bytes of each row replicate last source pixel
    const last_src = buf[(width * 3) - 3 .. width * 3];
    const row_bytes = 16 * 3;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = padded[y * row_bytes .. (y + 1) * row_bytes];
        const tail = row[row_bytes - 3 .. row_bytes];
        try std.testing.expectEqualSlices(u8, last_src, tail);
    }
}
