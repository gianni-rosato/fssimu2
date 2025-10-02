const std = @import("std");
const math = std.math;

const Color = extern union {
    vals: extern struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8 = 0xFF,
    },
    concat: u32,
};

fn lerp(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) * (1.0 - t) + @as(f32, @floatFromInt(b)) * t);
}

fn turboColor(x: f32) Color {
    const kRedVec4: @Vector(4, f32) = .{ 0.13572138, 4.61539260, -42.66032258, 132.13108234 };
    const kGreenVec4: @Vector(4, f32) = .{ 0.09140261, 2.19418839, 4.84296658, -14.18503333 };
    const kBlueVec4: @Vector(4, f32) = .{ 0.10667330, 12.64194608, -60.58204836, 110.36276771 };
    const kRedVec2: @Vector(2, f32) = .{ -152.94239396, 59.28637943 };
    const kGreenVec2: @Vector(2, f32) = .{ 4.27729857, 2.82956604 };
    const kBlueVec2: @Vector(2, f32) = .{ -89.90310912, 27.34824973 };

    const clamped_x = @max(0.0, @min(1.0, x));
    const v4: @Vector(4, f32) = .{
        1.0,
        clamped_x,
        clamped_x * clamped_x,
        clamped_x * clamped_x * clamped_x,
    };
    const v2 = [2]f32{
        v4[2] * v4[2],
        v4[3] * v4[2],
    };
    const r: f32 = @max(0.0, @min(1.0, @reduce(.Add, kRedVec4 * v4) + @reduce(.Add, kRedVec2 * v2)));
    const g: f32 = @max(0.0, @min(1.0, @reduce(.Add, kGreenVec4 * v4) + @reduce(.Add, kGreenVec2 * v2)));
    const b: f32 = @max(0.0, @min(1.0, @reduce(.Add, kBlueVec4 * v4) + @reduce(.Add, kBlueVec2 * v2)));

    return Color{
        .vals = .{
            .r = @intFromFloat(@round(r * 255.0)),
            .g = @intFromFloat(@round(g * 255.0)),
            .b = @intFromFloat(@round(b * 255.0)),
            .a = 0xFF,
        },
    };
}

pub const TURBO_MAP = blk: {
    @setEvalBranchQuota(2000);
    var map: [256]u32 = undefined;
    for (0..256) |i| {
        const x = @as(f32, @floatFromInt(i)) / 255.0;
        map[i] = turboColor(x).concat;
    }
    break :blk map;
};

pub fn generateErrorMap(error_accum: []const f32, error_map: []u32, stride: u32, w: u32, h: u32) void {
    for (0..h) |y| {
        const row_offset = y * stride;
        const out_row_offset = y * w;
        for (0..w) |x| {
            var ssim = error_accum[row_offset + x];

            ssim = ssim * 0.9562382616834844;
            ssim = 2.326765642916932 * ssim - 0.020884521182843837 * ssim * ssim + 6.248496625763138e-05 * ssim * ssim * ssim;

            if (ssim > 0.0)
                ssim = 100.0 - 10.0 * math.pow(f32, ssim, 0.6276336467831387)
            else
                ssim = 100.0;

            ssim = 1.0 - ssim / 100.0;

            const value: i32 = @intFromFloat(255.0 * @max(0.0, @min(ssim, 1.0)));
            error_map[out_row_offset + x] = TURBO_MAP[@intCast(value)];
        }
    }
}

inline fn bilinearSample(src: []const f32, fx: f32, fy: f32, stride: u32, w: u32, h: u32) f32 {
    const x_scaled = fx * @as(f32, @floatFromInt(w));
    const y_scaled = fy * @as(f32, @floatFromInt(h));

    const x_floor = @floor(x_scaled);
    const y_floor = @floor(y_scaled);

    const fx_frac = x_scaled - x_floor;
    const fy_frac = y_scaled - y_floor;

    const ix0: i32 = @intFromFloat(@max(0.0, @min(x_floor, @as(f32, @floatFromInt(w - 1)))));
    const iy0: i32 = @intFromFloat(@max(0.0, @min(y_floor, @as(f32, @floatFromInt(h - 1)))));
    const ix1: i32 = @intFromFloat(@max(0.0, @min(x_floor + 1.0, @as(f32, @floatFromInt(w - 1)))));
    const iy1: i32 = @intFromFloat(@max(0.0, @min(y_floor + 1.0, @as(f32, @floatFromInt(h - 1)))));

    const f00 = src[@as(usize, @intCast(iy0)) * stride + @as(usize, @intCast(ix0))];
    const f10 = src[@as(usize, @intCast(iy0)) * stride + @as(usize, @intCast(ix1))];
    const f01 = src[@as(usize, @intCast(iy1)) * stride + @as(usize, @intCast(ix0))];
    const f11 = src[@as(usize, @intCast(iy1)) * stride + @as(usize, @intCast(ix1))];

    const lerp0 = f00 * (1.0 - fx_frac) + f10 * fx_frac;
    const lerp1 = f01 * (1.0 - fx_frac) + f11 * fx_frac;

    return lerp0 * (1.0 - fy_frac) + lerp1 * fy_frac;
}

pub fn upscaleAndAccumulate(
    src: []const f32,
    dst: []f32,
    src_stride: u32,
    src_w: u32,
    src_h: u32,
    dst_stride: u32,
    dst_w: u32,
    dst_h: u32,
) void {
    const h_scale: f32 = 1.0 / @as(f32, @floatFromInt(dst_h));
    const w_scale: f32 = 1.0 / @as(f32, @floatFromInt(dst_w));
    for (0..dst_h) |y| {
        const fy = @as(f32, @floatFromInt(y)) * h_scale;
        const row_offset = y * dst_stride;
        for (0..dst_w) |x| {
            const fx = @as(f32, @floatFromInt(x)) * w_scale;
            const value = bilinearSample(src, fx, fy, src_stride, src_w, src_h);
            dst[row_offset + x] += value;
        }
    }
}
