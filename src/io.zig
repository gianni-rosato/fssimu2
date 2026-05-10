const std = @import("std");
const c = @import("c");
const print = std.debug.print;

pub const Image = struct {
    width: usize,
    height: usize,
    channels: u8, // 1=Gray,2=GrayA,3=RGB,4=RGBA
    data: []u8, // interleaved, row-major

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub fn loadJPEG(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(sys_io, path, .{});

    const file_ptr = c.fdopen(file.handle, "rb");
    if (file_ptr == null) {
        file.close(sys_io);
        return error.FailedToOpenFile;
    }
    defer _ = c.fclose(file_ptr);

    var cinfo: c.jpeg_decompress_struct = undefined;
    var jerr: c.jpeg_error_mgr = undefined;

    cinfo.err = c.jpeg_std_error(&jerr);
    c.jpeg_create_decompress(&cinfo);
    defer c.jpeg_destroy_decompress(&cinfo);

    c.jpeg_stdio_src(&cinfo, file_ptr);

    if (c.jpeg_read_header(&cinfo, c.TRUE) != c.JPEG_HEADER_OK)
        return error.InvalidJPEGHeader;

    if (cinfo.num_components == 1)
        cinfo.out_color_space = c.JCS_GRAYSCALE
    else
        cinfo.out_color_space = c.JCS_RGB;

    if (c.jpeg_start_decompress(&cinfo) != c.TRUE) {
        return error.JPEGDecompressFailed;
    }

    const width: usize = @intCast(cinfo.output_width);
    const height: usize = @intCast(cinfo.output_height);
    const channels: usize = @intCast(cinfo.output_components);

    const row_stride: usize = width * channels;
    const out_buf: []u8 = try allocator.alloc(u8, height * row_stride);
    errdefer allocator.free(out_buf);

    const row_buf = try allocator.alloc(u8, row_stride);
    defer allocator.free(row_buf);

    for (0..height) |y| {
        var row_pointers: [1][*c]u8 = .{row_buf.ptr};
        if (c.jpeg_read_scanlines(&cinfo, &row_pointers, 1) != 1)
            return error.JPEGReadScanlinesFailed;
        @memcpy(out_buf[y * row_stride .. (y + 1) * row_stride], row_buf);
    }

    if (c.jpeg_finish_decompress(&cinfo) != c.TRUE)
        return error.JPEGFinishDecompressFailed;

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = @intCast(channels),
        .data = out_buf,
    };
}

