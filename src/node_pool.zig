const std = @import("std");
const bitset256 = @import("bitset256.zig");

// Node pool for memory management optimization
// 
// Node pool pre-allocates node memory and reuses it to
// improve memory management efficiency. Main benefits:
// - Reduce memory allocation calls
// - Improve memory locality
// - Better cache efficiency
// - Prevent memory fragmentation

// Pool configuration
// - NODE_POOL_SIZE: number of nodes to allocate in pool
// - NODE_POOL_ALIGN: cache line size (64 bytes for x86_64)

pub const NODE_POOL_SIZE = 1024;
pub const NODE_POOL_ALIGN = 64;

// Node structure
// Cache-efficient layout
pub const Node = struct {
    // Bitmap (256 bits = 4 * 64 bits)
    // Aligned to cache line size
    // Each bit indicates presence of child node
    bitmap: [4]u64 align(NODE_POOL_ALIGN),

    // Array of pointers to child nodes
    // Same number of elements as 1s in bitmap
    children: ?[]*Node,

    // Whether this is a prefix terminal
    prefix_set: bool,

    // Value when this is a prefix terminal
    prefix_value: usize,

    // Find child node
    // 1. Check bit corresponding to key
    // 2. If bit is 1, return corresponding child node
    // 3. If bit is 0, return null
    //
    // Bitmap structure (4 u64s, total 256 bits)
    // [0..63] [64..127] [128..191] [192..255]
    pub fn findChild(self: *const Node, key: u8) ?*Node {
        // LPM search: return largest child node <= key
        const idx = bitset256.lpmSearch(&self.bitmap, key);
        if (idx) |i| {
            // Calculate child node index
            var index: usize = 0;
            const chunk_index: usize = i >> 6;
            const bit_offset: u6 = @as(u6, @truncate(i & 0x3F));
            var j: usize = 0;
            while (j < chunk_index) : (j += 1) {
                index += @popCount(self.bitmap[j]);
            }
            const mask = if (bit_offset == 0) 0 else (~(@as(u64, 1) << bit_offset));
            index += @popCount(self.bitmap[chunk_index] & mask);
            return self.children.?[index];
        }
        return null;
    }
};

// Node pool structure
// -------------------
// nodes: pre-allocated array of nodes
// free_list: array of pointers to unused nodes
// free_count: number of unused nodes
pub const NodePool = struct {
    // Aligned node array
    // Aligned to cache line size to prevent false sharing
    nodes: []Node align(NODE_POOL_ALIGN),
    
    // Array of pointers to unused nodes
    // Used as stack for O(1) node allocation/deallocation
    free_list: []?*Node,
    
    // Number of unused nodes
    // Manages valid elements in free_list
    free_count: usize,

    // Initialize pool
    // --------------
    // 1. Allocate memory for pool itself
    // 2. Allocate node array (aligned to cache line size)
    // 3. Initialize free list
    // 4. Set each node to initial state
    pub fn init(allocator: std.mem.Allocator) !*NodePool {
        // Allocate memory for pool itself
        const pool = try allocator.create(NodePool);
        errdefer allocator.destroy(pool);

        // Allocate aligned node array
        pool.nodes = try allocator.alignedAlloc(Node, NODE_POOL_ALIGN, NODE_POOL_SIZE);
        errdefer allocator.free(pool.nodes);

        // Allocate free list
        pool.free_list = try allocator.alloc(?*Node, NODE_POOL_SIZE);
        errdefer allocator.free(pool.free_list);

        // Set initial state
        pool.free_count = NODE_POOL_SIZE;

        // Initialize free list
        // Register each node as unused
        for (0..NODE_POOL_SIZE) |i| {
            // Initialize node
            pool.nodes[i] = Node{
                .bitmap = [_]u64{ 0, 0, 0, 0 },
                .children = null,
                .prefix_set = false,
                .prefix_value = 0,
            };
            // Add to free list
            pool.free_list[i] = &pool.nodes[i];
        }

        return pool;
    }

    // Free pool
    // -----------
    // Free all allocated memory
    pub fn deinit(self: *NodePool, allocator: std.mem.Allocator) void {
        allocator.free(self.free_list);
        allocator.free(self.nodes);
        allocator.destroy(self);
    }

    // Allocate node
    // ---------------
    // 1. Get unused node from free list
    // 2. Return null if no unused nodes
    // 3. Mark obtained node as in use
    pub fn allocate(self: *NodePool) ?*Node {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_list[self.free_count];
    }

    // Free node
    // -----------
    // 1. Return used node to free list
    // 2. Do nothing if pool is full
    // Note: node contents not cleared, overwritten on reuse
    pub fn free(self: *NodePool, node: *Node) void {
        if (self.free_count >= NODE_POOL_SIZE) return;
        self.free_list[self.free_count] = node;
        self.free_count += 1;
    }

    // Recursively free node
    // ------------------
    // 1. Recursively free child nodes
    // 2. Free child node array
    // 3. Return node itself to free list
    pub fn freeNodeRecursive(self: *NodePool, node: *Node) void {
        if (node.children) |children| {
            // Recursively free child nodes
            for (children) |child| {
                self.freeNodeRecursive(child);
            }
            // Free child node array
            std.heap.c_allocator.free(children);
            node.children = null;
        }
        // Return node to free list
        self.free(node);
    }
}; 