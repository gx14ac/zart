const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "bart",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, 
    });
    lib.installHeader(b.path("src/bart.h"), "bart.h");
    b.installArtifact(lib);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_exe.linkLibrary(lib);
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&run_bench.step);

    const rt_bench_exe = b.addExecutable(.{
        .name = "rt_bench",
        .root_source_file = b.path("src/rt_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    rt_bench_exe.linkLibrary(lib);
    b.installArtifact(rt_bench_exe);

    const run_rt_bench = b.addRunArtifact(rt_bench_exe);
    const rt_bench_step = b.step("rt_bench", "Run the rt benchmarks");
    rt_bench_step.dependOn(&run_rt_bench.step);

    const advanced_bench_exe = b.addExecutable(.{
        .name = "advanced_bench",
        .root_source_file = b.path("src/advanced_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    advanced_bench_exe.linkLibrary(lib);
    b.installArtifact(advanced_bench_exe);

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


    const base_index_tests = b.addTest(.{
        .root_source_file = b.path("src/base_index.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_base_index_tests = b.addRunArtifact(base_index_tests);
    const base_index_test_step = b.step("base_index_test", "Run base_index tests");
    base_index_test_step.dependOn(&run_base_index_tests.step);

    const test_basic_tests = b.addTest(.{
        .root_source_file = b.path("src/test_basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test_basic_tests = b.addRunArtifact(test_basic_tests);
    const test_basic_test_step = b.step("test_basic_test", "Run test_basic tests");
    test_basic_test_step.dependOn(&run_test_basic_tests.step);
}

pub fn asSlice(self: IPAddr) []const u8 {
    return switch (self) {
        .v4 => |*v4| v4[0..],
        .v6 => |*v6| v6[0..],
    };
}
