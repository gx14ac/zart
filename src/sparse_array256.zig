// Package sparse implements a special sparse array
// with popcount compression for max. 256 items.
const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// Array256 is a generic implementation of a sparse array
/// with popcount compression for max. 256 items with payload T.
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
        
        /// Clear of the underlying bitset is forbidden. The bitset and the items are coupled.
        /// An unsynchronized Clear() disturbs the coupling between bitset and Items[].
        pub fn clear(self: *Self, _i: u8) void {
            _ = self;
            _ = _i;
            @panic("forbidden, use deleteAt");
        }
        
        /// Get the value at i from sparse array.
        ///
        /// example: a.get(5) -> a.items.items[1]
        ///
        ///                         ⬇
        /// BitSet256:   [0|0|1|0|0|1|0|...|1] <- 3 bits set
        /// Items:       [*|*|*]               <- len(Items) = 3
        ///                 ⬆
        ///
        /// BitSet256.test(5):     true
        /// BitSet256.rank(5):     2,
        pub fn get(self: Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                return self.items.items[self.bitset.rank(i) - 1];
            }
            return null;
        }
        
        /// MustGet use it only after a successful test
        /// or the behavior is undefined, it will NOT PANIC.
        pub fn mustGet(self: Self, i: u8) T {
            return self.items.items[self.bitset.rank(i) - 1];
        }
        
        /// MustGetPtr: 書き込み用に、iの値へのポインタを返す（isSet前提）
        pub fn mustGetPtr(self: *Self, i: u8) *T {
            if (!self.bitset.isSet(i)) @panic("mustGetPtr: index not set");
            return &self.items.items[self.bitset.rank(i) - 1];
        }
        
        /// UpdateAt or set the value at i via callback. The new value is returned
        /// and true if the value was already present.
        pub fn updateAt(self: *Self, i: u8, cb: fn (T, bool) T) struct { new_value: T, was_present: bool } {
            var rank0: usize = 0;
            var old_value: T = undefined;
            const was_present = self.bitset.isSet(i);
            
            // if already set, get current value
            if (was_present) {
                rank0 = self.bitset.rank(i) - 1;
                old_value = self.items.items[rank0];
            }
            
            // callback function to get updated or new value
            const new_value = cb(old_value, was_present);
            
            // already set, update and return value
            if (was_present) {
                self.items.items[rank0] = new_value;
                return .{ .new_value = new_value, .was_present = was_present };
            }
            
            // new value, insert into bitset ...
            self.bitset.set(i);
            
            // bitset has changed, recalc rank
            rank0 = self.bitset.rank(i) - 1;
            
            // ... and insert value into slice
            self.insertItem(rank0, new_value);
            
            return .{ .new_value = new_value, .was_present = was_present };
        }
        
        /// Len returns the number of items in sparse array.
        pub fn len(self: Self) usize {
            return self.items.items.len;
        }
        
        /// Copy returns a shallow copy of the Array.
        /// The elements are copied using assignment, this is no deep clone.
        pub fn copy(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const copy_ptr = try allocator.create(Self);
            copy_ptr.* = Self{
                .bitset = self.bitset,
                .items = std.ArrayList(T).init(allocator),
            };
            try copy_ptr.items.appendSlice(self.items.items);
            return copy_ptr;
        }
        
        /// InsertAt a value at i into the sparse array.
        /// If the value already exists, overwrite it with val and return false.
        /// If the value is new, insert it and return true.
        pub fn insertAt(self: *Self, i: u8, value: T) bool {
            // slot exists, overwrite value
            if (self.bitset.isSet(i)) {
                self.items.items[self.bitset.rank(i) - 1] = value;
                return false;  // 既存値の上書き時はfalse
            }
            
            // new, insert into bitset ...
            self.bitset.set(i);
            
            // ... and slice
            self.insertItem(self.bitset.rank(i) - 1, value);
            
            return true;  // 新規挿入時はtrue
        }
        
        /// DeleteAt a value at i from the sparse array, zeroes the tail.
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (self.len() == 0 or !self.bitset.isSet(i)) {
                return null;
            }
            
            const rank0 = self.bitset.rank(i) - 1;
            const value = self.items.items[rank0];
            
            // delete from slice
            self.deleteItem(rank0);
            
            // delete from bitset
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
        
        /// insertItem inserts the item at index i, shift the rest one pos right
        ///
        /// It panics if i is out of range.
        fn insertItem(self: *Self, i: usize, item: T) void {
            self.items.append(item) catch unreachable;
            
            // shift one slot right, starting at [i]
            var j: usize = self.items.items.len - 1;
            while (j > i) : (j -= 1) {
                self.items.items[j] = self.items.items[j - 1];
            }
            self.items.items[i] = item; // insert new item at [i]
        }
        
        /// deleteItem at index i, shift the rest one pos left and clears the tail item
        ///
        /// It panics if i is out of range.
        fn deleteItem(self: *Self, i: usize) void {
            // shift left, overwrite item at [i]
            var j: usize = i;
            while (j < self.items.items.len - 1) : (j += 1) {
                self.items.items[j] = self.items.items[j + 1];
            }
            
            _ = self.items.orderedRemove(i);
        }
    };
} 