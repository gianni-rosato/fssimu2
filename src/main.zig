const std = @import("std");
const ssim = @import("ssimulacra2.zig");
const io = @import("io.zig");
const y4m = @import("y4m.zig");
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
    var thread_count_opt: ?usize = null;
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
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.items.len) {
                return usageExtra("--threads requires a positive integer argument");
            }
            const n = std.fmt.parseInt(usize, args.items[i], 10) catch {
                return usageExtra("--threads must be a positive integer");
            };
            if (n == 0) return usageExtra("--threads must be >= 1");
            thread_count_opt = n;
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

    if (io.hasExtension(ref_path, ".y4m") or io.hasExtension(dist_path, ".y4m")) {
        if (!io.hasExtension(ref_path, ".y4m") or !io.hasExtension(dist_path, ".y4m"))
            return fail("Both inputs must be .y4m for video mode", .{}, 2);

        const cpu_threads = std.Thread.getCpuCount() catch 1;
        const thread_count: usize = blk: {
            const t = thread_count_opt orelse cpu_threads;
            break :blk if (t == 0) 1 else t;
        };

        const ref_file = try std.fs.cwd().openFile(ref_path, .{});
        defer ref_file.close();
        const dist_file = try std.fs.cwd().openFile(dist_path, .{});
        defer dist_file.close();

        var ref_dec = try y4m.Decoder.init(allocator, ref_file);
        defer ref_dec.deinit();
        var dist_dec = try y4m.Decoder.init(allocator, dist_file);
        defer dist_dec.deinit();

        if (ref_dec.header.width != dist_dec.header.width or ref_dec.header.height != dist_dec.header.height)
            return fail("Input videos must have identical dimensions (got {d}x{d} vs {d}x{d})", .{ ref_dec.header.width, ref_dec.header.height, dist_dec.header.width, dist_dec.header.height }, 2);

        const w: usize = ref_dec.header.width;
        const h: usize = ref_dec.header.height;
        const frame_bytes_rgb: usize = w * h * 3;

        const QueueSlot = struct {
            ref_rgb: ?[]u8 = null,
            dist_rgb: ?[]u8 = null,
            index: usize = 0,
            is_end: bool = false,
        };

        const VideoQueue = struct {
            const Self = @This();

            allocator: std.mem.Allocator,
            mutex: std.Thread.Mutex = .{},
            not_empty: std.Thread.Condition = .{},
            not_full: std.Thread.Condition = .{},

            buf: []QueueSlot,
            head: usize = 0,
            tail: usize = 0,
            count: usize = 0,

            end_pushed: bool = false,
            seen_end: bool = false,

            pub fn init(allocator_: std.mem.Allocator, capacity: usize) !Self {
                const q: Self = .{
                    .allocator = allocator_,
                    .buf = try allocator_.alloc(QueueSlot, capacity),
                };
                @memset(q.buf, .{});
                return q;
            }

            pub fn deinit(self: *Self) void {
                for (self.buf) |slot| {
                    if (slot.ref_rgb) |p| self.allocator.free(p);
                    if (slot.dist_rgb) |p| self.allocator.free(p);
                }
                self.allocator.free(self.buf);
                self.* = undefined;
            }

            pub fn push(self: *Self, slot_in: QueueSlot) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.count == self.buf.len) {
                    self.not_full.wait(&self.mutex);
                }

                self.buf[self.tail] = slot_in;
                self.tail = (self.tail + 1) % self.buf.len;
                self.count += 1;

                if (slot_in.is_end) self.end_pushed = true;

                self.not_empty.signal();
            }

            pub fn pop(self: *Self) ?QueueSlot {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.count == 0) {
                    if (self.seen_end) return null;
                    self.not_empty.wait(&self.mutex);
                }

                const slot = self.buf[self.head];
                self.buf[self.head] = .{};
                self.head = (self.head + 1) % self.buf.len;
                self.count -= 1;

                if (slot.is_end) {
                    self.seen_end = true;
                    self.not_empty.broadcast();
                }

                self.not_full.signal();
                return slot;
            }
        };

        const WorkerCtx = struct {
            allocator: std.mem.Allocator,
            queue: *VideoQueue,
            scores: *std.ArrayList(f64),
            scores_mutex: *std.Thread.Mutex,
            width: u32,
            height: u32,
            progress: *std.atomic.Value(usize),

            pub fn worker(ctx: *@This()) !void {
                while (true) {
                    const slot_opt = ctx.queue.pop();
                    if (slot_opt == null) break;

                    const slot = slot_opt.?;
                    if (slot.is_end) break;

                    const ref_rgb = slot.ref_rgb.?;
                    const dist_rgb = slot.dist_rgb.?;

                    const score = try ssim.computeSsimu2(
                        ctx.allocator,
                        ref_rgb,
                        dist_rgb,
                        ctx.width,
                        ctx.height,
                        3,
                        null,
                    );

                    ctx.allocator.free(ref_rgb);
                    ctx.allocator.free(dist_rgb);

                    ctx.scores_mutex.lock();
                    try ctx.scores.append(ctx.allocator, score);
                    ctx.scores_mutex.unlock();

                    _ = ctx.progress.fetchAdd(1, .monotonic);
                }
            }
        };

        const queue_capacity: usize = @max(2, thread_count * 2);

        var queue = try VideoQueue.init(allocator, queue_capacity);
        defer queue.deinit();

        var scores_list: std.ArrayList(f64) = .empty;
        defer scores_list.deinit(allocator);

        var scores_mutex: std.Thread.Mutex = .{};
        var progress = std.atomic.Value(usize).init(0);

        const spawn_count: usize = if (thread_count > 1) thread_count - 1 else 0;
        var threads = try allocator.alloc(std.Thread, spawn_count);
        defer allocator.free(threads);

        var ctx = WorkerCtx{
            .allocator = allocator,
            .queue = &queue,
            .scores = &scores_list,
            .scores_mutex = &scores_mutex,
            .width = @intCast(w),
            .height = @intCast(h),
            .progress = &progress,
        };

        for (0..spawn_count) |ti| {
            threads[ti] = try std.Thread.spawn(.{}, WorkerCtx.worker, .{&ctx});
        }

        var produced: usize = 0;
        while (true) {
            const ref_opt = try ref_dec.readFrame();
            const dist_opt = try dist_dec.readFrame();

            if (ref_opt == null and dist_opt == null) break;
            if (ref_opt == null or dist_opt == null)
                return fail("Input videos have different frame counts", .{}, 2);

            var ref_frame = ref_opt.?;
            defer ref_frame.deinit(allocator);
            var dist_frame = dist_opt.?;
            defer dist_frame.deinit(allocator);

            const ref_rgb = io.yuv420ToRGB8(allocator, ref_frame.width, ref_frame.height, ref_frame.y, ref_frame.u, ref_frame.v, @intFromEnum(ref_frame.bit_depth)) catch |e| {
                return fail("Failed to convert reference frame to RGB: {s}", .{@errorName(e)}, 3);
            };
            errdefer allocator.free(ref_rgb);

            const dist_rgb = io.yuv420ToRGB8(allocator, dist_frame.width, dist_frame.height, dist_frame.y, dist_frame.u, dist_frame.v, @intFromEnum(dist_frame.bit_depth)) catch |e| {
                allocator.free(ref_rgb);
                return fail("Failed to convert distorted frame to RGB: {s}", .{@errorName(e)}, 3);
            };
            errdefer allocator.free(dist_rgb);

            if (ref_rgb.len != frame_bytes_rgb or dist_rgb.len != frame_bytes_rgb) {
                allocator.free(ref_rgb);
                allocator.free(dist_rgb);
                return fail("Unexpected RGB buffer size while decoding video frames", .{}, 3);
            }

            queue.push(.{
                .ref_rgb = ref_rgb,
                .dist_rgb = dist_rgb,
                .index = produced,
                .is_end = false,
            });

            produced += 1;

            if (!json_output) {
                const done = progress.load(.monotonic);
                print("\rFrames processed: {d} (queued/produced: {d})...", .{ done, produced });
            }
        }

        queue.push(.{ .is_end = true });

        WorkerCtx.worker(&ctx) catch |e| {
            for (threads) |t| t.join();
            return fail("SSIMULACRA2 computation failed: {s}", .{@errorName(e)}, 3);
        };

        for (threads) |t| t.join();

        if (!json_output and produced > 0)
            print("\r" ++ " " ** 60 ++ "\r", .{});

        if (scores_list.items.len == 0) return fail("No frames found in input videos", .{}, 2);

        const stats = computeStats(scores_list.items);

        if (json_output) {
            print(
                \\{{"metric":"SSIMULACRA2","score":{d:.8},"frames":{d},"threads":{d},"stats":{{"stddev":{d:.8},"median":{d:.8},"p5":{d:.8},"p95":{d:.8},"min":{d:.8},"max":{d:.8}}}}}
                \\
            , .{ stats.avg, stats.count, thread_count, stats.stddev, stats.median, stats.p5, stats.p95, stats.min, stats.max });
        } else {
            print("{d:.8}\n", .{stats.avg});
            print("frames:  {d}\n", .{stats.count});
            print("avg:     {d:.8}\n", .{stats.avg});
            print("stddev:  {d:.8}\n", .{stats.stddev});
            print("median:  {d:.8}\n", .{stats.median});
            print("p5:      {d:.8}\n", .{stats.p5});
            print("p95:     {d:.8}\n", .{stats.p95});
            print("min:     {d:.8}\n", .{stats.min});
            print("max:     {d:.8}\n", .{stats.max});
        }
        return;
    }

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

