const std = @import("std");
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const Array256 = @import("sparse_array256.zig").Array256;

// =============================================================================
// ルーティングテーブルの基本操作テスト
// =============================================================================

test "空のテーブルの初期状態" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // 空のテーブルを作成
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // 初期状態の確認
    try std.testing.expectEqual(@as(usize, 0), table.size());      // 総プレフィックス数
    try std.testing.expectEqual(@as(usize, 0), table.getSize4());  // IPv4プレフィックス数
    try std.testing.expectEqual(@as(usize, 0), table.getSize6());  // IPv6プレフィックス数
}

test "プレフィックスの挿入とサイズ管理" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト用プレフィックスを作成
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    var ip3 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 8);
    const pfx3 = Prefix.init(&ip3, 64);
    std.debug.print("pfx1={any}\n", .{pfx1});
    std.debug.print("pfx2={any}\n", .{pfx2});
    std.debug.print("pfx3={any}\n", .{pfx3});
    
    // プレフィックスを挿入
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);
    table.insert(&pfx3, 300);
    
    // サイズの確認
    try std.testing.expectEqual(@as(usize, 3), table.size());      // 総数: 3
    try std.testing.expectEqual(@as(usize, 2), table.getSize4());  // IPv4: 2個
    try std.testing.expectEqual(@as(usize, 1), table.getSize6());  // IPv6: 1個
}

test "プレフィックスの取得操作" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テストデータを準備
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    var ip3 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 8);
    const pfx3 = Prefix.init(&ip3, 64);
    
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);
    table.insert(&pfx3, 300);
    
    // 各プレフィックスの値を取得
    try std.testing.expectEqual(@as(?u32, 100), table.get(&pfx1));
    try std.testing.expectEqual(@as(?u32, 200), table.get(&pfx2));
    try std.testing.expectEqual(@as(?u32, 300), table.get(&pfx3));
    
    // 存在しないプレフィックスの確認
    var ip4 = IPAddr{ .v4 = .{ 172, 16, 1, 0 } };
    const pfx4 = Prefix.init(&ip4, 24);
    try std.testing.expectEqual(@as(?u32, null), table.get(&pfx4));
}

test "最長プレフィックスマッチング（LPM）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テストデータを準備
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    var ip3 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 8);
    const pfx3 = Prefix.init(&ip3, 64);
    
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);
    table.insert(&pfx3, 300);
    
    // IPv4アドレスのLPMテスト
    var ip1_match = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const pfx1_match = Prefix.init(&ip1_match, 24);
    const ip2_match = IPAddr{ .v4 = .{ 10, 1, 2, 3 } };
    const pfx2_match = Prefix.init(&ip2_match, 8);
    
    try std.testing.expectEqual(@as(?u32, 100), table.lookup(&pfx1_match));
    try std.testing.expectEqual(@as(?u32, 200), table.lookup(&pfx2_match));
    
    // IPv6アドレスのLPMテスト
    var ip3_match = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx3_match = Prefix.init(&ip3_match, 64);
    try std.testing.expectEqual(@as(?u32, 300), table.lookup(&pfx3_match));
    
    // マッチしないIPアドレスのテスト
    var ip4 = IPAddr{ .v4 = .{ 172, 16, 1, 1 } };
    const pfx4 = Prefix.init(&ip4, 24);
    try std.testing.expectEqual(@as(?u32, null), table.lookup(&pfx4));
}

test "IPアドレスの包含チェック" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テストデータを準備
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    var ip3 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 8);
    const pfx3 = Prefix.init(&ip3, 64);
    
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);
    table.insert(&pfx3, 300);
    
    // 包含されるIPアドレスのテスト
    var ip1_contain = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const pfx1_contain = Prefix.init(&ip1_contain, 24);
    var ip2_contain = IPAddr{ .v4 = .{ 10, 1, 2, 3 } };
    const pfx2_contain = Prefix.init(&ip2_contain, 8);
    var ip3_contain = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx3_contain = Prefix.init(&ip3_contain, 64);
    
    try std.testing.expect(table.contains(&pfx1_contain));  // 192.168.1.0/24に含まれる
    try std.testing.expect(table.contains(&pfx2_contain));  // 10.0.0.0/8に含まれる
    try std.testing.expect(table.contains(&pfx3_contain));  // IPv6プレフィックスに含まれる
    
    // 包含されないIPアドレスのテスト
    var ip4 = IPAddr{ .v4 = .{ 172, 16, 1, 1 } };
    const pfx4 = Prefix.init(&ip4, 24);
    try std.testing.expect(!table.contains(&pfx4));  // どのプレフィックスにも含まれない
}

