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

    // test_lookupprefixlpm_fixed test
    const test_lookupprefixlpm_fixed_exe = b.addTest(.{
        .name = "test_lookupprefixlpm_fixed",
        .root_source_file = b.path("src/test_lookupprefixlpm_fixed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_lookupprefixlpm_fixed_step = b.step("test_lookupprefixlpm_fixed", "Test LookupPrefixLPM fixed implementation");
    test_lookupprefixlpm_fixed_step.dependOn(&test_lookupprefixlpm_fixed_exe.step);

    // test_node_structure test
    const test_node_structure_exe = b.addTest(.{
        .name = "test_node_structure",
        .root_source_file = b.path("src/test_node_structure.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_node_structure_step = b.step("test_node_structure", "Test ZART node structure analysis");
    test_node_structure_step.dependOn(&test_node_structure_exe.step);

    // test_index_mapping test
    const test_index_mapping_exe = b.addTest(.{
        .name = "test_index_mapping",
        .root_source_file = b.path("src/test_index_mapping.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_index_mapping_step = b.step("test_index_mapping", "Test index mapping analysis");
    test_index_mapping_step.dependOn(&test_index_mapping_exe.step);

    // debug_lpm_detailed_analysis test
    const debug_lpm_detailed_analysis_exe = b.addExecutable(.{
        .name = "debug_lpm_detailed_analysis",
        .root_source_file = b.path("src/debug_lpm_detailed_analysis.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(debug_lpm_detailed_analysis_exe);
    
    const debug_lpm_detailed_analysis_cmd = b.addRunArtifact(debug_lpm_detailed_analysis_exe);
    debug_lpm_detailed_analysis_cmd.step.dependOn(b.getInstallStep());
    
    const debug_lpm_detailed_analysis_step = b.step("debug_lpm_detailed_analysis", "Debug LPM detailed analysis");
    debug_lpm_detailed_analysis_step.dependOn(&debug_lpm_detailed_analysis_cmd.step);


}
