//! Lookup functions test
//! Direct port from Go BART internal/allot/lookup_test.go

const std = @import("std");
const lookup_fringe = @import("lookup_fringe_routes.zig");
const lookup_prefix = @import("lookup_prefix_routes.zig");
const bitset256 = @import("bitset256.zig");
const BitSet256 = bitset256.BitSet256;

/// Helper function to convert BitSet256 to slice of set bits
fn bitsetToSlice(bitset: *const BitSet256, allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    // Use a temporary buffer for asSlice
    var buf: [256]u8 = undefined;
    const slice = bitset.asSlice(&buf);
    
    try result.appendSlice(slice);
    return result.toOwnedSlice();
}

// Test cases for IdxToFringeRoutes - direct port from Go BART
test "IdxToFringeRoutes" {
    const test_cases = [_]struct {
        idx: u8,
        want: []const u8,
    }{
        .{
            .idx = 0, // invalid
            .want = &[_]u8{},
        },
        .{
            .idx = 63,
            .want = &[_]u8{ 248, 249, 250, 251, 252, 253, 254, 255 },
        },
        .{
            .idx = 127,
            .want = &[_]u8{ 252, 253, 254, 255 },
        },
        .{
            .idx = 128,
            .want = &[_]u8{ 0, 1 },
        },
        .{
            .idx = 199,
            .want = &[_]u8{ 142, 143 },
        },
        .{
            .idx = 255,
            .want = &[_]u8{ 254, 255 },
        },
    };

    for (test_cases) |tc| {
        const bitset = lookup_fringe.idxToFringeRoutes(tc.idx);
        const got = try bitsetToSlice(bitset, std.testing.allocator);
        defer std.testing.allocator.free(got);

        // Check if arrays are equal
        try std.testing.expectEqualSlices(u8, tc.want, got);
    }
}

// Test cases for IdxToPrefixRoutes - direct port from Go BART
test "IdxToPrefixRoutes" {
    const test_cases = [_]struct {
        idx: u8,
        want: []const u8,
    }{
        .{
            .idx = 0, // invalid
            .want = &[_]u8{},
        },
        .{
            .idx = 41,
            .want = &[_]u8{ 41, 82, 83, 164, 165, 166, 167 },
        },
        .{
            .idx = 63,
            .want = &[_]u8{ 63, 126, 127, 252, 253, 254, 255 },
        },
        .{
            .idx = 127,
            .want = &[_]u8{ 127, 254, 255 },
        },
        .{
            .idx = 128,
            .want = &[_]u8{128},
        },
        .{
            .idx = 199,
            .want = &[_]u8{199},
        },
        .{
            .idx = 255,
            .want = &[_]u8{255},
        },
    };

    for (test_cases) |tc| {
        const bitset = lookup_prefix.idxToPrefixRoutes(tc.idx);
        const got = try bitsetToSlice(bitset, std.testing.allocator);
        defer std.testing.allocator.free(got);

        // Check if arrays are equal
        try std.testing.expectEqualSlices(u8, tc.want, got);
    }
}
