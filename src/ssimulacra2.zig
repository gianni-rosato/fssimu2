const std = @import("std");
const math = std.math;
const scl = @import("linearlight.zig");
const err_map = @import("err_map.zig");

// SSIMULACRA2 Metric Implementation

pub const Ssimu2Error = error{
    InvalidChannelCount,
    OutOfMemory,
};

const K_SIZE = 9;
const RADIUS = 4;
const VEC_LEN = 8;
const F32x8 = @Vector(VEC_LEN, f32);
const F32x4 = @Vector(4, f32);
const F64x4 = @Vector(4, f64);

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    stride: u32,
    plane_size: usize,
    planes: []f16,
    temp: []f32,
    scratch: []f32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Workspace {
        var ws: Workspace = .{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .stride = 0,
            .plane_size = 0,
            .planes = &[_]f16{},
            .temp = &[_]f32{},
            .scratch = &[_]f32{},
        };
        try ws.ensureCapacity(width, height);
        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.planes.len > 0) self.allocator.free(self.planes);
        if (self.temp.len > 0) self.allocator.free(self.temp);
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.* = undefined;
    }

    pub fn ensureCapacity(self: *Workspace, width: u32, height: u32) !void {
        if (self.width == width and self.height == height and self.planes.len > 0) return;

        if (self.planes.len > 0) self.allocator.free(self.planes);
        if (self.temp.len > 0) self.allocator.free(self.temp);
        if (self.scratch.len > 0) self.allocator.free(self.scratch);

        const pixels = @as(usize, width) * @as(usize, height);
        const total_floats: usize = pixels * 3 * 2;
        const plane_alloc = try self.allocator.alignedAlloc(f16, .of(f16), total_floats);

        const wh: usize = @as(usize, width) * @as(usize, height);
        const temp_alloc = try self.allocator.alignedAlloc(f32, .of(f32), wh * 20);
        const scratch_alloc = try self.allocator.alignedAlloc(f32, .of(f32), width);

        self.width = width;
        self.height = height;
        self.stride = width;
        self.plane_size = pixels;
        self.planes = plane_alloc;
        self.temp = temp_alloc;
        self.scratch = scratch_alloc;
    }
};

pub fn computeSsimu2WithWorkspace(
    workspace: *Workspace,
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    channels: u32,
    error_map: ?[]u32,
) Ssimu2Error!f64 {
    if (channels != 3 and channels != 4) return Ssimu2Error.InvalidChannelCount;

    const pixels = @as(usize, width) * @as(usize, height);
    const expected_len = pixels * @as(usize, channels);

    std.debug.assert(reference.len >= expected_len);
    std.debug.assert(distorted.len >= expected_len);

    try workspace.ensureCapacity(width, height);

    var ref_planes: [3][]f16 = undefined;
    var dist_planes: [3][]f16 = undefined;
    {
        var off: usize = 0;
        inline for (0..3) |i| {
            ref_planes[i] = workspace.planes[off .. off + workspace.plane_size];
            off += workspace.plane_size;
        }
        inline for (0..3) |i| {
            dist_planes[i] = workspace.planes[off .. off + workspace.plane_size];
            off += workspace.plane_size;
        }
    }

    scl.sRGBInterleavedToPlanarLinear(reference, ref_planes, width, height, channels);
    scl.sRGBInterleavedToPlanarLinear(distorted, dist_planes, width, height, channels);

    const ref_const: [3][]const f16 = .{
        ref_planes[0], ref_planes[1], ref_planes[2],
    };
    const dist_const: [3][]const f16 = .{
        dist_planes[0], dist_planes[1], dist_planes[2],
    };

    return processWithScratch(
        ref_const,
        dist_const,
        workspace.stride,
        width,
        height,
        error_map,
        workspace.temp,
        workspace.scratch,
    );
}

