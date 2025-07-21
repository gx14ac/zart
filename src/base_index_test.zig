//! Test for base_index.zig - Go BART compatibility tests
//!
//! All test cases are identical to Go BART's base_index_test.go
//! to ensure 100% compatibility

const std = @import("std");
const base_index = @import("base_index.zig");

// Test equivalent to Go BART TestIdx256OutOfBounds
test "Idx256OutOfBounds - idxToPfx256(0)" {
    try std.testing.expectError(error.InvalidIndex, base_index.idxToPfx256(0));
}

test "Idx256OutOfBounds - pfxLen256(0,0)" {
    try std.testing.expectError(error.InvalidIndex, base_index.pfxLen256(0, 0));
}

// Test hostIdx function (equivalent to Go BART TestHostIdx)
test "hostIdx compatibility with Go BART" {
    const testCases = [_]struct {
        octet: u8,
        want: usize,
    }{
        .{ .octet = 0, .want = 256 },
        .{ .octet = 255, .want = 511 },
    };

    for (testCases) |tc| {
        const got = base_index.hostIdx(tc.octet);
        try std.testing.expectEqual(tc.want, got);
    }
}

// Test pfxLen256 function (equivalent to Go BART TestPfxLen256)
test "pfxLen256 compatibility with Go BART" {
    const testCases = [_]struct {
        depth: i32,
        idx: u8,
        want: u8,
    }{
        .{ .depth = 0, .idx = 1, .want = 0 },
        .{ .depth = 0, .idx = 19, .want = 4 },
        .{ .depth = 15, .idx = 19, .want = 124 },
    };

    for (testCases) |tc| {
        const got = try base_index.pfxLen256(tc.depth, tc.idx);
        try std.testing.expectEqual(tc.want, got);
    }
}

// Test pfxToIdx function (equivalent to Go BART TestPfxToIdx)
test "pfxToIdx compatibility with Go BART" {
    const testCases = [_]struct {
        octet: u8,
        pfx_len: u8,
        want: usize,
    }{
        .{ .octet = 0, .pfx_len = 0, .want = 1 },
        .{ .octet = 0, .pfx_len = 1, .want = 2 },
        .{ .octet = 128, .pfx_len = 1, .want = 3 },
        .{ .octet = 80, .pfx_len = 4, .want = 21 },
        .{ .octet = 254, .pfx_len = 7, .want = 255 },
        .{ .octet = 255, .pfx_len = 7, .want = 255 },
        .{ .octet = 0, .pfx_len = 8, .want = 256 },
        .{ .octet = 255, .pfx_len = 8, .want = 511 },
    };

    for (testCases) |tc| {
        const got = base_index.pfxToIdx(tc.octet, tc.pfx_len);
        try std.testing.expectEqual(tc.want, got);
    }
}

// Test pfxToIdx256 function (equivalent to Go BART TestPfxToIdx256)
test "pfxToIdx256 compatibility with Go BART" {
    const testCases = [_]struct {
        octet: u8,
        pfx_len: u8,
        want: u8,
    }{
        .{ .octet = 0, .pfx_len = 0, .want = 1 },
        .{ .octet = 0, .pfx_len = 1, .want = 2 },
        .{ .octet = 128, .pfx_len = 1, .want = 3 },
        .{ .octet = 80, .pfx_len = 4, .want = 21 },
        .{ .octet = 255, .pfx_len = 7, .want = 255 },
        // pfx_len 8, idx gets shifted >> 1
        .{ .octet = 0, .pfx_len = 8, .want = 128 },
        .{ .octet = 255, .pfx_len = 8, .want = 255 },
    };

    for (testCases) |tc| {
        const got = base_index.pfxToIdx256(tc.octet, tc.pfx_len);
        try std.testing.expectEqual(tc.want, got);
    }
}

// Test idxToPfx256 function (equivalent to Go BART TestIdxToPfx256)
test "idxToPfx256 compatibility with Go BART" {
    const testCases = [_]struct {
        idx: u8,
        want_octet: u8,
        want_pfx_len: u8,
    }{
        .{ .idx = 1, .want_octet = 0, .want_pfx_len = 0 },
        .{ .idx = 15, .want_octet = 224, .want_pfx_len = 3 },
        .{ .idx = 255, .want_octet = 254, .want_pfx_len = 7 },
    };

    for (testCases) |tc| {
        const result = try base_index.idxToPfx256(tc.idx);
        try std.testing.expectEqual(tc.want_octet, result.octet);
        try std.testing.expectEqual(tc.want_pfx_len, result.pfx_len);
    }
}

// Test idxToRange256 function (equivalent to Go BART TestIdxToRange256)
test "idxToRange256 compatibility with Go BART" {
    const testCases = [_]struct {
        idx: u8,
        want_first: u8,
        want_last: u8,
    }{
        .{ .idx = 1, .want_first = 0, .want_last = 255 },
        .{ .idx = 2, .want_first = 0, .want_last = 127 },
        .{ .idx = 3, .want_first = 128, .want_last = 255 },
        .{ .idx = 4, .want_first = 0, .want_last = 63 },
        .{ .idx = 8, .want_first = 0, .want_last = 31 },
        .{ .idx = 81, .want_first = 68, .want_last = 71 },
        .{ .idx = 254, .want_first = 252, .want_last = 253 },
        .{ .idx = 255, .want_first = 254, .want_last = 255 },
    };

    for (testCases) |tc| {
        const result = try base_index.idxToRange256(tc.idx);
        try std.testing.expectEqual(tc.want_first, result.first);
        try std.testing.expectEqual(tc.want_last, result.last);
    }
}
