const std = @import("std");
const bitset256 = @import("bitset256.zig");

// ノードプールによるメモリ管理の最適化
// 
// ノードプールは、ノードのメモリを事前に確保して再利用することで
// メモリ管理を効率化します。主なメリット：
// - メモリ確保の回数を減らせる
// - メモリの局所性が向上する
// - キャッシュの効率が良くなる
// - メモリの断片化を防げる

// プールの設定
// - NODE_POOL_SIZE: プールに確保するノード数
// - NODE_POOL_ALIGN: キャッシュラインサイズ（x86_64なら64バイト）

pub const NODE_POOL_SIZE = 1024;
pub const NODE_POOL_ALIGN = 64;

// ノードの構造
// キャッシュ効率を考慮したレイアウト
pub const Node = struct {
    // ビットマップ（256ビット = 4 * 64ビット）
    // キャッシュラインに合わせてアライメント
    // 各ビットは子ノードの有無を示す
    bitmap: [4]u64 align(NODE_POOL_ALIGN),

    // 子ノードへのポインタ配列
    // ビットマップの1の数と同じ要素数
    children: ?[]*Node,

    // プレフィックスの終端かどうか
    prefix_set: bool,

    // プレフィックスが終端の場合の値
    prefix_value: usize,

    // 子ノードの検索
    // 1. キーに対応するビットを確認
    // 2. ビットが1なら対応する子ノードを返す
    // 3. ビットが0ならnullを返す
    //
    // ビットマップの構造（4個のu64、合計256ビット）
    // [0..63] [64..127] [128..191] [192..255]
    pub fn findChild(self: *const Node, key: u8) ?*Node {
        // LPM探索: key以下で最大の子ノードを返す
        const idx = bitset256.lpmSearch(&self.bitmap, key);
        if (idx) |i| {
            // 子ノードのインデックスを計算
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

// ノードプールの構造体
// -------------------
// nodes: 事前に確保されたノードの配列
// free_list: 未使用ノードへのポインタの配列
// free_count: 未使用ノードの数
pub const NodePool = struct {
    // アライメントされたノード配列
    // キャッシュラインサイズに合わせることで、false sharingを防止
    nodes: []Node align(NODE_POOL_ALIGN),
    
    // 未使用ノードへのポインタ配列
    // スタックとして使用し、O(1)でノードの割り当て/解放を実現
    free_list: []?*Node,
    
    // 未使用ノードの数
    // free_listの有効な要素数を管理
    free_count: usize,

    // プールの初期化
    // --------------
    // 1. プール自体のメモリを確保
    // 2. ノード配列を確保（キャッシュラインサイズにアライメント）
    // 3. フリーリストを初期化
    // 4. 各ノードを初期状態に設定
    pub fn init(allocator: std.mem.Allocator) !*NodePool {
        // プール自体のメモリを確保
        const pool = try allocator.create(NodePool);
        errdefer allocator.destroy(pool);

        // アライメントされたノード配列を確保
        pool.nodes = try allocator.alignedAlloc(Node, NODE_POOL_ALIGN, NODE_POOL_SIZE);
        errdefer allocator.free(pool.nodes);

        // フリーリストを確保
        pool.free_list = try allocator.alloc(?*Node, NODE_POOL_SIZE);
        errdefer allocator.free(pool.free_list);

        // 初期状態の設定
        pool.free_count = NODE_POOL_SIZE;

        // フリーリストの初期化
        // 各ノードを未使用状態として登録
        for (0..NODE_POOL_SIZE) |i| {
            // ノードを初期化
            pool.nodes[i] = Node{
                .bitmap = [_]u64{ 0, 0, 0, 0 },
                .children = null,
                .prefix_set = false,
                .prefix_value = 0,
            };
            // フリーリストに登録
            pool.free_list[i] = &pool.nodes[i];
        }

        return pool;
    }

    // プールの解放
    // -----------
    // 確保した全てのメモリを解放
    pub fn deinit(self: *NodePool, allocator: std.mem.Allocator) void {
        allocator.free(self.free_list);
        allocator.free(self.nodes);
        allocator.destroy(self);
    }

    // ノードの割り当て
    // ---------------
    // 1. フリーリストから未使用ノードを取得
    // 2. 未使用ノードがなければnullを返す
    // 3. 取得したノードは使用中としてマーク
    pub fn allocate(self: *NodePool) ?*Node {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_list[self.free_count];
    }

    // ノードの解放
    // -----------
    // 1. 使用済みノードをフリーリストに戻す
    // 2. プールが満杯の場合は何もしない
    // 注意: ノードの内容はクリアせず、再利用時に上書き
    pub fn free(self: *NodePool, node: *Node) void {
        if (self.free_count >= NODE_POOL_SIZE) return;
        self.free_list[self.free_count] = node;
        self.free_count += 1;
    }

    // ノードの再帰的な解放
    // ------------------
    // 1. 子ノードを再帰的に解放
    // 2. 子ノード配列を解放
    // 3. ノード自体をフリーリストに戻す
    pub fn freeNodeRecursive(self: *NodePool, node: *Node) void {
        if (node.children) |children| {
            // 子ノードを再帰的に解放
            for (children) |child| {
                self.freeNodeRecursive(child);
            }
            // 子ノード配列を解放
            std.heap.c_allocator.free(children);
            node.children = null;
        }
        // ノードをフリーリストに戻す
        self.free(node);
    }
}; 