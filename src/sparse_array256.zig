// Package sparse implements a special sparse array
// with popcount compression for max. 256 items.
const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// A sparse array with a maximum of 256 items
/// Uses a bitset to track which indices are set
/// and a dynamic array to store the actual values
pub fn Array256(comptime T: type) type {
    return struct {
        const Self = @This();
        
        bitset: BitSet256,
        items: std.ArrayList(T),
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .bitset = BitSet256.init(),
                .items = std.ArrayList(T).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }
        
        /// Set of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Set() disturbs the coupling between bitset and Items[].
        pub fn set(self: *Self, _i: u8) void {
            _ = self;
            _ = _i;
            @panic("forbidden, use insertAt");
        }
        
        /// Clear an entry by index, set the corresponding bit to 0 in the underlying bitset.
        /// Clear of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Clear() disturbs the coupling between bitset and Items[].
        pub fn clear(self: *Self, _i: u8) void {
            _ = self; _ = _i;
            @panic("clear(_i) not implemented yet for sparse_array256");
        }
        
        /// Clear all entries and reset the array to empty state
        pub fn clearAll(self: *Self) void {
            self.bitset = BitSet256.init();
            self.items.clearRetainingCapacity();
        }
        
        /// Get the value at i from sparse array.
        pub fn get(self: Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                return self.items.items[rank_idx - 1];
            }
            return null;
        }
        
        /// MustGet use it only after a successful test
        /// or the behavior is undefined, it will NOT PANIC.
        pub inline fn mustGet(self: Self, i: u8) T {
            const rank_idx = self.bitset.rank(i);
            return self.items.items[rank_idx - 1];
        }
        
        /// MustGetPtr: Get pointer to value at i (assumes isSet)
        pub fn mustGetPtr(self: *Self, i: u8) *T {
            if (!self.bitset.isSet(i)) @panic("mustGetPtr: index not set");
            const rank_idx = self.bitset.rank(i);
            return &self.items.items[rank_idx - 1];
        }
        
        /// Test if index i is set - HOTTEST PATH: Force inline
        pub inline fn isSet(self: Self, i: u8) bool {
            return self.bitset.isSet(i);
        }
        
        /// Length returns the number of items in sparse array
        pub fn len(self: Self) usize {
            return self.items.items.len;
        }
        
        /// Size returns the number of items in sparse array
        pub fn size(self: Self) usize {
            return self.items.items.len;
        }
        
        /// UpdateAt or set the value at i via callback. The new value is returned
        /// and true if the value was already present.
        pub fn updateAt(self: *Self, i: u8, callback: fn (current: ?T) T) bool {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_val = self.items.items[rank_idx - 1];
                self.items.items[rank_idx - 1] = callback(old_val);
                return true;  // Value was already present
            } else {
                // New insertion
                const rank_idx: usize = @as(usize, self.bitset.rank(i));
                self.bitset.set(i);
                
                // Insert at the calculated rank position
                self.items.insert(rank_idx, callback(null)) catch unreachable;
                
                return false;  // New value
            }
        }
        
        /// DeleteAt removes the value at i and returns it if it existed
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (!self.bitset.isSet(i)) {
                return null;
            }
            
            const rank_idx = self.bitset.rank(i) - 1;
            const old_val = self.items.items[rank_idx];
            
            // Remove from items array
            _ = self.items.orderedRemove(rank_idx);
            
            // Clear bit after item removal
            self.bitset.clear(i);
            
            return old_val;
        }
        
        /// Clone creates a deep copy of the sparse array
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) Self {
            var result = Self.init(allocator);
            result.bitset = self.bitset;
            result.items.appendSlice(self.items.items) catch unreachable;
            return result;
        }
        
        /// DeepCopy creates a deep copy using custom clone function
        pub fn deepCopy(self: *const Self, allocator: std.mem.Allocator, cloneFn: fn (*const T, std.mem.Allocator) T) Self {
            var result = Self.init(allocator);
            result.bitset = self.bitset;
            
            // Deep copy items
            for (self.items.items) |*item| {
                result.items.append(cloneFn(item, allocator)) catch unreachable;
            }
            
            return result;
        }
        
        /// InsertAt - High-performance implementation mirroring Go BART
        /// If the value already exists, overwrite it with val and return false.
        /// If the value is new, insert it and return true.
        pub inline fn insertAt(self: *Self, i: u8, value: T) bool {
            if (self.bitset.isSet(i)) {
                // Existing slot - just update value
                const rank_idx = self.bitset.rank(i) - 1;
                self.items.items[rank_idx] = value;
                return false;
            } else {
                // New slot - insert new value efficiently
                const rank_idx = self.bitset.rank(i);
                self.bitset.set(i);
                
                // Go BART style efficient insertion
                self.insertItemEfficient(rank_idx, value);
                
                return true;
            }
        }
        
        /// Efficient item insertion mirroring Go BART's insertItem
        /// Inserts item at index i, shifting the rest one position right
        fn insertItemEfficient(self: *Self, index: usize, item: T) void {
            // Fast resize if we have capacity
            if (self.items.items.len < self.items.capacity) {
                self.items.items.len += 1; // no alloc
            } else {
                // Append one item to grow capacity
                self.items.append(undefined) catch unreachable;
            }
            
            const items_slice = self.items.items;
            
            // Efficient slice operation: shift one slot right, starting at [index]
            if (index < items_slice.len - 1) {
                // equivalent to Go's copy(a.Items[i+1:], a.Items[i:])
                @memcpy(items_slice[index + 1..], items_slice[index..items_slice.len - 1]);
            }
            
            // Insert new item at [index]
            items_slice[index] = item;
        }
        
        /// ReplaceAt replaces the value at i and returns the old value if it existed.
        /// If the value didn't exist, inserts the new value and returns null.
        pub fn replaceAt(self: *Self, i: u8, value: T) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_val = self.items.items[rank_idx - 1];
                self.items.items[rank_idx - 1] = value;
                return old_val;
            } else {
                // Insert new value
                _ = self.insertAt(i, value);
                return null;
            }
        }
        
        /// FirstSet returns the first set bit if any
        pub fn firstSet(self: *const Self) ?u8 {
            return self.bitset.firstSet();
        }
        
        /// NextSet returns the next set bit after the given bit
        pub fn nextSet(self: *const Self, bit: u8) ?u8 {
            return self.bitset.nextSet(bit);
        }
        
        /// IntersectsAny returns true if this array intersects with the given bitset
        pub fn intersectsAny(self: *const Self, other: *const BitSet256) bool {
            return self.bitset.intersectsAny(other);
        }
        
        /// IntersectionTop returns the highest bit in the intersection
        pub fn intersectionTop(self: *const Self, other: *const BitSet256) ?u8 {
            return self.bitset.intersectionTop(other);
        }
    };
}

