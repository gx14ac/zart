// マルチスレッド環境での性能評価用ベンチマーク
// 
// 測定項目：
// - スレッド数に応じた性能スケーリング
// - 実際のルーティングテーブルに近いIPアドレスパターンでの性能
// - スレッドごとの性能分析
// - メモリ断片化の影響
// 
// 使い方：
// - マルチスレッド環境での性能確認
// - スレッド数による性能変化の測定
// - 実環境に近い条件での性能評価
// - スレッド間の性能差の分析
// 
// 特徴：
// - スレッド数は可変
// - 実環境に近いIPアドレスパターン
// - スレッドごとの詳細な性能データ
// - メモリ断片化の測定
// - エラー処理の強化

const std = @import("std");
const bart = @import("main.zig");
const time = std.time;
const Timer = time.Timer;
const builtin = @import("builtin");
const os = std.os;
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/task_info.h");
    @cInclude("unistd.h");
});

// テスト設定
const TestConfig = struct {
    prefix_count: u32,
    lookup_count: u32,
    random_seed: u64,
    thread_count: u32,
    test_duration_sec: u32,
    fragmentation_cycles: u32,
};

// スレッドごとの結果を格納する構造体
const ThreadResult = struct {
    lookups: u64,
    matches: u64,
    time_ns: u64,
};

// テスト結果
const BenchmarkResult = struct {
    prefix_count: usize,
    insert_time: u64,
    insert_rate: f64,
    lookup_time: u64,
    lookup_rate: f64,
    match_rate: f64,
    memory_usage: usize,
    cache_hit_rate: f64,
    thread_count: u32,  // 追加：スレッド数
    fragmentation_impact: f64,  // 追加：断片化の影響
};

// グローバルにスレッドごとの結果を格納する配列を用意
var global_thread_results: ?[]ThreadResult = null;
var global_thread_errors: ?[]?[]const u8 = null;

/// より多様なIPアドレスパターンを生成
/// 
/// この関数は以下のパターンのIPアドレスを生成します：
/// 1. 完全ランダム
/// 2. 連続したIP
/// 3. サブネット内のIP
/// 4. 特定のASのIP範囲
/// 5. マルチキャスト範囲
/// 
/// パラメータ：
/// - random: 乱数生成器
/// - count: 生成するIPアドレスの数
fn generateDiverseIPs(random: std.Random, count: u32) ![]u32 {
    var ips = try std.heap.page_allocator.alloc(u32, count);
    errdefer std.heap.page_allocator.free(ips);

    // 異なるパターンのIPアドレスを生成
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const pattern = random.uintAtMost(u8, 4); // 0から4までの5つのパターン
        switch (pattern) {
            0 => { // ランダム
                ips[i] = random.int(u32);
            },
            1 => { // 連続したIP
                if (i > 0) {
                    ips[i] = ips[i - 1] + 1;
                } else {
                    ips[i] = random.int(u32);
                }
            },
            2 => { // サブネット内のIP
                const base = random.int(u32) & 0xFFFFFF00; // /24のベース
                ips[i] = base | random.uintAtMost(u8, 255);
            },
            3 => { // 特定のASのIP範囲
                const as_base = @as(u32, random.uintAtMost(u16, 65535)) << 16;
                ips[i] = as_base | random.uintAtMost(u16, 65535);
            },
            4 => { // マルチキャスト範囲
                const multicast_base = 0xE0000000;
                ips[i] = multicast_base | random.uintAtMost(u32, 0x0FFFFFFF);
            },
            else => { // 予期しないパターンの場合はランダムなIPを生成
                ips[i] = random.int(u32);
            },
        }
    }
    return ips;
}

/// メモリ断片化のシミュレーション
/// 
/// この関数はメモリ断片化をシミュレートします：
/// 1. ランダムなサイズのメモリブロックを割り当て
/// 2. 定期的にブロックを解放
/// 3. 断片化の影響を測定
fn simulateFragmentation(allocator: std.mem.Allocator, cycles: u32) !void {
    var blocks = std.ArrayList([]u8).init(allocator);
    defer {
        for (blocks.items) |block| {
            allocator.free(block);
        }
        blocks.deinit();
    }

    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        // ランダムなサイズのメモリブロックを割り当て
        const size = 1024 + (i % 10) * 1024; // 1KBから10KB
        const block = try allocator.alloc(u8, size);
        try blocks.append(block);

        // 時々ブロックを解放して断片化を促進
        if (i % 3 == 0 and blocks.items.len > 0) {
            const idx = i % blocks.items.len;
            allocator.free(blocks.orderedRemove(idx));
        }
    }
}

