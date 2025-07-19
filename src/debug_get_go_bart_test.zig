const std = @import("std");
const print = std.debug.print;

pub fn main() !void {
    print("=== Go BART Get Method Analysis ===\n\n", .{});
    
    // Go BARTのGetメソッドのロジックを分析
    print("Go BART Get method for 1.2.3.4/32:\n", .{});
    print("  octets = [1, 2, 3, 4]\n", .{});
    print("  maxDepth = 4, lastBits = 0\n\n", .{});
    
    print("Loop execution:\n", .{});
    print("  for depth, octet := range octets {{\n", .{});
    print("    depth=0, octet=1: if 0 == 4 -> false, continue\n", .{});
    print("    depth=1, octet=2: if 1 == 4 -> false, continue\n", .{});
    print("    depth=2, octet=3: if 2 == 4 -> false, continue\n", .{});
    print("    depth=3, octet=4: if 3 == 4 -> false, check children\n", .{});
    print("  }}\n\n", .{});
    
    print("At depth=3 (last octet):\n", .{});
    print("- depth != maxDepth, so it doesn't check prefixes array\n", .{});
    print("- It checks children and finds a leafNode\n", .{});
    print("- leafNode contains the full prefix 1.2.3.4/32\n", .{});
    print("- It compares: kid.prefix == pfx\n", .{});
    print("- If match, returns kid.value\n\n", .{});
    
    print("=== The Issue in ZART ===\n", .{});
    print("ZART's current implementation:\n", .{});
    print("1. Has an extra check: if (depth >= octets.len) break;\n", .{});
    print("2. This prevents processing the last octet properly\n", .{});
    print("3. We need to remove this check\n\n", .{});
    
    print("But wait, that check was just added to fix another issue!\n", .{});
    print("The real problem might be elsewhere...\n", .{});
} 