pub fn loadPNG(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(sys_io, path, .{});
    defer file.close(sys_io);
    const size = try file.length(sys_io);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    if (try file.readPositionalAll(sys_io, buf, 0) != buf.len) return error.UnexpectedEof;

    const ctx = c.spng_ctx_new(0);
    if (ctx == null) return error.FailedCreateContext;
    defer c.spng_ctx_free(ctx);

    if (c.spng_set_png_buffer(ctx, buf.ptr, buf.len) != 0)
        return error.SetBufferFailed;

    var ihdr: c.struct_spng_ihdr = undefined;
    if (c.spng_get_ihdr(ctx, &ihdr) != 0)
        return error.GetHeaderFailed;

    // prefer RGB8 (ignore alpha), but if alpha, decode RGBA8 & strip later.
    const fmt: c_int = switch (ihdr.color_type) {
        c.SPNG_COLOR_TYPE_TRUECOLOR => c.SPNG_FMT_RGB8,
        c.SPNG_COLOR_TYPE_TRUECOLOR_ALPHA => c.SPNG_FMT_RGBA8,
        c.SPNG_COLOR_TYPE_GRAYSCALE => c.SPNG_FMT_RGBA8, // libspng expands to RGBA; we'll drop A later
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

    return .{
        .width = ihdr.width,
        .height = ihdr.height,
        .channels = channels,
        .data = out_buf,
    };
}

pub fn loadPAM(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(sys_io, path, .{});
    defer file.close(sys_io);

    const file_size = try file.length(sys_io);
    const buf = try allocator.alloc(u8, file_size);
    defer allocator.free(buf);
    if (try file.readPositionalAll(sys_io, buf, 0) != buf.len) return error.UnexpectedEof;

    if (buf.len < 3 or !std.mem.startsWith(u8, buf, "P7")) return error.NotAPamFile;

    // Find header end. Prefer explicit ENDHDR marker; else look for double newline.
    const endhdr_explicit = std.mem.find(u8, buf, "ENDHDR\n");
    var header_end_index: ?usize = null;
    if (endhdr_explicit) |i| {
        header_end_index = i + 7; // include terminator
    } else {
        // Look for first occurrence of "\n\n" (empty line). PAM spec mandates ENDHDR
        // but some generators may still use empty line.
        const empty_line = std.mem.find(u8, buf, "\n\n");
        if (empty_line) |i| header_end_index = i + 2;
    }
    if (header_end_index == null) return error.HeaderNotFound;
    const header_end = header_end_index.?;

    const header = buf[0..header_end];

    var width: usize = 0;
    var height: usize = 0;
    var depth: usize = 0;
    var maxval: usize = 0;
    var tuple_type: []const u8 = "UNSPECIFIED";

    var line_it = std.mem.tokenizeAny(u8, header, "\r\n");
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue; // comment
        if (std.mem.startsWith(u8, line, "WIDTH")) {
            var it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (it.next()) |v| width = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "HEIGHT")) {
            var it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (it.next()) |v| height = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "DEPTH")) {
            var it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (it.next()) |v| depth = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "MAXVAL")) {
            var it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (it.next()) |v| maxval = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "TUPLTYPE")) {
            var it = std.mem.tokenizeAny(u8, line[8..], " \t");
            if (it.next()) |v| tuple_type = v;
        } else if (std.mem.eql(u8, line, "ENDHDR")) {
            break;
        }
    }

    if (width == 0 or height == 0 or depth == 0 or maxval == 0)
        return error.InvalidPamDimensions;
    if (maxval != 255) return error.UnsupportedPamMaxVal;
    if (depth != 1 and depth != 2 and depth != 3 and depth != 4)
        return error.UnsupportedPamDepth;

    var channels: u8 = @intCast(depth);
    if (std.ascii.eqlIgnoreCase(tuple_type, "GRAYSCALE")) {
        if (depth != 1) return error.PamTupleMismatch;
        channels = 1;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "GRAYSCALE_ALPHA")) {
        if (depth != 2) return error.PamTupleMismatch;
        channels = 2;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "RGB")) {
        if (depth != 3) return error.PamTupleMismatch;
        channels = 3;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "RGB_ALPHA")) {
        if (depth != 4) return error.PamTupleMismatch;
        channels = 4;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "BLACKANDWHITE")) {
        // binary (maxval should be 1) - not supporting
        return error.UnsupportedPamTuple;
    }

    const pixel_count = width * height;
    const data_size = pixel_count * channels;
    if (header_end + data_size > buf.len) return error.InsufficientDataInFile;

    const out = try allocator.alloc(u8, pixel_count * channels);
    errdefer allocator.free(out);
    @memcpy(out, buf[header_end .. header_end + data_size]);

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .data = out,
    };
}

pub fn loadWebP(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(sys_io, path, .{});
    defer file.close(sys_io);
    const size = try file.length(sys_io);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    if (try file.readPositionalAll(sys_io, buf, 0) != buf.len) return error.UnexpectedEof;

    var width: c_int = 0;
    var height: c_int = 0;
    const data = c.WebPDecodeRGBA(buf.ptr, buf.len, &width, &height);
    if (data == null) return error.WebPDecodeFailed;
    defer c.WebPFree(data);

    const out_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const out_buf = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out_buf);
    @memcpy(out_buf, @as([*]const u8, @ptrCast(data))[0..out_size]);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = 4,
        .data = out_buf,
    };
}

