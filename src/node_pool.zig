const std = @import("std");

// メモリ管理の最適化: ノードプールの実装
// ============================================
// ノードプールは、ノードのメモリを事前に確保し、再利用することで
// 以下の最適化を実現します：
// 1. アロケーション回数の削減
// 2. メモリの局所性の向上
// 3. キャッシュの効率的な利用
// 4. メモリフラグメンテーションの防止

// ノードプールの設定
// ------------------
// NODE_POOL_SIZE: プール内のノード数
// NODE_POOL_ALIGN: キャッシュラインサイズに合わせたアライメント
//                  (一般的なx86_64では64バイト)
pub const NODE_POOL_SIZE = 1024;
pub const NODE_POOL_ALIGN = 64;

// ノードの基本構造
// ---------------
// キャッシュフレンドリーなレイアウトを考慮した構造体
pub const Node = struct {
    // ビットマップ（256ビット = 4 * 64ビット）
    // キャッシュラインサイズにアライメント
    // 各ビットが子ノードの存在を示す
    bitmap: [4]u64 align(NODE_POOL_ALIGN),

    // 子ノードへのポインタ配列
    // ビットマップの1の数と同数の要素を持つ
    children: ?[]*Node,

    // プレフィックス終端フラグ
    // このノードがプレフィックスの終端かどうか
    prefix_set: bool,

    // プレフィックス値
    // プレフィックス終端の場合の値
    prefix_value: usize,

    // 子ノードの検索
    // -------------
    // 1. キーに対応するビットをチェック
    // 2. ビットが1の場合、対応する子ノードを返す
    // 3. ビットが0の場合、nullを返す
    //
    // ビットマップの構造（4個のu64、合計256ビット）
    // [chunk_index=0] [chunk_index=1] [chunk_index=2] [chunk_index=3]
    // [0..63]         [64..127]       [128..191]      [192..255]
    pub fn findChild(self: *const Node, key: u8) ?*Node {
        // キーをビットマップのインデックスに変換
        // 例: key=65の場合
        // chunk_index = 65 >> 6 = 1 (2番目のu64)
        // bit_offset = 65 & 0x3F = 1 (2番目のビット)
        const chunk_index = key >> 6;
        const bit_offset = @as(u6, @truncate(key & 0x3F));

        // 該当するビットをチェック
        if (((self.bitmap[chunk_index] >> bit_offset) & 1) == 0) {
            return null;
        }

        // 子ノードのインデックスを計算
        // 1. 前のチャンクの1のビット数を合計
        // 2. 現在のチャンクで、該当ビットより前の1のビット数を加算
        var index: usize = 0;
        var i: usize = 0;
        while (i < chunk_index) : (i += 1) {
            index += @popCount(self.bitmap[i]);
        }

        // マスクを作成して、該当ビットより前の1のビット数を計算
        const mask = if (bit_offset == 0) 0 else (~(@as(u64, 1) << bit_offset));
        index += @popCount(self.bitmap[chunk_index] & mask);

        // 対応する子ノードを返す
        return self.children.?[index];
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