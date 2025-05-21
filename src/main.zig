const std = @import("std");
const c_allocator = std.heap.c_allocator;

// Node構造体: 256ビットのビットマップと子ポインタ配列、プレフィックス値を持つ
const Node = struct {
    bitmap: [4]u64, // 各ビットが子ノードの存在を示す256ビット(4 * 64)
    children: ?[*]Node, // 子ノードへのポインタ配列 (bitmapの1の数と同数)
    // prefixフラグと値: このノード自体がプレフィックス終端ならprefix_set=true, prefix_valueに値を保持
    prefix_set: bool,
    prefix_value: usize,

    // 子ノードを検索する内部関数 (キーは0〜255)
    fn findChild(self: *Node, key: u8) ?*Node {
        const chunk_index = key >> 6;
        const bit_offset = @as(u6, @truncate(key & 0x3F));  // u8からu6に変換
        if (((self.bitmap[chunk_index] >> bit_offset) & 1) == 0) {
            return null;
        }
        // ビットセット中のkey未満のビット数を数え、子配列インデックスを得る
        var index: usize = 0;
        // 完全なチャンク分を集計
        var i: usize = 0;
        while (i < chunk_index) : (i += 1) {
            index += @popCount(self.bitmap[i]);
        }
        // 部分チャンク内のビット (key未満) を集計
        const mask = if ((key & 0x3F) == 0) 0 else (~(@as(u64, 1) << @as(u6, @truncate(key & 0x3F))));
        index += @popCount(self.bitmap[chunk_index] & mask);
        // children配列から対応する子ノードポインタを返す
         return &self.children.?[index];
    }
};

// ルーティングテーブル構造体 (C互換構造体)
pub const BartTable = extern struct {
    root4: ?*Node,
    root6: ?*Node
};

// 内部ヘルパー: 新しいNodeを確保して初期化 (c_allocatorを使用)
fn allocNode() !*Node {
    const node_ptr = try c_allocator.create(Node);
    node_ptr.* = Node{
        .bitmap = [_]u64{0,0,0,0},
        .children = null,
        .prefix_set = false,
        .prefix_value = 0
    };
    return node_ptr;
}

// 内部ヘルパー: Nodeの子配列に新しい子ノードポインタを挿入 (ビットセットの該当ビットもセット)
fn insertChild(parent: *Node, key: u8, child: *Node) !void {
    const chunk_index = key >> 6;
    const bit_offset = @as(u6, @truncate(key & 0x3F));  // u8からu6に変換
    if (((parent.bitmap[chunk_index] >> bit_offset) & 1) != 0) {
        return;
    }
    // ビットを立てる
    parent.bitmap[chunk_index] |= (@as(u64, 1) << bit_offset);
    const new_count = @popCount(parent.bitmap[0]) + @popCount(parent.bitmap[1]) + @popCount(parent.bitmap[2]) + @popCount(parent.bitmap[3]);
    const old_count = new_count - 1;
    // 新しい子ポインタ配列を確保
    var new_children = try c_allocator.alloc(Node, new_count);
    // 挿入位置indexを計算
    var index: usize = 0;
    var j: usize = 0;
    while (j < chunk_index) : (j += 1) {
        index += @popCount(parent.bitmap[j]);
    }
    const mask = if (bit_offset == 0) 0 else ((@as(u64, 1) << bit_offset) - 1);
    index += @popCount(parent.bitmap[chunk_index] & mask);

    if (parent.children) |old_children| {
        // 手動でコピー
        var i: usize = 0;
        while (i < index) : (i += 1) {
            new_children[i] = old_children[i];  // Nodeをコピー
        }
        i = index;
        while (i < old_count) : (i += 1) {
            new_children[i + 1] = old_children[i];  // Nodeをコピー
        }
        // 古い配列を解放（一度だけ）
        _ = c_allocator.free(@as([*]Node, old_children)[0..old_count]);
    }
    
    // 新しいノードを挿入
    new_children[index] = child.*;  // Nodeの内容をコピー
    
    // 新しい配列を設定
    parent.children = new_children.ptr;  // 直接ポインタを設定
}

// 内部ヘルパー: ノードを再帰的に解放
fn freeNode(node: *Node) void {
    if (node.children) |children| {
        const count = @popCount(node.bitmap[0]) + @popCount(node.bitmap[1]) + @popCount(node.bitmap[2]) + @popCount(node.bitmap[3]);
        var prev_child: ?*Node = null;
        var idx: usize = 0;
        while (idx < count) : (idx += 1) {
            const child_ptr = &children[idx];
            if (prev_child == null or child_ptr != prev_child.?) {
                freeNode(child_ptr);
                prev_child = child_ptr;
            }
        }
        // 配列の解放方法を修正
         _ = c_allocator.free(@as([*]Node, children)[0..count]);
    }
    _ = c_allocator.destroy(node);
}

// 内部ヘルパー: IPv4アドレス(32bit整数)からバイト配列(長さ4)を取得 (ネットワークバイトオーダー)
fn ip4ToBytes(ip: u32) [4]u8 {
    return [4]u8{
        @as(u8, @truncate((ip >> 24) & 0xFF)),
        @as(u8, @truncate((ip >> 16) & 0xFF)),
        @as(u8, @truncate((ip >> 8) & 0xFF)),
        @as(u8, @truncate(ip & 0xFF))
    };
}

