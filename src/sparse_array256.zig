// Package sparse implements a special sparse array
// with popcount compression for max. 256 items.
const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// Go BART compatible Array256 - Fixed-size array for maximum performance  
/// Uses popcount compression exactly like Go BART
/// Cache-efficient design for Go BART compatibility and beyond
pub fn Array256(comptime T: type) type {
    return struct {
        const Self = @This();
        const MAX_ITEMS: usize = 256;
        
        bitset: BitSet256,
        // Fixed-size array - no ArrayList overhead
        items: [MAX_ITEMS]T,
        count: u16, // Real item count (0-256), using u16 to prevent overflow
        
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
        
        /// Clear an entry by index, set the corresponding bit to 0 in the underlying bitset.
        /// Clear of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Clear() disturbs the coupling between bitset and Items[].
        pub fn clear(self: *Self, _i: u8) void {
            _ = self; _ = _i;
            @panic("clear(_i) not implemented yet for sparse_array256"); // TODO: Implement clear
        }
        
        /// Clear all entries and reset the array to empty state
        /// Used by memory pool for efficient node reuse
        pub fn clearAll(self: *Self) void {
            self.bitset = BitSet256.init();
            self.count = 0;
            // No need to clear items - count tracks valid range
        }
        
        /// Get the value at i from sparse array.
        /// Go BART compatible implementation
        pub fn get(self: Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                return self.items[rank_idx - 1];
            }
            return null;
        }
        
        /// MustGet use it only after a successful test
        /// or the behavior is undefined, it will NOT PANIC.
        /// Go BART compatible implementation
        pub fn mustGet(self: Self, i: u8) T {
            const rank_idx = self.bitset.rank(i);
            return self.items[rank_idx - 1];
        }
        
        /// MustGetPtr: Get pointer to value at i (assumes isSet)
        /// Go BART compatible pointer access
        pub fn mustGetPtr(self: *Self, i: u8) *T {
            if (!self.bitset.isSet(i)) @panic("mustGetPtr: index not set");
            const rank_idx = self.bitset.rank(i);
            return &self.items[rank_idx - 1];
        }
        
        /// Test if index i is set
        pub fn isSet(self: Self, i: u8) bool {
            return self.bitset.isSet(i);
        }
        
        /// Length returns the number of items in sparse array
        pub fn len(self: Self) usize {
            return self.count;
        }
        
        /// Size returns the number of items in sparse array
        pub fn size(self: Self) usize {
            return self.count;
        }
        
        /// UpdateAt or set the value at i via callback. The new value is returned
        /// and true if the value was already present.
        /// Go BART compatible implementation
        pub fn updateAt(self: *Self, i: u8, callback: fn (current: ?T) T) bool {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_val = self.items[rank_idx - 1];
                self.items[rank_idx - 1] = callback(old_val);
                return true;  // Value was already present
            } else {
                // New insertion
                const rank_idx: usize = @as(usize, self.bitset.rank(i));
                self.bitset.set(i);
                
                // Shift items to make room
                self.shiftRight(rank_idx);
                self.items[rank_idx] = callback(null);
                self.count += 1;
                
                return false;  // New value
            }
        }
        
        /// DeleteAt removes the value at i and returns it if it existed
        /// Go BART compatible implementation
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (!self.bitset.isSet(i)) {
                return null;
            }
            
            const rank_idx = self.bitset.rank(i) - 1;
            const old_val = self.items[rank_idx];
            
            // Clear bit and shift items left
            self.bitset.clear(i);
            self.shiftLeft(rank_idx);
            self.count -= 1;
            
            return old_val;
        }
        
        /// Clone creates a deep copy of the sparse array
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) Self {
            _ = allocator;
            const new_array = Self{
                .bitset = self.bitset,
                .items = self.items,
                .count = self.count,
            };
            return new_array;
        }
        
        /// DeepCopy creates a deep copy using custom clone function
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
        /// Go BART compatible implementation
        pub fn insertAt(self: *Self, i: u8, value: T) bool {
            // Fast path: slot exists, overwrite value
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                self.items[rank_idx - 1] = value;
                return false;  // Existing value overwritten
            }
            
            // New insertion path
            const rank_idx: usize = @as(usize, self.bitset.rank(i));
            self.bitset.set(i);
            
            // Shift items to make room and insert
            self.shiftRight(rank_idx);
            self.items[rank_idx] = value;
            self.count += 1;
            
            return true;  // New insertion
        }
        
        /// ReplaceAt replaces the value at i and returns the old value if it existed.
        /// If the value didn't exist, inserts the new value and returns null.
        /// Go BART compatible implementation
        pub fn replaceAt(self: *Self, i: u8, value: T) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_val = self.items[rank_idx - 1];
                self.items[rank_idx - 1] = value;
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
        
        /// Go BART compatible array shifting - optimized for cache efficiency
        fn shiftRight(self: *Self, index: usize) void {
            if (index >= self.count) {
                return;
            }
            
            const move_count = self.count - index;
            if (move_count == 0) return;
            
            // Shift elements right to make room for new element
            var i: usize = self.count;
            while (i > index) : (i -= 1) {
                self.items[i] = self.items[i - 1];
            }
        }
        
        /// Go BART compatible array shifting - optimized for cache efficiency
        fn shiftLeft(self: *Self, index: usize) void {
            if (index >= self.count) return;
            
            const move_count = self.count - index - 1;
            if (move_count == 0) return;
            
            // Shift elements left to close the gap
            for (0..move_count) |i| {
                self.items[index + i] = self.items[index + i + 1];
            }
        }
    };
}

test "Go BART compatible SparseArray256" {
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
    
    std.debug.print("✅ Go BART compatible SparseArray256 test passed!\n", .{});
}

test "Go BART SparseArray256 performance test" {
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
    
    std.debug.print("SparseArray256 Go BART intersectsAny: {d:.2} ns/op ({d:.2} million ops/sec) [hits: {d}]\n", 
                   .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), hit_count });
    
    try std.testing.expectEqual(iterations, hit_count); // Should always hit
    
    std.debug.print("✅ Go BART SparseArray256 performance test completed!\n", .{});
} 