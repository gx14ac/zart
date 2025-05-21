const std = @import("std");
const bart = @import("main.zig");

pub fn main() !void {
    // ベンチマーク用ルーティングテーブルを作成
    const table = bart.bart_create();
    defer {
        bart.bart_destroy(table);
    }

    // 1000個の/16プレフィックスを登録
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const ip_net = i << 16; // i.0.0.0/16 として挿入
        const res = bart.bart_insert4(table, ip_net, 16, 1);
        std.debug.assert(res == 0);
    }

    // ルックアップベンチマーク (100万回)
    var timer = std.time.Timer.start() catch unreachable;
    var j: u32 = 0;
    var found: i32 = 0;
    while (j < 1000000) : (j += 1) {
        const prefix_index = j % 1000;
        // prefix_indexに対応するネットワーク内のアドレスを構成 (prefix_index.x.y.z)
        const ip_addr = (prefix_index << 16) | (j & 0xFFFF);
        _ = bart.bart_lookup4(table, ip_addr, &found);
        std.debug.assert(found != 0);
    }
    const ns = timer.read();
    const avg = ns / 1000000;
    std.debug.print("Average lookup time: {d} ns\n", .{avg});
}
