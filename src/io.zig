const std = @import("std");
const c = @import("c");
const imgio = @import("simpleimgio");
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

fn simpleImageToRaster(allocator: std.mem.Allocator, simple_in: imgio.Image) !Image {
    var simple = simple_in;

    if (simple.depth < 1 or simple.depth > 4) {
        simple.deinit(allocator);
        return error.UnsupportedChannelCount;
    }

    if (simple.maxval == 255 and simple.kind != .bitmap) {
        return .{
            .width = simple.width,
            .height = simple.height,
            .channels = simple.depth,
            .data = simple.data,
        };
    }

    var eight = simple.to8Bit(allocator) catch |err| {
        simple.deinit(allocator);
        return err;
    };
    simple.deinit(allocator);

    if (eight.depth < 1 or eight.depth > 4) {
        eight.deinit(allocator);
        return error.UnsupportedChannelCount;
    }
    return .{
        .width = eight.width,
        .height = eight.height,
        .channels = eight.depth,
        .data = eight.data,
    };
}

pub fn loadSimpleImage(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    const simple = if (hasExtension(path, ".qoi"))
        try imgio.decodeQoiFile(sys_io, allocator, path)
    else if (hasExtension(path, ".pam"))
        try imgio.decodePamFile(sys_io, allocator, path)
    else
        try imgio.decodePnmFile(sys_io, allocator, path);

    return simpleImageToRaster(allocator, simple);
}

pub fn loadImage(allocator: std.mem.Allocator, sys_io: std.Io, path: []const u8) !Image {
    if (hasExtension(path, ".png"))
        return loadPNG(allocator, sys_io, path)
    else if (hasExtension(path, ".pam") or hasExtension(path, ".pnm") or hasExtension(path, ".pbm") or hasExtension(path, ".pgm") or hasExtension(path, ".ppm") or hasExtension(path, ".qoi"))
        return loadSimpleImage(allocator, sys_io, path)
    else if (hasExtension(path, ".jpg") or hasExtension(path, ".jpeg"))
        return loadJPEG(allocator, sys_io, path)
    else if (hasExtension(path, ".webp"))
        return loadWebP(allocator, sys_io, path)
    else if (hasExtension(path, ".avif"))
        return loadAVIF(allocator, sys_io, path)
    else {
        print("Error: Unrecognized image format; fssimu2 supports PNG, PNM/PAM, QOI, JPG, WEBP, AVIF, or Y4M\n", .{});
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

pub fn yuv420FrameToRGB8Into(allocator: std.mem.Allocator, dst: []u8, frame: imgio.YuvFrame) !void {
    var eight_storage: ?imgio.YuvFrame = null;
    defer if (eight_storage) |*eight| eight.deinit(allocator);

    const frame8 = if (frame.bit_depth == .b8) frame else blk: {
        eight_storage = try frame.to8Bit(allocator);
        break :blk eight_storage.?;
    };

    try yuv420ToRGB8Into(dst, frame8.width, frame8.height, frame8.y, frame8.u, frame8.v);
}

fn yuv420ToRGB8Into(dst: []u8, width: usize, height: usize, y: []const u8, u: []const u8, v: []const u8) !void {
    const pixels = width * height;
    if (dst.len < pixels * 3) return error.BufferTooSmall;
    if (y.len < pixels) return error.BadPlaneSize;
    const chroma_width = (width + 1) / 2;
    const chroma_height = (height + 1) / 2;
    if (u.len < chroma_width * chroma_height or v.len < chroma_width * chroma_height) return error.BadPlaneSize;

    for (0..height) |j| {
        for (0..width) |i| {
            const y_idx = j * width + i;
            const uv_idx = (j / 2) * chroma_width + (i / 2);

            const py: f32 = @floatFromInt(y[y_idx]);
            const pu: f32 = @floatFromInt(u[uv_idx]);
            const pv: f32 = @floatFromInt(v[uv_idx]);

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
