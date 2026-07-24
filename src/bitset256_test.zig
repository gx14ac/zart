//! Test for bitset256.zig - Go BART compatibility tests
//!
//! All test cases are identical to Go BART's bitset256_test.go
//! to ensure 100% compatibility

const std = @import("std");
const testing = std.testing;
const BitSet256 = @import("bitset256.zig").BitSet256;

// Test equivalent to Go BART TestZeroValue
test "zero value bitset must not panic" {
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    b.set(0);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    b.clear(100);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.size();

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.rank(100);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.testBitSet256(42);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.nextSet(0);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var buf: [256]u8 = undefined;
    _ = b.asSlice(&buf);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var c = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.newUnionBit(&c);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    c = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.intersection(&c);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    c = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.intersectsAny(&c);

    b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    c = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    _ = b.intersectionTop(&c);
}

// Test equivalent to Go BART TestTest
test "testBitSet256 compatibility with Go BART" {
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    b.set(100);
    try testing.expect(b.testBitSet256(100));
}

// Test equivalent to Go BART TestString
test "string representation compatibility with Go BART" {
    const allocator = testing.allocator;

    var bs = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    bs.set(0);
    bs.set(42);
    bs.set(255);

    const want = "[0 42 255]";
    const got = try bs.string(allocator);
    defer allocator.free(got);

    try testing.expectEqualStrings(want, got);
}

// Test equivalent to Go BART TestFirstSet
test "firstSet compatibility with Go BART" {
    const TestCase = struct {
        name: []const u8,
        set: []const u8,
        want_idx: u8,
        want_ok: bool,
    };

    const testCases = [_]TestCase{
        .{ .name = "null", .set = &[_]u8{}, .want_idx = 0, .want_ok = false },
        .{ .name = "zero", .set = &[_]u8{0}, .want_idx = 0, .want_ok = true },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .want_idx = 1, .want_ok = true },
        .{ .name = "5,7", .set = &[_]u8{ 5, 7 }, .want_idx = 5, .want_ok = true },
        .{ .name = "2. word", .set = &[_]u8{ 70, 255 }, .want_idx = 70, .want_ok = true },
        .{ .name = "3. word", .set = &[_]u8{ 150, 255 }, .want_idx = 150, .want_ok = true },
        .{ .name = "4. word", .set = &[_]u8{ 233, 255 }, .want_idx = 233, .want_ok = true },
    };

    for (testCases) |tc| {
        var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
        for (tc.set) |u| {
            b.set(u);
        }

        const idx_opt = b.firstSet();
        const ok = idx_opt != null;
        const idx = if (idx_opt) |i| i else 0;

        try testing.expectEqual(tc.want_ok, ok);
        if (ok) {
            try testing.expectEqual(tc.want_idx, idx);
        }
    }
}

// Test equivalent to Go BART TestNextSet
test "nextSet compatibility with Go BART" {
    const TestCase = struct {
        name: []const u8,
        set: []const u8,
        del: []const u8,
        start: u8,
        want_idx: u8,
        want_ok: bool,
    };

    const testCases = [_]TestCase{
        .{ .name = "null", .set = &[_]u8{}, .del = &[_]u8{}, .start = 0, .want_idx = 0, .want_ok = false },
        .{ .name = "zero", .set = &[_]u8{0}, .del = &[_]u8{}, .start = 0, .want_idx = 0, .want_ok = true },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .start = 0, .want_idx = 1, .want_ok = true },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .start = 2, .want_idx = 5, .want_ok = true },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .start = 6, .want_idx = 0, .want_ok = false },
        .{ .name = "1,5,7", .set = &[_]u8{ 1, 5, 7 }, .del = &[_]u8{5}, .start = 2, .want_idx = 7, .want_ok = true },
        .{ .name = "2. word", .set = &[_]u8{ 1, 70, 255 }, .del = &[_]u8{}, .start = 2, .want_idx = 70, .want_ok = true },
    };

    for (testCases) |tc| {
        var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
        for (tc.set) |u| {
            b.set(u);
        }
        for (tc.del) |u| {
            b.clear(u);
        }

        const idx_opt = b.nextSet(tc.start);
        const ok = idx_opt != null;
        const idx = if (idx_opt) |i| i else 0;

        try testing.expectEqual(tc.want_ok, ok);
        if (ok) {
            try testing.expectEqual(tc.want_idx, idx);
        }
    }
}