pub fn computeSsimu2(
    allocator: std.mem.Allocator,
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    channels: u32,
    error_map: ?[]u32,
) Ssimu2Error!f64 {
    var workspace = try Workspace.init(allocator, width, height);
    defer workspace.deinit();
    return computeSsimu2WithWorkspace(&workspace, reference, distorted, width, height, channels, error_map);
}

inline fn loadF32x8(src: []const f32, index: usize) F32x8 {
    return @as(*align(1) const F32x8, @ptrCast(src.ptr + index)).*;
}

inline fn storeF32x8(dst: []f32, index: usize, value: F32x8) void {
    @as(*align(1) F32x8, @ptrCast(dst.ptr + index)).* = value;
}

inline fn loadF32x4(src: []const f32, index: usize) F32x4 {
    return @as(*align(1) const F32x4, @ptrCast(src.ptr + index)).*;
}

inline fn multiply(src1: []const f32, src2: []const f32, dst: []f32, stride: u32, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row: usize = @as(usize, y) * stride;
        var x: usize = 0;
        while (x + VEC_LEN <= w) : (x += VEC_LEN) {
            storeF32x8(dst, row + x, loadF32x8(src1, row + x) * loadF32x8(src2, row + x));
        }
        while (x < w) : (x += 1) {
            dst[row + x] = src1[row + x] * src2[row + x];
        }
    }
}

