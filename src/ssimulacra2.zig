const std = @import("std");
const math = std.math;
const scl = @import("linearlight.zig");

// SSIMULACRA2 Metric Implementation

pub const Ssimu2Error = error{
    InvalidChannelCount,
    OutOfMemory,
};

const K_SIZE = 9;
const RADIUS = 4;

pub fn computeSsimu2(
    allocator: std.mem.Allocator,
    reference: []const u8,
    distorted: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) Ssimu2Error!f64 {
    if (channels != 3 and channels != 4) return Ssimu2Error.InvalidChannelCount;

    const pixels = @as(usize, width) * @as(usize, height);
    const expected_len = pixels * @as(usize, channels);

    std.debug.assert(reference.len >= expected_len);
    std.debug.assert(distorted.len >= expected_len);

    const stride: u32 = width;

    const plane_size: usize = pixels;
    const total_floats: usize = plane_size * 3 * 2;
    var planes: []f32 = try allocator.alignedAlloc(f32, .of(f32), total_floats);
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

    scl.sRGBInterleavedToPlanarLinear(reference, ref_planes, width, height, channels);
    scl.sRGBInterleavedToPlanarLinear(distorted, dist_planes, width, height, channels);

    const ref_const: [3][]const f32 = .{
        ref_planes[0], ref_planes[1], ref_planes[2],
    };
    const dist_const: [3][]const f32 = .{
        dist_planes[0], dist_planes[1], dist_planes[2],
    };

    return process(allocator, ref_const, dist_const, stride, width, height);
}

inline fn multiply(src1: []const f32, src2: []const f32, dst: []f32, stride: u32, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            dst[row + x] = src1[row + x] * src2[row + x];
        }
    }
}

fn blurH(srcp: []f32, dstp: []f32, kernel: [K_SIZE]f32, w: i32) void {
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

    j = RADIUS;
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

fn gaussianKernel(kernel: []f32, radius: usize, sigma: f32) void {
    const size = kernel.len;
    const scaler: f32 = -1.0 / (2.0 * sigma * sigma);
    var sum: f32 = 0.0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        const val = @as(f32, math.exp(@as(f64, scaler * x * x)));
        kernel[i] = val;
        sum += val;
    }
    i = 0;
    while (i < size) : (i += 1) {
        kernel[i] /= sum;
    }
}

fn convolveXSampleAndTranspose(src: []const f32, out: []f32, xs: u32, ys: u32, kernel: []const f32) void {
    const size = kernel.len;
    const r = size / 2;
    var y: u32 = 0;
    while (y < ys) : (y += 1) {
        const row_off = @as(usize, y) * @as(usize, xs);
        var x: i32 = 0;
        while (x < @as(i32, @intCast(xs))) : (x += 1) {
            var sum: f32 = 0.0;
            var k: i32 = 0;
            const r_i32 = @as(i32, @intCast(r));
            while (k < @as(i32, @intCast(size))) : (k += 1) {
                const xi = x + k - r_i32;
                const id = if (xi < 0) 0 else if (xi >= @as(i32, @intCast(xs))) xs - 1 else @as(u32, @intCast(xi));
                sum += src[row_off + id] * kernel[@intCast(k)];
            }
            // transpose write
            out[@as(usize, @intCast(x)) * @as(usize, ys) + @as(usize, y)] = sum;
        }
    }
}

fn slowGaussian(src: []const f32, tmp: []f32, dst: []f32, xs: u32, ys: u32, kernel: []const f32) void {
    convolveXSampleAndTranspose(src, tmp, xs, ys, kernel);
    convolveXSampleAndTranspose(tmp, dst, ys, xs, kernel);
}

inline fn blurV(src: anytype, dstp: []f32, kernel: [K_SIZE]f32, w: u32) void {
    var j: u32 = 0;
    while (j < w) : (j += 1) {
        var accum: f32 = 0.0;
        var k: u32 = 0;
        while (k < K_SIZE) : (k += 1) {
            accum += kernel[k] * src[k][j];
        }
        dstp[j] = accum;
    }
}

inline fn blur(src: []const f32, dst: []f32, w: u32, h: u32, tmp: []f32) void {
    var kernel: [9]f32 = [_]f32{
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
    slowGaussian(src, tmp, dst, w, h, &kernel);
}

const K_D0: f32 = 0.0037930734;
const K_D1: f32 = std.math.lossyCast(f32, math.cbrt(@as(f32, K_D0)));

const V00 = 0.0;
const V05 = 0.5;
const V10 = 1.0;

const V001 = 0.01;
const V055 = 0.55;
const V042 = 0.42;
const V140 = 14.0;

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
const OPSIN_ABSORBANCE_BIAS: f32 = @as(f32, K_D0);
const ABSORBANCE_BIAS: f32 = @as(f32, -K_D1);

inline fn cbrtVec(x: f32) f32 {
    return std.math.lossyCast(f32, math.cbrt(@as(f32, x)));
}

inline fn opsinAbsorbance(rgb: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    out[0] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[0], rgb[0], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[1], rgb[1], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[2], rgb[2], OPSIN_ABSORBANCE_BIAS)));
    out[1] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[3], rgb[0], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[4], rgb[1], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[5], rgb[2], OPSIN_ABSORBANCE_BIAS)));
    out[2] = @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[6], rgb[0], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[7], rgb[1], @mulAdd(f32, OPSIN_ABSORBANCE_MATRIX[8], rgb[2], OPSIN_ABSORBANCE_BIAS)));
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

fn process(
    allocator: std.mem.Allocator,
    srcp1: [3][]const f32,
    srcp2: [3][]const f32,
    stride: u32,
    w: u32,
    h: u32,
) f64 {
    const wh: u32 = stride * h;
    const temp_alloc = allocator.alignedAlloc(f32, .of(f32), wh * 18) catch unreachable;
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

    // Single scratch buffer for all blurs
    const scratch = allocator.alignedAlloc(f32, .of(f32), wh) catch unreachable;
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
            blur(tmpp3, tmpps11, w2, h2, scratch);

            multiply(tmpp2[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
            blur(tmpp3, tmpps22, w2, h2, scratch);

            multiply(tmpp1[plane], tmpp2[plane], tmpp3, stride2, w2, h2);
            blur(tmpp3, tmpps12, w2, h2, scratch);

            blur(tmpp1[plane], tmppmu1, w2, h2, scratch);
            blur(tmpp2[plane], tmpp3, w2, h2, scratch);

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
