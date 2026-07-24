const std = @import("std");
const testing = std.testing;
const sparse_array256 = @import("sparse_array256.zig");
const Array256 = sparse_array256.Array256;

// Test Go BART compatible Get method
test "Go BART compatible Get method" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert some test values
    _ = try a.insertAt(5, 42);
    _ = try a.insertAt(10, 100);
    _ = try a.insertAt(15, 200);

    // Test Get method for existing values
    const result1 = a.Get(5);
    try testing.expect(result1.ok);
    try testing.expectEqual(@as(i32, 42), result1.value);

    const result2 = a.Get(10);
    try testing.expect(result2.ok);
    try testing.expectEqual(@as(i32, 100), result2.value);

    const result3 = a.Get(15);
    try testing.expect(result3.ok);
    try testing.expectEqual(@as(i32, 200), result3.value);

    // Test Get method for non-existing values
    const result4 = a.Get(0);
    try testing.expect(!result4.ok);

    const result5 = a.Get(255);
    try testing.expect(!result5.ok);
}

// Test Go BART compatible Test and Rank methods
test "Go BART compatible Test and Rank methods" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert values at specific positions
    _ = try a.insertAt(1, 10);
    _ = try a.insertAt(5, 50);
    _ = try a.insertAt(10, 100);

    // Test Test method
    try testing.expect(a.Test(1));
    try testing.expect(a.Test(5));
    try testing.expect(a.Test(10));
    try testing.expect(!a.Test(0));
    try testing.expect(!a.Test(7));

    // Test Rank method
    try testing.expectEqual(@as(u8, 1), a.Rank(1));
    try testing.expectEqual(@as(u8, 2), a.Rank(5));
    try testing.expectEqual(@as(u8, 3), a.Rank(10));
}

// Test Go BART compatible MustGet method
test "Go BART compatible MustGet method" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert test values
    _ = try a.insertAt(3, 30);
    _ = try a.insertAt(7, 70);

    // Test MustGet for existing values
    const val1 = a.mustGet(3);
    try testing.expectEqual(@as(i32, 30), val1);

    const val2 = a.mustGet(7);
    try testing.expectEqual(@as(i32, 70), val2);
}

// Test equivalent to Go BART example usage
test "Go BART usage pattern compatibility" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert some values
    _ = try a.insertAt(42, 999);
    _ = try a.insertAt(100, 777);

    // Go BART pattern: if value, ok := a.Get(42); ok { ... }
    const result = a.Get(42);
    if (result.ok) {
        try testing.expectEqual(@as(i32, 999), result.value);
    } else {
        try testing.expect(false); // Should not reach here
    }

    // Go BART pattern: if a.Test(42) { value := a.MustGet(42) }
    if (a.Test(42)) {
        const value = a.mustGet(42);
        try testing.expectEqual(@as(i32, 999), value);
    } else {
        try testing.expect(false); // Should not reach here
    }

    // Test non-existing key
    const empty_result = a.Get(255);
    try testing.expect(!empty_result.ok);
}

// Test equivalent to Go BART TestSparseArrayUpdate
test "sparse array update operations - Go BART compatible" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert items 0-99
    for (0..100) |i| {
        _ = try a.insertAt(@intCast(i), @intCast(i));
    }

    // Simulate Go BART UpdateAt behavior: double existing values
    const DoubleFn = struct {
        fn update(oldVal: i32, existsOld: bool) i32 {
            if (existsOld) {
                return oldVal * 2;
            } else {
                return oldVal;
            }
        }
    };

    for (0..100) |idx| {
        _ = try a.updateAt(@intCast(idx), DoubleFn.update);
    }

    // Add new values (100-150) with value = index * 3
    for (100..151) |idx| {
        _ = try a.insertAt(@intCast(idx), @as(i32, @intCast(idx)) * 3);
    }

    // Check values 0-99 (should be doubled)
    for (0..100) |idx| {
        const result = a.Get(@intCast(idx));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(idx)) * 2, result.value);
    }

    // Check values 100-150 (should be tripled)
    for (100..151) |idx| {
        const result = a.Get(@intCast(idx));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(idx)) * 3, result.value);
    }
}

// ============================================================
// Capacity management harness tests
// ============================================================

test "capacity grows on insert" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // First insert triggers initial capacity allocation (4)
    _ = try a.insertAt(0, 100);
    try testing.expect(a.capacity >= 1);
    try testing.expectEqual(@as(usize, 1), a.len());

    // Fill up to initial capacity (4)
    _ = try a.insertAt(1, 101);
    _ = try a.insertAt(2, 102);
    _ = try a.insertAt(3, 103);
    try testing.expectEqual(@as(usize, 4), a.len());
    try testing.expect(a.capacity >= 4);

    // 5th insert should trigger growth (capacity doubles to 8)
    const old_cap = a.capacity;
    _ = try a.insertAt(4, 104);
    try testing.expectEqual(@as(usize, 5), a.len());
    try testing.expect(a.capacity > old_cap);
    try testing.expect(a.capacity >= 8);
}

