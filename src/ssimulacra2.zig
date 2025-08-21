/// SSIMULACRA2 standalone implementation (ported from Vapoursynth filter version).
///
/// Original metric core was designed to operate on planar, linear RGB float
/// images whose row stride and width are multiples of 16 (to simplify
/// SIMD-by-hand using Zig vectors of width 16).
///
/// This standalone module exposes:
///   pub fn computeSSIMULACRA2(
///       allocator: std.mem.Allocator,
///       reference: []const u8,
///       distorted: []const u8,
///       width: u32,
///       height: u32,
///       channels: u32,
///   ) !f64
///
/// Inputs:
///   - reference / distorted: interleaved 8-bit sRGB buffers (RGB or RGBA)
///   - width, height: image dimensions (must match for both images)
///   - channels: 3 (RGB) or 4 (RGBA). Alpha (if present) is ignored.
/// Constraints:
///   - width must be a multiple of 16 (the original implementation assumes this).
///
/// Returns:
///   - SSIMULACRA2 score as f64 (higher is better, ~0-100 range)
///
/// Errors:
///   - error.WidthNotMultipleOf16
///   - error.InvalidChannelCount
///
/// NOTE:
/// If you need to support arbitrary widths, you can add horizontal padding
/// of the last pixel up to the next multiple of 16 and adjust the loops
/// to limit statistical accumulation to original width. For parity with the
/// existing code, we keep the width constraint explicit here.
const std = @import("std");
const math = std.math;

pub const Ssimu2Error = error{
    WidthNotMultipleOf16,
    InvalidChannelCount,
    OutOfMemory,
};

/// Public convenience entry point.
pub fn computeSSIMULACRA2(
    allocator: std.mem.Allocator,
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) Ssimu2Error!f64 {
    if (channels != 3 and channels != 4) return Ssimu2Error.InvalidChannelCount;
    if (width % 16 != 0) return Ssimu2Error.WidthNotMultipleOf16;

    const pixels = @as(usize, width) * @as(usize, height);
    const expected_len = pixels * @as(usize, channels);

    std.debug.assert(reference.len >= expected_len);
    std.debug.assert(distorted.len >= expected_len);

    // Allocate planar float (linear RGB) buffers for both images.
    // Stride equals width (no padding) because width is guaranteed multiple of 16.
    const stride: u32 = width;

    const plane_size: usize = pixels;
    const total_floats: usize = plane_size * 3 * 2; // 3 planes * 2 images
    var planes = try allocator.alignedAlloc(f32, 32, total_floats);
    defer allocator.free(planes);

    var ref_planes: [3][]f32 = undefined;
    var dist_planes: [3][]f32 = undefined;
    {
        var off: usize = 0;
        inline for (0..3) |i| {
            ref_planes[i] = planes[off .. off + plane_size];
            off += plane_size;
        }
        inline for (0..3) |i| {
            dist_planes[i] = planes[off .. off + plane_size];
            off += plane_size;
        }
    }

    // Fill using sRGB->linear conversion.
    sRGBInterleavedToPlanarLinear(reference, ref_planes, width, height, channels);
    sRGBInterleavedToPlanarLinear(distorted, dist_planes, width, height, channels);

    // Wrap as [][]const f32 for process signature.
    const ref_const: [3][]const f32 = .{
        ref_planes[0], ref_planes[1], ref_planes[2],
    };
    const dist_const: [3][]const f32 = .{
        dist_planes[0], dist_planes[1], dist_planes[2],
    };

    return process(allocator, ref_const, dist_const, stride, width, height);
}

// -------------------- Internal metric implementation (ported) --------------------

const ksize = 9;
const radius = 4;
const vec_t: type = @Vector(16, f32);

inline fn multiplyVec(src1: anytype, src2: anytype, dst: []f32) void {
    dst[0..16].* = @as(vec_t, src1[0..16].*) * @as(vec_t, src2[0..16].*);
}

pub inline fn multiply(src1: []const f32, src2: []const f32, dst: []f32, stride: u32, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: u32 = 0;
        while (x + 16 <= w) : (x += 16) {
            multiplyVec(src1[row + x ..], src2[row + x ..], dst[row + x ..]);
        }
        // (width is guaranteed multiple of 16, so no tail handling)
    }
}