fn blurH(srcp: []const f32, dstp: []f32, kernel: [K_SIZE]f32, w: i32) void {
    var j: i32 = 0;
    while (j < @min(w, RADIUS)) : (j += 1) {
        const dist_from_right: i32 = w - 1 - j;
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < RADIUS) : (k += 1) {
            const idx: i32 = if (j < RADIUS - k) @min(RADIUS - k - j, w - 1) else (j - RADIUS + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        k = RADIUS;
        while (k < K_SIZE) : (k += 1) {
            const idx: i32 = if (dist_from_right < k - RADIUS) (j - @min(k - RADIUS - dist_from_right, j)) else (j - RADIUS + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        dstp[@intCast(j)] = sum;
    }

    const interior_end: usize = @intCast(w - @min(w, RADIUS));
    var ju: usize = RADIUS;
    while (ju + VEC_LEN <= interior_end) : (ju += VEC_LEN) {
        var sum: F32x8 = @splat(0.0);
        inline for (0..K_SIZE) |k|
            sum += @as(F32x8, @splat(kernel[k])) * loadF32x8(srcp, ju + k - RADIUS);
        storeF32x8(dstp, ju, sum);
    }

    j = @intCast(ju);
    while (j < w - @min(w, RADIUS)) : (j += 1) {
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < K_SIZE) : (k += 1) {
            sum += kernel[@intCast(k)] * srcp[@intCast(j - RADIUS + k)];
        }
        dstp[@intCast(j)] = sum;
    }

    j = @max(RADIUS, w - @min(w, RADIUS));
    while (j < w) : (j += 1) {
        const dist_from_right: i32 = w - 1 - j;
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < RADIUS) : (k += 1) {
            const idx: i32 = if (j < RADIUS - k) @min(RADIUS - k - j, w - 1) else (j - RADIUS + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        k = RADIUS;
        while (k < K_SIZE) : (k += 1) {
            const idx: i32 = if (dist_from_right < k - RADIUS) (j - @min(k - RADIUS - dist_from_right, j)) else (j - RADIUS + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        dstp[@intCast(j)] = sum;
    }
}

inline fn blurV(src: anytype, dstp: []f32, kernel: [K_SIZE]f32, w: u32) void {
    var j: usize = 0;
    while (j + VEC_LEN <= w) : (j += VEC_LEN) {
        var accum: F32x8 = @splat(0.0);
        inline for (0..K_SIZE) |k|
            accum += @as(F32x8, @splat(kernel[k])) * loadF32x8(src[k], j);
        storeF32x8(dstp, j, accum);
    }
    while (j < w) : (j += 1) {
        var accum: f32 = 0.0;
        var k: u32 = 0;
        while (k < K_SIZE) : (k += 1) {
            accum += kernel[k] * @as(f32, @floatCast(src[k][j]));
        }
        dstp[j] = accum;
    }
}

inline fn blur(src: []const f32, dst: []f32, stride: u32, w: u32, h: u32, tmp_row: []f32) void {
    const kernel = [K_SIZE]f32{
        0.0076144188642501831054687500,
        0.0360749699175357818603515625,
        0.1095860823988914489746093750,
        0.2134445458650588989257812500,
        0.2665599882602691650390625000,
        0.2134445458650588989257812500,
        0.1095860823988914489746093750,
        0.0360749699175357818603515625,
        0.0076144188642501831054687500,
    };
    var i: i32 = 0;
    const ih: i32 = @bitCast(h);
    while (i < ih) : (i += 1) {
        const ui: u32 = @bitCast(i);
        var srcp_rows: [K_SIZE][]const f32 = undefined;
        const dstp_row: []f32 = dst[(ui * stride)..];
        const dist_from_bottom: i32 = ih - 1 - i;

        var k: i32 = 0;
        while (k < RADIUS) : (k += 1) {
            const row: i32 = if (i < RADIUS - k) (@min(RADIUS - k - i, ih - 1)) else (i - RADIUS + k);
            const urow: u32 = @bitCast(row);
            srcp_rows[@intCast(k)] = src[(urow * stride)..];
        }
        k = RADIUS;
        while (k < K_SIZE) : (k += 1) {
            const row: i32 = if (dist_from_bottom < k - RADIUS)
                (i - @min(k - RADIUS - dist_from_bottom, i))
            else
                (i - RADIUS + k);
            const urow: u32 = @bitCast(row);
            srcp_rows[@intCast(k)] = src[(urow * stride)..];
        }

        blurV(srcp_rows, tmp_row, kernel, w);
        blurH(tmp_row, dstp_row, kernel, @intCast(w));
    }
}

const K_D0: f32 = 0.0037930734;
const K_D1: f32 = std.math.lossyCast(f32, math.cbrt(K_D0));

const V00: f32 = 0.0;
const V05: f32 = 0.5;
const V10: f32 = 1.0;
const V001: f32 = 0.01;
const V055: f32 = 0.55;
const V042: f32 = 0.42;
const V140: f32 = 14.0;

const weight = [108]f64{
    0.0,
    0.0007376606707406586,
    0.0,
    0.0,
    0.0007793481682867309,
    0.0,
    0.0,
    0.0004371155730107379,
    0.0,
    1.1041726426657346,
    0.00066284834129271,
    0.00015231632783718752,
    0.0,
    0.0016406437456599754,
    0.0,
    1.8422455520539298,
    11.441172603757666,
    0.0,
    0.0007989109436015163,
    0.000176816438078653,
    0.0,
    1.8787594979546387,
    10.94906990605142,
    0.0,
    0.0007289346991508072,
    0.9677937080626833,
    0.0,
    0.00014003424285435884,
    0.9981766977854967,
    0.00031949755934435053,
    0.0004550992113792063,
    0.0,
    0.0,
    0.0013648766163243398,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    7.466890328078848,
    0.0,
    17.445833984131262,
    0.0006235601634041466,
    0.0,
    0.0,
    6.683678146179332,
    0.00037724407979611296,
    1.027889937768264,
    225.20515300849274,
    0.0,
    0.0,
    19.213238186143016,
    0.0011401524586618361,
    0.001237755635509985,
    176.39317598450694,
    0.0,
    0.0,
    24.43300999870476,
    0.28520802612117757,
    0.0004485436923833408,
    0.0,
    0.0,
    0.0,
    34.77906344483772,
    44.835625328877896,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0008680556573291698,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0005313191874358747,
    0.0,
    0.00016533814161379112,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0004179171803251336,
    0.0017290828234722833,
    0.0,
    0.0020827005846636437,
    0.0,
    0.0,
    8.826982764996862,
    23.19243343998926,
    0.0,
    95.1080498811086,
    0.9863978034400682,
    0.9834382792465353,
    0.0012286405048278493,
    171.2667255897307,
    0.9807858872435379,
    0.0,
    0.0,
    0.0,
    0.0005130064588990679,
    0.0,
    0.00010854057858411537,
};

inline fn getWeight(c: i32, scale: i32, map: i32, norm: i32) f64 {
    std.debug.assert(c >= 0 and c < 3);
    std.debug.assert(scale >= 0 and scale < 6);
    std.debug.assert(map >= 0 and map < 3);
    std.debug.assert(norm >= 0 and norm < 2);
    const idx = 36 * c + 6 * scale + 3 * norm + map;
    std.debug.assert(idx >= 0 and idx < 108);
    return weight[@intCast(idx)];
}

inline fn activeWeight(plane: i32, scale: i32, map: i32) bool {
    const w0 = @abs(getWeight(plane, scale, map, 0));
    const w1 = @abs(getWeight(plane, scale, map, 1));
    return @max(w0, w1) > 0.01;
}

const K_M02 = 0.078;
const K_M00 = 0.30;
const K_M01 = V10 - K_M02 - K_M00;
const K_M12 = 0.078;
const K_M10 = 0.23;
const K_M11 = V10 - K_M12 - K_M10;
const K_M20 = 0.24342269;
const K_M21 = 0.20476745;
const K_M22 = V10 - K_M20 - K_M21;

const OPSIN_ABSORBANCE_MATRIX = [_]f32{
    K_M00, K_M01, K_M02,
    K_M10, K_M11, K_M12,
    K_M20, K_M21, K_M22,
};
const OPSIN_ABSORBANCE_BIAS: f32 = K_D0;
const ABSORBANCE_BIAS: f32 = -K_D1;

inline fn cbrtVec(x: f32) f32 {
    return std.math.lossyCast(f32, math.cbrt(x));
}

inline fn opsinAbsorbance(rgb: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    const r = rgb[0];
    const g = rgb[1];
    const b = rgb[2];
    out[0] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[0], r, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[1], g, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[2], b, OPSIN_ABSORBANCE_BIAS)));
    out[1] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[3], r, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[4], g, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[5], b, OPSIN_ABSORBANCE_BIAS)));
    out[2] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[6], r, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[7], g, @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[8], b, OPSIN_ABSORBANCE_BIAS)));
    return out;
}

