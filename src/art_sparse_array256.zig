const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// ART-optimized Sparse Array256 implementation
/// Based on Go BART's sparse.Array256 with popcount compression
/// 
/// This is a generic sparse array for max 256 items with payload T.
/// The BitSet256 and items are tightly coupled - synchronization is critical.
pub fn SparseArray256(comptime T: type) type {
    return struct {
        const Self = @This();

        bitset: BitSet256,
        items: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .bitset = BitSet256.init(),
                .items = std.ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        /// Get the value at i from sparse array.
        /// Returns null if not present.
        /// 
        /// example: a.get(5) -> a.items[1]
        ///                          ⬇
        ///   BitSet256:   [0|0|1|0|0|1|0|...|1] <- 3 bits set
        ///   Items:       [*|*|*]               <- len(items) = 3
        ///                  ⬆
        ///   BitSet256.test(5):  true
        ///   BitSet256.rank(5):  2
        pub fn get(self: *const Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                return self.items.items[rank_idx - 1];
            }
            return null;
        }

        /// MustGet - use only after a successful test
        /// or the behavior is undefined, it will NOT PANIC.
        pub fn mustGet(self: *const Self, i: u8) T {
            const rank_idx = self.bitset.rank(i);
            return self.items.items[rank_idx - 1];
        }

        /// Test if index i is set
        pub fn testBit(self: *const Self, i: u8) bool {
            return self.bitset.isSet(i);
        }

        /// Len returns the number of items in sparse array.
        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        /// InsertAt a value at i into the sparse array.
        /// If the value already exists, overwrite it and return old value.
        /// Returns null if this was a new insertion.
        pub fn insertAt(self: *Self, i: u8, value: T) !?T {
            // Slot exists, overwrite value
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                const old_value = self.items.items[rank_idx - 1];
                self.items.items[rank_idx - 1] = value;
                return old_value;
            }

            // New, insert into bitset first
            self.bitset.set(i);

            // Calculate rank after setting bit
            const rank_idx = self.bitset.rank(i);
            
            // Insert into items array at the correct position
            try self.insertItem(rank_idx - 1, value);

            return null;
        }

        /// DeleteAt a value at i from the sparse array.
        /// Returns the deleted value and true if it existed.
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (!self.bitset.isSet(i)) {
                return null;
            }

            const rank_idx = self.bitset.rank(i);
            const value = self.items.items[rank_idx - 1];

            // Delete from items array
            self.deleteItem(rank_idx - 1);

            // Delete from bitset
            self.bitset.clear(i);

            return value;
        }

        /// UpdateAt or set the value at i via callback.
        /// The new value is returned and true if the value was already present.
        pub fn updateAt(self: *Self, i: u8, comptime cb: fn (T, bool) T) !struct { value: T, old_value: ?T } {
            var rank_idx: usize = undefined;
            var old_value: ?T = null;
            var was_present = false;

            // If already set, get current value
            if (self.bitset.isSet(i)) {
                was_present = true;
                rank_idx = self.bitset.rank(i) - 1;
                old_value = self.items.items[rank_idx];
            }

            // Callback function to get updated or new value
            const new_value = cb(if (was_present) old_value.? else undefined, was_present);

            // Already set, update and return value
            if (was_present) {
                self.items.items[rank_idx] = new_value;
                return .{ .value = new_value, .old_value = old_value };
            }

            // New value, insert into bitset
            self.bitset.set(i);

            // Bitset has changed, recalc rank
            rank_idx = self.bitset.rank(i) - 1;

            // Insert value into slice
            try self.insertItem(rank_idx, new_value);

            return .{ .value = new_value, .old_value = null };
        }

        /// Copy returns a shallow copy of the array.
        /// The elements are copied using assignment, no deep clone.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) !Self {
            var new_items = std.ArrayList(T).init(allocator);
            try new_items.appendSlice(self.items.items);
            
            return .{
                .bitset = self.bitset,
                .items = new_items,
            };
        }

        /// Private: Insert item at index, shift the rest one pos right
        fn insertItem(self: *Self, index: usize, item: T) !void {
            // Ensure we have capacity
            try self.items.ensureUnusedCapacity(1);

            // Resize without initialization (we'll overwrite anyway)
            self.items.items.len += 1;

            // Shift right starting from the end
            var i = self.items.items.len - 1;
            while (i > index) : (i -= 1) {
                self.items.items[i] = self.items.items[i - 1];
            }

            // Insert new item
            self.items.items[index] = item;
        }

        /// Private: Delete item at index, shift the rest one pos left
        fn deleteItem(self: *Self, index: usize) void {
            // Shift left
            var i = index;
            while (i < self.items.items.len - 1) : (i += 1) {
                self.items.items[i] = self.items.items[i + 1];
            }

            // Shrink
            self.items.items.len -= 1;
        }

        /// Iterate over all set indices
        pub fn iterator(self: *const Self) Iterator {
            return .{ .array = self, .next_idx = 0 };
        }

        pub const Iterator = struct {
            array: *const Self,
            next_idx: u16,

            pub fn next(it: *Iterator) ?struct { index: u8, value: T } {
                while (it.next_idx < 256) {
                    const idx = @as(u8, @intCast(it.next_idx));
                    it.next_idx += 1;
                    
                    if (it.array.bitset.isSet(idx)) {
                        const rank_idx = it.array.bitset.rank(idx);
                        return .{
                            .index = idx,
                            .value = it.array.items.items[rank_idx - 1],
                        };
                    }
                }
                return null;
            }
        };
    };
}

