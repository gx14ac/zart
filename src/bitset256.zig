const std = @import("std");
const lookup_tbl = @import("lookup_tbl.zig");

const BitSet256 = struct {
    data: [4]u64,

    const Self = @This();

    pub fn testBitSet256(self: *const Self, bit: u8) bool {
        return self.data[bit >> 6] & (@as(u64, 1) << (bit & 63)) != 0;
    }

    pub fn string(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const allBits = self.All();
        return std.fmt.allocPrint(allocator, "{any}", .{allBits});
    }
    
    pub fn set(self: *Self, bit: u8) void {
        self.data[bit >> 6] |= @as(u64, 1) << (bit & 63);
    }
    
    pub fn clear(self: *Self, bit: u8) void {
        self.data[bit >> 6] &= ~(@as(u64, 1) << (bit & 63));
    }

    pub fn all(self: *const Self) []u8 {
        return self.asSlice(&[256]u8{});
    }

    pub fn asSlice(self: *const Self, buf: *[256]u8) []u8 {
        var idx: usize = 0;
        
        // for wIdx, word := range b と同等
        for (self.data, 0..) |word_orig, wIdx| {
            var word = word_orig;
            
            // for ; word != 0; size++ と同等
            while (word != 0) : (idx += 1) {
                // uint8(wIdx<<6 + bits.TrailingZeros64(word))
                buf[idx] = @intCast((wIdx << 6) + @ctz(word));
                
                // word &= word - 1 (clear the rightmost set bit)
                word &= word - 1;
            }
        }
        
        return buf[0..idx];
    }

    // 高速検索: 並列処理でパイプライン最適化
    // 早期終了: 最初に見つかった時点で終了
    // 0から255の範囲で最小値を効率的に発見
    pub fn firstSet(self: *const Self) ?u8 {
        const x0: u8 = @intCast(@ctz(self.data[0]));
        const x1: u8 = @intCast(@ctz(self.data[1]));
        const x2: u8 = @intCast(@ctz(self.data[2]));
        const x3: u8 = @intCast(@ctz(self.data[3]));
        
        if (x0 != 64) return x0;
        if (x1 != 64) return x1 + 64;
        if (x2 != 64) return x2 + 128;
        if (x3 != 64) return x3 + 192;
        
        return null;
    }

    pub fn nextSet(self: *const Self, bit: u8) ?u8 {
        var wIdx: usize = bit >> 6;

        // process the first (maybe partial) word
        const first = self.data[wIdx] >> (bit & 63);
        if (first != 0) {
            return bit + @as(u8, @intCast(@ctz(first)));
        }

        // process the following words until next bit is set
        wIdx += 1;
        while (wIdx < 4) : (wIdx += 1) {
            const next = self.data[wIdx];
            if (next != 0) {
                return @as(u8, @intCast(wIdx << 6)) + @as(u8, @intCast(@ctz(next)));
            }
        }

        return null;
    }

    // 2つのBitSet256の積集合（AND演算）を計算し、結果が空でなければ最上位（最大値）のセットビットを返す
    pub fn intersectionTop(self: *const Self, c: *const Self) ?u8 {
        var wIdx: i32 = 3;
        while (wIdx >= 0) : (wIdx -= 1) {
            const word = self.data[@intCast(wIdx)] & c.data[@intCast(wIdx)];
            if (word != 0) {
                return @as(u8, @intCast(@as(u32, @intCast(wIdx)) << 6)) + @as(u8, @intCast(@bitSizeOf(u64) - @clz(word))) - 1;
            }
        }
        return null;
    }

    // 指定されたインデックス位置より前にある、セットされているビットの個数を数える（ランク操作）
    pub fn rank(self: *const Self, idx: u8) u8 {
        var rnk: u8 = 0;
        rnk += @popCount(self.data[0] & rankMask[idx][0]);
        rnk += @popCount(self.data[1] & rankMask[idx][1]);
        rnk += @popCount(self.data[2] & rankMask[idx][2]);
        rnk += @popCount(self.data[3] & rankMask[idx][3]);
        return rnk;
    }

    // BitSet256に1つもセットされているビットがないか（空か）をチェック
    pub fn isEmpty(self: *const Self) bool {
        return self.data[0] | self.data[1] | self.data[2] | self.data[3] == 0;
    }
    
    // 2つのBitSet256が共通のセットビットを持つかをチェック
    pub fn intersectsAny(self: *const Self, c: *const Self) bool {
        return self.data[0] & c.data[0] != 0 or
               self.data[1] & c.data[1] != 0 or
               self.data[2] & c.data[2] != 0 or
               self.data[3] & c.data[3] != 0;
    }
    
    // 2つのBitSetの共通ビット（AND演算）で新しいBitSetを作成
    pub fn intersection(self: *const Self, c: *const Self) Self {
        return Self{
            .data = .{
                self.data[0] & c.data[0],
                self.data[1] & c.data[1],
                self.data[2] & c.data[2],
                self.data[3] & c.data[3],
            },
        };
    }
    
    // 2つのBitSetの共通ビット数をカウント
    pub fn newUnionBit(self: *const Self, c: *const Self) Self {
        return Self{
            .data = .{
                self.data[0] | c.data[0],
                self.data[1] | c.data[1],
                self.data[2] | c.data[2],
                self.data[3] | c.data[3],
            },
        };
    }
    
    // 2つのBitSetの共通ビット数をカウント
    pub fn intersectionCardinality(self: *const Self, c: *const Self) i32 {
        var cnt: i32 = 0;
        cnt += @popCount(self.data[0] & c.data[0]);
        cnt += @popCount(self.data[1] & c.data[1]);
        cnt += @popCount(self.data[2] & c.data[2]);
        cnt += @popCount(self.data[3] & c.data[3]);
        return cnt;
    }
    
    // BitSetにセットされているビットの総数
    pub fn size(self: *const Self) i32 {
        return self.popcnt();
    }
    
    pub fn popcnt(self: *const Self) i32 {
        var cnt: i32 = 0;
        cnt += @popCount(self.data[0]);
        cnt += @popCount(self.data[1]);
        cnt += @popCount(self.data[2]);
        cnt += @popCount(self.data[3]);
        return cnt;
    }
};