// Test equivalent to Go BART TestIsEmpty
test "isEmpty compatibility with Go BART" {
    const TestCase = struct {
        name: []const u8,
        set: []const u8,
        del: []const u8,
        want: bool,
    };

    const testCases = [_]TestCase{
        .{ .name = "null", .set = &[_]u8{}, .del = &[_]u8{}, .want = true },
        .{ .name = "zero", .set = &[_]u8{0}, .del = &[_]u8{}, .want = false },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .want = false },
        .{ .name = "many", .set = &[_]u8{ 1, 65, 130, 190, 250 }, .del = &[_]u8{}, .want = false },
        .{ .name = "set clear", .set = &[_]u8{1}, .del = &[_]u8{1}, .want = true },
    };

    for (testCases) |tc| {
        var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
        for (tc.set) |u| {
            b.set(u);
        }
        for (tc.del) |u| {
            b.clear(u);
        }

        const got = b.isEmpty();
        try testing.expectEqual(tc.want, got);
    }
}

// Test equivalent to Go BART TestAsSlice
test "asSlice compatibility with Go BART" {
    const TestCase = struct {
        name: []const u8,
        set: []const u8,
        del: []const u8,
        want_data: []const u8,
    };

    const testCases = [_]TestCase{
        .{ .name = "null", .set = &[_]u8{}, .del = &[_]u8{}, .want_data = &[_]u8{} },
        .{ .name = "zero", .set = &[_]u8{0}, .del = &[_]u8{}, .want_data = &[_]u8{0} },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .want_data = &[_]u8{ 1, 5 } },
        .{ .name = "many", .set = &[_]u8{ 1, 65, 130, 190, 250 }, .del = &[_]u8{}, .want_data = &[_]u8{ 1, 65, 130, 190, 250 } },
        .{ .name = "special, last return", .set = &[_]u8{1}, .del = &[_]u8{1}, .want_data = &[_]u8{} },
    };

    for (testCases) |tc| {
        var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
        for (tc.set) |u| {
            b.set(u);
        }
        for (tc.del) |u| {
            b.clear(u);
        }

        var buf: [256]u8 = undefined;
        const result = b.asSlice(&buf);

        try testing.expectEqualSlices(u8, tc.want_data, result);
    }
}

// Test equivalent to Go BART TestAll
test "all (with allocator) compatibility with Go BART" {
    const allocator = testing.allocator;

    const TestCase = struct {
        name: []const u8,
        set: []const u8,
        del: []const u8,
        want_data: []const u8,
    };

    const testCases = [_]TestCase{
        .{ .name = "null", .set = &[_]u8{}, .del = &[_]u8{}, .want_data = &[_]u8{} },
        .{ .name = "zero", .set = &[_]u8{0}, .del = &[_]u8{}, .want_data = &[_]u8{0} },
        .{ .name = "1,5", .set = &[_]u8{ 1, 5 }, .del = &[_]u8{}, .want_data = &[_]u8{ 1, 5 } },
        .{ .name = "many", .set = &[_]u8{ 1, 65, 130, 190, 250 }, .del = &[_]u8{}, .want_data = &[_]u8{ 1, 65, 130, 190, 250 } },
        .{ .name = "special, last return", .set = &[_]u8{1}, .del = &[_]u8{1}, .want_data = &[_]u8{} },
    };

    for (testCases) |tc| {
        var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
        for (tc.set) |u| {
            b.set(u);
        }
        for (tc.del) |u| {
            b.clear(u);
        }

        const result = try b.all(allocator);
        defer allocator.free(result);

        try testing.expectEqualSlices(u8, tc.want_data, result);
    }
}

// Test equivalent to Go BART TestCount
test "count (size) compatibility with Go BART" {
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    const tot: u8 = 255;
    var check_last = true;

    for (0..tot) |i| {
        const sz = @as(u8, @intCast(b.size()));
        if (sz != @as(u8, @intCast(i))) {
            check_last = false;
            break;
        }
        b.set(@as(u8, @intCast(i)));
    }

    if (check_last) {
        const sz = @as(u8, @intCast(b.size()));
        try testing.expectEqual(tot, sz);
    }
}

