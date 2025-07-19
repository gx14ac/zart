const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");
const lookup_tbl = @import("lookup_tbl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Detailed Octet Matching Debug ===\n", .{});
    
    // Test the exact case from testInsert
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    table.insert(&prefix1, 1);
    
    print("Step 2: Analyze what happens during lookup of 192.168.0.1\n", .{});
    
    // Manually analyze the lookup process
    const octets = addr1.asSlice();
    print("IP octets: [{}, {}, {}, {}]\n", .{ octets[0], octets[1], octets[2], octets[3] });
    
    // At depth 3 (last octet), what should happen?
    const depth = 3;
    const octet = octets[depth]; // Should be 1
    print("Depth {}: octet = {}\n", .{ depth, octet });
    
    // What index does 192.168.0.1/32 map to?
    const stored_idx = base_index.pfxToIdx256(octet, 8); // /32 means 8 bits in last octet
    print("Stored index for octet {} with 8 bits: {}\n", .{ octet, stored_idx });
    
    // What does this index decode back to?
    const decoded = base_index.idxToPfx256(stored_idx) catch {
        print("ERROR: Failed to decode index {}\n", .{stored_idx});
        return;
    };
    print("Index {} decodes to: octet={}, pfx_len={}\n", .{ stored_idx, decoded.octet, decoded.pfx_len });
    
    // During lookup, what host index is used?
    const host_idx = base_index.hostIdx(octet);
    print("Host index for octet {}: {}\n", .{ octet, host_idx });
    
    // What does BackTrackingBitset contain?
    const bs = lookup_tbl.backTrackingBitset(host_idx);
    print("BackTrackingBitset for host_idx {} contains indices: ", .{host_idx});
    for (0..256) |i| {
        if (bs.isSet(@intCast(i))) {
            print("{} ", .{i});
        }
    }
    print("\n", .{});
    
    // Key question: Does BackTrackingBitset contain our stored index?
    const contains_stored = bs.isSet(stored_idx);
    print("Does BackTrackingBitset contain stored index {}? {}\n", .{ stored_idx, contains_stored });
    
    // And the most important: does the octet match?
    if (decoded.octet == octet) {
        print("✅ Octet match: decoded.octet({}) == lookup.octet({})\n", .{ decoded.octet, octet });
    } else {
        print("❌ Octet mismatch: decoded.octet({}) != lookup.octet({})\n", .{ decoded.octet, octet });
    }
    
    print("\nStep 3: Perform actual lookup\n", .{});
    const result = table.lookup(&addr1);
    print("Lookup result: ok={}, value={}\n", .{ result.ok, if (result.ok) result.value else 0 });
    
    if (!result.ok) {
        print("❌ Lookup failed - investigating why...\n", .{});
        
        // The issue might be that we're checking octet match too strictly
        // Let's see what Go BART actually does
        print("\nPossible issues:\n", .{});
        print("1. Index {} might not represent a /32 prefix\n", .{stored_idx});
        print("2. pfx_len from index might be {} instead of 8\n", .{decoded.pfx_len});
        print("3. Octet matching logic might be incorrect\n", .{});
    }
} 