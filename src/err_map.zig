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
