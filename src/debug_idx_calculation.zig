const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== Manual Calculation for idx=128 ===\n\n", .{});

    const idx: u8 = 128;
    
    // Step 1: Calculate bits.Len8(idx) equivalent
    // In Go: bits.Len8(128) = 8 (number of bits needed to represent 128)
    // 128 = 0b10000000, so we need 8 bits
    const bits_len = @as(u8, @intCast(std.math.log2_int(u8, idx))) + 1;
    try stdout.print("Step 1: bits.Len8({}) = {}\n", .{ idx, bits_len });
    try stdout.print("  128 in binary: 0b{b:0>8}\n", .{idx});
    
    // Step 2: Calculate pfx_len
    const pfx_len = bits_len - 1;
    try stdout.print("\nStep 2: pfx_len = bits_len - 1 = {} - 1 = {}\n", .{ bits_len, pfx_len });
    
    // Step 3: Calculate shift_bits
    const shift_bits = 8 - pfx_len;
    try stdout.print("\nStep 3: shift_bits = 8 - pfx_len = 8 - {} = {}\n", .{ pfx_len, shift_bits });
    
    // Step 4: Calculate mask
    const mask = @as(u8, 0xff) >> @as(u3, @intCast(shift_bits));
    try stdout.print("\nStep 4: mask = 0xff >> {} = 0b{b:0>8}\n", .{ shift_bits, mask });
    
    // Step 5: Calculate octet
    const octet = (idx & mask) << @as(u3, @intCast(shift_bits));
    try stdout.print("\nStep 5: octet = (idx & mask) << shift_bits\n", .{});
    try stdout.print("  idx & mask = {} & {} = {}\n", .{ idx, mask, idx & mask });
    try stdout.print("  {} << {} = {}\n", .{ idx & mask, shift_bits, octet });
    
    try stdout.print("\nFinal result: idx={} → octet={}, pfx_len={}\n", .{ idx, octet, pfx_len });
    
    // Now let's check what this means
    try stdout.print("\n=== What does this represent? ===\n", .{});
    try stdout.print("With pfx_len=7, this represents a /7 prefix\n", .{});
    try stdout.print("The octet value {} with /7 covers range {}-{}\n", .{ 
        octet, 
        octet, 
        octet | ((@as(u8, 1) << @as(u3, @intCast(shift_bits))) - 1)
    });

    // Compare with Go BART expectation
    try stdout.print("\n=== Go BART Expectation ===\n", .{});
    try stdout.print("For 192.168.0.1/32, we expect:\n", .{});
    try stdout.print("  PfxToIdx256(1, 8) should give us index 128\n", .{});
    try stdout.print("  So idx=128 should represent octet=1 with pfx_len=8\n", .{});
    try stdout.print("  But we're getting octet=0 with pfx_len=7!\n", .{});
} 