inline fn mixedToXYB(mixed: [3]f32) [3]f32 {
    return .{
        V05 * (mixed[0] - mixed[1]),
        V05 * (mixed[0] + mixed[1]),
        mixed[2],
    };
}

inline fn linearRGBtoXYB(input: [3]f32) [3]f32 {
    var mixed = opsinAbsorbance(input);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (mixed[i] < V00) mixed[i] = V00;
        mixed[i] = cbrtVec(mixed[i]) + ABSORBANCE_BIAS;
    }
    return mixedToXYB(mixed);
}

inline fn makePositiveXYB(xyb_in: *[3]f32) void {
    // Safely dereference the pointer into a local array, mutate, then write back.
    var arr = xyb_in.*;
    arr[2] = (arr[2] - arr[1]) + V055;
    arr[0] = arr[0] * V140 + V042;
    arr[1] = arr[1] + V001;
    xyb_in.* = arr;
}

inline fn xyb(src: [3][]const f32, dst: [3][]f32, idx: usize) void {
    const rgb = [3]f32{
        src[0][idx],
        src[1][idx],
        src[2][idx],
    };
    var out = linearRGBtoXYB(rgb);
    makePositiveXYB(&out);
    inline for (0..3) |i| {
        dst[i][idx] = out[i];
    }
}

inline fn toXYB(srcp: [3][]const f32, dstp: [3][]f32, stride: u32, w: u32, h: u32) void {
    var src = srcp;
    var dst = dstp;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            xyb(src, dst, @intCast(x));
        }
        inline for (0..3) |i| {
            src[i] = src[i][stride..];
            dst[i] = dst[i][stride..];
        }
    }
}

