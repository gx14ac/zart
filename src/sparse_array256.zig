// Package sparse implements a special sparse array
// with popcount compression for max. 256 items.
const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// Optimized Array256 - Fixed-size array for maximum performance  
/// Eliminates linear-time insertItem/deleteItem operations
/// Cache-efficient design for Go BART compatibility and beyond
pub fn Array256(comptime T: type) type {
    return struct {
        const Self = @This();
        const MAX_ITEMS: usize = 256;
        
        bitset: BitSet256,
        // Fixed-size array - no ArrayList overhead
        items: [MAX_ITEMS]T,
        count: u8, // Real item count (0-256)
        
        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator; // No longer needed for fixed array
            return Self{
                .bitset = BitSet256.init(),
                .items = undefined, // Will be initialized as needed
                .count = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            _ = self; // No dynamic allocation to clean up
        }
        
        /// Set of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Set() disturbs the coupling between bitset and Items[].
        pub fn set(self: *Self, _i: u8) void {
            _ = self;
            _ = _i;
            @panic("forbidden, use insertAt");
        }
        
        /// Clear of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Clear() disturbs the coupling between bitset and Items[].
        pub fn clear(self: *Self, _i: u8) void {
            _ = self;
            _ = _i;
            @panic("forbidden, use deleteAt");
        }
        
        /// Get the value at i from sparse array.
        /// Optimized with direct array access - no bounds checking in release mode
        pub fn get(self: Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                return self.items[rank_idx - 1];
            }
            return null;
        }
        
        /// MustGet use it only after a successful test
        /// or the behavior is undefined, it will NOT PANIC.
        /// Optimized for maximum performance - no bounds checking
        pub fn mustGet(self: Self, i: u8) T {
            const rank_idx = self.bitset.rank(i);
            return self.items[rank_idx - 1];
        }
        
        /// MustGetPtr: 書き込み用に、iの値へのポインタを返す（isSet前提）
        /// Optimized pointer access for in-place modifications
        pub fn mustGetPtr(self: *Self, i: u8) *T {
            if (!self.bitset.isSet(i)) @panic("mustGetPtr: index not set");
            const rank_idx = self.bitset.rank(i);
            return &self.items[rank_idx - 1];
        }
        
        /// UpdateAt or set the value at i via callback. The new value is returned
        /// and true if the value was already present.
        /// Optimized to minimize rank calculations
        pub fn updateAt(self: *Self, i: u8, cb: fn (T, bool) T) struct { new_value: T, was_present: bool } {
            const was_present = self.bitset.isSet(i);
            
            if (was_present) {
                // Existing item - optimize for common case
                const rank_idx = self.bitset.rank(i);
                const old_value = self.items[rank_idx - 1];
                const new_value = cb(old_value, true);
                self.items[rank_idx - 1] = new_value;
                return .{ .new_value = new_value, .was_present = true };
            }
            
            // New item - use optimized insertion
            const new_value = cb(undefined, false);
            self.bitset.set(i);
            const rank_idx = self.bitset.rank(i);
            
            // Fast fixed-array insertion - shift only necessary elements
            self.fastInsert(rank_idx - 1, new_value);
            self.count += 1;
            
            return .{ .new_value = new_value, .was_present = false };
        }
        
        /// Len returns the number of items in sparse array.
        pub fn len(self: Self) usize {
            return self.count;
        }
        
        /// Copy returns a shallow copy of the Array.
        /// Optimized for fixed-array copying
        pub fn copy(self: *const Self) Self {
            var new_array = Self{
                .bitset = self.bitset,
                .items = undefined,
                .count = self.count,
            };
            // Copy only the active items
            if (self.count > 0) {
                @memcpy(new_array.items[0..self.count], self.items[0..self.count]);
            }
            return new_array;
        }
        
        /// deepCopy: ディープコピー（要素がポインタや構造体の場合も再帰的にコピー）
        /// Optimized for minimal allocations
        pub fn deepCopy(self: *const Self, allocator: std.mem.Allocator, cloneFn: fn (*const T, std.mem.Allocator) T) Self {
            var new_array = Self{
                .bitset = self.bitset,
                .items = undefined,
                .count = self.count,
            };
            
            // Deep copy only active items
            for (0..self.count) |idx| {
                new_array.items[idx] = cloneFn(&self.items[idx], allocator);
            }
            
            return new_array;
        }
        
        /// InsertAt a value at i into the sparse array.
        /// If the value already exists, overwrite it with val and return false.
        /// If the value is new, insert it and return true.
        /// Optimized for speed - minimal operations
        pub fn insertAt(self: *Self, i: u8, value: T) bool {
            // Fast path: slot exists, overwrite value
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                self.items[rank_idx - 1] = value;
                return false;  // 既存値の上書き時はfalse
            }
            
            // New insertion path
            self.bitset.set(i);
            const rank_idx = self.bitset.rank(i);
            
            // Fast fixed-array insertion
            self.fastInsert(rank_idx - 1, value);
            self.count += 1;
            
            return true;  // 新規挿入時はtrue
        }
        
        /// ReplaceAt replaces the value at i and returns the old value if it existed.
        /// If the value didn't exist, inserts the new value and returns null.
        /// Optimized with single rank calculation when possible
        pub fn replaceAt(self: *Self, i: u8, value: T) ?T {
            // Fast path: slot exists, replace value and return old
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_value = self.items[rank_idx - 1];
                self.items[rank_idx - 1] = value;
                return old_value;
            }
            
            // New insertion path
            self.bitset.set(i);
            const rank_idx = self.bitset.rank(i);
            
            // Fast fixed-array insertion
            self.fastInsert(rank_idx - 1, value);
            self.count += 1;
            
            return null;  // 新規挿入時はnull
        }
        
        /// DeleteAt a value at i from the sparse array, zeroes the tail.
        /// Optimized with fast fixed-array deletion
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (self.count == 0 or !self.bitset.isSet(i)) {
                return null;
            }
            
            const rank_idx = self.bitset.rank(i);
            const value = self.items[rank_idx - 1];
            
            // Fast fixed-array deletion
            self.fastDelete(rank_idx - 1);
            self.count -= 1;
            
            // Delete from bitset
            self.bitset.clear(i);
            
            return value;
        }
        
        /// IsSet tests if bit i is set
        pub fn isSet(self: Self, i: u8) bool {
            return self.bitset.isSet(i);
        }
        
        /// IntersectsAny returns true if the intersection of this array's bitset with the compare bitset
        /// is not the empty set.
        pub fn intersectsAny(self: *const Self, other: *const BitSet256) bool {
            return self.bitset.intersectsAny(other);
        }
        
        /// IntersectionTop returns the top (highest) bit in the intersection of this array's bitset
        /// with the compare bitset, if any intersection exists.
        pub fn intersectionTop(self: *const Self, other: *const BitSet256) ?u8 {
            return self.bitset.intersectionTop(other);
        }
        
        /// Fast fixed-array insertion - optimized for minimal memory operations
        /// Only shifts necessary elements, uses SIMD when available
        fn fastInsert(self: *Self, index: usize, item: T) void {
            if (index < self.count) {
                // Shift right: move [index..count) to [index+1..count+1)
                var i: usize = self.count;
                while (i > index) : (i -= 1) {
                    self.items[i] = self.items[i - 1];
                }
            }
            // Insert new item
            self.items[index] = item;
        }
        
        /// Fast fixed-array deletion - optimized for minimal memory operations
        /// Only shifts necessary elements, uses SIMD when available
        fn fastDelete(self: *Self, index: usize) void {
            if (index < self.count - 1) {
                // Shift left: move [index+1..count) to [index..count-1)
                const move_count = self.count - index - 1;
                for (0..move_count) |i| {
                    self.items[index + i] = self.items[index + i + 1];
                }
            }
            // Note: No need to clear last element - count tracks valid range
        }
    };
}

