const std = @import("std");
const ssimu2 = @import("ssimulacra2.zig");

const SSIMU2_OK: c_int = 0;
const SSIMU2_INVALID_CHANNELS: c_int = 1;
const SSIMU2_OUT_OF_MEMORY: c_int = 2;

export fn ssimulacra2_score(
    reference: [*]const u8,
    distorted: [*]const u8,
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    out_score: *f64,
) callconv(.c) c_int {
    const gpa = std.heap.c_allocator;

    const pixels: usize = @intCast(width * height);
    const expected_len = pixels * @as(usize, channels);

    const ref_slice = reference[0..expected_len];
    const dist_slice = distorted[0..expected_len];

    const result = ssimu2.computeSsimu2(
        gpa,
        ref_slice,
        dist_slice,
        @intCast(width),
        @intCast(height),
        @intCast(channels),
        null,
    );

    if (result) |val| {
        out_score.* = val;
        return SSIMU2_OK;
    } else |err| return switch (err) {
        error.InvalidChannelCount => SSIMU2_INVALID_CHANNELS,
        error.OutOfMemory => SSIMU2_OUT_OF_MEMORY,
    };
}