inline fn tothe4th(y: f64) f64 {
    const x = y * y;
    return x * x;
}

inline fn ssimMap(
    s11: []f32,
    s22: []f32,
    s12: []f32,
    mu1: []f32,
    mu2: []f32,
    stride: u32,
    w: u32,
    h: u32,
    plane: u32,
    one_per_pixels: f64,
    plane_avg_ssim: []f64,
    error_map: ?[]f32,
    scale: u32,
) void {
    var sum1 = [2]f64{ 0.0, 0.0 };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: usize = 0;
        if (error_map == null) {
            var sum_d: F64x4 = @splat(0.0);
            var sum_d4: F64x4 = @splat(0.0);
            while (x + 4 <= w) : (x += 4) {
                const m1: F64x4 = @floatCast(loadF32x4(mu1, row + x));
                const m2: F64x4 = @floatCast(loadF32x4(mu2, row + x));
                const s11v: F64x4 = @floatCast(loadF32x4(s11, row + x));
                const s22v: F64x4 = @floatCast(loadF32x4(s22, row + x));
                const s12v: F64x4 = @floatCast(loadF32x4(s12, row + x));

                const m11 = m1 * m1;
                const m22 = m2 * m2;
                const m12 = m1 * m2;
                const m_diff = m1 - m2;
                const num_m = @as(F64x4, @splat(1.0)) - m_diff * m_diff;
                const num_s = (s12v - m12) * @as(F64x4, @splat(2.0)) + @as(F64x4, @splat(0.0009));
                const denom_s = (s11v - m11) + (s22v - m22) + @as(F64x4, @splat(0.0009));
                const d = @max(@as(F64x4, @splat(1.0)) - ((num_m * num_s) / denom_s), @as(F64x4, @splat(0.0)));
                const d2 = d * d;
                sum_d += d;
                sum_d4 += d2 * d2;
            }
            sum1[0] += @reduce(.Add, sum_d);
            sum1[1] += @reduce(.Add, sum_d4);
        }
        while (x < w) : (x += 1) {
            const m1: f32 = @floatCast(mu1[row + x]);
            const m2: f32 = @floatCast(mu2[row + x]);
            const m11 = m1 * m1;
            const m22 = m2 * m2;
            const m12 = m1 * m2;
            const m_diff = m1 - m2;
            const num_m: f64 = @mulAdd(f32, m_diff, -m_diff, 1.0);
            const num_s: f64 = @mulAdd(f32, (@as(f32, @floatCast(s12[row + x])) - m12), 2.0, 0.0009);
            const denom_s: f64 = (@as(f32, @floatCast(s11[row + x])) - m11) + (@as(f32, @floatCast(s22[row + x])) - m22) + 0.0009;
            const d1: f64 = @max(1.0 - ((num_m * num_s) / denom_s), 0.0);
            sum1[0] += d1;
            sum1[1] += tothe4th(d1);

            if (error_map) |emap| {
                const d: f32 = @floatCast(d1);
                const weight1: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 0, 0));
                const weight2: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 0, 1));
                emap[row + x] += weight1 * d;
                emap[row + x] += weight2 * d;
            }
        }
    }
    plane_avg_ssim[plane * 2] = one_per_pixels * sum1[0];
    plane_avg_ssim[plane * 2 + 1] = @sqrt(@sqrt(one_per_pixels * sum1[1]));
}