const rankMask = [256][4]u64{
    //   0 
    .{ 0x0, 0x0, 0x0, 0x0 },
    //   1 
    .{ 0x1, 0x0, 0x0, 0x0 },
    //   2 
    .{ 0x3, 0x0, 0x0, 0x0 },
    //   3 
    .{ 0x7, 0x0, 0x0, 0x0 },
    //   4 
    .{ 0xf, 0x0, 0x0, 0x0 },
    //   5 
    .{ 0x1f, 0x0, 0x0, 0x0 },
    //   6 
    .{ 0x3f, 0x0, 0x0, 0x0 },
    //   7 
    .{ 0x7f, 0x0, 0x0, 0x0 },
    //   8 
    .{ 0xff, 0x0, 0x0, 0x0 },
    //   9 
    .{ 0x1ff, 0x0, 0x0, 0x0 },
    //  10 
    .{ 0x3ff, 0x0, 0x0, 0x0 },
    //  11 
    .{ 0x7ff, 0x0, 0x0, 0x0 },
    //  12 
    .{ 0xfff, 0x0, 0x0, 0x0 },
    //  13 
    .{ 0x1fff, 0x0, 0x0, 0x0 },
    //  14 
    .{ 0x3fff, 0x0, 0x0, 0x0 },
    //  15 
    .{ 0x7fff, 0x0, 0x0, 0x0 },
    //  16 
    .{ 0xffff, 0x0, 0x0, 0x0 },
    //  17 
    .{ 0x1ffff, 0x0, 0x0, 0x0 },
    //  18 
    .{ 0x3ffff, 0x0, 0x0, 0x0 },
    //  19 
    .{ 0x7ffff, 0x0, 0x0, 0x0 },
    //  20 
    .{ 0xfffff, 0x0, 0x0, 0x0 },
    //  21 
    .{ 0x1fffff, 0x0, 0x0, 0x0 },
    //  22 
    .{ 0x3fffff, 0x0, 0x0, 0x0 },
    //  23 
    .{ 0x7fffff, 0x0, 0x0, 0x0 },
    //  24 
    .{ 0xffffff, 0x0, 0x0, 0x0 },
    //  25 
    .{ 0x1ffffff, 0x0, 0x0, 0x0 },
    //  26 
    .{ 0x3ffffff, 0x0, 0x0, 0x0 },
    //  27 
    .{ 0x7ffffff, 0x0, 0x0, 0x0 },
    //  28 
    .{ 0xfffffff, 0x0, 0x0, 0x0 },
    //  29 
    .{ 0x1fffffff, 0x0, 0x0, 0x0 },
    //  30 
    .{ 0x3fffffff, 0x0, 0x0, 0x0 },
    //  31 
    .{ 0x7fffffff, 0x0, 0x0, 0x0 },
    //  32 
    .{ 0xffffffff, 0x0, 0x0, 0x0 },
    //  33 
    .{ 0x1ffffffff, 0x0, 0x0, 0x0 },
    //  34 
    .{ 0x3ffffffff, 0x0, 0x0, 0x0 },
    //  35 
    .{ 0x7ffffffff, 0x0, 0x0, 0x0 },
    //  36 
    .{ 0xfffffffff, 0x0, 0x0, 0x0 },
    //  37 
    .{ 0x1fffffffff, 0x0, 0x0, 0x0 },
    //  38 
    .{ 0x3fffffffff, 0x0, 0x0, 0x0 },
    //  39 
    .{ 0x7fffffffff, 0x0, 0x0, 0x0 },
    //  40 
    .{ 0xffffffffff, 0x0, 0x0, 0x0 },
    //  41 
    .{ 0x1ffffffffff, 0x0, 0x0, 0x0 },
    //  42 
    .{ 0x3ffffffffff, 0x0, 0x0, 0x0 },
    //  43 
    .{ 0x7ffffffffff, 0x0, 0x0, 0x0 },
    //  44 
    .{ 0xfffffffffff, 0x0, 0x0, 0x0 },
    //  45 
    .{ 0x1fffffffffff, 0x0, 0x0, 0x0 },
    //  46 
    .{ 0x3fffffffffff, 0x0, 0x0, 0x0 },
    //  47 
    .{ 0x7fffffffffff, 0x0, 0x0, 0x0 },
    //  48 
    .{ 0xffffffffffff, 0x0, 0x0, 0x0 },
    //  49 
    .{ 0x1ffffffffffff, 0x0, 0x0, 0x0 },
    //  50 
    .{ 0x3ffffffffffff, 0x0, 0x0, 0x0 },
    //  51 
    .{ 0x7ffffffffffff, 0x0, 0x0, 0x0 },
    //  52 
    .{ 0xfffffffffffff, 0x0, 0x0, 0x0 },
    //  53 
    .{ 0x1fffffffffffff, 0x0, 0x0, 0x0 },
    //  54 
    .{ 0x3fffffffffffff, 0x0, 0x0, 0x0 },
    //  55 
    .{ 0x7fffffffffffff, 0x0, 0x0, 0x0 },
    //  56 
    .{ 0xffffffffffffff, 0x0, 0x0, 0x0 },
    //  57 
    .{ 0x1ffffffffffffff, 0x0, 0x0, 0x0 },
    //  58 
    .{ 0x3ffffffffffffff, 0x0, 0x0, 0x0 },
    //  59 
    .{ 0x7ffffffffffffff, 0x0, 0x0, 0x0 },
    //  60 
    .{ 0xfffffffffffffff, 0x0, 0x0, 0x0 },
    //  61 
    .{ 0x1fffffffffffffff, 0x0, 0x0, 0x0 },
    //  62 
    .{ 0x3fffffffffffffff, 0x0, 0x0, 0x0 },
    //  63 
    .{ 0x7fffffffffffffff, 0x0, 0x0, 0x0 },
    //  64 
    .{ 0xffffffffffffffff, 0x0, 0x0, 0x0 },
    //  65 
    .{ 0xffffffffffffffff, 0x1, 0x0, 0x0 },
    //  66 
    .{ 0xffffffffffffffff, 0x3, 0x0, 0x0 },
    //  67 
    .{ 0xffffffffffffffff, 0x7, 0x0, 0x0 },
    //  68 
    .{ 0xffffffffffffffff, 0xf, 0x0, 0x0 },
    //  69 
    .{ 0xffffffffffffffff, 0x1f, 0x0, 0x0 },
    //  70 
    .{ 0xffffffffffffffff, 0x3f, 0x0, 0x0 },
    //  71 
    .{ 0xffffffffffffffff, 0x7f, 0x0, 0x0 },
    //  72 
    .{ 0xffffffffffffffff, 0xff, 0x0, 0x0 },
    //  73 
    .{ 0xffffffffffffffff, 0x1ff, 0x0, 0x0 },
    //  74 
    .{ 0xffffffffffffffff, 0x3ff, 0x0, 0x0 },
    //  75 
    .{ 0xffffffffffffffff, 0x7ff, 0x0, 0x0 },
    //  76 
    .{ 0xffffffffffffffff, 0xfff, 0x0, 0x0 },
    //  77 
    .{ 0xffffffffffffffff, 0x1fff, 0x0, 0x0 },
    //  78 
    .{ 0xffffffffffffffff, 0x3fff, 0x0, 0x0 },
    //  79 
    .{ 0xffffffffffffffff, 0x7fff, 0x0, 0x0 },
    //  80 
    .{ 0xffffffffffffffff, 0xffff, 0x0, 0x0 },
    //  81 
    .{ 0xffffffffffffffff, 0x1ffff, 0x0, 0x0 },
    //  82 
    .{ 0xffffffffffffffff, 0x3ffff, 0x0, 0x0 },
    //  83 
    .{ 0xffffffffffffffff, 0x7ffff, 0x0, 0x0 },
    //  84 
    .{ 0xffffffffffffffff, 0xfffff, 0x0, 0x0 },
    //  85 
    .{ 0xffffffffffffffff, 0x1fffff, 0x0, 0x0 },
    //  86 
    .{ 0xffffffffffffffff, 0x3fffff, 0x0, 0x0 },
    //  87 
    .{ 0xffffffffffffffff, 0x7fffff, 0x0, 0x0 },
    //  88 
    .{ 0xffffffffffffffff, 0xffffff, 0x0, 0x0 },
    //  89 
    .{ 0xffffffffffffffff, 0x1ffffff, 0x0, 0x0 },
    //  90 
    .{ 0xffffffffffffffff, 0x3ffffff, 0x0, 0x0 },
    //  91 
    .{ 0xffffffffffffffff, 0x7ffffff, 0x0, 0x0 },
    //  92 
    .{ 0xffffffffffffffff, 0xfffffff, 0x0, 0x0 },
    //  93 
    .{ 0xffffffffffffffff, 0x1fffffff, 0x0, 0x0 },
    //  94 
    .{ 0xffffffffffffffff, 0x3fffffff, 0x0, 0x0 },
    //  95 
    .{ 0xffffffffffffffff, 0x7fffffff, 0x0, 0x0 },
    //  96 
    .{ 0xffffffffffffffff, 0xffffffff, 0x0, 0x0 },
    //  97 
    .{ 0xffffffffffffffff, 0x1ffffffff, 0x0, 0x0 },
    //  98 
    .{ 0xffffffffffffffff, 0x3ffffffff, 0x0, 0x0 },
    //  99 
    .{ 0xffffffffffffffff, 0x7ffffffff, 0x0, 0x0 },
    // 100 
    .{ 0xffffffffffffffff, 0xfffffffff, 0x0, 0x0 },
    // 101 
    .{ 0xffffffffffffffff, 0x1fffffffff, 0x0, 0x0 },
    // 102 
    .{ 0xffffffffffffffff, 0x3fffffffff, 0x0, 0x0 },
    // 103 
    .{ 0xffffffffffffffff, 0x7fffffffff, 0x0, 0x0 },
    // 104 
    .{ 0xffffffffffffffff, 0xffffffffff, 0x0, 0x0 },
    // 105 
    .{ 0xffffffffffffffff, 0x1ffffffffff, 0x0, 0x0 },
    // 106 
    .{ 0xffffffffffffffff, 0x3ffffffffff, 0x0, 0x0 },
    // 107 
    .{ 0xffffffffffffffff, 0x7ffffffffff, 0x0, 0x0 },
    // 108 
    .{ 0xffffffffffffffff, 0xfffffffffff, 0x0, 0x0 },
    // 109 
    .{ 0xffffffffffffffff, 0x1fffffffffff, 0x0, 0x0 },
    // 110 
    .{ 0xffffffffffffffff, 0x3fffffffffff, 0x0, 0x0 },
    // 111 
    .{ 0xffffffffffffffff, 0x7fffffffffff, 0x0, 0x0 },
    // 112 
    .{ 0xffffffffffffffff, 0xffffffffffff, 0x0, 0x0 },
    // 113 
    .{ 0xffffffffffffffff, 0x1ffffffffffff, 0x0, 0x0 },
    // 114 
    .{ 0xffffffffffffffff, 0x3ffffffffffff, 0x0, 0x0 },
    // 115 
    .{ 0xffffffffffffffff, 0x7ffffffffffff, 0x0, 0x0 },
    // 116 
    .{ 0xffffffffffffffff, 0xfffffffffffff, 0x0, 0x0 },
    // 117 
    .{ 0xffffffffffffffff, 0x1fffffffffffff, 0x0, 0x0 },
    // 118 
    .{ 0xffffffffffffffff, 0x3fffffffffffff, 0x0, 0x0 },
    // 119 
    .{ 0xffffffffffffffff, 0x7fffffffffffff, 0x0, 0x0 },
    // 120 
    .{ 0xffffffffffffffff, 0xffffffffffffff, 0x0, 0x0 },
    // 121 
    .{ 0xffffffffffffffff, 0x1ffffffffffffff, 0x0, 0x0 },
    // 122 
    .{ 0xffffffffffffffff, 0x3ffffffffffffff, 0x0, 0x0 },
    // 123 
    .{ 0xffffffffffffffff, 0x7ffffffffffffff, 0x0, 0x0 },
    // 124 
    .{ 0xffffffffffffffff, 0xfffffffffffffff, 0x0, 0x0 },
    // 125 
    .{ 0xffffffffffffffff, 0x1fffffffffffffff, 0x0, 0x0 },
    // 126 
    .{ 0xffffffffffffffff, 0x3fffffffffffffff, 0x0, 0x0 },
    // 127 
    .{ 0xffffffffffffffff, 0x7fffffffffffffff, 0x0, 0x0 },
    // 128 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x0, 0x0 },
    // 129 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1, 0x0 },
    // 130 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3, 0x0 },
    // 131 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7, 0x0 },
    // 132 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xf, 0x0 },
    // 133 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1f, 0x0 },
    // 134 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3f, 0x0 },
    // 135 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7f, 0x0 },
    // 136 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xff, 0x0 },
    // 137 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ff, 0x0 },
    // 138 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ff, 0x0 },
    // 139 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ff, 0x0 },
    // 140 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfff, 0x0 },
    // 141 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fff, 0x0 },
    // 142 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fff, 0x0 },
    // 143 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fff, 0x0 },
    // 144 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffff, 0x0 },
    // 145 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffff, 0x0 },
    // 146 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffff, 0x0 },
    // 147 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffff, 0x0 },
    // 148 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffff, 0x0 },
    // 149 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffff, 0x0 },
    // 150 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffff, 0x0 },
    // 151 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffff, 0x0 },
    // 152 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffff, 0x0 },
    // 153 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffff, 0x0 },
    // 154 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffff, 0x0 },
    // 155 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffff, 0x0 },
    // 156 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffff, 0x0 },
    // 157 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffff, 0x0 },
    // 158 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffff, 0x0 },
    // 159 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffff, 0x0 },
    // 160 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffff, 0x0 },
    // 161 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffff, 0x0 },
    // 162 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffff, 0x0 },
    // 163 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffff, 0x0 },
    // 164 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffff, 0x0 },
    // 165 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffff, 0x0 },
    // 166 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffff, 0x0 },
    // 167 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffff, 0x0 },
    // 168 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffff, 0x0 },
    // 169 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffff, 0x0 },
    // 170 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffff, 0x0 },
    // 171 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffff, 0x0 },
    // 172 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffff, 0x0 },
    // 173 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffff, 0x0 },
    // 174 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffff, 0x0 },
    // 175 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffff, 0x0 },
    // 176 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffff, 0x0 },
    // 177 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffffff, 0x0 },
    // 178 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffffff, 0x0 },
    // 179 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffffff, 0x0 },
    // 180 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffffff, 0x0 },
    // 181 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffffff, 0x0 },
    // 182 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffffff, 0x0 },
    // 183 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffff, 0x0 },
    // 184 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffff, 0x0 },
    // 185 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffffffff, 0x0 },
    // 186 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffffffff, 0x0 },
    // 187 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffffffff, 0x0 },
    // 188 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffffffff, 0x0 },
    // 189 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffffffff, 0x0 },
    // 190 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffffffff, 0x0 },
    // 191 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffffff, 0x0 },
    // 192 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x0 },
    // 193 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1 },
    // 194 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3 },
    // 195 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7 },
    // 196 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xf },
    // 197 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1f },
    // 198 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3f },
    // 199 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7f },
    // 200 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xff },
    // 201 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ff },
    // 202 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ff },
    // 203 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ff },
    // 204 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfff },
    // 205 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fff },
    // 206 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fff },
    // 207 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fff },
    // 208 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffff },
    // 209 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffff },
    // 210 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffff },
    // 211 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffff },
    // 212 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffff },
    // 213 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffff },
    // 214 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffff },
    // 215 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffff },
    // 216 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffff },
    // 217 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffff },
    // 218 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffff },
    // 219 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffff },
    // 220 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffff },
    // 221 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffff },
    // 222 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffff },
    // 223 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffff },
    // 224 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffff },
    // 225 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffff },
    // 226 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffff },
    // 227 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffff },
    // 228 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffff },
    // 229 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffff },
    // 230 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffff },
    // 231 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffff },
    // 232 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffff },
    // 233 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffff },
    // 234 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffff },
    // 235 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffff },
    // 236 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffff },
    // 237 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffff },
    // 238 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffff },
    // 239 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffff },
    // 240 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffff },
    // 241 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffffff },
    // 242 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffffff },
    // 243 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffffff },
    // 244 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffffff },
    // 245 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffffff },
    // 246 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffffff },
    // 247 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffff },
    // 248 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffff },
    // 249 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1ffffffffffffff },
    // 250 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3ffffffffffffff },
    // 251 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7ffffffffffffff },
    // 252 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffffffff },
    // 253 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x1fffffffffffffff },
    // 254 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x3fffffffffffffff },
    // 255 
    .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffffff },
};