//! 基本的なベンチマークテスト
//! 
//! このベンチマークは以下の項目をテストします：
//! 1. 基本的なルックアップ性能（単一スレッド）
//! 2. シンプルな使用パターンでの性能
//! 3. 基本的なメモリ使用量
//! 
//! 主な用途：
//! - 基本的な性能のベースライン測定
//! - 単一スレッド環境での性能評価
//! - シンプルな使用パターンでの最適化の検証
//! 
//! 注意点：
//! - 単一スレッドのみのテスト
//! - 比較的単純なIPアドレスパターンを使用
//! - メモリ断片化の影響は考慮しない

const std = @import("std");
const bart = @import("main.zig");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("unistd.h");
});

// メモリ使用量を計測する関数
fn measureMemoryUsage() usize {
    if (comptime builtin.target.os.tag == .linux) {
        var usage: usize = 0;
        if (std.os.linux.sysinfo(&usage) == 0) {
            return usage;
        }
    } else if (comptime builtin.target.os.tag == .macos) {
        // macOS: psコマンドでRSSを取得
        var argv_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&argv_buf, "{d}", .{c.getpid()}) catch return 0;
        var child = std.process.Child.init(&[_][]const u8{
            "ps", "-o", "rss=", "-p", pid_str,
        }, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.spawn() catch return 0;
        var out_buf: [64]u8 = undefined;
        const n = child.stdout.?.readAll(&out_buf) catch return 0;
        _ = child.wait() catch return 0;
        const trimmed = std.mem.trim(u8, out_buf[0..n], &std.ascii.whitespace);
        const rss_kb = std.fmt.parseInt(usize, trimmed, 10) catch return 0;
        return rss_kb * 1024;
    }
    return 0;
}

// ベンチマーク結果の構造体を共通の型として定義
const BenchmarkResult = struct {
    prefix_count: usize,
    insert_time: u64,
    insert_rate: f64,
    lookup_time: u64,
    lookup_rate: f64,
    match_rate: f64,
    memory_usage: usize,
    cache_hit_rate: f64, // benchではキャッシュテストしないので0固定
};

// ベンチマーク結果をCSVに出力する関数
fn writeBenchmarkResultsToCSV(
    results: []const BenchmarkResult,
    filename: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("prefix_count,insert_time_ns,insert_rate,lookup_time_ns,lookup_rate,match_rate,memory_usage_bytes,cache_hit_rate\n");
    for (results) |result| {
        try writer.print("{d},{d},{d:.2},{d},{d:.2},{d:.2},{d},{d:.2}\n", .{
            result.prefix_count,
            result.insert_time,
            result.insert_rate,
            result.lookup_time,
            result.lookup_rate,
            result.match_rate,
            result.memory_usage,
            result.cache_hit_rate,
        });
    }
}