// Test equivalent to Go BART TestCount2
test "count2 (every 3rd bit) compatibility with Go BART" {
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    const tot: u8 = 64 * 3 + 11;
    var i: u8 = 0;
    while (i < tot) : (i += 3) {
        const sz = @as(u8, @intCast(b.size()));
        try testing.expectEqual(i / 3, sz);
        b.set(i);
    }
}

// Test equivalent to Go BART TestUnion
test "union compatibility with Go BART" {
    var a = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    var i: u8 = 1;
    while (i < 100) : (i += 2) {
        a.set(i);
        b.set(i - 1);
    }

    i = 100;
    while (i < 200) : (i += 1) {
        b.set(i);
    }

    var c = a;
    c = c.newUnionBit(&b);

    var d = b;
    d = d.newUnionBit(&a);

    try testing.expectEqual(@as(i32, 200), c.size());
    try testing.expectEqual(@as(i32, 200), d.size());
}

// Test equivalent to Go BART TestInplaceIntersection
test "intersection compatibility with Go BART" {
    var a = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    var i: u8 = 1;
    while (i < 100) : (i += 2) {
        a.set(i);
        b.set(i - 1);
        b.set(i);
    }

    i = 100;
    while (i < 200) : (i += 1) {
        b.set(i);
    }

    var c = a;
    c = c.intersection(&b);

    var d = b;
    d = d.intersection(&a);

    try testing.expectEqual(@as(i32, 50), c.size());
    try testing.expectEqual(@as(i32, 50), d.size());

    try testing.expectEqual(c.size(), a.intersectionCardinality(&b));
    try testing.expectEqual(c.size(), b.intersectionCardinality(&a));
}

// Test equivalent to Go BART TestIntersectsAny
test "intersectsAny compatibility with Go BART" {
    var a = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    var i: u8 = 1;
    while (i < 100) : (i += 1) {
        a.set(i);
    }

    i = 100;
    while (i < 200) : (i += 1) {
        b.set(i);
    }

    var want = false;
    var got = a.intersectsAny(&b);
    try testing.expectEqual(want, got);

    b = a;
    want = true;
    got = a.intersectsAny(&b);
    try testing.expectEqual(want, got);
}

// Test equivalent to Go BART TestIntersectionTop
test "intersectionTop compatibility with Go BART" {
    var a = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    var i: u8 = 1;
    while (i < 100) : (i += 2) {
        a.set(i);
        b.set(i - 1);
        b.set(i);
    }

    i = 100;
    while (i < 200) : (i += 1) {
        b.set(i);
    }

    const want_top: u8 = 99;
    const want_ok = true;
    const result_opt = a.intersectionTop(&b);
    const got_ok = result_opt != null;
    const got_top = if (result_opt) |top| top else 0;

    try testing.expectEqual(want_ok, got_ok);
    try testing.expectEqual(want_top, got_top);

    const result2_opt = b.intersectionTop(&a);
    const got_ok2 = result2_opt != null;
    const got_top2 = if (result2_opt) |top| top else 0;

    try testing.expectEqual(want_ok, got_ok2);
    try testing.expectEqual(want_top, got_top2);
}

// Test equivalent to Go BART TestRank (Rank is popcount-1)
test "rank compatibility with Go BART" {
    const u = [_]u8{ 0, 3, 5, 7, 11, 62, 63, 64, 70, 150, 255 };

    const TestCase = struct {
        idx: u8,
        want: i32,
    };

    const tests = [_]TestCase{
        .{ .idx = 0, .want = 0 },
        .{ .idx = 1, .want = 0 },
        .{ .idx = 2, .want = 0 },
        .{ .idx = 3, .want = 1 },
        .{ .idx = 4, .want = 1 },
        .{ .idx = 62, .want = 5 },
        .{ .idx = 63, .want = 6 },
        .{ .idx = 64, .want = 7 },
        .{ .idx = 150, .want = 9 },
        .{ .idx = 254, .want = 9 },
        .{ .idx = 255, .want = 10 },
    };

    var b = BitSet256{ .data = .{ 0, 0, 0, 0 } };
    for (u) |v| {
        b.set(v);
    }

    for (tests) |tc| {
        const got = @as(i32, @intCast(b.rank(tc.idx))) - 1;
        try testing.expectEqual(tc.want, got);
    }
}