// ルーティングテーブルを初期化 (ヒープ上に確保)
pub export fn bart_create() callconv(.C) *BartTable {
    const table = c_allocator.create(BartTable) catch unreachable;
    table.root4 = null;
    table.root6 = null;
    return table;
}

// ルーティングテーブルを解放 (全ノードを再帰的に解放)
pub export fn bart_destroy(table: *BartTable) callconv(.C) void {
    if (table.root4) |r4| {
        freeNode(r4);
    }
    if (table.root6) |r6| {
        freeNode(r6);
    }
    _ = c_allocator.destroy(table);
}

fn insert4Internal(table: *BartTable, ip: u32, prefix_len: u8, value: usize) !void {
    if (table.root4 == null) {  // !table.root4 から変更
        table.root4 = try allocNode();
    }
    var node = table.root4.?; // 現在のノード
    const addr_bytes = ip4ToBytes(ip);
    var bit_index: u8 = 0;
    var byte_index: u8 = 0;
    while (byte_index < 4 and bit_index < prefix_len) : (byte_index += 1) {
        const remaining = prefix_len - bit_index;
        if (remaining < 8) {
            const byte_val = addr_bytes[byte_index];
            const r = @as(u4, @truncate(remaining));  // u8からu4に変換
            const mask = (@as(u16, 1) << (8 - r)) - 1;
            const start_key = byte_val & ~@as(u8, @truncate(mask));
            const end_key = byte_val | @as(u8, @truncate(mask));
            var prefix_node = try allocNode();
            prefix_node.prefix_set = true;
            prefix_node.prefix_value = value;
            var k: u16 = start_key;
            while (k <= end_key) : (k += 1) {
                const kb = @as(u8, @truncate(k));
                if (((node.bitmap[kb >> 6] >> @as(u6, @truncate(kb & 0x3F))) & 1) == 0) {  // u6に変換
                    try insertChild(node, kb, prefix_node);
                }
            }
            return;
        }
        const key = addr_bytes[byte_index];
        var next = node.findChild(key);
        if (next == null) {  // !next から変更
            next = try allocNode();
            try insertChild(node, key, next.?);
        }
        bit_index += 8;
    }
    node.prefix_set = true;
    node.prefix_value = value;
}

fn insert6Internal(table: *BartTable, addr_ptr: [*]const u8, prefix_len: u8, value: usize) !void {
    if (table.root6 == null) {  // !table.root6 から変更
        table.root6 = try allocNode();
    }
    var node = table.root6.?; 
    var bit_index: u8 = 0;
    var byte_index: u8 = 0;
    while (byte_index < 16 and bit_index < prefix_len) : (byte_index += 1) {
        const remaining = prefix_len - bit_index;
        if (remaining < 8) {
            const byte_val = addr_ptr[byte_index];
            const r = @as(u4, @truncate(remaining));  // u8からu4に変換
            const mask = (@as(u16, 1) << (8 - r)) - 1;
            const start_key = byte_val & ~@as(u8, @truncate(mask));
            const end_key = byte_val | @as(u8, @truncate(mask));
            var prefix_node = try allocNode();
            prefix_node.prefix_set = true;
            prefix_node.prefix_value = value;
            var k: u16 = start_key;
            while (k <= end_key) : (k += 1) {
                const kb = @as(u8, @truncate(k));
                if (((node.bitmap[kb >> 6] >> @as(u6, @truncate(kb & 0x3F))) & 1) == 0) {  // u6に変換
                    try insertChild(node, kb, prefix_node);
                }
            }
            return;
        }
        const key = addr_ptr[byte_index];
        var next = node.findChild(key);
        if (next == null) {  // !next から変更
            next = try allocNode();
            try insertChild(node, key, next.?);
        }
        bit_index += 8;
    }
    node.prefix_set = true;
    node.prefix_value = value;
}

// IPv4プレフィックスをテーブルに挿入 (C API関数)
pub export fn bart_insert4(table: *BartTable, ip: u32, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert4Internal(table, ip, prefix_len, value) catch return -1;  // if (insert4Internal(...)) |_| から変更
    return 0;
}

// IPv6プレフィックスをテーブルに挿入
pub export fn bart_insert6(table: *BartTable, addr_ptr: [*]const u8, prefix_len: u8, value: usize) callconv(.C) i32 {
    insert6Internal(table, addr_ptr, prefix_len, value) catch return -1;  // if (insert6Internal(...)) |_| から変更
    return 0;
}

// IPv4アドレスでルックアップ (最長一致検索)
pub export fn bart_lookup4(table: *BartTable, ip: u32, found: *i32) callconv(.C) usize {
    if (table.root4 == null) {  // !table.root4 から変更
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
        if (next == null) break;  // !next から変更
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
    if (table.root6 == null) {  // !table.root6 から変更
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
        if (next == null) break;  // !next から変更
        node = next.?;
    }
    if (node.prefix_set) {
        have_value = true;
        best_value = node.prefix_value;
    }
    found.* = if (have_value) 1 else 0;
    return best_value;
}