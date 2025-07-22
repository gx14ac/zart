// ZART sparse.Array256 - Go BART完全互換実装
// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT
//
// Go BART internal/sparse.Array256の完全移植

const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// Array256 is a generic implementation of a sparse array
/// with popcount compression for max. 256 items with payload T.
///
/// Direct port of Go BART's sparse.Array256[T]
pub fn Array256(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying bitset (Go BART: embedded BitSet256)
        bitset: BitSet256,

        /// Dynamic array of items (Go BART: Items []T)
        items: std.ArrayList(T),

        /// Initialize empty sparse array
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .bitset = BitSet256{ .data = [4]u64{ 0, 0, 0, 0 } },
                .items = std.ArrayList(T).init(allocator),
            };
        }

        /// Cleanup (Go BART: automatic GC)
        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        /// Test if bit i is set (Go BART: a.Test(i))
        pub fn testBit(self: *const Self, i: u8) bool {
            return self.bitset.testBitSet256(i);
        }

        /// Test - Go BART compatible version (Go BART: a.Test(i))
        pub fn Test(self: *const Self, i: u8) bool {
            return self.bitset.testBitSet256(i);
        }

        /// Get rank of bit i (Go BART: a.Rank(i))
        pub fn rank(self: *const Self, i: u8) u8 {
            return self.bitset.rank(i);
        }

        /// Rank - Go BART compatible version (Go BART: a.Rank(i))
        pub fn Rank(self: *const Self, i: u8) u8 {
            return self.bitset.rank(i);
        }

        /// Get the value at i from sparse array with optional return (convenience method)
        pub fn get(self: *const Self, i: u8) ?T {
            if (self.testBit(i)) {
                const rank_idx = self.rank(i) - 1;
                return self.items.items[rank_idx];
            }
            return null;
        }

        /// Get returns value and ok flag (Go BART: a.Get(i))
        ///
        /// example: a.Get(5) -> {.value = items[1], .ok = true}
        ///
        ///                        ⬇
        /// BitSet256:   [0|0|1|0|0|1|0|...|1] <- 3 bits set
        /// items:       [*|*|*]               <- len(items) = 3
        ///                ⬆
        ///
        /// BitSet256.testBit(5):     true
        /// BitSet256.rank(5):     2,
        pub fn Get(self: *const Self, i: u8) struct { value: T, ok: bool } {
            if (self.testBit(i)) {
                const rank_idx = self.rank(i) - 1;
                return .{ .value = self.items.items[rank_idx], .ok = true };
            }
            return .{ .value = undefined, .ok = false };
        }

        /// MustGet - use it only after a successful test (Go BART: a.MustGet(i))
        /// or the behavior is undefined, it will NOT PANIC.
        pub fn mustGet(self: *const Self, i: u8) T {
            const rank_idx = self.rank(i) - 1;
            return self.items.items[rank_idx];
        }

        /// UpdateAt or set the value at i via callback (Go BART: a.UpdateAt(i, cb))
        /// The new value is returned and true if the value was already present.
        pub fn updateAt(self: *Self, i: u8, cb: fn (T, bool) T) !struct { new_value: T, was_present: bool } {
            var rank0: usize = 0;

            // if already set, get current value
            var old_value: T = undefined;
            const was_present = self.testBit(i);

            if (was_present) {
                rank0 = self.rank(i) - 1;
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
            rank0 = self.rank(i) - 1;

            // ... and insert value into slice
            try self.insertItem(rank0, new_value);

            return .{ .new_value = new_value, .was_present = was_present };
        }

        /// Len returns the number of items in sparse array (Go BART: a.Len())
        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        /// Items - Go BART compatible Items slice access (Go BART: a.Items)
        pub fn Items(self: *const Self) []T {
            return self.items.items;
        }

        /// Copy returns a shallow copy of the Array (Go BART: a.Copy())
        /// The elements are copied using assignment, this is no deep clone.
        /// Returns null if self is null (Go BART compatible).
        pub fn copy(self: ?*const Self, allocator: std.mem.Allocator) !?*Self {
            if (self == null) {
                return null;
            }

            var new_array = try allocator.create(Self);
            new_array.* = Self{
                .bitset = self.?.bitset,
                .items = std.ArrayList(T).init(allocator),
            };

            try new_array.items.appendSlice(self.?.items.items);
            return new_array;
        }

        /// InsertAt a value at i into the sparse array (Go BART: a.InsertAt(i, value))
        /// If the value already exists, overwrite it with val and return true.
        pub fn insertAt(self: *Self, i: u8, value: T) !bool {
            // slot exists, overwrite value
            if (self.testBit(i)) {
                const rank_idx = self.rank(i) - 1;
                self.items.items[rank_idx] = value;
                return true;
            }

            // new, insert into bitset ...
            self.bitset.set(i);

            // ... and slice
            const rank_idx = self.rank(i) - 1;
            try self.insertItem(rank_idx, value);

            return false;
        }

        /// DeleteAt a value at i from the sparse array (Go BART: a.DeleteAt(i))
        /// Returns value and true if existed, zeroes the tail.
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (self.len() == 0 or !self.testBit(i)) {
                return null;
            }

            const rank_idx = self.rank(i) - 1;
            const value = self.items.items[rank_idx];

            // delete from slice
            self.deleteItem(rank_idx);

            // delete from bitset
            self.bitset.clear(i);

            return value;
        }

        /// insertItem inserts the item at index i, shift the rest one pos right
        /// (Go BART: a.insertItem(i, item))
        ///
        /// It panics if i is out of range.
        fn insertItem(self: *Self, i: usize, item: T) !void {
            // Go BART optimization: fast resize if capacity available
            if (self.items.items.len < self.items.capacity) {
                // fast resize, no alloc (Go BART: a.Items = a.Items[:len(a.Items)+1])
                const old_len = self.items.items.len;
                self.items.items.len += 1;

                // BCE (Bounds Check Elimination)
                std.debug.assert(i <= old_len);

                // shift one slot right, starting at [i] (Go BART: copy(a.Items[i+1:], a.Items[i:]))
                if (i < old_len) {
                    std.mem.copyBackwards(T, self.items.items[i + 1 .. old_len + 1], self.items.items[i..old_len]);
                }

                // insert new item at [i]
                self.items.items[i] = item;
            } else {
                // append one item, mostly enlarge cap by more than one item
                try self.items.append(undefined);

                // shift and insert
                if (i < self.items.items.len - 1) {
                    std.mem.copyBackwards(T, self.items.items[i + 1 ..], self.items.items[i .. self.items.items.len - 1]);
                }
                self.items.items[i] = item;
            }
        }

        /// deleteItem at index i, shift the rest one pos left and clears the tail item
        /// (Go BART: a.deleteItem(i))
        ///
        /// It panics if i is out of range.
        fn deleteItem(self: *Self, i: usize) void {
            // BCE (Bounds Check Elimination)
            std.debug.assert(i < self.items.items.len);

            // shift left, overwrite item at [i] (Go BART: copy(a.Items[i:], a.Items[i+1:]))
            if (i < self.items.items.len - 1) {
                @memcpy(self.items.items[i .. self.items.items.len - 1], self.items.items[i + 1 ..]);
            }

            const new_len = self.items.items.len - 1;

            // clear the tail item (Go BART: a.Items[nl] = zero)
            self.items.items[new_len] = undefined;

            // new len, cap is unchanged (Go BART: a.Items = a.Items[:nl])
            self.items.items.len = new_len;
        }

        /// Debug: print array state
        pub fn debugPrint(self: *const Self) void {
            std.debug.print("SparseArray256: bitset={}, items=[", .{self.bitset});
            for (self.items.items, 0..) |item, idx| {
                if (idx > 0) std.debug.print(", ");
                std.debug.print("{}", .{item});
            }
            std.debug.print("]\n");
        }

        /// IntersectionTop - Go BART compatible IntersectionTop method (Go BART: a.IntersectionTop(other))
        /// Returns the highest bit index from the intersection of this sparse array's bitset and the given bitset
        pub fn IntersectionTop(self: *const Self, other: *const BitSet256) ?u8 {
            return self.bitset.intersectionTop(other);
        }

        /// intersectionTop - Go BART compatible intersectionTop method (Go BART: a.intersectionTop(other))
        /// Returns the highest bit index from the intersection of this sparse array's bitset and the given bitset
        pub fn intersectionTop(self: *const Self, other: *const BitSet256) ?u8 {
            return self.bitset.intersectionTop(other);
        }

        /// IntersectsAny - Go BART compatible IntersectsAny method (Go BART: a.IntersectsAny(other))
        /// Returns true if this sparse array's bitset intersects with the given bitset
        pub fn IntersectsAny(self: *const Self, other: *const BitSet256) bool {
            return self.bitset.intersectsAny(other);
        }

        /// intersectsAny - Go BART compatible intersectsAny method (Go BART: a.intersectsAny(other))
        /// Returns true if this sparse array's bitset intersects with the given bitset
        pub fn intersectsAny(self: *const Self, other: *const BitSet256) bool {
            return self.bitset.intersectsAny(other);
        }
    };
}