test "プレフィックスの削除操作" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テストデータを準備
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 8);
    
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);
    
    // 削除前の確認
    try std.testing.expectEqual(@as(usize, 2), table.size());
    try std.testing.expectEqual(@as(?u32, 100), table.get(&pfx1));
    
    // プレフィックスを削除
    const deleted = table.getAndDelete(&pfx1);
    try std.testing.expectEqual(@as(?u32, 100), deleted);  // 削除された値を確認
    
    // 削除後の確認
    try std.testing.expectEqual(@as(usize, 1), table.size());      // サイズが1減る
    try std.testing.expectEqual(@as(usize, 1), table.getSize4());  // IPv4が1個になる
    try std.testing.expectEqual(@as(?u32, null), table.get(&pfx1)); // 削除されたプレフィックスは取得できない
    
    // 削除されたプレフィックスに関連するIPアドレスの確認
    var ip1_deleted = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const pfx1_deleted = Prefix.init(&ip1_deleted, 24);
    try std.testing.expectEqual(@as(?u32, null), table.lookup(&pfx1_deleted)); // LPMでも見つからない
}

// =============================================================================
// プレフィックス検証とマスキングテスト
// =============================================================================

test "プレフィックスの有効性検証" {
    // 有効なプレフィックスのテスト
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip2 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    
    const pfx1 = Prefix.init(&ip1, 24);
    const pfx2 = Prefix.init(&ip2, 64);
    
    try std.testing.expect(pfx1.isValid());  // IPv4 /24は有効
    try std.testing.expect(pfx2.isValid());  // IPv6 /64は有効
    
    // 無効なプレフィックスのテスト
    var ip3 = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    var ip4 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    
    const pfx3 = Prefix.init(&ip3, 33);  // IPv4で33ビットは無効
    const pfx4 = Prefix.init(&ip4, 129); // IPv6で129ビットは無効
    
    try std.testing.expect(!pfx3.isValid());
    try std.testing.expect(!pfx4.isValid());
}

test "プレフィックスのマスキング処理" {
    // IPv4プレフィックスのマスキングテスト
    var ip1 = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const pfx1 = Prefix.init(&ip1, 24);
    const masked1 = pfx1.masked();
    
    try std.testing.expectEqual(@as(u8, 24), masked1.bits);  // ビット長は変わらない
    try std.testing.expectEqual(@as(u8, 0), masked1.addr.v4[3]);  // 最後のバイトが0にマスクされる
    
    // IPv6プレフィックスのマスキングテスト
    var ip2 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const pfx2 = Prefix.init(&ip2, 64);
    const masked2 = pfx2.masked();
    
    try std.testing.expectEqual(@as(u8, 64), masked2.bits);  // ビット長は変わらない
    // 後半8バイトが0にマスクされることを確認
    for (masked2.addr.v6[8..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

// =============================================================================
// 更新操作のテスト
// =============================================================================

test "コールバック関数による更新操作" {
    const allocator = std.testing.allocator;
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    var ip = IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    const pfx = Prefix.init(&ip, 24);
    
    // 存在しないプレフィックスの更新（新規作成）
    const result1 = table.update(&pfx, struct {
        fn callback(val: u32, exists: bool) u32 {
            _ = val;
            if (exists) {
                @panic("存在しないプレフィックスが存在すると判定された");
            }
            return 100;  // 新規作成時の値
        }
    }.callback);
    
    try std.testing.expectEqual(@as(u32, 100), result1);
    try std.testing.expectEqual(@as(usize, 1), table.size());
    
    // 既存プレフィックスの更新
    const result2 = table.update(&pfx, struct {
        fn callback(val: u32, exists: bool) u32 {
            if (!exists) {
                @panic("存在するプレフィックスが存在しないと判定された");
            }
            return val + 50;  // 既存値に50を加算
        }
    }.callback);
    
    try std.testing.expectEqual(@as(u32, 150), result2);
    try std.testing.expectEqual(@as(usize, 1), table.size());  // サイズは変わらない
    try std.testing.expectEqual(@as(?u32, 150), table.get(&pfx));  // 更新された値を確認
}

// =============================================================================
// Array256のメソッド呼び出しテスト
// =============================================================================

test "Array256の読み取り・書き込み操作" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arr = Array256(u32).init(allocator);
    defer arr.deinit();

    // 書き込み操作: 位置5に値100を挿入
    _ = (&arr).insertAt(5, 100);
    
    // 読み取り操作: 値の確認
    const arr_val = arr;  // constで受ける（読み取り専用）
    try std.testing.expect(arr_val.isSet(5));  // 位置5が設定されているか確認
    try std.testing.expectEqual(@as(u32, 100), arr_val.mustGet(5));  // 値を取得
    
    // 安全な取得操作
    if (arr_val.get(5)) |value| {
        try std.testing.expectEqual(@as(u32, 100), value);
    } else {
        return error.GetFailed;  // 取得に失敗
    }
    
    // 存在しない位置の確認
    try std.testing.expect(!arr_val.isSet(10));  // 位置10は設定されていない
    try std.testing.expectEqual(@as(?u32, null), arr_val.get(10));  // nullが返される
} 