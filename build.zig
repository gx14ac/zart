const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 静的ライブラリlibbart.aのビルド設定
    const lib = b.addStaticLibrary(.{
        .name = "bart",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ヘッダファイルをインストール (zig-out/include/bart.h)
    lib.installHeader(b.path("src/bart.h"), "bart.h");
    b.installArtifact(lib);

    // ベンチマーク実行ファイルのビルド設定
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/benchmark.zig"),
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
}
