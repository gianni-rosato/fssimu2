const std = @import("std");
const math = std.math;

// sRGB to Linear Light scaling for proper metric computation

fn makeSRGBToLinearLUT() [256]f16 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    var lut: [256]f16 = undefined;
    for (0..256) |i| {
        const c: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        const linear = if (c <= 0.04045) c / 12.92 else math.pow(f32, (c + 0.055) / 1.055, 2.4);
        lut[i] = @floatCast(linear);
    }
    return lut;
}

const SRGB_LUT: [256]f16 = makeSRGBToLinearLUT();

pub fn sRGBInterleavedToPlanarLinear(
    src: []const u8,
    dst_planes: [3][]f16,
    width: u32,
    height: u32,
    channels: u32,
) void {
    const w = @as(usize, width);
    const h = @as(usize, height);
    for (0..h) |y|
        for (0..w) |x| {
            const idx = (y * w + x) * @as(usize, channels);
            const r = SRGB_LUT[src[idx + 0]];
            const g = SRGB_LUT[src[idx + 1]];
            const b = SRGB_LUT[src[idx + 2]];
            dst_planes[0][y * w + x] = r;
            dst_planes[1][y * w + x] = g;
            dst_planes[2][y * w + x] = b;
        };
}
