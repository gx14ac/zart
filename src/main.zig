const std = @import("std");
const c_allocator = std.heap.c_allocator;
const node_pool = @import("node_pool.zig");
const Node = node_pool.Node;
const NodePool = node_pool.NodePool;

// ルーティングテーブル構造体 (C互換構造体)
pub const BartTable = extern struct {
    root4: ?*Node,
    root6: ?*Node,
    pool: *NodePool,  // ノードプールへの参照を追加
};

// ルーティングテーブルを初期化 (ヒープ上に確保)
pub export fn bart_create() callconv(.C) *BartTable {
    const table = c_allocator.create(BartTable) catch unreachable;
    table.root4 = null;
    table.root6 = null;
    // ノードプールを初期化
    table.pool = NodePool.init(c_allocator) catch unreachable;
    return table;
}

// ルーティングテーブルを解放 (全ノードを再帰的に解放)
pub export fn bart_destroy(table: *BartTable) callconv(.C) void {
    if (table.root4) |r4| {
        table.pool.freeNodeRecursive(r4);
    }
    if (table.root6) |r6| {
        table.pool.freeNodeRecursive(r6);
    }
    // ノードプールを解放
    table.pool.deinit(c_allocator);
    _ = c_allocator.destroy(table);
}

// 子ノードの挿入（最適化版）
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

    // ビットを立てる
    parent.bitmap[chunk_index] |= (@as(u64, 1) << bit_offset);

    var new_count: usize = 0;
    new_count +%= @popCount(parent.bitmap[0]);
    new_count +%= @popCount(parent.bitmap[1]);
    new_count +%= @popCount(parent.bitmap[2]);
    new_count +%= @popCount(parent.bitmap[3]);

    const old_count = new_count -% 1;

    var new_children = try c_allocator.alloc(*Node, new_count);
    errdefer c_allocator.free(new_children);

    // 挿入位置indexを計算
    var index: usize = 0;
    var j: usize = 0;
    while (j < chunk_index) : (j += 1) {
        index +%= @popCount(parent.bitmap[j]);
    }
    const mask = if (bit_offset == 0) 0 else ((@as(u64, 1) << bit_offset) - 1);
    index +%= @popCount(parent.bitmap[chunk_index] & mask);

    // 古い配列の内容をコピー
    if (parent.children) |old_children| {
        if (old_count > 0) {
            // 修正: ポインタを直接コピー
            var i: usize = 0;
            while (i < index) : (i += 1) {
                new_children[i] = old_children[i]; // &を削除
            }
            i = index;
            while (i < old_count) : (i += 1) {
                new_children[i + 1] = old_children[i]; // &を削除
            }
            // 古い配列を解放
            c_allocator.free(parent.children.?);
        }
    }

    // 新しいノードを挿入
    new_children[index] = child;

    // 新しい配列を設定
    parent.children = new_children; // スライスとして設定する必要はない
}

// 内部ヘルパー: IPv4アドレス(32bit整数)からバイト配列(長さ4)を取得 (ネットワークバイトオーダー)
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

            // 各キーに対して新しいノードを作成
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

            // 各キーに対して新しいノードを作成
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

// IPv4プレフィックスをテーブルに挿入 (C API関数)
pub export fn bart_insert4(table: *BartTable, ip: u32, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert4Internal(table, ip, prefix_len, value) catch return -1; // if (insert4Internal(...)) |_| から変更
    return 0;
}

// IPv6プレフィックスをテーブルに挿入
pub export fn bart_insert6(table: *BartTable, addr_ptr: [*]const u8, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert6Internal(table, addr_ptr, prefix_len, value) catch return -1; // if (insert6Internal(...)) |_| から変更
    return 0;
}

// IPv4アドレスでルックアップ (最長一致検索)
pub export fn bart_lookup4(table: *BartTable, ip: u32, found: *i32) callconv(.C) usize {
    if (table.root4 == null) { // !table.root4 から変更
        found.* = 0;
        return 0;
    }
    const addr_bytes = ip4ToBytes(ip);
    var node = table.root4.?;
    var best_value: usize = 0;
    var have_value = false;
    // 各バイト毎に子ノードを辿り、prefix値があれば更新
    for (addr_bytes) |byte| {
        if (node.prefix_set) {
            have_value = true;
            best_value = node.prefix_value;
        }
        const next = node.findChild(byte);
        if (next == null) break; // !next から変更
        node = next.?;
    }
    // ループ外でも終端ノードにprefixがあれば確認
    if (node.prefix_set) {
        have_value = true;
        best_value = node.prefix_value;
    }
    found.* = if (have_value) 1 else 0;
    return best_value;
}

// IPv6アドレスでルックアップ
pub export fn bart_lookup6(table: *BartTable, addr_ptr: [*]const u8, found: *i32) callconv(.C) usize {
    if (table.root6 == null) { // !table.root6 から変更
        found.* = 0;
        return 0;
    }
    var node = table.root6.?;
    var best_value: usize = 0;
    var have_value = false;
    // 16バイトを順次辿る
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (node.prefix_set) {
            have_value = true;
            best_value = node.prefix_value;
        }
        const next = node.findChild(addr_ptr[i]);
        if (next == null) break; // !next から変更
        node = next.?;
    }
    if (node.prefix_set) {
        have_value = true;
        best_value = node.prefix_value;
    }
    found.* = if (have_value) 1 else 0;
    return best_value;
}