/// スレッドごとのルックアップテスト
/// 
/// この関数は各スレッドで実行され、以下の項目を測定します：
/// 1. スレッドごとのルックアップ速度
/// 2. スレッドごとのマッチ率
/// 3. スレッドごとの実行時間
/// 
/// パラメータ：
/// - table: ルックアップテーブル
/// - ips: テスト用IPアドレス配列
/// - iterations: 実行するルックアップの数
/// - thread_id: スレッドID
fn threadLookupTest(
    table: *bart.BartTable,
    ips: []const u32,
    iterations: u32,
    thread_id: u32,
) void {
    // エラー情報を格納するバッファ
    var error_buf: [256]u8 = undefined;
    var error_message: ?[]const u8 = null;

    // Timerの初期化
    var timer = Timer.start() catch |err| {
        const msg = std.fmt.bufPrint(&error_buf, "Timer.start() failed: {}", .{err}) catch "Timer.start() failed";
        error_message = msg;
        if (global_thread_errors) |errors| {
            errors[thread_id] = error_message;
        }
        return;
    };

    // 乱数生成器の初期化
    var prng = std.rand.DefaultPrng.init(42 + thread_id);
    const random = prng.random();
    var matches: u64 = 0;

    // ルックアップテストの実行
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        if (ips.len == 0) {
            const msg = std.fmt.bufPrint(&error_buf, "Empty IPs array", .{}) catch "Empty IPs array";
            error_message = msg;
            break;
        }

        const ip = ips[random.uintAtMost(u32, @intCast(ips.len - 1))];
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, ip, &found);
        if (found != 0) matches += 1;
    }

    // 結果の保存
    if (global_thread_results) |results| {
        results[thread_id] = ThreadResult{
            .lookups = iterations,
            .matches = matches,
            .time_ns = timer.read(),
        };
    }

    // エラー情報の保存
    if (error_message != null) {
        if (global_thread_errors) |errors| {
            errors[thread_id] = error_message;
        }
    }
}

/// マルチスレッドベンチマーク
/// 
/// このテストは以下の項目を測定します：
/// 1. マルチスレッド環境での総合性能
/// 2. スレッドごとの詳細な性能
/// 3. メモリ断片化の影響
/// 4. 全体のメモリ使用量
/// 
/// パラメータ：
/// - config: テスト設定（プレフィックス数、ルックアップ数、スレッド数など）
/// 
/// 戻り値：
/// - BenchmarkResult: テスト結果（ルックアップ数、マッチ数、実行時間など）
fn runMultiThreadedBenchmark(config: TestConfig) !BenchmarkResult {
    const stdout = std.io.getStdOut().writer();
    var prng = std.rand.DefaultPrng.init(config.random_seed);
    const random = prng.random();

    // テーブルの作成
    const table = bart.bart_create();
    defer bart.bart_destroy(table);

    // 多様なIPアドレスの生成
    const test_ips = try generateDiverseIPs(random, config.lookup_count);
    defer std.heap.page_allocator.free(test_ips);

    // プレフィックスの挿入
    try stdout.print("\nInserting prefixes...\n", .{});
    var i: u32 = 0;
    while (i < config.prefix_count) : (i += 1) {
        const ip = random.int(u32);
        const length = 8 + random.uintAtMost(u8, 24); // /8から/32
        _ = bart.bart_insert4(@constCast(table), ip, length, 1);
    }

    // メモリ断片化の影響を測定
    try stdout.print("\nMeasuring fragmentation impact...\n", .{});
    const initial_mem = try measureMemoryUsage();
    try simulateFragmentation(std.heap.page_allocator, config.fragmentation_cycles);
    const final_mem = try measureMemoryUsage();
    const fragmentation_impact = @as(f64, @floatFromInt(final_mem - initial_mem)) / @as(f64, @floatFromInt(initial_mem)) * 100.0;

    // スレッドごとの結果配列をグローバルにセット
    const thread_results = try std.heap.page_allocator.alloc(ThreadResult, config.thread_count);
    global_thread_results = thread_results;

    // スレッドごとのエラー情報配列をグローバルにセット
    const thread_errors = try std.heap.page_allocator.alloc(?[]const u8, config.thread_count);
    global_thread_errors = thread_errors;

    // スレッドの作成と実行
    try stdout.print("\nRunning multi-threaded test with {d} threads...\n", .{config.thread_count});
    const threads = try std.heap.page_allocator.alloc(std.Thread, config.thread_count);
    defer std.heap.page_allocator.free(threads);

    var timer = try Timer.start();
    for (threads, 0..) |*thread, tid| {
        const tid_u32: u32 = @truncate(tid);
        thread.* = try std.Thread.spawn(.{}, threadLookupTest, .{
            @constCast(table),
            test_ips,
            config.lookup_count / config.thread_count,
            tid_u32,
        });
    }

    // スレッドの終了を待つ
    for (threads) |thread| {
        thread.join();
    }
    const total_time = timer.read();

    // エラーチェック
    if (global_thread_errors) |errors| {
        for (errors, 0..) |err, tid| {
            if (err) |msg| {
                try stdout.print("Thread {d} error: {s}\n", .{tid, msg});
            }
        }
    }

    // 結果の集計
    var total_lookups: u64 = 0;
    var total_matches: u64 = 0;
    for (thread_results) |result| {
        total_lookups += result.lookups;
        total_matches += result.matches;
    }

    // グローバル変数のクリーンアップ
    global_thread_errors = null;
    global_thread_results = null;

    // エラー情報配列の解放
    std.heap.page_allocator.free(thread_errors);

    const lookup_rate = @as(f64, @floatFromInt(total_lookups)) / (@as(f64, @floatFromInt(total_time)) / 1_000_000_000.0);
    const match_rate = @as(f64, @floatFromInt(total_matches)) / @as(f64, @floatFromInt(total_lookups)) * 100.0;

    return BenchmarkResult{
        .prefix_count = config.prefix_count,
        .insert_time = 0,  // マルチスレッドテストでは挿入時間は計測しない
        .insert_rate = 0,  // マルチスレッドテストでは挿入レートは計測しない
        .lookup_time = total_time,
        .lookup_rate = lookup_rate,
        .match_rate = match_rate,
        .memory_usage = final_mem,
        .cache_hit_rate = 0.0,  // キャッシュテストは実装していない
        .thread_count = config.thread_count,
        .fragmentation_impact = fragmentation_impact,
    };
}