const Stats = struct {
    avg: f64,
    count: usize,
    stddev: f64,
    median: f64,
    p5: f64,
    p95: f64,
    min: f64,
    max: f64,
};

fn computeStats(scores: []f64) Stats {
    var sum: f64 = 0;
    var min: f64 = scores[0];
    var max: f64 = scores[0];
    for (scores) |s| {
        sum += s;
        if (s < min) min = s;
        if (s > max) max = s;
    }
    const avg = sum / @as(f64, @floatFromInt(scores.len));

    var variance: f64 = 0;
    for (scores) |s| {
        const diff = s - avg;
        variance += diff * diff;
    }
    const stddev = @sqrt(variance / @as(f64, @floatFromInt(scores.len)));

    std.mem.sort(f64, scores, {}, std.sort.asc(f64));
    const median = scores[scores.len / 2];
    const p5 = scores[scores.len / 20];
    const p95 = scores[scores.len * 19 / 20];

    return .{
        .avg = avg,
        .count = scores.len,
        .stddev = stddev,
        .median = median,
        .p5 = p5,
        .p95 = p95,
        .min = min,
        .max = max,
    };
}

fn usage() void {
    print("\x1b[34mfssimu2\x1b[0m | {s}\n\n", .{VERSION});
    print(
        \\usage:
        \\  fssimu2 [options] <reference> <distorted>
        \\
        \\options:
        \\  --json                 output result as json
        \\  --err-map <out>        save error map to .png/.tga
        \\  -t, --threads <n>      number of worker threads for video scoring (default: CPU threads)
        \\  -h, --help             show this help
        \\  -v, --version          show version information
    , .{});
    print("\n\n\x1b[37msRGB PNG, PAM, JPEG, WebP, AVIF, or Y4M input expected\x1b[0m\n", .{});
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