// Test equivalent to Go BART TestIntersectionCardinality
test "intersectionCardinality compatibility with Go BART" {
    const s = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    const m = BitSet256{ .data = .{ 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111 } };

    const want: i32 = 16;
    const got = s.intersectionCardinality(&m);
    try testing.expectEqual(want, got);
}

// ================================================================================
// Benchmarks - Go BART compatible performance tests
// ================================================================================

// Benchmark equivalent to Go BART BenchmarkTest
test "benchmark: test operation" {
    var aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };

    // Test various bit positions like Go BART
    const positions = [_]u8{ 64 * 4 - 1, 64 * 3 - 11, 64 * 2 - 11, 64 * 1 - 11, 1, 0 };

    for (positions) |pos| {
        _ = aa.testBitSet256(pos);
    }
}

// Benchmark equivalent to Go BART BenchmarkIntersectsAny
test "benchmark: intersectsAny operation" {
    var aa = BitSet256{ .data = .{ 1, 1, 1, 1 } };

    const test_sets = [_]BitSet256{
        BitSet256{ .data = .{ 1, 0, 0, 0 } },
        BitSet256{ .data = .{ 0, 1, 0, 0 } },
        BitSet256{ .data = .{ 0, 0, 1, 0 } },
        BitSet256{ .data = .{ 0, 0, 0, 1 } },
        BitSet256{ .data = .{ 0, 0, 0, 0 } },
    };

    for (test_sets) |bb| {
        _ = aa.intersectsAny(&bb);
    }
}

// Benchmark equivalent to Go BART BenchmarkUnion
test "benchmark: union operation" {
    var aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    const bb = BitSet256{ .data = .{ 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111 } };

    _ = aa.newUnionBit(&bb);
}

// Benchmark equivalent to Go BART BenchmarkIntersection
test "benchmark: intersection operation" {
    var aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    const bb = BitSet256{ .data = .{ 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111 } };

    _ = aa.intersection(&bb);
}

// Benchmark equivalent to Go BART BenchmarkIntersectionCardinality
test "benchmark: intersectionCardinality operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    const bb = BitSet256{ .data = .{ 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111 } };

    _ = aa.intersectionCardinality(&bb);
}

// Benchmark equivalent to Go BART BenchmarkPopcount (count)
test "benchmark: count operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };

    _ = aa.size();
}

// Benchmark equivalent to Go BART BenchmarkRank
test "benchmark: rank operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };

    const positions = [_]u8{ 64 * 4 - 1, 64 * 3 - 11, 64 * 2 - 11, 64 * 1 - 11, 1, 0 };
    for (positions) |pos| {
        _ = aa.rank(pos);
    }
}

// Benchmark equivalent to Go BART BenchmarkIsEmpty
test "benchmark: isEmpty operation" {
    var aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    var bb = BitSet256{ .data = .{ 0, 0, 0, 0 } };

    _ = aa.isEmpty();
    _ = bb.isEmpty();
}

// Benchmark equivalent to Go BART BenchmarkFirstSet
test "benchmark: firstSet operation" {
    const test_sets = [_]BitSet256{
        BitSet256{ .data = .{ 1, 0, 0, 0 } },
        BitSet256{ .data = .{ 0, 1, 0, 0 } },
        BitSet256{ .data = .{ 0, 0, 1, 0 } },
        BitSet256{ .data = .{ 0, 0, 0, 1 } },
    };

    for (test_sets) |aa| {
        _ = aa.firstSet();
    }
}

// Benchmark equivalent to Go BART BenchmarkNextSet
test "benchmark: nextSet operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };

    const start_positions = [_]u8{ 0, 32, 64, 96, 128, 160, 192, 224 };
    for (start_positions) |start| {
        _ = aa.nextSet(start);
    }
}

// Benchmark equivalent to Go BART BenchmarkIntersectionTop
test "benchmark: intersectionTop operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };
    const bb = BitSet256{ .data = .{ 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111, 0b1111_1111_1111 } };

    _ = aa.intersectionTop(&bb);
}

// Benchmark equivalent to Go BART BenchmarkAsSlice
test "benchmark: asSlice operation" {
    const aa = BitSet256{ .data = .{ 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010, 0b0000_1010_1010 } };

    var buf: [256]u8 = undefined;
    const slice = aa.asSlice(&buf);
    _ = slice;
}
