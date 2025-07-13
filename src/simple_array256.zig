const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// Simple ArrayList-based replacement for sparse_array256
/// This is a temporary solution to fix compilation issues
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
        
        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            var items = std.ArrayList(T).init(allocator);
            items.ensureTotalCapacity(capacity) catch {};
            return Self{
                .bitset = BitSet256.init(),
                .items = items,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }
        
        pub fn get(self: Self, i: u8) ?T {
            if (self.bitset.isSet(i)) {
                const rank_idx = self.bitset.rank(i);
                return self.items.items[rank_idx - 1];
            }
            return null;
        }
        
        pub fn mustGet(self: Self, i: u8) T {
            const rank_idx = self.bitset.rank(i);
            return self.items.items[rank_idx - 1];
        }
        
        pub fn isSet(self: Self, i: u8) bool {
            return self.bitset.isSet(i);
        }
        
        pub fn len(self: Self) usize {
            return self.items.items.len;
        }
        
        pub fn insertAt(self: *Self, i: u8, value: T) bool {
            const was_set = self.bitset.isSet(i);
            const rank_idx = self.bitset.rank(i);
            
            if (was_set) {
                self.items.items[rank_idx - 1] = value;
                return false;
            }
            
            self.bitset.set(i);
            self.items.insert(rank_idx, value) catch unreachable;
            return true;
        }
        
        pub fn deleteAt(self: *Self, i: u8) ?T {
            if (!self.bitset.isSet(i)) {
                return null;
            }
            
            const rank_idx = self.bitset.rank(i) - 1;
            const old_val = self.items.items[rank_idx];
            _ = self.items.orderedRemove(rank_idx);
            self.bitset.clear(i);
            return old_val;
        }
        
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) Self {
            var result = Self.init(allocator);
            result.bitset = self.bitset;
            result.items.appendSlice(self.items.items) catch unreachable;
            return result;
        }
        
        pub fn deepCopy(self: *const Self, allocator: std.mem.Allocator, cloneFn: fn (*const T, std.mem.Allocator) T) Self {
            var result = Self.init(allocator);
            result.bitset = self.bitset;
            
            for (self.items.items) |*item| {
                result.items.append(cloneFn(item, allocator)) catch unreachable;
            }
            
            return result;
        }
        
        pub fn intersectsAny(self: *const Self, other: *const BitSet256) bool {
            return self.bitset.intersectsAny(other);
        }
        
        pub fn intersectionTop(self: *const Self, other: *const BitSet256) ?u8 {
            return self.bitset.intersectionTop(other);
        }
        
        pub fn clearAll(self: *Self) void {
            self.bitset = BitSet256.init();
            self.items.clearRetainingCapacity();
        }
    };
} 