inline fn edgeMap(
    im1: []f32,
    im2: []f32,
    mu1: []f32,
    mu2: []f32,
    stride: u32,
    w: u32,
    h: u32,
    plane: u32,
    one_per_pixels: f64,
    plane_avg_edge: []f64,
    error_map: ?[]f32,
    scale: u32,
) void {
    var sum2 = [4]f64{ 0.0, 0.0, 0.0, 0.0 };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: usize = 0;
        if (error_map == null) {
            var sum_artifact: F64x4 = @splat(0.0);
            var sum_artifact4: F64x4 = @splat(0.0);
            var sum_lost: F64x4 = @splat(0.0);
            var sum_lost4: F64x4 = @splat(0.0);
            while (x + 4 <= w) : (x += 4) {
                const im1v: F64x4 = @floatCast(loadF32x4(im1, row + x));
                const im2v: F64x4 = @floatCast(loadF32x4(im2, row + x));
                const mu1v: F64x4 = @floatCast(loadF32x4(mu1, row + x));
                const mu2v: F64x4 = @floatCast(loadF32x4(mu2, row + x));

                const d = (@as(F64x4, @splat(1.0)) + @abs(im2v - mu2v)) /
                    (@as(F64x4, @splat(1.0)) + @abs(im1v - mu1v)) - @as(F64x4, @splat(1.0));
                const artifact = @max(d, @as(F64x4, @splat(0.0)));
                const detail_lost = @max(-d, @as(F64x4, @splat(0.0)));
                const artifact2 = artifact * artifact;
                const lost2 = detail_lost * detail_lost;
                sum_artifact += artifact;
                sum_artifact4 += artifact2 * artifact2;
                sum_lost += detail_lost;
                sum_lost4 += lost2 * lost2;
            }
            sum2[0] += @reduce(.Add, sum_artifact);
            sum2[1] += @reduce(.Add, sum_artifact4);
            sum2[2] += @reduce(.Add, sum_lost);
            sum2[3] += @reduce(.Add, sum_lost4);
        }
        while (x < w) : (x += 1) {
            const d1: f64 = (1.0 + @as(f64, @abs(@as(f32, @floatCast(im2[row + x])) - @as(f32, @floatCast(mu2[row + x]))))) /
                (1.0 + @as(f64, @abs(@as(f32, @floatCast(im1[row + x])) - @as(f32, @floatCast(mu1[row + x]))))) - 1.0;
            const artifact: f64 = @max(d1, 0.0);
            sum2[0] += artifact;
            sum2[1] += tothe4th(artifact);
            const detail_lost: f64 = @max(-d1, 0.0);
            sum2[2] += detail_lost;
            sum2[3] += tothe4th(detail_lost);

            if (error_map) |emap| {
                const artifact_f: f32 = @floatCast(artifact);
                const detail_lost_f: f32 = @floatCast(detail_lost);
                const weight1: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 1, 0));
                const weight2: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 1, 1));
                const weight3: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 2, 0));
                const weight4: f32 = @floatCast(getWeight(@intCast(plane), @intCast(scale), 2, 1));
                emap[row + x] += weight1 * @abs(artifact_f);
                emap[row + x] += weight2 * @abs(artifact_f);
                emap[row + x] += weight3 * @abs(detail_lost_f);
                emap[row + x] += weight4 * @abs(detail_lost_f);
            }
        }
    }
    plane_avg_edge[plane * 4] = one_per_pixels * sum2[0];
    plane_avg_edge[plane * 4 + 1] = @sqrt(@sqrt(one_per_pixels * sum2[1]));
    plane_avg_edge[plane * 4 + 2] = one_per_pixels * sum2[2];
    plane_avg_edge[plane * 4 + 3] = @sqrt(@sqrt(one_per_pixels * sum2[3]));
}

