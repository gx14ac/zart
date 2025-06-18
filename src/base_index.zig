//! プレフィックスとベースインデックスの相互変換機能
//! 
//! このモジュールは、プレフィックス（オクテットとプレフィックス長）と
//! ベースインデックスの間の変換を提供します。
//! 
//! 主な機能：
//! - プレフィックスからインデックスへの変換
//! - インデックスからプレフィックスへの変換
//! - ホストアドレスのインデックス計算
//! - プレフィックス長と範囲の計算

const std = @import("std");

/// ホストアドレスのインデックスを計算
/// これはPfxToIdx(octet/8)の高速版です。
pub fn hostIdx(octet: u8) usize {
    return @as(usize, octet) + 256;
}

/// 8ビットプレフィックスを数値にマッピング
/// プレフィックスは0/0から255/8の範囲で、マッピングされた値は1から511の範囲です。
/// 
/// 例：octet/pfxLen: 160/3 = 0b1010_0000/3 => idxToPfx(160/3) => 13
/// 
///     0b1010_0000 => 0b0000_0101
///      ^^^ >> (8-3)         ^^^
/// 
///     0b0000_0001 => 0b0000_1000
///               ^ << 3      ^
///      + -----------------------
///                0b0000_1101 = 13
fn pfxToIdx(octet: u8, pfx_len: u8) usize {
    std.debug.assert(pfx_len <= 63);
    const shift: u6 = @intCast(pfx_len);
    const right_shift: u6 = @intCast(8 - pfx_len);
    return (@as(usize, octet) >> right_shift) + (@as(usize, 1) << shift);
}

/// 8ビットプレフィックスを数値にマッピング（256バージョン）
/// 値の範囲は[1..255]です。255より大きい値は>>1でシフトされます。
pub fn pfxToIdx256(octet: u8, pfx_len: u8) u8 {
    const idx = pfxToIdx(octet, pfx_len);
    if (idx > 255) {
        return @as(u8, @intCast(idx >> 1));
    }
    return @as(u8, @intCast(idx));
}

/// ベースインデックスからオクテットとプレフィックス長を返す
/// pfxToIdx256の逆関数です。
/// 
/// 無効な入力の場合はエラーを返します。
pub fn idxToPfx256(idx: u8) !struct { octet: u8, pfx_len: u8 } {
    if (idx == 0) {
        return error.InvalidIndex;
    }

    const pfx_len = @as(u8, @intCast(std.math.log2_int(u8, idx)));
    const shift_bits = 8 - pfx_len;
    const mask = @as(u8, 0xff) >> @intCast(shift_bits);
    const octet = (idx & mask) << @intCast(shift_bits);

    return .{
        .octet = octet,
        .pfx_len = pfx_len,
    };
}

/// 深さとインデックスからプレフィックス長を計算
pub fn pfxLen256(depth: i32, idx: u8) !u8 {
    if (idx == 0) {
        return error.InvalidIndex;
    }
    return @as(u8, @intCast(depth * 8 + std.math.log2_int(u8, idx)));
}

/// プレフィックスインデックスから範囲（最初と最後のオクテット）を返す
pub fn idxToRange256(idx: u8) !struct { first: u8, last: u8 } {
    const pfx = try idxToPfx256(idx);
    const last = pfx.octet | ~netMask(pfx.pfx_len);
    return .{
        .first = pfx.octet,
        .last = last,
    };
}

/// ビット数に基づくネットワークマスクを生成
/// 
/// 0b0000_0000, // bits == 0
/// 0b1000_0000, // bits == 1
/// 0b1100_0000, // bits == 2
/// 0b1110_0000, // bits == 3
/// 0b1111_0000, // bits == 4
/// 0b1111_1000, // bits == 5
/// 0b1111_1100, // bits == 6
/// 0b1111_1110, // bits == 7
/// 0b1111_1111, // bits == 8
pub fn netMask(bits: u8) u8 {
    std.debug.assert(bits <= 8);
    if (bits == 0) return 0;
    const shift: u3 = @intCast(8 - bits);
    return @as(u8, 0xff) << shift;
}

// テスト
test "base_index" {
    // HostIdxのテスト
    try std.testing.expectEqual(@as(usize, 256), hostIdx(0));
    try std.testing.expectEqual(@as(usize, 257), hostIdx(1));
    try std.testing.expectEqual(@as(usize, 511), hostIdx(255));

    // PfxToIdx256のテスト
    try std.testing.expectEqual(@as(u8, 13), pfxToIdx256(160, 3));
    try std.testing.expectEqual(@as(u8, 1), pfxToIdx256(0, 0));
    try std.testing.expectEqual(@as(u8, 255), pfxToIdx256(255, 8));

    // IdxToPfx256のテスト
    const pfx1 = try idxToPfx256(13);
    try std.testing.expectEqual(@as(u8, 160), pfx1.octet);
    try std.testing.expectEqual(@as(u8, 3), pfx1.pfx_len);

    // PfxLen256のテスト
    try std.testing.expectEqual(@as(u8, 3), try pfxLen256(0, 13));
    try std.testing.expectEqual(@as(u8, 11), try pfxLen256(1, 13));

    // IdxToRange256のテスト
    const range1 = try idxToRange256(13);
    try std.testing.expectEqual(@as(u8, 160), range1.first);
    try std.testing.expectEqual(@as(u8, 191), range1.last);

    // NetMaskのテスト
    try std.testing.expectEqual(@as(u8, 0b0000_0000), netMask(0));
    try std.testing.expectEqual(@as(u8, 0b1000_0000), netMask(1));
    try std.testing.expectEqual(@as(u8, 0b1111_1111), netMask(8));
} 