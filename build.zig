const std = @import("std");
const print = std.debug.print;

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
    b.installArtifact(lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ZART",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // ZART Benchmark executable - matching Go BART's fulltable_test.go
    const zart_bench = b.addExecutable(.{
        .name = "zart_benchmark", 
        .root_source_file = b.path("src/zart_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true, // Strip symbols for maximum performance
        .link_libc = false, // Avoid libc overhead
    });
    
    const contains_lookup_bench = b.addExecutable(.{
        .name = "contains_lookup_bench", 
        .root_source_file = b.path("src/benchmark_contains_lookup.zig"),
        .target = target,
        .optimize = optimize,
    });

    const insert_bench = b.addExecutable(.{
        .name = "insert_bench", 
        .root_source_file = b.path("src/benchmark_insert.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    b.installArtifact(zart_bench);
    b.installArtifact(contains_lookup_bench);
    b.installArtifact(insert_bench);

    // Test executable
    const test_exe = b.addExecutable(.{
        .name = "test_basic",
        .root_source_file = b.path("src/test_basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(test_exe);

    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ZART Benchmark run command
    const bench_cmd = b.addRunArtifact(zart_bench);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Contains & Lookup Benchmark run command
    const contains_lookup_cmd = b.addRunArtifact(contains_lookup_bench);
    contains_lookup_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        contains_lookup_cmd.addArgs(args);
    }

    // Insert Benchmark run command
    const insert_cmd = b.addRunArtifact(insert_bench);
    insert_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        insert_cmd.addArgs(args);
    }

    // Test run command  
    const test_cmd = b.addRunArtifact(test_exe);
    test_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_cmd.addArgs(args);
    }

    // Build steps
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const bench_step = b.step("bench", "Run ZART benchmarks (matches Go BART's fulltable_test.go)");
    bench_step.dependOn(&bench_cmd.step);

    const contains_lookup_step = b.step("contains_lookup", "Run contains_lookup benchmarks");
    contains_lookup_step.dependOn(&contains_lookup_cmd.step);

    const insert_step = b.step("insert", "Run insert benchmarks"); 
    insert_step.dependOn(&insert_cmd.step);

    const test_step = b.step("test-basic", "Run basic tests");
    test_step.dependOn(&test_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_unit_step = b.step("test", "Run unit tests");
    test_unit_step.dependOn(&run_lib_unit_tests.step);

    // Bitset tests
    const bitset_tests = b.addTest(.{
        .root_source_file = b.path("src/bitset256.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_bitset_tests = b.addRunArtifact(bitset_tests);
    test_unit_step.dependOn(&run_bitset_tests.step);

    // Lookup table tests
    const lookup_tests = b.addTest(.{
        .root_source_file = b.path("src/lookup_tbl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lookup_tests = b.addRunArtifact(lookup_tests);
    test_unit_step.dependOn(&run_lookup_tests.step);

    // Sparse array tests
    const sparse_tests = b.addTest(.{
        .root_source_file = b.path("src/sparse_array256.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_sparse_tests = b.addRunArtifact(sparse_tests);
    test_unit_step.dependOn(&run_sparse_tests.step);



    // NodePool tests
    const nodepool_tests = b.addTest(.{
        .root_source_file = b.path("src/node_pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_nodepool_tests = b.addRunArtifact(nodepool_tests);
    test_unit_step.dependOn(&run_nodepool_tests.step);

    // NodePool usage test
    const nodepool_usage_test = b.addExecutable(.{
        .name = "nodepool_test",
        .root_source_file = b.path("src/nodepool_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(nodepool_usage_test);

    const nodepool_usage_cmd = b.addRunArtifact(nodepool_usage_test);
    nodepool_usage_cmd.step.dependOn(b.getInstallStep());

    const nodepool_usage_step = b.step("nodepool-test", "Run NodePool usage test");
    nodepool_usage_step.dependOn(&nodepool_usage_cmd.step);

    // NodePool advanced test
    const nodepool_advanced_test = b.addExecutable(.{
        .name = "nodepool_advanced_test",
        .root_source_file = b.path("src/nodepool_advanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(nodepool_advanced_test);

    const nodepool_advanced_cmd = b.addRunArtifact(nodepool_advanced_test);
    nodepool_advanced_cmd.step.dependOn(b.getInstallStep());

    const nodepool_advanced_step = b.step("nodepool-advanced", "Run advanced NodePool test with Insert→Delete→Insert cycles");
    nodepool_advanced_step.dependOn(&nodepool_advanced_cmd.step);
}