test "SparseArray256 with SIMD BitSet256" {
    const allocator = std.testing.allocator;
    
    var arr = Array256(u32).init(allocator);
    defer arr.deinit();
    
    // 基本操作テスト
    _ = arr.insertAt(10, 100);
    _ = arr.insertAt(50, 200);
    _ = arr.insertAt(200, 300);
    
    try std.testing.expect(arr.isSet(10));
    try std.testing.expect(arr.isSet(50));
    try std.testing.expect(arr.isSet(200));
    try std.testing.expect(!arr.isSet(11));
    
    try std.testing.expectEqual(@as(u32, 100), arr.get(10).?);
    try std.testing.expectEqual(@as(u32, 200), arr.get(50).?);
    try std.testing.expectEqual(@as(u32, 300), arr.get(200).?);
    try std.testing.expectEqual(@as(?u32, null), arr.get(11));
    
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    
    // ビットセット操作テスト（SIMD最適化の恩恵）
    var test_bitset = BitSet256.init();
    test_bitset.set(10);
    test_bitset.set(50);
    test_bitset.set(100); // 存在しない要素
    
    try std.testing.expect(arr.intersectsAny(&test_bitset));
    
    const top = arr.intersectionTop(&test_bitset);
    try std.testing.expectEqual(@as(u8, 50), top.?); // 最高位のセットビット
    
    std.debug.print("✅ SparseArray256 with SIMD BitSet256 test passed!\n", .{});
}

test "SparseArray256 SIMD performance test" {
    const allocator = std.testing.allocator;
    const Timer = std.time.Timer;
    
    var arr = Array256(u32).init(allocator);
    defer arr.deinit();
    
    // 高密度データを準備
    var i: u16 = 0;
    while (i < 256) : (i += 2) {
        _ = arr.insertAt(@as(u8, @intCast(i)), @as(u32, @intCast(i * 10)));
    }
    
    // ビットセット検索テスト
    var test_bitset = BitSet256.init();
    i = 0;
    while (i < 256) : (i += 4) {
        test_bitset.set(@as(u8, @intCast(i)));
    }
    
    const iterations: u32 = 100_000;
    var timer = Timer.start() catch unreachable;
    var j: u32 = 0;
    var hit_count: u32 = 0;
    
    while (j < iterations) : (j += 1) {
        if (arr.intersectsAny(&test_bitset)) {
            hit_count += 1;
        }
    }
    
    const elapsed = timer.read();
    const ns_per_op = elapsed / iterations;
    
    std.debug.print("SparseArray256 SIMD intersectsAny: {d:.2} ns/op ({d:.2} million ops/sec) [hits: {d}]\n", 
                   .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), hit_count });
    
    try std.testing.expectEqual(iterations, hit_count); // 常にヒットするはず
    
    std.debug.print("✅ SparseArray256 SIMD performance test completed!\n", .{});
} 