inline fn score(plane_avg_ssim: [6][6]f64, plane_avg_edge: [6][12]f64) f64 {
    var ssim_accum: f64 = 0.0;
    var idx: usize = 0;

    for (0..3) |plane| {
        for (0..6) |scale| {
            for (0..2) |n| {
                ssim_accum = @mulAdd(f64, weight[idx], @abs(plane_avg_ssim[scale][plane * 2 + n]), ssim_accum);
                idx += 1;
                ssim_accum = @mulAdd(f64, weight[idx], @abs(plane_avg_edge[scale][plane * 4 + n]), ssim_accum);
                idx += 1;
                ssim_accum = @mulAdd(f64, weight[idx], @abs(plane_avg_edge[scale][plane * 4 + n + 2]), ssim_accum);
                idx += 1;
            }
        }
    }

    ssim_accum *= 0.9562382616834844;
    ssim_accum = (6.248496625763138e-5 * ssim_accum * ssim_accum) * ssim_accum +
        2.326765642916932 * ssim_accum -
        0.020884521182843837 * ssim_accum * ssim_accum;

    if (ssim_accum > 0.0) {
        ssim_accum = math.pow(f64, ssim_accum, 0.6276336467831387) * -10.0 + 100.0;
    } else {
        ssim_accum = 100.0;
    }
    return ssim_accum;
}

inline fn downscale(src: [3][]f32, dst: [3][]f32, src_stride: u32, in_w: u32, in_h: u32) void {
    const fscale: f32 = 2.0;
    const uscale: u32 = 2;
    const out_w = @divTrunc((in_w + uscale - 1), uscale);
    const out_h = @divTrunc((in_h + uscale - 1), uscale);
    const dst_stride = @divTrunc((src_stride + uscale - 1), uscale);
    const normalize: f32 = 1.0 / (fscale * fscale);

    var plane: u32 = 0;
    while (plane < 3) : (plane += 1) {
        const srcp = src[plane];
        var dstp = dst[plane];
        var oy: u32 = 0;
        while (oy < out_h) : (oy += 1) {
            var ox: u32 = 0;
            while (ox < out_w) : (ox += 1) {
                var sum: f32 = 0.0;
                var iy: u32 = 0;
                while (iy < uscale) : (iy += 1) {
                    var ix: u32 = 0;
                    while (ix < uscale) : (ix += 1) {
                        const x: u32 = @min((ox * uscale + ix), (in_w - 1));
                        const y: u32 = @min((oy * uscale + iy), (in_h - 1));
                        sum += srcp[y * src_stride + x];
                    }
                }
                dstp[ox] = sum * normalize;
            }
            dstp = dstp[dst_stride..];
        }
    }
}

fn process(
    allocator: std.mem.Allocator,
    srcp1: [3][]const f16,
    srcp2: [3][]const f16,
    stride: u32,
    w: u32,
    h: u32,
    error_map: ?[]u32,
) f64 {
    const wh: u32 = stride * h;
    const error_map_count: u32 = if (error_map != null) 2 else 0; // error_accum and error_scale
    const temp_alloc = allocator.alignedAlloc(f32, .of(f32), wh * (18 + error_map_count)) catch unreachable;
    defer allocator.free(temp_alloc);
    const scratch = allocator.alignedAlloc(f32, .of(f32), stride) catch unreachable;
    defer allocator.free(scratch);

    return processWithScratch(srcp1, srcp2, stride, w, h, error_map, temp_alloc, scratch);
}

