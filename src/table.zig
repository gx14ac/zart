// ZART (Zig Adaptive Routing Table) - High-performance IP routing table implementation
//
// ZART is optimized for both memory usage and lookup time
// for longest-prefix match operations.
//
// ZART is a multibit-trie with fixed stride length of 8 bits,
// using an efficient mapping function to map the 256 prefixes
// in each level node to form a complete-binary-tree.
//
// This complete binary tree is implemented with popcount compressed
// sparse arrays together with path compression. This reduces storage
// consumption significantly while maintaining excellent lookup times.
//
// The ZART algorithm is based on bit vectors and precalculated
// lookup tables. The search is performed entirely by fast,
// cache-friendly bitmask operations, utilizing modern CPU bit
// manipulation instruction sets (POPCNT, LZCNT, TZCNT).
//
// The algorithm was specially developed so that it can always work with a fixed
// length of 256 bits. This means that the bitsets fit well in a cache line and
// that loops in hot paths (4x uint64 = 256) can be accelerated by loop unrolling.

const std = @import("std");
const Node = @import("node.zig").Node;

// Table is an IPv4 and IPv6 routing table with payload V.
// The zero value is ready to use.
//
// The Table is safe for concurrent readers but not for concurrent readers
// and/or writers. Either the update operations must be protected by an
// external lock mechanism or the various ...Persist functions must be used
// which return a modified routing table by leaving the original unchanged
//
// A Table must not be copied by value.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // the root nodes, implemented as popcount compressed multibit tries
        // Go BART: root4 node[V]
        // Go BART: root6 node[V]
        root4: Node(V),
        root6: Node(V),
        
        // the number of prefixes in the routing table
        // Go BART: size4 int
        // Go BART: size6 int
        size4_count: i32,
        size6_count: i32,
        
        allocator: std.mem.Allocator,

        /// Initialize a new Table
        /// Go BART equivalent: var table Table[V] (zero value ready to use)
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .root4 = Node(V).init(allocator),
                .root6 = Node(V).init(allocator),
                .size4_count = 0,
                .size6_count = 0,
                .allocator = allocator,
            };
        }

        /// Deinitialize the table and free memory
        /// Go BART doesn't need explicit cleanup, but Zig does
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }

        /// rootNodeByVersion, root node getter for ip version.
        /// Go BART: func (t *Table[V]) rootNodeByVersion(is4 bool) *node[V]
        fn rootNodeByVersion(self: *Self, is4: bool) *Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }

        /// Size returns the prefix count.
        /// Go BART: func (t *Table[V]) Size() int
        pub fn size(self: *const Self) i32 {
            return self.size4_count + self.size6_count;
        }

        /// Size4 returns the IPv4 prefix count.
        /// Go BART: func (t *Table[V]) Size4() int
        pub fn size4(self: *const Self) i32 {
            return self.size4_count;
        }

        /// Size6 returns the IPv6 prefix count.
        /// Go BART: func (t *Table[V]) Size6() int
        pub fn size6(self: *const Self) i32 {
            return self.size6_count;
        }
    };
}

// 基本的なテスト
const testing = std.testing;

test "Table basic structure" {
    const allocator = testing.allocator;
    
    // Table[i32]のインスタンス作成
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // 初期状態の確認 - フィールド直接アクセス
    try testing.expectEqual(@as(i32, 0), table.size4_count);
    try testing.expectEqual(@as(i32, 0), table.size6_count);
    
    // 初期状態の確認 - Go BART互換メソッド
    try testing.expectEqual(@as(i32, 0), table.size());
    try testing.expectEqual(@as(i32, 0), table.size4());
    try testing.expectEqual(@as(i32, 0), table.size6());
}

test "Table with different types" {
    const allocator = testing.allocator;
    
    // 異なる型でのTable作成をテスト
    var int_table = Table(i32).init(allocator);
    defer int_table.deinit();
    
    var str_table = Table([]const u8).init(allocator);
    defer str_table.deinit();
    
    var void_table = Table(void).init(allocator);
    defer void_table.deinit();
    
    // すべて正常に作成できることを確認
    try testing.expect(true);
}
