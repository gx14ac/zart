const std = @import("std");
const lookupTbl = @import("lookup_tbl.zig").lookupTbl;

// 0〜255までのビットを管理するビットセット
// キャッシュ効率を考慮して4個のu64で実装
// CPUのビット操作命令を活用

pub const BitSet256 = struct {
    // キャッシュライン（64バイト）に合わせてアライメント
    data: [4]u64 align(64),

    // ビットを1にセット
    pub fn set(self: *BitSet256, bit: u8) void {
        self.data[bit >> 6] |= (@as(u64, 1) << (bit & 63));
    }

    // ビットをクリアします。
    pub fn clear(self: *BitSet256, bit: u8) void {
        self.data[bit >> 6] &= ~(@as(u64, 1) << (bit & 63));
    }

    // ビットが立っているかチェックします。
    pub fn isSet(self: *const BitSet256, bit: u8) bool {
        return (self.data[bit >> 6] & (@as(u64, 1) << (bit & 63))) != 0;
    }

    // 最初に立っているビットを返します。立っているビットがない場合はnullを返します。
    pub fn firstSet(self: *const BitSet256) ?u8 {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (self.data[i] != 0) {
                const trailing = @ctz(self.data[i]);
                return @as(u8, (i << 6) + trailing);
            }
        }
        return null;
    }

    // 指定したビット以降で最初に立っているビットを返します。立っているビットがない場合はnullを返します。
    pub fn nextSet(self: *const BitSet256, bit: u8) ?u8 {
        var wIdx: usize = bit >> 6;
        const first: u64 = self.data[wIdx] >> (bit & 63);
        if (first != 0) {
            const trailing = @ctz(first);
            return @as(u8, bit + trailing);
        }
        wIdx += 1;
        while (wIdx < 4) : (wIdx += 1) {
            if (self.data[wIdx] != 0) {
                const trailing = @ctz(self.data[wIdx]);
                return @as(u8, (wIdx << 6) + trailing);
            }
        }
        return null;
    }

    // 立っているビットの数を返します（popcount）。
    pub fn popcnt(self: *const BitSet256) u8 {
        var cnt: u8 = 0;
        cnt += @popCount(self.data[0]);
        cnt += @popCount(self.data[1]);
        cnt += @popCount(self.data[2]);
        cnt += @popCount(self.data[3]);
        return cnt;
    }

    // 指定したビット位置までの立っているビットの数を返します（rank）。
    pub fn rank(self: *const BitSet256, idx: u8) u8 {
        var rnk: u8 = 0;
        rnk += @popCount(self.data[0] & rankMask[idx].data[0]);
        rnk += @popCount(self.data[1] & rankMask[idx].data[1]);
        rnk += @popCount(self.data[2] & rankMask[idx].data[2]);
        rnk += @popCount(self.data[3] & rankMask[idx].data[3]);
        return rnk;
    }

    // ビットセットが空かどうかを返します。
    pub fn isEmpty(self: *const BitSet256) bool {
        return (self.data[0] | self.data[1] | self.data[2] | self.data[3]) == 0;
    }

    // 2つのビットセットの積（intersection）を計算します。
    pub fn intersection(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        bs.data[0] = self.data[0] & other.data[0];
        bs.data[1] = self.data[1] & other.data[1];
        bs.data[2] = self.data[2] & other.data[2];
        bs.data[3] = self.data[3] & other.data[3];
        return bs;
    }

    // 2つのビットセットの和（union）を計算します。
    pub fn bitUnion(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        bs.data[0] = self.data[0] | other.data[0];
        bs.data[1] = self.data[1] | other.data[1];
        bs.data[2] = self.data[2] | other.data[2];
        bs.data[3] = self.data[3] | other.data[3];
        return bs;
    }

    // 2つのビットセットの積（intersection）の立っているビットの数を返します。
    pub fn intersectionCardinality(self: *const BitSet256, other: *const BitSet256) u8 {
        var cnt: u8 = 0;
        cnt += @popCount(self.data[0] & other.data[0]);
        cnt += @popCount(self.data[1] & other.data[1]);
        cnt += @popCount(self.data[2] & other.data[2]);
        cnt += @popCount(self.data[3] & other.data[3]);
        return cnt;
    }

    // 2つのビットセットの積（intersection）が空でないかどうかを返します。
    pub fn intersectsAny(self: *const BitSet256, other: *const BitSet256) bool {
        return (self.data[0] & other.data[0] != 0) ||
               (self.data[1] & other.data[1] != 0) ||
               (self.data[2] & other.data[2] != 0) ||
               (self.data[3] & other.data[3] != 0);
    }

    // 2つのビットセットの積（intersection）の最上位ビットを返します。積が空の場合はnullを返します。
    pub fn intersectionTop(self: *const BitSet256, other: *const BitSet256) ?u8 {
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const word = self.data[i-1] & other.data[i-1];
            if (word != 0) {
                const lz = @clz(word);
                const bit_pos = @as(u8, @intCast((i-1))) << 6;
                const bit_offset = @as(u8, @intCast(63 - lz));
                return bit_pos + bit_offset;
            }
        }
        return null;
    }

    // 立っているビットをスライスとして返します。bufは256個のu8のバッファです。
    pub fn asSlice(self: *const BitSet256, buf: *[256]u8) []u8 {
        var size: usize = 0;
        var wIdx: usize = 0;
        while (wIdx < 4) : (wIdx += 1) {
            var word = self.data[wIdx];
            while (word != 0) : (size += 1) {
                const trailing = @ctz(word);
                buf[size] = @as(u8, (wIdx << 6) + trailing);
                word &= (word - 1); // 最下位ビットをクリア
            }
        }
        return buf[0..size];
    }

    // 立っているビットをスライスとして返します。内部でバッファを確保します。
    pub fn all(self: *const BitSet256) []u8 {
        var buf: [256]u8 = undefined;
        return self.asSlice(&buf);
    }

    // デバッグ用の文字列を返します。
    pub fn string(self: *const BitSet256) []const u8 {
        var buf: [256]u8 = undefined;
        const slice = self.asSlice(&buf);
        var i: usize = 0;
        var j: usize = 0;
        while (i < slice.len) : (i += 1) {
            j += std.fmt.bufPrint(buf[j..], "{d} ", .{ slice[i] }) catch break;
        }
        return buf[0..j];
    }
};

// rankMaskは、0〜255までのビットが立ったBitSet256の配列です。
// 例：rankMask[7]は、0〜7までのビットが立ったBitSet256です。
pub const rankMask = blk: {
    var arr: [256]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        var j: usize = 0;
        while (j <= i) : (j += 1) {
            bs.set(@as(u8, j));
        }
        arr[i] = bs;
    }
    break :blk arr;
};

/// LPM（最長一致）検索: bitmap内でkey以下の最大ビット位置を返す（なければnull）
pub fn lpmSearch(bitmap: *const [4]u64, key: u8) ?u8 {
    // key + 1が256を超えないように制限
    const safe_key = if (key == 255) 255 else key + 1;
    const mask = lookupTbl[safe_key]; // key以下を全て1にしたマスク
    var masked = BitSet256{ .data = .{
        bitmap[0] & mask.data[0],
        bitmap[1] & mask.data[1],
        bitmap[2] & mask.data[2],
        bitmap[3] & mask.data[3],
    }};
    // 最上位ビット（key以下で最大のビット）を返す
    return masked.intersectionTop(&masked);
} 