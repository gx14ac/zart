const std = @import("std");
const c_allocator = std.heap.c_allocator;
const node_pool = @import("node_pool.zig");
const Node = node_pool.Node;
const NodePool = node_pool.NodePool;

// Routing table structure (C-compatible)
pub const BartTable = extern struct {
    root4: ?*Node,
    root6: ?*Node,
    pool: *NodePool,  // Reference to node pool
};

// Initialize routing table (allocated on heap)
pub export fn bart_create() callconv(.C) *BartTable {
    const table = c_allocator.create(BartTable) catch unreachable;
    table.root4 = null;
    table.root6 = null;
    // Initialize node pool
    table.pool = NodePool.init(c_allocator) catch unreachable;
    return table;
}

// Free routing table (recursively free all nodes)
pub export fn bart_destroy(table: *BartTable) callconv(.C) void {
    if (table.root4) |r4| {
        table.pool.freeNodeRecursive(r4);
    }
    if (table.root6) |r6| {
        table.pool.freeNodeRecursive(r6);
    }
    // Free node pool
    table.pool.deinit(c_allocator);
    _ = c_allocator.destroy(table);
}

// Insert child node (optimized version)
fn insertChild(parent: *Node, key: u8, child: *Node, pool: *NodePool) !void {
    const chunk_index = key >> 6;
    const bit_offset = @as(u6, @truncate(key & 0x3F));
    if (((parent.bitmap[chunk_index] >> bit_offset) & 1) != 0) {
        var index: usize = 0;
        var j: usize = 0;
        while (j < chunk_index) : (j += 1) {
            index +%= @popCount(parent.bitmap[j]);
        }
        const mask = if (bit_offset == 0) 0 else ((@as(u64, 1) << bit_offset) - 1);
        index +%= @popCount(parent.bitmap[chunk_index] & mask);

        if (parent.children) |old_children| {
            pool.freeNodeRecursive(old_children[index]);
        }
        return;
    }

    // Set bit
    parent.bitmap[chunk_index] |= (@as(u64, 1) << bit_offset);

    var new_count: usize = 0;
    new_count +%= @popCount(parent.bitmap[0]);
    new_count +%= @popCount(parent.bitmap[1]);
    new_count +%= @popCount(parent.bitmap[2]);
    new_count +%= @popCount(parent.bitmap[3]);

    const old_count = new_count -% 1;

    var new_children = try c_allocator.alloc(*Node, new_count);
    errdefer c_allocator.free(new_children);

    // Calculate insertion index
    var index: usize = 0;
    var j: usize = 0;
    while (j < chunk_index) : (j += 1) {
        index +%= @popCount(parent.bitmap[j]);
    }
    const mask = if (bit_offset == 0) 0 else ((@as(u64, 1) << bit_offset) - 1);
    index +%= @popCount(parent.bitmap[chunk_index] & mask);

    // Copy old array contents
    if (parent.children) |old_children| {
        if (old_count > 0) {
            // Fix: copy pointers directly
            var i: usize = 0;
            while (i < index) : (i += 1) {
                new_children[i] = old_children[i]; // Remove &
            }
            i = index;
            while (i < old_count) : (i += 1) {
                new_children[i + 1] = old_children[i]; // Remove &
            }
            // Free old array
            c_allocator.free(parent.children.?);
        }
    }

    // Insert new node
    new_children[index] = child;

    // Set new array
    parent.children = new_children; // No need to set as slice
}

// Internal helper: convert IPv4 address (32bit int) to byte array (length 4) (network byte order)
fn ip4ToBytes(ip: u32) [4]u8 {
    return [4]u8{ @as(u8, @truncate((ip >> 24) & 0xFF)), @as(u8, @truncate((ip >> 16) & 0xFF)), @as(u8, @truncate((ip >> 8) & 0xFF)), @as(u8, @truncate(ip & 0xFF)) };
}

fn insert4Internal(table: *BartTable, ip: u32, prefix_len: u8, value: usize) !void {
    if (table.root4 == null) {
        table.root4 = table.pool.allocate() orelse return error.OutOfMemory;
    }
    var node = table.root4.?;
    const addr_bytes = ip4ToBytes(ip);
    var bit_index: u8 = 0;
    var byte_index: u8 = 0;
    while (byte_index < 4 and bit_index < prefix_len) : (byte_index += 1) {
        const remaining = prefix_len - bit_index;
        if (remaining < 8) {
            const byte_val = addr_bytes[byte_index];
            const r = @as(u4, @truncate(remaining));
            const mask = (@as(u16, 1) << (8 - r)) - 1;
            const start_key = byte_val & ~@as(u8, @truncate(mask));
            const end_key = byte_val | @as(u8, @truncate(mask));

            // Create new node for each key
            var k: u16 = start_key;
            while (k <= end_key) : (k += 1) {
                const kb = @as(u8, @truncate(k));
                if (((node.bitmap[kb >> 6] >> @as(u6, @truncate(kb & 0x3F))) & 1) == 0) {
                    var prefix_node = table.pool.allocate() orelse return error.OutOfMemory;
                    prefix_node.prefix_set = true;
                    prefix_node.prefix_value = value;
                    try insertChild(node, kb, prefix_node, table.pool);
                }
            }
            return;
        }
        const key = addr_bytes[byte_index];
        var next = node.findChild(key);
        if (next == null) {
            next = table.pool.allocate() orelse return error.OutOfMemory;
            try insertChild(node, key, next.?, table.pool);
        }
        bit_index += 8;
    }
    node.prefix_set = true;
    node.prefix_value = value;
}

