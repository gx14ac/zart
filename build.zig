const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 静的ライブラリlibbart.aのビルド設定
    const lib = b.addStaticLibrary(.{
        .name = "bart",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, 
    });
    // ヘッダファイルをインストール (zig-out/include/bart.h)
    lib.installHeader(b.path("src/bart.h"), "bart.h");
    b.installArtifact(lib);

    // ベンチマーク実行ファイルのビルド設定
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ライブラリをリンク
    bench_exe.linkLibrary(lib);
    b.installArtifact(bench_exe);

    // ベンチマーク実行用のステップを追加
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ベンチマーク実行ファイルのビルド設定
    const rt_bench_exe = b.addExecutable(.{
        .name = "rt_bench",
        .root_source_file = b.path("src/rt_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ライブラリをリンク
    rt_bench_exe.linkLibrary(lib);
    b.installArtifact(rt_bench_exe);

    const run_rt_bench = b.addRunArtifact(rt_bench_exe);
    const rt_bench_step = b.step("rt_bench", "Run the rt benchmarks");
    rt_bench_step.dependOn(&run_rt_bench.step);

    // 高度なベンチマーク実行ファイル
    const advanced_bench_exe = b.addExecutable(.{
        .name = "advanced_bench",
        .root_source_file = b.path("src/advanced_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    advanced_bench_exe.linkLibrary(lib);
    b.installArtifact(advanced_bench_exe);

    // 高度なベンチマーク実行ステップ
    const run_advanced_bench = b.addRunArtifact(advanced_bench_exe);
    const advanced_bench_step = b.step("advanced_bench", "Run advanced benchmarks");
    advanced_bench_step.dependOn(&run_advanced_bench.step);

    // テスト
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