fn blurH(srcp: []f32, dstp: []f32, kernel: [ksize]f32, w: i32) void {
    var j: i32 = 0;
    while (j < @min(w, radius)) : (j += 1) {
        const dist_from_right: i32 = w - 1 - j;
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < radius) : (k += 1) {
            const idx: i32 = if (j < radius - k) @min(radius - k - j, w - 1) else (j - radius + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        k = radius;
        while (k < ksize) : (k += 1) {
            const idx: i32 = if (dist_from_right < k - radius) (j - @min(k - radius - dist_from_right, j)) else (j - radius + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        dstp[@intCast(j)] = sum;
    }

    j = radius;
    while (j < w - @min(w, radius)) : (j += 1) {
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < ksize) : (k += 1) {
            sum += kernel[@intCast(k)] * srcp[@intCast(j - radius + k)];
        }
        dstp[@intCast(j)] = sum;
    }

    j = @max(radius, w - @min(w, radius));
    while (j < w) : (j += 1) {
        const dist_from_right: i32 = w - 1 - j;
        var sum: f32 = 0.0;
        var k: i32 = 0;
        while (k < radius) : (k += 1) {
            const idx: i32 = if (j < radius - k) @min(radius - k - j, w - 1) else (j - radius + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        k = radius;
        while (k < ksize) : (k += 1) {
            const idx: i32 = if (dist_from_right < k - radius) (j - @min(k - radius - dist_from_right, j)) else (j - radius + k);
            sum += kernel[@intCast(k)] * srcp[@intCast(idx)];
        }
        dstp[@intCast(j)] = sum;
    }
}

inline fn blurV(src: anytype, dstp: []f32, kernel: [ksize]f32, w: u32) void {
    var j: u32 = 0;
    while (j < w) : (j += 1) {
        var accum: f32 = 0.0;
        var k: u32 = 0;
        while (k < ksize) : (k += 1) {
            accum += kernel[k] * src[k][j];
        }
        dstp[j] = accum;
    }
}

pub inline fn blur(src: []const f32, dst: []f32, stride: u32, w: u32, h: u32, tmp_row: []f32) void {
    const kernel = [ksize]f32{
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
        var srcp_rows: [ksize][]const f32 = undefined;
        const dstp_row: []f32 = dst[(ui * stride)..];
        const dist_from_bottom: i32 = ih - 1 - i;

        var k: i32 = 0;
        while (k < radius) : (k += 1) {
            const row: i32 = if (i < radius - k) (@min(radius - k - i, ih - 1)) else (i - radius + k);
            const urow: u32 = @bitCast(row);
            srcp_rows[@intCast(k)] = src[(urow * stride)..];
        }
        k = radius;
        while (k < ksize) : (k += 1) {
            const row: i32 = if (dist_from_bottom < k - radius)
                (i - @min(k - radius - dist_from_bottom, i))
            else
                (i - radius + k);
            const urow: u32 = @bitCast(row);
            srcp_rows[@intCast(k)] = src[(urow * stride)..];
        }

        blurV(srcp_rows, tmp_row, kernel, w);
        blurH(tmp_row, dstp_row, kernel, @intCast(w));
    }
}

const K_D0: f32 = 0.0037930734;
const K_D1: f32 = std.math.lossyCast(f32, math.cbrt(@as(f32, K_D0)));

const V00: vec_t = @splat(@as(f32, 0.0));
const V05: vec_t = @splat(@as(f32, 0.5));
const V10: vec_t = @splat(@as(f32, 1.0));
const V11_unused: vec_t = @splat(@as(f32, 1.1)); // kept for parity (unused below)

const V001: vec_t = @splat(@as(f32, 0.01));
const V055: vec_t = @splat(@as(f32, 0.55));
const V042: vec_t = @splat(@as(f32, 0.42));
const V140: vec_t = @splat(@as(f32, 14.0));

const K_M02: vec_t = @splat(@as(f32, 0.078));
const K_M00: vec_t = @splat(@as(f32, 0.30));
const K_M01: vec_t = V10 - K_M02 - K_M00;
const K_M12: vec_t = @splat(@as(f32, 0.078));
const K_M10: vec_t = @splat(@as(f32, 0.23));
const K_M11: vec_t = V10 - K_M12 - K_M10;
const K_M20: vec_t = @splat(@as(f32, 0.24342269));
const K_M21: vec_t = @splat(@as(f32, 0.20476745));
const K_M22: vec_t = V10 - K_M20 - K_M21;

const OPSIN_ABSORBANCE_MATRIX = [_]vec_t{
    K_M00, K_M01, K_M02,
    K_M10, K_M11, K_M12,
    K_M20, K_M21, K_M22,
};
const OPSIN_ABSORBANCE_BIAS: vec_t = @splat(K_D0);
const ABSORBANCE_BIAS: vec_t = @splat(-K_D1);

inline fn cbrtVec(x: vec_t) vec_t {
    var out: vec_t = undefined;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        out[i] = std.math.lossyCast(f32, math.cbrt(@as(f32, x[i])));
    }
    return out;
}

inline fn opsinAbsorbance(rgb: [3]vec_t) [3]vec_t {
    var out: [3]vec_t = undefined;
    out[0] = @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[0], rgb[0], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[1], rgb[1], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[2], rgb[2], OPSIN_ABSORBANCE_BIAS)));
    out[1] = @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[3], rgb[0], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[4], rgb[1], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[5], rgb[2], OPSIN_ABSORBANCE_BIAS)));
    out[2] = @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[6], rgb[0], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[7], rgb[1], @mulAdd(vec_t, OPSIN_ABSORBANCE_MATRIX[8], rgb[2], OPSIN_ABSORBANCE_BIAS)));
    return out;
}

