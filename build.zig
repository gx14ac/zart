const std = @import("std");
const print = std.debug.print;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 📦 Main library
    const lib = b.addStaticLibrary(.{
        .name = "zart",
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

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



    // Build steps
    const bench_step = b.step("bench", "Run ZART benchmarks (matches Go BART's fulltable_test.go)");
    bench_step.dependOn(&bench_cmd.step);

    const contains_lookup_step = b.step("contains_lookup", "Run contains_lookup benchmarks");
    contains_lookup_step.dependOn(&contains_lookup_cmd.step);

    const insert_step = b.step("insert", "Run insert benchmarks"); 
    insert_step.dependOn(&insert_cmd.step);



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

    // Sparse array tests removed - DirectNode implementation now used

    // NodePool tests removed - DirectNode implementation doesn't use NodePool

    // Zero Alloc Insert Implementation Tests removed - integrated into DirectNode

    // Debug LMP Issue
    const debug_lmp = b.addExecutable(.{
        .name = "debug_lmp_issue",
        .root_source_file = b.path("src/debug_lmp_issue.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(debug_lmp);

    const debug_lmp_cmd = b.addRunArtifact(debug_lmp);
    debug_lmp_cmd.step.dependOn(b.getInstallStep());
    
    const debug_lmp_step = b.step("debug-lmp", "Debug LMP issue with 192.168.0.3");
    debug_lmp_step.dependOn(&debug_lmp_cmd.step);

    // Debug Detailed LMP
    const debug_detailed_lmp = b.addExecutable(.{
        .name = "debug_detailed_lmp",
        .root_source_file = b.path("src/debug_detailed_lmp.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(debug_detailed_lmp);

    const debug_detailed_lmp_cmd = b.addRunArtifact(debug_detailed_lmp);
    debug_detailed_lmp_cmd.step.dependOn(b.getInstallStep());
    
    const debug_detailed_lmp_step = b.step("debug-detailed-lmp", "Detailed analysis of LMP issue");
    debug_detailed_lmp_step.dependOn(&debug_detailed_lmp_cmd.step);

    // Debug LMP Fix Analysis
    const debug_lmp_fix = b.addExecutable(.{
        .name = "debug_lmp_fix",
        .root_source_file = b.path("src/debug_lmp_fix.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(debug_lmp_fix);

    const debug_lmp_fix_cmd = b.addRunArtifact(debug_lmp_fix);
    debug_lmp_fix_cmd.step.dependOn(b.getInstallStep());
    
    const debug_lmp_fix_step = b.step("debug-lmp-fix", "Run comprehensive LMP bug fix analysis");
    debug_lmp_fix_step.dependOn(&debug_lmp_fix_cmd.step);
    
    // Test LMP Fix Verification
    const test_lmp_fix = b.addExecutable(.{
        .name = "test_lmp_fix",
        .root_source_file = b.path("src/test_lmp_fix.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(test_lmp_fix);

    const test_lmp_fix_cmd = b.addRunArtifact(test_lmp_fix);
    test_lmp_fix_cmd.step.dependOn(b.getInstallStep());
    
    const test_lmp_fix_step = b.step("test-lmp-fix", "Run LMP fix verification test");
    test_lmp_fix_step.dependOn(&test_lmp_fix_cmd.step);
}