fn insert6Internal(table: *BartTable, addr_ptr: [*]const u8, prefix_len: u8, value: usize) !void {
    if (table.root6 == null) {
        table.root6 = table.pool.allocate() orelse return error.OutOfMemory;
    }
    var node = table.root6.?;
    var bit_index: u8 = 0;
    var byte_index: u8 = 0;
    while (byte_index < 16 and bit_index < prefix_len) : (byte_index += 1) {
        const remaining = prefix_len - bit_index;
        if (remaining < 8) {
            const byte_val = addr_ptr[byte_index];
            const r = @as(u4, @truncate(remaining));
            const mask = (@as(u16, 1) << (8 - r)) - 1;
            const start_key = byte_val & ~@as(u8, @truncate(mask));
            const end_key = byte_val | @as(u8, @truncate(mask));

            // Create new node for each key
            var k: u16 = start_key;
            while (k <= end_key) : (k += 1) {
                const kb = @as(u8, @truncate(k));
                if (((node.bitmap[kb >> 6] >> @as(u6, @truncate(kb & 0x3F))) & 1) == 0) {
                    var prefix_node = table.pool.allocate() orelse return error.OutOfMemory;
                    prefix_node.prefix_set = true;
                    prefix_node.prefix_value = value;
                    try insertChild(node, kb, prefix_node, table.pool);
                }
            }
            return;
        }
        const key = addr_ptr[byte_index];
        var next = node.findChild(key);
        if (next == null) {
            next = table.pool.allocate() orelse return error.OutOfMemory;
            try insertChild(node, key, next.?, table.pool);
        }
        bit_index += 8;
    }
    node.prefix_set = true;
    node.prefix_value = value;
}

// Insert IPv4 prefix into table (C API function)
pub export fn bart_insert4(table: *BartTable, ip: u32, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert4Internal(table, ip, prefix_len, value) catch return -1; // Changed from if (insert4Internal(...)) |_|
    return 0;
}

// Insert IPv6 prefix into table
pub export fn bart_insert6(table: *BartTable, addr_ptr: [*]const u8, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert6Internal(table, addr_ptr, prefix_len, value) catch return -1; // Changed from if (insert6Internal(...)) |_|
    return 0;
}

// Lookup IPv4 address (longest prefix match)
pub export fn bart_lookup4(table: *BartTable, ip: u32, found: *i32) callconv(.C) usize {
    if (table.root4 == null) { // Changed from !table.root4
        found.* = 0;
        return 0;
    }
    const addr_bytes = ip4ToBytes(ip);
    var node = table.root4.?;
    var best_value: usize = 0;
    var have_value = false;
    // Traverse child nodes for each byte, update prefix value if exists
    for (addr_bytes) |byte| {
        if (node.prefix_set) {
            have_value = true;
            best_value = node.prefix_value;
        }
        const next = node.findChild(byte);
        if (next == null) break; // Changed from !next
        node = next.?;
    }
    // Check if terminal node has prefix outside loop
    if (node.prefix_set) {
        have_value = true;
        best_value = node.prefix_value;
    }
    found.* = if (have_value) 1 else 0;
    return best_value;
}

// Lookup IPv6 address
pub export fn bart_lookup6(table: *BartTable, addr_ptr: [*]const u8, found: *i32) callconv(.C) usize {
    if (table.root6 == null) { // Changed from !table.root6
        found.* = 0;
        return 0;
    }
    var node = table.root6.?;
    var best_value: usize = 0;
    var have_value = false;
    // Traverse 16 bytes sequentially
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (node.prefix_set) {
            have_value = true;
            best_value = node.prefix_value;
        }
        const next = node.findChild(addr_ptr[i]);
        if (next == null) break; // Changed from !next
        node = next.?;
    }
    if (node.prefix_set) {
        have_value = true;
        best_value = node.prefix_value;
    }
    found.* = if (have_value) 1 else 0;
    return best_value;
}

// Test main function
pub fn main() !void {
    std.debug.print("BART (Binary Art Routing Table) - Zig Implementation\n", .{});
    std.debug.print("Testing basic functionality...\n", .{});
    
    // Create a test table
    const table = bart_create();
    defer bart_destroy(table);
    
    // Test IPv4 insertion
    const test_ip: u32 = 0x0A000001; // 10.0.0.1
    const result = bart_insert4(table, test_ip, 24, 42);
    if (result == 0) {
        std.debug.print("IPv4 insertion successful\n", .{});
    } else {
        std.debug.print("IPv4 insertion failed\n", .{});
    }
    
    std.debug.print("Test completed\n", .{});
}