pub fn loadAVIF(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const file = try std.Io.Dir.cwd().openFile(sys_io, path, .{});
    defer file.close(sys_io);
    const size = try file.length(sys_io);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    if (try file.readPositionalAll(sys_io, buf, 0) != buf.len) return error.UnexpectedEof;

    const decoder = c.avifDecoderCreate();
    if (decoder == null) return error.AvifCreateDecoderFailed;
    defer c.avifDecoderDestroy(decoder);

    // decode the first frame
    var r = c.avifDecoderSetIOMemory(decoder, buf.ptr, buf.len);
    if (r != c.AVIF_RESULT_OK) return error.AvifSetIOMemoryFailed;
    r = c.avifDecoderParse(decoder);
    if (r != c.AVIF_RESULT_OK) return error.AvifParseFailed;
    r = c.avifDecoderNextImage(decoder);
    if (r != c.AVIF_RESULT_OK) return error.AvifNoImageDecoded;

    // request 8-bit RGB out
    var rgb = c.avifRGBImage{};
    c.avifRGBImageSetDefaults(&rgb, decoder[0].image);
    rgb.format = c.AVIF_RGB_FORMAT_RGB;
    rgb.depth = 8;

    r = c.avifRGBImageAllocatePixels(&rgb);
    if (r != c.AVIF_RESULT_OK) return error.AvifAllocatePixelsFailed;
    defer c.avifRGBImageFreePixels(&rgb);

    r = c.avifImageYUVToRGB(decoder[0].image, &rgb);
    if (r != c.AVIF_RESULT_OK) return error.AvifYUVToRGBFailed;

    const img_ptr = decoder[0].image;
    const width: usize = @intCast(img_ptr.*.width);
    const height: usize = @intCast(img_ptr.*.height);
    const rowBytes: usize = @intCast(rgb.rowBytes);
    const channels: usize = 3;

    const out_size = width * height * channels;
    const out_buf = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out_buf);

    const src_pixels: [*]const u8 = @ptrCast(rgb.pixels);
    const src_all: []const u8 = src_pixels[0..(rowBytes * height)];
    for (0..height) |y| {
        const src_off = y * rowBytes;
        const dst_off = y * width * channels;
        @memcpy(out_buf[dst_off .. dst_off + width * channels], src_all[src_off .. src_off + width * channels]);
    }

    return .{
        .width = width,
        .height = height,
        .channels = @intCast(channels),
        .data = out_buf,
    };
}

pub fn loadImage(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    if (hasExtension(path, ".png"))
        return loadPNG(allocator, sys_io, path)
    else if (hasExtension(path, ".pam"))
        return loadPAM(allocator, sys_io, path)
    else if (hasExtension(path, ".jpg") or hasExtension(path, ".jpeg"))
        return loadJPEG(allocator, sys_io, path)
    else if (hasExtension(path, ".webp"))
        return loadWebP(allocator, sys_io, path)
    else if (hasExtension(path, ".avif"))
        return loadAVIF(allocator, sys_io, path)
    else {
        print("Error: Unrecognized image format; fssimu2 supports PNG, PAM, JPG, WEBP, or AVIF\n", .{});
        return error.UnrecognizedImageFormat;
    }
}

pub fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const tail = path[path.len - ext.len ..];
    return std.ascii.eqlIgnoreCase(tail, ext);
}

pub fn toRGB8(allocator: std.mem.Allocator, img: Image) ![]u8 {
    const pixels = img.width * img.height;
    const rgb = try allocator.alloc(u8, pixels * 3);
    switch (img.channels) {
        3 => {
            // direct copy
            for (0..pixels) |i| {
                rgb[i * 3 + 0] = img.data[i * 3 + 0];
                rgb[i * 3 + 1] = img.data[i * 3 + 1];
                rgb[i * 3 + 2] = img.data[i * 3 + 2];
            }
        },
        4 => {
            for (0..pixels) |i| {
                rgb[i * 3 + 0] = img.data[i * 4 + 0];
                rgb[i * 3 + 1] = img.data[i * 4 + 1];
                rgb[i * 3 + 2] = img.data[i * 4 + 2];
            }
        },
        1 => {
            // replicate grayscale channel
            for (0..pixels) |i| {
                const g = img.data[i];
                rgb[i * 3 + 0] = g;
                rgb[i * 3 + 1] = g;
                rgb[i * 3 + 2] = g;
            }
        },
        2 => {
            // grayscale + alpha -> ignore alpha
            for (0..pixels) |i| {
                const g = img.data[i * 2 + 0];
                rgb[i * 3 + 0] = g;
                rgb[i * 3 + 1] = g;
                rgb[i * 3 + 2] = g;
            }
        },
        else => return error.UnsupportedChannelCount,
    }
    return rgb;
}