test "ART SparseArray256 basic operations" {
    const testing = std.testing;
    var array = SparseArray256(u32).init(testing.allocator);
    defer array.deinit();

    // Test empty
    try testing.expect(array.len() == 0);
    try testing.expect(array.get(0) == null);

    // Test insert
    try testing.expect(try array.insertAt(5, 100) == null); // New
    try testing.expect(array.len() == 1);
    try testing.expect(array.get(5).? == 100);

    // Test overwrite
    try testing.expect(try array.insertAt(5, 200) == 100); // Returns old value
    try testing.expect(array.len() == 1);
    try testing.expect(array.get(5).? == 200);

    // Test multiple inserts
    try testing.expect(try array.insertAt(3, 300) == null);
    try testing.expect(try array.insertAt(7, 400) == null);
    try testing.expect(try array.insertAt(1, 500) == null);
    try testing.expect(array.len() == 4);

    // Verify order in items array (sorted by index due to rank)
    try testing.expect(array.get(1).? == 500);
    try testing.expect(array.get(3).? == 300);
    try testing.expect(array.get(5).? == 200);
    try testing.expect(array.get(7).? == 400);

    // Test delete
    try testing.expect(array.deleteAt(5).? == 200);
    try testing.expect(array.len() == 3);
    try testing.expect(array.get(5) == null);

    // Test iterator
    var it = array.iterator();
    const item1 = it.next().?;
    try testing.expect(item1.index == 1);
    try testing.expect(item1.value == 500);

    const item2 = it.next().?;
    try testing.expect(item2.index == 3);
    try testing.expect(item2.value == 300);

    const item3 = it.next().?;
    try testing.expect(item3.index == 7);
    try testing.expect(item3.value == 400);

    try testing.expect(it.next() == null);
}

test "ART SparseArray256 edge cases" {
    const testing = std.testing;
    var array = SparseArray256(u32).init(testing.allocator);
    defer array.deinit();

    // Test boundary indices
    try testing.expect(try array.insertAt(0, 1000) == null);
    try testing.expect(try array.insertAt(255, 2000) == null);
    try testing.expect(array.len() == 2);

    try testing.expect(array.get(0).? == 1000);
    try testing.expect(array.get(255).? == 2000);

    // Test deletion of non-existent
    try testing.expect(array.deleteAt(100) == null);

    // Test copy
    var copy = try array.copy(testing.allocator);
    defer copy.deinit();

    try testing.expect(copy.len() == 2);
    try testing.expect(copy.get(0).? == 1000);
    try testing.expect(copy.get(255).? == 2000);
} 