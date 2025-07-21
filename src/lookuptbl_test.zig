const std = @import("std");
const testing = std.testing;
const lookup_tbl = @import("lookup_tbl.zig");

// Test equivalent to Go BART TestBackTrackingBitset
test "BackTrackingBitset compatibility with Go BART" {
    const TestCase = struct {
        idx: usize,
        want: []const u8,
    };

    const tests = [_]TestCase{
        .{ .idx = 0, .want = &[_]u8{} }, // invalid
        .{ .idx = 1, .want = &[_]u8{1} }, // default route
        .{ .idx = 2, .want = &[_]u8{ 1, 2 } },
        .{ .idx = 3, .want = &[_]u8{ 1, 3 } },
        .{ .idx = 15, .want = &[_]u8{ 1, 3, 7, 15 } },
        .{ .idx = 16, .want = &[_]u8{ 1, 2, 4, 8, 16 } },
        .{ .idx = 509, .want = &[_]u8{ 1, 3, 7, 15, 31, 63, 127, 254 } },
        .{ .idx = 510, .want = &[_]u8{ 1, 3, 7, 15, 31, 63, 127, 255 } },
        .{ .idx = 511, .want = &[_]u8{ 1, 3, 7, 15, 31, 63, 127, 255 } },
        .{ .idx = 512, .want = &[_]u8{} }, // overflow
        .{ .idx = 513, .want = &[_]u8{1} }, // overflow
    };

    for (tests) |tc| {
        const bitset = lookup_tbl.backTrackingBitset(tc.idx);
        const got = try bitset.all(testing.allocator);
        defer testing.allocator.free(got);

        // Compare arrays
        try testing.expectEqual(tc.want.len, got.len);
        for (tc.want, 0..) |expected, i| {
            try testing.expectEqual(expected, got[i]);
        }
    }
}