pub fn yuv420ToRGB8(allocator: std.mem.Allocator, width: usize, height: usize, y: []const u8, u: []const u8, v: []const u8, bit_depth: u8) ![]u8 {
    const pixels = width * height;
    const rgb = try allocator.alloc(u8, pixels * 3);
    try yuv420ToRGB8Into(rgb, width, height, y, u, v, bit_depth);
    return rgb;
}

pub fn yuv420ToRGB8Into(dst: []u8, width: usize, height: usize, y: []const u8, u: []const u8, v: []const u8, bit_depth: u8) !void {
    const pixels = width * height;
    if (dst.len < pixels * 3) return error.BufferTooSmall;

    const y_ptr = y.ptr;
    const u_ptr = u.ptr;
    const v_ptr = v.ptr;

    for (0..height) |j| {
        for (0..width) |i| {
            const y_idx = j * width + i;
            const uv_idx = (j / 2) * (width / 2) + (i / 2);

            var py: f32 = undefined;
            var pu: f32 = undefined;
            var pv: f32 = undefined;

            if (bit_depth == 8) {
                py = @floatFromInt(y[y_idx]);
                pu = @floatFromInt(u[uv_idx]);
                pv = @floatFromInt(v[uv_idx]);
            } else {
                const y_u16 = @as(*align(1) const u16, @ptrCast(y_ptr + y_idx * 2)).*;
                const u_u16 = @as(*align(1) const u16, @ptrCast(u_ptr + uv_idx * 2)).*;
                const v_u16 = @as(*align(1) const u16, @ptrCast(v_ptr + uv_idx * 2)).*;
                // Scale 10-bit to 8-bit range for the formula
                py = @as(f32, @floatFromInt(y_u16)) / 4.0;
                pu = @as(f32, @floatFromInt(u_u16)) / 4.0;
                pv = @as(f32, @floatFromInt(v_u16)) / 4.0;
            }

            // BT.709 YUV to RGB conversion (limited range)
            const y_f = (py - 16.0) / 219.0;
            const u_f = (pu - 128.0) / 224.0;
            const v_f = (pv - 128.0) / 224.0;

            const r = y_f + 1.5748 * v_f;
            const g = y_f - 0.1873 * u_f - 0.4681 * v_f;
            const b = y_f + 1.8556 * u_f;

            dst[y_idx * 3 + 0] = @trunc(std.math.clamp(r * 255.0, 0, 255));
            dst[y_idx * 3 + 1] = @trunc(std.math.clamp(g * 255.0, 0, 255));
            dst[y_idx * 3 + 2] = @trunc(std.math.clamp(b * 255.0, 0, 255));
        }
    }
}

