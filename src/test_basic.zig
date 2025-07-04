const std = @import("std");
const node = @import("node.zig");
const Table = @import("table.zig").Table;
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;

test "Basic operations" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // テストデータを挿入
    const v4_addr1 = node.IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    const v4_addr2 = node.IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const v4_addr3 = node.IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const v4_addr4 = node.IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
    
    const pfx1 = node.Prefix.init(&v4_addr1, 24);
    const pfx2 = node.Prefix.init(&v4_addr2, 16);
    const pfx3 = node.Prefix.init(&v4_addr3, 8);
    const pfx4 = node.Prefix.init(&v4_addr4, 0);
    
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    table.insert(&pfx4, 4);

    // 基本的な検索テスト
    try std.testing.expectEqual(@as(u32, 1), table.get(&pfx1).?);
    try std.testing.expectEqual(@as(u32, 2), table.get(&pfx2).?);
    try std.testing.expectEqual(@as(u32, 3), table.get(&pfx3).?);
    try std.testing.expectEqual(@as(u32, 4), table.get(&pfx4).?);

    // サイズテスト
    try std.testing.expectEqual(@as(usize, 4), table.size());
    try std.testing.expectEqual(@as(usize, 4), table.getSize4());
    try std.testing.expectEqual(@as(usize, 0), table.getSize6());

    // 削除テスト
    const deleted = table.getAndDelete(&pfx1);
    try std.testing.expect(deleted.ok);
    try std.testing.expectEqual(@as(u32, 1), deleted.value);
    try std.testing.expect(table.get(&pfx1) == null);
    try std.testing.expectEqual(@as(usize, 3), table.size());
}

test "Lookup operations" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // テストデータを挿入
    const v4_addr1 = node.IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    const v4_addr2 = node.IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const v4_addr3 = node.IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const v4_addr4 = node.IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
    
    const pfx1 = node.Prefix.init(&v4_addr1, 24);
    const pfx2 = node.Prefix.init(&v4_addr2, 16);
    const pfx3 = node.Prefix.init(&v4_addr3, 8);
    const pfx4 = node.Prefix.init(&v4_addr4, 0);
    
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    table.insert(&pfx4, 4);

    // IPアドレスでのルックアップテスト
    const search_addr = node.IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const result1 = table.lookup(&search_addr);
    try std.testing.expect(result1.ok);
    try std.testing.expectEqual(@as(u32, 1), result1.value);

    // プレフィックスでのルックアップテスト
    const search_pfx = node.Prefix.init(&node.IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const result2 = table.lookupPrefix(&search_pfx);
    try std.testing.expect(result2.ok);
    try std.testing.expectEqual(@as(u32, 1), result2.value);
}

test "Table Clone" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // 初期データを挿入
    const v4_addr1 = node.IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const v4_addr2 = node.IPAddr{ .v4 = .{ 192, 168, 1, 0 } };
    const pfx1 = node.Prefix.init(&v4_addr1, 16);
    const pfx2 = node.Prefix.init(&v4_addr2, 24);
    table.insert(&pfx1, 100);
    table.insert(&pfx2, 200);

    // テーブルをクローン
    var cloned = table.clone();
    defer cloned.deinit();

    // クローンには同じデータがあることを確認
    try std.testing.expectEqual(@as(u32, 100), cloned.get(&pfx1).?);
    try std.testing.expectEqual(@as(u32, 200), cloned.get(&pfx2).?);
    try std.testing.expectEqual(@as(usize, 2), cloned.size());

    // pfx1のサブネットではない別のネットワークを作成（LPMでマッチしない）
    const v4_addr3 = node.IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const pfx3 = node.Prefix.init(&v4_addr3, 24);
    
    const cloned2 = cloned.insertPersist(&pfx3, 300);
    defer cloned2.deinitAndDestroy();
    
    // 元のテーブルには新しいプレフィックスが存在しないことを確認
    try std.testing.expect(table.get(&pfx3) == null);
    try std.testing.expectEqual(@as(usize, 2), table.size());
    
    // クローンされたテーブルには新しいプレフィックスが存在しないことを確認
    try std.testing.expect(cloned.get(&pfx3) == null);
    try std.testing.expectEqual(@as(usize, 2), cloned.size());
    
    // 新しいテーブルには新しいデータがあることを確認
    try std.testing.expectEqual(@as(u32, 300), cloned2.get(&pfx3).?);
    try std.testing.expectEqual(@as(usize, 3), cloned2.size());
} 