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

    // Benchmarks
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


    // Application tests
    // base_index
    const base_index_tests = b.addTest(.{
        .root_source_file = b.path("src/base_index.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_base_index_tests = b.addRunArtifact(base_index_tests);
    const base_index_test_step = b.step("base_index_test", "Run base_index tests");
    base_index_test_step.dependOn(&run_base_index_tests.step);

    // test_basic
    const test_basic_tests = b.addTest(.{
        .root_source_file = b.path("src/test_basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test_basic_tests = b.addRunArtifact(test_basic_tests);
    const test_basic_test_step = b.step("test_basic_test", "Run test_basic tests");
    test_basic_test_step.dependOn(&run_test_basic_tests.step);

    // bitset256
    const bitset256_tests = b.addTest(.{
        .root_source_file = b.path("src/bitset256.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_bitset256_tests = b.addRunArtifact(bitset256_tests);
    const bitset256_test_step = b.step("bitset256_test", "Run bitset256 tests");
    bitset256_test_step.dependOn(&run_bitset256_tests.step);

    // table
    const table_tests = b.addTest(.{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_table_tests = b.addRunArtifact(table_tests);
    const table_test_step = b.step("table_test", "Run table tests");
    table_test_step.dependOn(&run_table_tests.step);

    // lookup_tbl
    const lookup_tbl_tests = b.addTest(.{
        .root_source_file = b.path("src/lookup_tbl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lookup_tbl_tests = b.addRunArtifact(lookup_tbl_tests);
    const lookup_tbl_test_step = b.step("lookup_tbl_test", "Run lookup_tbl tests");
    lookup_tbl_test_step.dependOn(&run_lookup_tbl_tests.step);

    // combine all application tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_base_index_tests.step);
    test_step.dependOn(&run_test_basic_tests.step);
    test_step.dependOn(&run_bitset256_tests.step);
    test_step.dependOn(&run_table_tests.step);
    test_step.dependOn(&run_lookup_tbl_tests.step);
}