// runBenchmarkの戻り値をBenchmarkResultに変更
fn runBenchmark(numPrefixes: usize, prefixLen: u8) !BenchmarkResult {
    // ルーティングテーブルの作成
    const table = bart.bart_create();
    defer bart.bart_destroy(table);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nBenchmark Configuration:\n", .{});
    try stdout.print("------------------------\n\n", .{});
    try stdout.print("Inserting {d} prefixes (/{d}):\n", .{ numPrefixes, prefixLen });
    // メモリ使用量の計測開始
    const memBefore = measureMemoryUsage();
    const startTime = std.time.milliTimestamp();
    // プレフィックスの挿入
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var i: usize = 0;
    while (i < numPrefixes) : (i += 1) {
        const addr = random.int(u32);
        _ = bart.bart_insert4(table, addr, prefixLen, 1);
        if (i < 3 or i > numPrefixes - 3) {
            try stdout.print("  {d}.{d}.{d}.{d}/{d}\n", .{
                (addr >> 24) & 0xFF,
                (addr >> 16) & 0xFF,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
                prefixLen
            });
        } else if (i == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const endTime = std.time.milliTimestamp();
    const memAfter = measureMemoryUsage();
    const insertTime = @as(f64, @floatFromInt(endTime - startTime)) / 1000.0;
    const insertRate = @as(f64, @floatFromInt(numPrefixes)) / insertTime;
    try stdout.print("\nMemory Usage:\n", .{});
    try stdout.print("  Before: {d} bytes\n", .{memBefore});
    try stdout.print("  After:  {d} bytes\n", .{memAfter});
    try stdout.print("  Delta:  {d} bytes\n", .{memAfter - memBefore});
    try stdout.print("  Per Entry: {d:.2} bytes\n", .{@as(f64, @floatFromInt(memAfter - memBefore)) / @as(f64, @floatFromInt(numPrefixes))});
    try stdout.print("\nInsert Performance: {d:.2} prefixes/sec\n\n", .{insertRate});
    // ルックアップテスト
    const numLookups: usize = 1000000;
    try stdout.print("Running {d} lookups:\n", .{numLookups});
    var matches: usize = 0;
    const lookupStartTime = std.time.milliTimestamp();
    i = 0;
    while (i < numLookups) : (i += 1) {
        const addr = random.int(u32);
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, addr, &found);
        if (found != 0) matches += 1;
        if (i < 3 or i > numLookups - 3) {
            try stdout.print("  Lookup: {d}.{d}.{d}.{d} -> {s}\n", .{
                (addr >> 24) & 0xFF,
                (addr >> 16) & 0xFF,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
                if (found != 0) "Match" else "No Match"
            });
        } else if (i == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const lookupEndTime = std.time.milliTimestamp();
    const lookupTime = @as(f64, @floatFromInt(lookupEndTime - lookupStartTime)) / 1000.0;
    const lookupRate = @as(f64, @floatFromInt(numLookups)) / lookupTime;
    const matchRate = (@as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(numLookups))) * 100.0;
    try stdout.print("\nBenchmark Results:\n", .{});
    try stdout.print("  Insert Time: {d:.2}ms\n", .{insertTime * 1000.0});
    try stdout.print("  Insert Rate: {d:.2} prefixes/sec\n", .{insertRate});
    try stdout.print("  Lookup Time: {d:.2}ms\n", .{lookupTime * 1000.0});
    try stdout.print("  Lookup Rate: {d:.2} lookups/sec\n", .{lookupRate});
    try stdout.print("  Match Rate: {d:.2}%\n", .{matchRate});
    // BenchmarkResultで返す
    return BenchmarkResult{
        .prefix_count = numPrefixes,
        .insert_time = @as(u64, @intCast(@abs(endTime - startTime) * 1000000)), // 安全な変換
        .insert_rate = insertRate,
        .lookup_time = @as(u64, @intCast(@abs(lookupEndTime - lookupStartTime) * 1000000)), // 安全な変換
        .lookup_rate = lookupRate,
        .match_rate = matchRate,
        .memory_usage = memAfter,
        .cache_hit_rate = 0.0,
    };
}

// main関数で複数回のベンチマーク結果を集約し、CSV出力
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Routing Table Benchmark\n", .{});
    try stdout.print("===========================\n\n", .{});
    var benchmark_results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer benchmark_results.deinit();
    // 既存のテストケース
    try benchmark_results.append(try runBenchmark(1000, 16));
    try benchmark_results.append(try runBenchmark(10000, 24));
    try benchmark_results.append(try runBenchmark(100000, 32));
    // 新しい大規模テストケース
    try stdout.print("\nLarge Scale Benchmark:\n", .{});
    try stdout.print("=====================\n", .{});
    try benchmark_results.append(try runBenchmark(1000000, 24));
    // assetsディレクトリの作成（存在しない場合）
    std.fs.cwd().makeDir("assets") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // CSV出力
    try writeBenchmarkResultsToCSV(benchmark_results.items, "assets/basic_bench_results.csv");
    try stdout.print("\nBenchmark results have been written to assets/basic_bench_results.csv\n", .{});
} 