test "capacity does not shrink on delete" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert 10 items
    for (0..10) |i| {
        _ = try a.insertAt(@intCast(i), @intCast(i * 10));
    }
    const cap_after_insert = a.capacity;

    // Delete all items
    for (0..10) |i| {
        _ = a.deleteAt(@intCast(i));
    }
    // Capacity should remain, len should be 0
    try testing.expectEqual(@as(usize, 0), a.len());
    try testing.expectEqual(cap_after_insert, a.capacity);
}

test "data integrity across capacity growth" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert 200 items, forcing multiple capacity doublings
    // 4 → 8 → 16 → 32 → 64 → 128 → 256
    for (0..200) |i| {
        _ = try a.insertAt(@intCast(i), @as(i32, @intCast(i * 7)));
    }

    // Verify all values survived the growth
    for (0..200) |i| {
        const result = a.Get(@intCast(i));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(i * 7)), result.value);
    }
}

test "insert and delete interleaved maintains consistency" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    // Insert 50, delete 25, insert 50, check all
    for (0..50) |i| {
        _ = try a.insertAt(@intCast(i), @as(i32, @intCast(i)));
    }
    for (0..25) |i| {
        _ = a.deleteAt(@intCast(i));
    }
    try testing.expectEqual(@as(usize, 25), a.len());

    // Remaining items (25..49) should still be correct
    for (25..50) |i| {
        const result = a.Get(@intCast(i));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(i)), result.value);
    }

    // Insert more
    for (100..150) |i| {
        _ = try a.insertAt(@intCast(i), @as(i32, @intCast(i * 2)));
    }
    try testing.expectEqual(@as(usize, 75), a.len());

    // Check everything
    for (25..50) |i| {
        const result = a.Get(@intCast(i));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(i)), result.value);
    }
    for (100..150) |i| {
        const result = a.Get(@intCast(i));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(i * 2)), result.value);
    }
}

test "deinit after growth frees correctly" {
    // This test verifies no leak when capacity > len at deinit time.
    // testing.allocator (GPA) will detect leaks.
    var a = Array256(i32).init(testing.allocator);

    _ = try a.insertAt(0, 1);
    _ = try a.insertAt(1, 2);
    _ = try a.insertAt(2, 3);
    _ = try a.insertAt(3, 4);
    _ = try a.insertAt(4, 5); // triggers growth to cap=8

    // Delete some (len=2, cap=8)
    _ = a.deleteAt(0);
    _ = a.deleteAt(1);
    _ = a.deleteAt(2);

    try testing.expectEqual(@as(usize, 2), a.len());
    try testing.expect(a.capacity >= 8);

    // deinit should free the full capacity buffer without leak
    a.deinit();
}

test "copy creates independent capacity" {
    var a = Array256(i32).init(testing.allocator);
    defer a.deinit();

    for (0..20) |i| {
        _ = try a.insertAt(@intCast(i), @as(i32, @intCast(i)));
    }

    const b_opt = try Array256(i32).copy(&a, testing.allocator);
    const b = b_opt.?;
    defer {
        b.deinit();
        testing.allocator.destroy(b);
    }

    // Mutate original
    for (0..10) |i| {
        _ = a.deleteAt(@intCast(i));
    }

    // Copy should be unaffected
    for (0..20) |i| {
        const result = b.Get(@intCast(i));
        try testing.expect(result.ok);
        try testing.expectEqual(@as(i32, @intCast(i)), result.value);
    }
}

// ============================================================
// Original tests
// ============================================================

// Test equivalent to Go BART TestSparseArrayCopy
test "sparse array copy operations - Go BART compatible" {
    // Test nil array copy (Go BART: if a.Copy() != nil)
    const a: ?*Array256(i32) = null;
    const null_copy = try Array256(i32).copy(a, testing.allocator);
    try testing.expect(null_copy == null);

    // Create actual array
    var real_a = Array256(i32).init(testing.allocator);
    defer real_a.deinit();

    // Insert 255 items (0-254)
    for (0..255) |i| {
        _ = try real_a.insertAt(@intCast(i), @intCast(i));
    }

    const b_optional = try Array256(i32).copy(&real_a, testing.allocator);
    const b = b_optional.?; // We know it's not null since real_a is not null
    defer {
        b.deinit();
        testing.allocator.destroy(b);
    }

    // Basic values identity (Go BART: for i, v := range a.Items)
    const a_items = real_a.Items();
    const b_items = b.Items();

    for (a_items, 0..) |v, idx| {
        if (b_items[idx] != v) {
            try testing.expect(false); // Clone, expect identical values
        }
    }

    // Update array a (Go BART: a.UpdateAt(uint8(i), func(u int, _ bool) int { return u + 1 }))
    for (0..255) |idx| {
        _ = try real_a.updateAt(@intCast(idx), struct {
            fn update(u: i32, _: bool) i32 {
                return u + 1;
            }
        }.update);
    }

    // Cloned array must now differ (Go BART: if b.Items[i] == v)
    const updated_a_items = real_a.Items();
    const unchanged_b_items = b.Items();

    for (updated_a_items, 0..) |a_val, idx| {
        if (unchanged_b_items[idx] == a_val) {
            try testing.expect(false); // Update a after Clone, b must now differ
        }
    }
}