/// メモリ使用量の計測
/// 
/// この関数は現在のプロセスのメモリ使用量を計測します。
/// OSに応じて異なる方法を使用：
/// - macOS: psコマンドを使用
/// - Linux: /proc/self/statmを読み取り
fn measureMemoryUsage() !usize {
    if (comptime builtin.os.tag == .macos) {
        var argv_buf: [32]u8 = undefined;
        const pid_str = try std.fmt.bufPrint(&argv_buf, "{d}", .{c.getpid()});
        var child = std.process.Child.init(&[_][]const u8{
            "ps", "-o", "rss=", "-p", pid_str,
        }, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        var out_buf: [64]u8 = undefined;
        const n = try child.stdout.?.readAll(&out_buf);
        _ = try child.wait();
        const trimmed = std.mem.trim(u8, out_buf[0..n], &std.ascii.whitespace);
        const rss_kb = try std.fmt.parseInt(usize, trimmed, 10);
        return rss_kb * 1024;
    } else if (comptime builtin.os.tag == .linux) {
        const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
        defer file.close();
        var buf: [128]u8 = undefined;
        const bytes_read = try file.read(&buf);
        const content = buf[0..bytes_read];
        var it = std.mem.splitScalar(u8, content, ' ');
        _ = it.next();
        if (it.next()) |resident_pages_str| {
            const resident_pages = try std.fmt.parseInt(usize, resident_pages_str, 10);
            return resident_pages * std.os.system.sysconf(.PAGE_SIZE);
        }
        return error.InvalidStatmFormat;
    }
    return error.UnsupportedOS;
}

// ベンチマーク結果をCSVに出力する関数
fn writeBenchmarkResultsToCSV(
    results: []const BenchmarkResult,
    filename: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("prefix_count,insert_time_ns,insert_rate,lookup_time_ns,lookup_rate,match_rate,memory_usage_bytes,cache_hit_rate,thread_count,fragmentation_impact\n");
    for (results) |result| {
        try writer.print("{d},{d},{d:.2},{d},{d:.2},{d:.2},{d},{d:.2},{d},{d:.2}\n", .{
            result.prefix_count,
            result.insert_time,
            result.insert_rate,
            result.lookup_time,
            result.lookup_rate,
            result.match_rate,
            result.memory_usage,
            result.cache_hit_rate,
            result.thread_count,
            result.fragmentation_impact,
        });
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Advanced Benchmark Tests\n", .{});
    try stdout.print("===========================\n", .{});

    // テスト設定
    const configs = [_]TestConfig{
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 1,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 2,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 4,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 8,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
    };

    // ベンチマーク結果を格納する配列
    var benchmark_results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer benchmark_results.deinit();

    // 各設定でベンチマークを実行
    for (configs) |config| {
        try stdout.print("\nRunning benchmark with {d} threads...\n", .{config.thread_count});
        const result = try runMultiThreadedBenchmark(config);
        try benchmark_results.append(result);
    }

    // assetsディレクトリの作成（存在しない場合）
    std.fs.cwd().makeDir("assets") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // 結果をCSVファイルに出力
    try writeBenchmarkResultsToCSV(benchmark_results.items, "assets/advanced_bench_results.csv");
    try stdout.print("\nBenchmark results have been written to assets/advanced_bench_results.csv\n", .{});
} 