fn processWithScratch(
    srcp1: [3][]const f16,
    srcp2: [3][]const f16,
    stride: u32,
    w: u32,
    h: u32,
    error_map: ?[]u32,
    temp: []f32,
    scratch: []f32,
) f64 {
    const wh: u32 = stride * h;
    const error_map_count: u32 = if (error_map != null) 2 else 0; // error_accum and error_scale
    const required: usize = @as(usize, wh) * @as(usize, 18 + error_map_count);
    std.debug.assert(temp.len >= required);
    std.debug.assert(scratch.len >= stride);
    var temp_use = temp[0..required];

    var temp6x3: [6][3][]f32 = undefined;
    var x: u32 = 0;
    for (0..6) |i| {
        for (0..3) |ii| {
            temp6x3[i][ii] = temp_use[x..(x + wh)];
            x += wh;
        }
    }

    var error_accum: []f32 = undefined;
    var error_scale: []f32 = undefined;
    if (error_map != null) {
        error_accum = temp_use[x..(x + wh)];
        x += wh;
        error_scale = temp_use[x..(x + wh)];
        x += wh;
        @memset(error_scale, 0.0);
    }

    const srcp1b = temp6x3[0];
    const srcp2b = temp6x3[1];
    const tmpp1 = temp6x3[2];
    const tmpp2 = temp6x3[3];

    const tmpp3 = temp6x3[4][0];
    const tmpps11 = temp6x3[4][1];
    const tmpps22 = temp6x3[4][2];
    const tmpps12 = temp6x3[5][0];
    const tmppmu1 = temp6x3[5][1];

    inline for (0..3) |i| {
        for (srcp1[i], 0..) |v, j|
            srcp1b[i][j] = @floatCast(v);
        for (srcp2[i], 0..) |v, j|
            srcp2b[i][j] = @floatCast(v);
    }

    var plane_avg_ssim: [6][6]f64 = std.mem.zeroes([6][6]f64);
    var plane_avg_edge: [6][12]f64 = std.mem.zeroes([6][12]f64);
    var stride2 = stride;
    var w2 = w;
    var h2 = h;

    var scale: u32 = 0;
    while (scale < 6) : (scale += 1) {
        if (scale > 0) {
            downscale(srcp1b, srcp1b, stride2, w2, h2);
            downscale(srcp2b, srcp2b, stride2, w2, h2);
            stride2 = @divTrunc((stride2 + 1), 2);
            w2 = @divTrunc((w2 + 1), 2);
            h2 = @divTrunc((h2 + 1), 2);
        }

        if (error_map != null) {
            const current_wh = stride2 * h2;
            @memset(error_scale[0..current_wh], 0.0);
        }

        const one_per_pixels: f64 = 1.0 / @as(f64, @floatFromInt(w2 * h2));
        toXYB(srcp1b, tmpp1, stride2, w2, h2);
        toXYB(srcp2b, tmpp2, stride2, w2, h2);

        for (0..3) |plane| {
            const ssim_on = activeWeight(@intCast(plane), @intCast(scale), 0);
            const edge_on = activeWeight(@intCast(plane), @intCast(scale), 1) or
                activeWeight(@intCast(plane), @intCast(scale), 2);

            if (ssim_on) {
                multiply(tmpp1[plane], tmpp1[plane], tmpp3, stride2, w2, h2);
                blur(tmpp3, tmpps11, stride2, w2, h2, scratch);
                multiply(tmpp2[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
                blur(tmpp3, tmpps22, stride2, w2, h2, scratch);
                multiply(tmpp1[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
                blur(tmpp3, tmpps12, stride2, w2, h2, scratch);
            }

            if (ssim_on or edge_on) {
                blur(tmpp1[plane], tmppmu1, stride2, w2, h2, scratch);
                blur(tmpp2[plane], tmpp3, stride2, w2, h2, scratch);
            }

            if (ssim_on)
                ssimMap(
                    tmpps11,
                    tmpps22,
                    tmpps12,
                    tmppmu1,
                    tmpp3,
                    stride2,
                    w2,
                    h2,
                    @intCast(plane),
                    one_per_pixels,
                    &plane_avg_ssim[scale],
                    if (error_map != null) error_scale else null,
                    scale,
                );

            if (edge_on)
                edgeMap(
                    tmpp1[plane],
                    tmpp2[plane],
                    tmppmu1,
                    tmpp3,
                    stride2,
                    w2,
                    h2,
                    @intCast(plane),
                    one_per_pixels,
                    &plane_avg_edge[scale],
                    if (error_map != null) error_scale else null,
                    @intCast(scale),
                );
        }

        if (error_map != null) {
            if (scale == 0)
                @memcpy(error_accum, error_scale)
            else if (scale < 3)
                err_map.upscaleAndAccumulate(error_scale, error_accum, stride2, w2, h2, stride, w, h);
        }
    }

    if (error_map) |emap|
        err_map.generateErrorMap(error_accum, emap, stride, w, h);

    return score(plane_avg_ssim, plane_avg_edge);
}