fn savePNG(sys_io: std.Io, path: []const u8, rgba_data: []const u8, width: u16, height: u16) !void {
    const ctx = c.spng_ctx_new(c.SPNG_CTX_ENCODER);
    if (ctx == null) return error.FailedCreateContext;
    defer c.spng_ctx_free(ctx);

    if (c.spng_set_option(ctx, c.SPNG_ENCODE_TO_BUFFER, 1) != 0)
        return error.FailedSetOption;

    var ihdr: c.spng_ihdr = undefined;
    ihdr.width = width;
    ihdr.height = height;
    ihdr.bit_depth = 8;
    ihdr.color_type = c.SPNG_COLOR_TYPE_TRUECOLOR_ALPHA;
    ihdr.compression_method = 0;
    ihdr.filter_method = 0;
    ihdr.interlace_method = 0;

    if (c.spng_set_ihdr(ctx, &ihdr) != 0)
        return error.FailedSetIhdr;
    if (c.spng_encode_image(ctx, rgba_data.ptr, rgba_data.len, c.SPNG_FMT_PNG, c.SPNG_ENCODE_FINALIZE) != 0)
        return error.FailedEncode;

    var png_size: usize = 0;
    const png_buf = c.spng_get_png_buffer(ctx, &png_size, null);
    if (png_buf == null) return error.FailedGetBuffer;

    const file = try std.Io.Dir.cwd().createFile(sys_io, path, .{});
    defer file.close(sys_io);
    const png_slice = @as([*]const u8, @ptrCast(png_buf))[0..png_size];
    try file.writeStreamingAll(sys_io, png_slice);
}

fn saveTarga(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8, bgra_data: []const u8, width: u16, height: u16) !void {
    const pixels = @as(usize, width) * @as(usize, height);
    const tga_data = try allocator.alloc(u8, 18 + pixels * 4);
    defer allocator.free(tga_data);

    tga_data[0] = 0; // ID length
    tga_data[1] = 0; // Color map type
    tga_data[2] = 2; // Image type (uncompressed true-color)
    @memset(tga_data[3..8], 0); // Color map spec (5 bytes, all 0)

    std.mem.writeInt(u16, tga_data[8..10], 0, .little); // X-origin
    std.mem.writeInt(u16, tga_data[10..12], 0, .little); // Y-origin
    std.mem.writeInt(u16, tga_data[12..14], width, .little); // Width
    std.mem.writeInt(u16, tga_data[14..16], height, .little); // Height

    tga_data[16] = 32; // Pixel depth
    tga_data[17] = 8; // Image descriptor (alpha depth 8)

    var offset: usize = 18;
    for (0..height) |i| {
        const row_start = (height - 1 - i) * width * 4;
        @memcpy(tga_data[offset .. offset + width * 4], bgra_data[row_start .. row_start + width * 4]);
        offset += width * 4;
    }

    const file = try std.Io.Dir.cwd().createFile(sys_io, path, .{});
    defer file.close(sys_io);
    try file.writeStreamingAll(sys_io, tga_data);
}

pub fn saveErrorMap(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8, error_map: []const u32, width: u16, height: u16) !void {
    const pixels = @as(usize, width) * @as(usize, height);
    if (hasExtension(path, ".tga")) {
        // Convert to BGRA for TGA
        const bgra_data = try allocator.alloc(u8, pixels * 4);
        defer allocator.free(bgra_data);
        for (0..pixels) |i| {
            const color = error_map[i];
            bgra_data[i * 4 + 0] = @intCast((color >> 16) & 0xFF); // B
            bgra_data[i * 4 + 1] = @intCast((color >> 8) & 0xFF); // G
            bgra_data[i * 4 + 2] = @intCast((color >> 0) & 0xFF); // R
            bgra_data[i * 4 + 3] = @intCast((color >> 24) & 0xFF); // A
        }
        try saveTarga(allocator, sys_io, path, bgra_data, width, height);
    } else {
        // Convert to RGBA for PNG
        const rgba_data = try allocator.alloc(u8, pixels * 4);
        defer allocator.free(rgba_data);
        for (0..pixels) |i| {
            const color = error_map[i];
            rgba_data[i * 4 + 0] = @intCast((color >> 0) & 0xFF); // R
            rgba_data[i * 4 + 1] = @intCast((color >> 8) & 0xFF); // G
            rgba_data[i * 4 + 2] = @intCast((color >> 16) & 0xFF); // B
            rgba_data[i * 4 + 3] = @intCast((color >> 24) & 0xFF); // A
        }
        try savePNG(sys_io, path, rgba_data, width, height);
    }
}