inline fn mixedToXYB(mixed: [3]vec_t) [3]vec_t {
    return .{
        V05 * (mixed[0] - mixed[1]),
        V05 * (mixed[0] + mixed[1]),
        mixed[2],
    };
}

inline fn linearRGBtoXYB(input: [3]vec_t) [3]vec_t {
    var mixed = opsinAbsorbance(input);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const pred: @Vector(16, bool) = mixed[i] < V00;
        mixed[i] = @select(f32, pred, V00, mixed[i]);
        mixed[i] = cbrtVec(mixed[i]) + ABSORBANCE_BIAS;
    }
    return mixedToXYB(mixed);
}

inline fn makePositiveXYB(xyb: *[3]vec_t) void {
    xyb[2] = (xyb[2] - xyb[1]) + V055;
    xyb[0] = xyb[0] * V140 + V042;
    xyb[1] += V001;
}

inline fn xybVec(src: [3][]const f32, dst: [3][]f32) void {
    const rgb = [3]vec_t{
        src[0][0..16].*,
        src[1][0..16].*,
        src[2][0..16].*,
    };
    var out = linearRGBtoXYB(rgb);
    makePositiveXYB(&out);
    inline for (0..3) |i| {
        dst[i][0..16].* = out[i];
    }
}

pub inline fn toXYB(srcp: [3][]const f32, dstp: [3][]f32, stride: u32, w: u32, h: u32) void {
    var src = srcp;
    var dst = dstp;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x + 16 <= w) : (x += 16) {
            const x2 = x + 16;
            const srcs = [3][]const f32{ src[0][x..x2], src[1][x..x2], src[2][x..x2] };
            const dsts = [3][]f32{ dst[0][x..x2], dst[1][x..x2], dst[2][x..x2] };
            xybVec(srcs, dsts);
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
) void {
    var sum1 = [2]f64{ 0.0, 0.0 };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const m1: f32 = mu1[row + x];
            const m2: f32 = mu2[row + x];
            const m11 = m1 * m1;
            const m22 = m2 * m2;
            const m12 = m1 * m2;
            const m_diff = m1 - m2;
            const num_m: f64 = @mulAdd(f32, m_diff, -m_diff, 1.0);
            const num_s: f64 = @mulAdd(f32, (s12[row + x] - m12), 2.0, 0.0009);
            const denom_s: f64 = (s11[row + x] - m11) + (s22[row + x] - m22) + 0.0009;
            const d1: f64 = @max(1.0 - ((num_m * num_s) / denom_s), 0.0);
            sum1[0] += d1;
            sum1[1] += tothe4th(d1);
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
) void {
    var sum2 = [4]f64{ 0.0, 0.0, 0.0, 0.0 };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const d1: f64 = (1.0 + @as(f64, @abs(im2[row + x] - mu2[row + x]))) /
                (1.0 + @as(f64, @abs(im1[row + x] - mu1[row + x]))) - 1.0;
            const artifact: f64 = @max(d1, 0.0);
            sum2[0] += artifact;
            sum2[1] += tothe4th(artifact);
            const detail_lost: f64 = @max(-d1, 0.0);
            sum2[2] += detail_lost;
            sum2[3] += tothe4th(detail_lost);
        }
    }
    plane_avg_edge[plane * 4] = one_per_pixels * sum2[0];
    plane_avg_edge[plane * 4 + 1] = @sqrt(@sqrt(one_per_pixels * sum2[1]));
    plane_avg_edge[plane * 4 + 2] = one_per_pixels * sum2[2];
    plane_avg_edge[plane * 4 + 3] = @sqrt(@sqrt(one_per_pixels * sum2[3]));
}