test "SparseArray256 basic operations" {
    const allocator = std.testing.allocator;
    
    var arr = Array256(u32).init(allocator);
    defer arr.deinit();
    
    // Basic operations test
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
    
    // Bitset operations test (real bit manipulation)
    var test_bitset = BitSet256.init();
    test_bitset.set(10);
    test_bitset.set(50);
    test_bitset.set(100); // Non-existent element
    
    try std.testing.expect(arr.intersectsAny(&test_bitset));
    
    const top = arr.intersectionTop(&test_bitset);
    try std.testing.expectEqual(@as(u8, 50), top.?); // Highest set bit
    
    std.debug.print("✅ SparseArray256 basic operations test passed!\n", .{});
}

test "SparseArray256 performance test" {
    const allocator = std.testing.allocator;
    const Timer = std.time.Timer;
    
    var arr = Array256(u32).init(allocator);
    defer arr.deinit();
    
    // High-density data preparation
    var i: u16 = 0;
    while (i < 256) : (i += 2) {
        _ = arr.insertAt(@as(u8, @intCast(i)), @as(u32, @intCast(i * 10)));
    }
    
    // Bitset search test
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
    
    std.debug.print("SparseArray256 intersectsAny: {d:.2} ns/op ({d:.2} million ops/sec) [hits: {d}]\n", 
                   .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), hit_count });
    
    try std.testing.expectEqual(iterations, hit_count); // Should always hit
    
    std.debug.print("✅ SparseArray256 performance test completed!\n", .{});
} 