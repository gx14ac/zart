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

    // BART Benchmark executable - matching Go BART's fulltable_test.go
    const bart_bench = b.addExecutable(.{
        .name = "bart_benchmark", 
        .root_source_file = b.path("src/bart_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true, // Strip symbols for maximum performance
        .link_libc = false, // Avoid libc overhead
    });
    
    // Go BART Compatible Benchmark - exact same conditions as fulltable_test.go
    const go_bart_bench = b.addExecutable(.{
        .name = "go_bart_benchmark", 
        .root_source_file = b.path("src/go_bart_compatible_bench.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true, // Strip symbols for maximum performance
        .link_libc = false, // Avoid libc overhead
    });
    
    // Add aggressive optimization for ReleaseFast builds
    if (optimize == .ReleaseFast) {
        bart_bench.root_module.single_threaded = true; // Single-threaded optimization
        go_bart_bench.root_module.single_threaded = true; // Single-threaded optimization
    }

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
    
    b.installArtifact(bart_bench);
    b.installArtifact(go_bart_bench);
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

    // BART Benchmark run command
    const bench_cmd = b.addRunArtifact(bart_bench);
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

    // Go BART Compatible Benchmark run command
    const go_bart_cmd = b.addRunArtifact(go_bart_bench);
    go_bart_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        go_bart_cmd.addArgs(args);
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

    const bench_step = b.step("bench", "Run BART benchmarks (matches Go BART's fulltable_test.go)");
    bench_step.dependOn(&bench_cmd.step);

    const go_bart_step = b.step("go-bench", "Run Go BART Compatible benchmarks (exact same conditions as fulltable_test.go)");
    go_bart_step.dependOn(&go_bart_cmd.step);

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
}