inline fn score(plane_avg_ssim: [6][6]f64, plane_avg_edge: [6][12]f64) f64 {
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

pub fn process(
    allocator: std.mem.Allocator,
    srcp1: [3][]const f32,
    srcp2: [3][]const f32,
    stride: u32,
    w: u32,
    h: u32,
) f64 {
    const wh: u32 = stride * h;
    const temp_alloc = allocator.alignedAlloc(f32, 32, wh * 18) catch unreachable;
    defer allocator.free(temp_alloc);
    var temp = temp_alloc[0..];

    var temp6x3: [6][3][]f32 = undefined;
    var x: u32 = 0;
    for (0..6) |i| {
        for (0..3) |ii| {
            temp6x3[i][ii] = temp[x..(x + wh)];
            x += wh;
        }
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
        @memcpy(srcp1b[i], srcp1[i]);
        @memcpy(srcp2b[i], srcp2[i]);
    }

    // Single scratch buffer for all blurs (width never exceeds original stride)
    const scratch = allocator.alignedAlloc(f32, 32, stride) catch unreachable;
    defer allocator.free(scratch);

    var plane_avg_ssim: [6][6]f64 = undefined;
    var plane_avg_edge: [6][12]f64 = undefined;
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

        const one_per_pixels: f64 = 1.0 / @as(f64, @floatFromInt(w2 * h2));
        toXYB(srcp1b, tmpp1, stride2, w2, h2);
        toXYB(srcp2b, tmpp2, stride2, w2, h2);

        var plane: u32 = 0;
        while (plane < 3) : (plane += 1) {
            multiply(tmpp1[plane], tmpp1[plane], tmpp3, stride2, w2, h2);
            blur(tmpp3, tmpps11, stride2, w2, h2, scratch);

            multiply(tmpp2[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
            blur(tmpp3, tmpps22, stride2, w2, h2, scratch);

            multiply(tmpp1[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
            blur(tmpp3, tmpps12, stride2, w2, h2, scratch);

            blur(tmpp1[plane], tmppmu1, stride2, w2, h2, scratch);
            blur(tmpp2[plane], tmpp3, stride2, w2, h2, scratch);

            ssimMap(
                tmpps11,
                tmpps22,
                tmpps12,
                tmppmu1,
                tmpp3,
                stride2,
                w2,
                h2,
                plane,
                one_per_pixels,
                &plane_avg_ssim[scale],
            );

            edgeMap(
                tmpp1[plane],
                tmpp2[plane],
                tmppmu1,
                tmpp3,
                stride2,
                w2,
                h2,
                plane,
                one_per_pixels,
                &plane_avg_edge[scale],
            );
        }
    }

    return score(plane_avg_ssim, plane_avg_edge);
}

// -------------------- sRGB -> Linear helpers --------------------

fn makeSRGBToLinearLUT() [256]f32 {
    var lut: [256]f32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const c = @as(f32, @floatFromInt(i)) / 255.0;
        lut[i] = if (c <= 0.04045) c / 12.92 else math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    return lut;
}

const SRGB_LUT: [256]f32 = .{
    0.0,          0.000303527,  0.000607054,  0.000910581,  0.0012141079, 0.0015176349, 0.0018211619, 0.0021246889, 0.0024282159, 0.0027317429, 0.0030352698, 0.0033465358, 0.0036765073, 0.004024717,  0.004391442,  0.0047769535,
    0.0051815167, 0.0056053916, 0.006048833,  0.0065120908, 0.0069954102, 0.007499032,  0.008023193,  0.0085681256, 0.0091340587, 0.0097212173, 0.010329823,  0.010960094,  0.0116122452, 0.0122864884, 0.0129830323, 0.013702083,
    0.0144438436, 0.0152085144, 0.0159962934, 0.0168073758, 0.0176419545, 0.0185002201, 0.019382361,  0.0202885631, 0.0212190104, 0.0221738848, 0.0231533662, 0.0241576324, 0.0251868596, 0.0262412219, 0.0273208916, 0.0284260395,
    0.0295568344, 0.0307134437, 0.0318960331, 0.0331047666, 0.0343398068, 0.0356013149, 0.0368894504, 0.0382043716, 0.0395462353, 0.0409151969, 0.0423114106, 0.0437350293, 0.0451862044, 0.0466650863, 0.0481718242, 0.049706566,
    0.0512694584, 0.052860647,  0.0544802764, 0.05612849,   0.0578054302, 0.0595112382, 0.0612460542, 0.0630100177, 0.0648032667, 0.0666259386, 0.0684781698, 0.0703600957, 0.0722718507, 0.0742135684, 0.0761853815, 0.0781874218,
    0.0802198203, 0.0822827071, 0.0843762115, 0.086500462,  0.0886555863, 0.0908417112, 0.0930589628, 0.0953074666, 0.0975873471, 0.0998987282, 0.1022417331, 0.1046164841, 0.107023103,  0.1094617108, 0.1119324278, 0.1144353738,
    0.1169706678, 0.119538428,  0.1221387722, 0.1247718176, 0.1274376804, 0.1301364767, 0.1328683216, 0.1356333297, 0.138431615,  0.1412632911, 0.1441284709, 0.1470272665, 0.1499597898, 0.152926152,  0.1559264637, 0.1589608351,
    0.1620293756, 0.1651321945, 0.1682694002, 0.1714411007, 0.1746474037, 0.177888416,  0.1811642442, 0.1844749945, 0.1878207723, 0.1912016827, 0.1946178304, 0.1980693196, 0.2015562538, 0.2050787364, 0.2086368701, 0.2122307574,
    0.2158605001, 0.2195261997, 0.2232279573, 0.2269658735, 0.2307400485, 0.2345505822, 0.2383975738, 0.2422811225, 0.2462013267, 0.2501582847, 0.2541520943, 0.2581828529, 0.2622506575, 0.2663556048, 0.270497791,  0.2746773121,
    0.2788942635, 0.2831487404, 0.2874408377, 0.2917706498, 0.2961382708, 0.3005437944, 0.3049873141, 0.3094689228, 0.3139887134, 0.3185467781, 0.3231432091, 0.3277780981, 0.3324515363, 0.337163615,  0.3419144249, 0.3467040564,
    0.3515325995, 0.3564001441, 0.3613067798, 0.3662525956, 0.3712376805, 0.376262123,  0.3813260114, 0.3864294338, 0.3915724777, 0.3967552307, 0.4019777798, 0.4072402119, 0.4125426135, 0.4178850708, 0.42326767,   0.4286904966,
    0.4341536362, 0.4396571738, 0.4452011945, 0.4507857828, 0.4564110232, 0.4620769997, 0.4677837961, 0.4735314961, 0.4793201831, 0.4851499401, 0.4910208498, 0.4969329951, 0.502886458,  0.5088813209, 0.5149176654, 0.5209955732,
    0.5271151257, 0.533276404,  0.539479489,  0.5457244614, 0.5520114015, 0.5583403896, 0.5647115057, 0.5711248295, 0.5775804404, 0.5840784179, 0.5906188409, 0.5972017884, 0.6038273389, 0.6104955708, 0.6172065624, 0.6239603917,
    0.6307571363, 0.637596874,  0.644479682,  0.6514056374, 0.6583748173, 0.6653872983, 0.672443157,  0.6795424696, 0.6866853124, 0.6938717613, 0.7011018919, 0.7083757799, 0.7156935005, 0.7230551289, 0.7304607401, 0.7379104088,
    0.7454042095, 0.7529422168, 0.7605245047, 0.7681511472, 0.7758222183, 0.7835377915, 0.7912979403, 0.799102738,  0.8069522577, 0.8148465722, 0.8227857544, 0.8307698768, 0.8387990117, 0.8468732315, 0.8549926081, 0.8631572135,
    0.8713671192, 0.8796223969, 0.8879231179, 0.8962693534, 0.9046611744, 0.9130986518, 0.9215818563, 0.9301108584, 0.9386857285, 0.9473065367, 0.9559733532, 0.9646862479, 0.9734452904, 0.9822505503, 0.9911020971, 1.0,
};

fn sRGBInterleavedToPlanarLinear(
    src: []const u8,
    dst_planes: [3][]f32,
    width: u32,
    height: u32,
    channels: u32,
) void {
    const w = @as(usize, width);
    const h = @as(usize, height);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const idx = (y * w + x) * @as(usize, channels);
            const r = SRGB_LUT[src[idx + 0]];
            const g = SRGB_LUT[src[idx + 1]];
            const b = SRGB_LUT[src[idx + 2]];
            dst_planes[0][y * w + x] = r;
            dst_planes[1][y * w + x] = g;
            dst_planes[2][y * w + x] = b;
        }
    }
}
