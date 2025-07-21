const std = @import("std");
const lookup_tbl = @import("lookup_tbl.zig");

const BitSet256 = struct {
    data: [4]u64,

    const Self = @This();

    pub fn testBitSet256(self: *const Self, bit: u8) bool {
        return self.data[bit >> 6] & (@as(u64, 1) << (bit & 63)) != 0;
    }

    pub fn string(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const allBits = self.all();
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

const fringeRoutesLookupTbl = [256]BitSet256{
    // idx:   0
    .{ .data = .{ 0x0, 0x0, 0x0, 0x0 } }, // invalid
    // idx:   1
    .{ .data = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff } }, // [0 1 2 3 4 5 6 7 8 9 10 11 12 ...
    // idx:   2
    .{ .data = .{ 0xffffffffffffffff, 0xffffffffffffffff, 0x0, 0x0 } }, // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 ...
    // idx:   3
    .{ .data = .{ 0x0, 0x0, 0xffffffffffffffff, 0xffffffffffffffff } }, // [128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 ...
    // idx:   4
    .{ .data = .{ 0xffffffffffffffff, 0x0, 0x0, 0x0 } }, // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 ...
    // idx:   5
    .{ .data = .{ 0x0, 0xffffffffffffffff, 0x0, 0x0 } }, // [64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 ...
    // idx:   6
    .{ .data = .{ 0x0, 0x0, 0xffffffffffffffff, 0x0 } }, // [128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 ...
    // idx:   7
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffffffffffffffff } }, // [192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 210 ...
    // idx:   8
    .{ .data = .{ 0xffffffff, 0x0, 0x0, 0x0 } }, // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31]
    // idx:   9
    .{ .data = .{ 0xffffffff00000000, 0x0, 0x0, 0x0 } }, // [32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 ...
    // idx:  10
    .{ .data = .{ 0x0, 0xffffffff, 0x0, 0x0 } }, // [64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 ...
    // idx:  11
    .{ .data = .{ 0x0, 0xffffffff00000000, 0x0, 0x0 } }, // [96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 ...
    // idx:  12
    .{ .data = .{ 0x0, 0x0, 0xffffffff, 0x0 } }, // [128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 ...
    // idx:  13
    .{ .data = .{ 0x0, 0x0, 0xffffffff00000000, 0x0 } }, // [160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 ...
    // idx:  14
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffffffff } }, // [192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 210 211 212 ...
    // idx:  15
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffffffff00000000 } }, // [224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239 240 241 242 ...
    // idx:  16
    .{ .data = .{ 0xffff, 0x0, 0x0, 0x0 } }, // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15]
    // idx:  17
    .{ .data = .{ 0xffff0000, 0x0, 0x0, 0x0 } }, // [16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31]
    // idx:  18
    .{ .data = .{ 0xffff00000000, 0x0, 0x0, 0x0 } }, // [32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47]
    // idx:  19
    .{ .data = .{ 0xffff000000000000, 0x0, 0x0, 0x0 } }, // [48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63]
    // idx:  20
    .{ .data = .{ 0x0, 0xffff, 0x0, 0x0 } }, // [64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79]
    // idx:  21
    .{ .data = .{ 0x0, 0xffff0000, 0x0, 0x0 } }, // [80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95]
    // idx:  22
    .{ .data = .{ 0x0, 0xffff00000000, 0x0, 0x0 } }, // [96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111]
    // idx:  23
    .{ .data = .{ 0x0, 0xffff000000000000, 0x0, 0x0 } }, // [112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127]
    // idx:  24
    .{ .data = .{ 0x0, 0x0, 0xffff, 0x0 } }, // [128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143]
    // idx:  25
    .{ .data = .{ 0x0, 0x0, 0xffff0000, 0x0 } }, // [144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159]
    // idx:  26
    .{ .data = .{ 0x0, 0x0, 0xffff00000000, 0x0 } }, // [160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175]
    // idx:  27
    .{ .data = .{ 0x0, 0x0, 0xffff000000000000, 0x0 } }, // [176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191]
    // idx:  28
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffff } }, // [192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207]
    // idx:  29
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffff0000 } }, // [208 209 210 211 212 213 214 215 216 217 218 219 220 221 222 223]
    // idx:  30
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffff00000000 } }, // [224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239]
    // idx:  31
    .{ .data = .{ 0x0, 0x0, 0x0, 0xffff000000000000 } }, // [240 241 242 243 244 245 246 247 248 249 250 251 252 253 254 255]
    // idx:  32
    .{ .data = .{ 0xff, 0x0, 0x0, 0x0 } }, // [0 1 2 3 4 5 6 7]
    // idx:  33
    .{ .data = .{ 0xff00, 0x0, 0x0, 0x0 } }, // [8 9 10 11 12 13 14 15]
    // idx:  34
    .{ .data = .{ 0xff0000, 0x0, 0x0, 0x0 } }, // [16 17 18 19 20 21 22 23]
    // idx:  35
    .{ .data = .{ 0xff000000, 0x0, 0x0, 0x0 } }, // [24 25 26 27 28 29 30 31]
    // idx:  36
    .{ .data = .{ 0xff00000000, 0x0, 0x0, 0x0 } }, // [32 33 34 35 36 37 38 39]
    // idx:  37
    .{ .data = .{ 0xff0000000000, 0x0, 0x0, 0x0 } }, // [40 41 42 43 44 45 46 47]
    // idx:  38
    .{ .data = .{ 0xff000000000000, 0x0, 0x0, 0x0 } }, // [48 49 50 51 52 53 54 55]
    // idx:  39
    .{ .data = .{ 0xff00000000000000, 0x0, 0x0, 0x0 } }, // [56 57 58 59 60 61 62 63]
    // idx:  40
    .{ .data = .{ 0x0, 0xff, 0x0, 0x0 } }, // [64 65 66 67 68 69 70 71]
    // idx:  41
    .{ .data = .{ 0x0, 0xff00, 0x0, 0x0 } }, // [72 73 74 75 76 77 78 79]
    // idx:  42
    .{ .data = .{ 0x0, 0xff0000, 0x0, 0x0 } }, // [80 81 82 83 84 85 86 87]
    // idx:  43
    .{ .data = .{ 0x0, 0xff000000, 0x0, 0x0 } }, // [88 89 90 91 92 93 94 95]
    // idx:  44
    .{ .data = .{ 0x0, 0xff00000000, 0x0, 0x0 } }, // [96 97 98 99 100 101 102 103]
    // idx:  45
    .{ .data = .{ 0x0, 0xff0000000000, 0x0, 0x0 } }, // [104 105 106 107 108 109 110 111]
    // idx:  46
    .{ .data = .{ 0x0, 0xff000000000000, 0x0, 0x0 } }, // [112 113 114 115 116 117 118 119]
    // idx:  47
    .{ .data = .{ 0x0, 0xff00000000000000, 0x0, 0x0 } }, // [120 121 122 123 124 125 126 127]
    // idx:  48
    .{ .data = .{ 0x0, 0x0, 0xff, 0x0 } }, // [128 129 130 131 132 133 134 135]
    // idx:  49
    .{ .data = .{ 0x0, 0x0, 0xff00, 0x0 } }, // [136 137 138 139 140 141 142 143]
    // idx:  50
    .{ .data = .{ 0x0, 0x0, 0xff0000, 0x0 } }, // [144 145 146 147 148 149 150 151]
    // idx:  51
    .{ .data = .{ 0x0, 0x0, 0xff000000, 0x0 } }, // [152 153 154 155 156 157 158 159]
    // idx:  52
    .{ .data = .{ 0x0, 0x0, 0xff00000000, 0x0 } }, // [160 161 162 163 164 165 166 167]
    // idx:  53
    .{ .data = .{ 0x0, 0x0, 0xff0000000000, 0x0 } }, // [168 169 170 171 172 173 174 175]
    // idx:  54
    .{ .data = .{ 0x0, 0x0, 0xff000000000000, 0x0 } }, // [176 177 178 179 180 181 182 183]
    // idx:  55
    .{ .data = .{ 0x0, 0x0, 0xff00000000000000, 0x0 } }, // [184 185 186 187 188 189 190 191]
    // idx:  56
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff } }, // [192 193 194 195 196 197 198 199]
    // idx:  57
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff00 } }, // [200 201 202 203 204 205 206 207]
    // idx:  58
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff0000 } }, // [208 209 210 211 212 213 214 215]
    // idx:  59
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff000000 } }, // [216 217 218 219 220 221 222 223]
    // idx:  60
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff00000000 } }, // [224 225 226 227 228 229 230 231]
    // idx:  61
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff0000000000 } }, // [232 233 234 235 236 237 238 239]
    // idx:  62
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff000000000000 } }, // [240 241 242 243 244 245 246 247]
    // idx:  63
    .{ .data = .{ 0x0, 0x0, 0x0, 0xff00000000000000 } }, // [248 249 250 251 252 253 254 255]
    // idx:  64
    .{ .data = .{ 0xf, 0x0, 0x0, 0x0 } }, // [0 1 2 3]
    // idx:  65
    .{ .data = .{ 0xf0, 0x0, 0x0, 0x0 } }, // [4 5 6 7]
    // idx:  66
    .{ .data = .{ 0xf00, 0x0, 0x0, 0x0 } }, // [8 9 10 11]
    // idx:  67
    .{ .data = .{ 0xf000, 0x0, 0x0, 0x0 } }, // [12 13 14 15]
    // idx:  68
    .{ .data = .{ 0xf0000, 0x0, 0x0, 0x0 } }, // [16 17 18 19]
    // idx:  69
    .{ .data = .{ 0xf00000, 0x0, 0x0, 0x0 } }, // [20 21 22 23]
    // idx:  70
    .{ .data = .{ 0xf000000, 0x0, 0x0, 0x0 } }, // [24 25 26 27]
    // idx:  71
    .{ .data = .{ 0xf0000000, 0x0, 0x0, 0x0 } }, // [28 29 30 31]
    // idx:  72
    .{ .data = .{ 0xf00000000, 0x0, 0x0, 0x0 } }, // [32 33 34 35]
    // idx:  73
    .{ .data = .{ 0xf000000000, 0x0, 0x0, 0x0 } }, // [36 37 38 39]
    // idx:  74
    .{ .data = .{ 0xf0000000000, 0x0, 0x0, 0x0 } }, // [40 41 42 43]
    // idx:  75
    .{ .data = .{ 0xf00000000000, 0x0, 0x0, 0x0 } }, // [44 45 46 47]
    // idx:  76
    .{ .data = .{ 0xf000000000000, 0x0, 0x0, 0x0 } }, // [48 49 50 51]
    // idx:  77
    .{ .data = .{ 0xf0000000000000, 0x0, 0x0, 0x0 } }, // [52 53 54 55]
    // idx:  78
    .{ .data = .{ 0xf00000000000000, 0x0, 0x0, 0x0 } }, // [56 57 58 59]
    // idx:  79
    .{ .data = .{ 0xf000000000000000, 0x0, 0x0, 0x0 } }, // [60 61 62 63]
    // idx:  80
    .{ .data = .{ 0x0, 0xf, 0x0, 0x0 } }, // [64 65 66 67]
    // idx:  81
    .{ .data = .{ 0x0, 0xf0, 0x0, 0x0 } }, // [68 69 70 71]
    // idx:  82
    .{ .data = .{ 0x0, 0xf00, 0x0, 0x0 } }, // [72 73 74 75]
    // idx:  83
    .{ .data = .{ 0x0, 0xf000, 0x0, 0x0 } }, // [76 77 78 79]
    // idx:  84
    .{ .data = .{ 0x0, 0xf0000, 0x0, 0x0 } }, // [80 81 82 83]
    // idx:  85
    .{ .data = .{ 0x0, 0xf00000, 0x0, 0x0 } }, // [84 85 86 87]
    // idx:  86
    .{ .data = .{ 0x0, 0xf000000, 0x0, 0x0 } }, // [88 89 90 91]
    // idx:  87
    .{ .data = .{ 0x0, 0xf0000000, 0x0, 0x0 } }, // [92 93 94 95]
    // idx:  88
    .{ .data = .{ 0x0, 0xf00000000, 0x0, 0x0 } }, // [96 97 98 99]
    // idx:  89
    .{ .data = .{ 0x0, 0xf000000000, 0x0, 0x0 } }, // [100 101 102 103]
    // idx:  90
    .{ .data = .{ 0x0, 0xf0000000000, 0x0, 0x0 } }, // [104 105 106 107]
    // idx:  91
    .{ .data = .{ 0x0, 0xf00000000000, 0x0, 0x0 } }, // [108 109 110 111]
    // idx:  92
    .{ .data = .{ 0x0, 0xf000000000000, 0x0, 0x0 } }, // [112 113 114 115]
    // idx:  93
    .{ .data = .{ 0x0, 0xf0000000000000, 0x0, 0x0 } }, // [116 117 118 119]
    // idx:  94
    .{ .data = .{ 0x0, 0xf00000000000000, 0x0, 0x0 } }, // [120 121 122 123]
    // idx:  95
    .{ .data = .{ 0x0, 0xf000000000000000, 0x0, 0x0 } }, // [124 125 126 127]
    // idx:  96
    .{ .data = .{ 0x0, 0x0, 0xf, 0x0 } }, // [128 129 130 131]
    // idx:  97
    .{ .data = .{ 0x0, 0x0, 0xf0, 0x0 } }, // [132 133 134 135]
    // idx:  98
    .{ .data = .{ 0x0, 0x0, 0xf00, 0x0 } }, // [136 137 138 139]
    // idx:  99
    .{ .data = .{ 0x0, 0x0, 0xf000, 0x0 } }, // [140 141 142 143]
    // idx: 100
    .{ .data = .{ 0x0, 0x0, 0xf0000, 0x0 } }, // [144 145 146 147]
    // idx: 101
    .{ .data = .{ 0x0, 0x0, 0xf00000, 0x0 } }, // [148 149 150 151]
    // idx: 102
    .{ .data = .{ 0x0, 0x0, 0xf000000, 0x0 } }, // [152 153 154 155]
    // idx: 103
    .{ .data = .{ 0x0, 0x0, 0xf0000000, 0x0 } }, // [156 157 158 159]
    // idx: 104
    .{ .data = .{ 0x0, 0x0, 0xf00000000, 0x0 } }, // [160 161 162 163]
    // idx: 105
    .{ .data = .{ 0x0, 0x0, 0xf000000000, 0x0 } }, // [164 165 166 167]
    // idx: 106
    .{ .data = .{ 0x0, 0x0, 0xf0000000000, 0x0 } }, // [168 169 170 171]
    // idx: 107
    .{ .data = .{ 0x0, 0x0, 0xf00000000000, 0x0 } }, // [172 173 174 175]
    // idx: 108
    .{ .data = .{ 0x0, 0x0, 0xf000000000000, 0x0 } }, // [176 177 178 179]
    // idx: 109
    .{ .data = .{ 0x0, 0x0, 0xf0000000000000, 0x0 } }, // [180 181 182 183]
    // idx: 110
    .{ .data = .{ 0x0, 0x0, 0xf00000000000000, 0x0 } }, // [184 185 186 187]
    // idx: 111
    .{ .data = .{ 0x0, 0x0, 0xf000000000000000, 0x0 } }, // [188 189 190 191]
    // idx: 112
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf } }, // [192 193 194 195]
    // idx: 113
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf0 } }, // [196 197 198 199]
    // idx: 114
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf00 } }, // [200 201 202 203]
    // idx: 115
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf000 } }, // [204 205 206 207]
    // idx: 116
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf0000 } }, // [208 209 210 211]
    // idx: 117
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf00000 } }, // [212 213 214 215]
    // idx: 118
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf000000 } }, // [216 217 218 219]
    // idx: 119
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf0000000 } }, // [220 221 222 223]
    // idx: 120
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf00000000 } }, // [224 225 226 227]
    // idx: 121
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf000000000 } }, // [228 229 230 231]
    // idx: 122
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf0000000000 } }, // [232 233 234 235]
    // idx: 123
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf00000000000 } }, // [236 237 238 239]
    // idx: 124
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf000000000000 } }, // [240 241 242 243]
    // idx: 125
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf0000000000000 } }, // [244 245 246 247]
    // idx: 126
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf00000000000000 } }, // [248 249 250 251]
    // idx: 127
    .{ .data = .{ 0x0, 0x0, 0x0, 0xf000000000000000 } }, // [252 253 254 255]
    // idx: 128
    .{ .data = .{ 0x3, 0x0, 0x0, 0x0 } }, // [0 1]
    // idx: 129
    .{ .data = .{ 0xc, 0x0, 0x0, 0x0 } }, // [2 3]
    // idx: 130
    .{ .data = .{ 0x30, 0x0, 0x0, 0x0 } }, // [4 5]
    // idx: 131
    .{ .data = .{ 0xc0, 0x0, 0x0, 0x0 } }, // [6 7]
    // idx: 132
    .{ .data = .{ 0x300, 0x0, 0x0, 0x0 } }, // [8 9]
    // idx: 133
    .{ .data = .{ 0xc00, 0x0, 0x0, 0x0 } }, // [10 11]
    // idx: 134
    .{ .data = .{ 0x3000, 0x0, 0x0, 0x0 } }, // [12 13]
    // idx: 135
    .{ .data = .{ 0xc000, 0x0, 0x0, 0x0 } }, // [14 15]
    // idx: 136
    .{ .data = .{ 0x30000, 0x0, 0x0, 0x0 } }, // [16 17]
    // idx: 137
    .{ .data = .{ 0xc0000, 0x0, 0x0, 0x0 } }, // [18 19]
    // idx: 138
    .{ .data = .{ 0x300000, 0x0, 0x0, 0x0 } }, // [20 21]
    // idx: 139
    .{ .data = .{ 0xc00000, 0x0, 0x0, 0x0 } }, // [22 23]
    // idx: 140
    .{ .data = .{ 0x3000000, 0x0, 0x0, 0x0 } }, // [24 25]
    // idx: 141
    .{ .data = .{ 0xc000000, 0x0, 0x0, 0x0 } }, // [26 27]
    // idx: 142
    .{ .data = .{ 0x30000000, 0x0, 0x0, 0x0 } }, // [28 29]
    // idx: 143
    .{ .data = .{ 0xc0000000, 0x0, 0x0, 0x0 } }, // [30 31]
    // idx: 144
    .{ .data = .{ 0x300000000, 0x0, 0x0, 0x0 } }, // [32 33]
    // idx: 145
    .{ .data = .{ 0xc00000000, 0x0, 0x0, 0x0 } }, // [34 35]
    // idx: 146
    .{ .data = .{ 0x3000000000, 0x0, 0x0, 0x0 } }, // [36 37]
    // idx: 147
    .{ .data = .{ 0xc000000000, 0x0, 0x0, 0x0 } }, // [38 39]
    // idx: 148
    .{ .data = .{ 0x30000000000, 0x0, 0x0, 0x0 } }, // [40 41]
    // idx: 149
    .{ .data = .{ 0xc0000000000, 0x0, 0x0, 0x0 } }, // [42 43]
    // idx: 150
    .{ .data = .{ 0x300000000000, 0x0, 0x0, 0x0 } }, // [44 45]
    // idx: 151
    .{ .data = .{ 0xc00000000000, 0x0, 0x0, 0x0 } }, // [46 47]
    // idx: 152
    .{ .data = .{ 0x3000000000000, 0x0, 0x0, 0x0 } }, // [48 49]
    // idx: 153
    .{ .data = .{ 0xc000000000000, 0x0, 0x0, 0x0 } }, // [50 51]
    // idx: 154
    .{ .data = .{ 0x30000000000000, 0x0, 0x0, 0x0 } }, // [52 53]
    // idx: 155
    .{ .data = .{ 0xc0000000000000, 0x0, 0x0, 0x0 } }, // [54 55]
    // idx: 156
    .{ .data = .{ 0x300000000000000, 0x0, 0x0, 0x0 } }, // [56 57]
    // idx: 157
    .{ .data = .{ 0xc00000000000000, 0x0, 0x0, 0x0 } }, // [58 59]
    // idx: 158
    .{ .data = .{ 0x3000000000000000, 0x0, 0x0, 0x0 } }, // [60 61]
    // idx: 159
    .{ .data = .{ 0xc000000000000000, 0x0, 0x0, 0x0 } }, // [62 63]
    // idx: 160
    .{ .data = .{ 0x0, 0x3, 0x0, 0x0 } }, // [64 65]
    // idx: 161
    .{ .data = .{ 0x0, 0xc, 0x0, 0x0 } }, // [66 67]
    // idx: 162
    .{ .data = .{ 0x0, 0x30, 0x0, 0x0 } }, // [68 69]
    // idx: 163
    .{ .data = .{ 0x0, 0xc0, 0x0, 0x0 } }, // [70 71]
    // idx: 164
    .{ .data = .{ 0x0, 0x300, 0x0, 0x0 } }, // [72 73]
    // idx: 165
    .{ .data = .{ 0x0, 0xc00, 0x0, 0x0 } }, // [74 75]
    // idx: 166
    .{ .data = .{ 0x0, 0x3000, 0x0, 0x0 } }, // [76 77]
    // idx: 167
    .{ .data = .{ 0x0, 0xc000, 0x0, 0x0 } }, // [78 79]
    // idx: 168
    .{ .data = .{ 0x0, 0x30000, 0x0, 0x0 } }, // [80 81]
    // idx: 169
    .{ .data = .{ 0x0, 0xc0000, 0x0, 0x0 } }, // [82 83]
    // idx: 170
    .{ .data = .{ 0x0, 0x300000, 0x0, 0x0 } }, // [84 85]
    // idx: 171
    .{ .data = .{ 0x0, 0xc00000, 0x0, 0x0 } }, // [86 87]
    // idx: 172
    .{ .data = .{ 0x0, 0x3000000, 0x0, 0x0 } }, // [88 89]
    // idx: 173
    .{ .data = .{ 0x0, 0xc000000, 0x0, 0x0 } }, // [90 91]
    // idx: 174
    .{ .data = .{ 0x0, 0x30000000, 0x0, 0x0 } }, // [92 93]
    // idx: 175
    .{ .data = .{ 0x0, 0xc0000000, 0x0, 0x0 } }, // [94 95]
    // idx: 176
    .{ .data = .{ 0x0, 0x300000000, 0x0, 0x0 } }, // [96 97]
    // idx: 177
    .{ .data = .{ 0x0, 0xc00000000, 0x0, 0x0 } }, // [98 99]
    // idx: 178
    .{ .data = .{ 0x0, 0x3000000000, 0x0, 0x0 } }, // [100 101]
    // idx: 179
    .{ .data = .{ 0x0, 0xc000000000, 0x0, 0x0 } }, // [102 103]
    // idx: 180
    .{ .data = .{ 0x0, 0x30000000000, 0x0, 0x0 } }, // [104 105]
    // idx: 181
    .{ .data = .{ 0x0, 0xc0000000000, 0x0, 0x0 } }, // [106 107]
    // idx: 182
    .{ .data = .{ 0x0, 0x300000000000, 0x0, 0x0 } }, // [108 109]
    // idx: 183
    .{ .data = .{ 0x0, 0xc00000000000, 0x0, 0x0 } }, // [110 111]
    // idx: 184
    .{ .data = .{ 0x0, 0x3000000000000, 0x0, 0x0 } }, // [112 113]
    // idx: 185
    .{ .data = .{ 0x0, 0xc000000000000, 0x0, 0x0 } }, // [114 115]
    // idx: 186
    .{ .data = .{ 0x0, 0x30000000000000, 0x0, 0x0 } }, // [116 117]
    // idx: 187
    .{ .data = .{ 0x0, 0xc0000000000000, 0x0, 0x0 } }, // [118 119]
    // idx: 188
    .{ .data = .{ 0x0, 0x300000000000000, 0x0, 0x0 } }, // [120 121]
    // idx: 189
    .{ .data = .{ 0x0, 0xc00000000000000, 0x0, 0x0 } }, // [122 123]
    // idx: 190
    .{ .data = .{ 0x0, 0x3000000000000000, 0x0, 0x0 } }, // [124 125]
    // idx: 191
    .{ .data = .{ 0x0, 0xc000000000000000, 0x0, 0x0 } }, // [126 127]
    // idx: 192
    .{ .data = .{ 0x0, 0x0, 0x3, 0x0 } }, // [128 129]
    // idx: 193
    .{ .data = .{ 0x0, 0x0, 0xc, 0x0 } }, // [130 131]
    // idx: 194
    .{ .data = .{ 0x0, 0x0, 0x30, 0x0 } }, // [132 133]
    // idx: 195
    .{ .data = .{ 0x0, 0x0, 0xc0, 0x0 } }, // [134 135]
    // idx: 196
    .{ .data = .{ 0x0, 0x0, 0x300, 0x0 } }, // [136 137]
    // idx: 197
    .{ .data = .{ 0x0, 0x0, 0xc00, 0x0 } }, // [138 139]
    // idx: 198
    .{ .data = .{ 0x0, 0x0, 0x3000, 0x0 } }, // [140 141]
    // idx: 199
    .{ .data = .{ 0x0, 0x0, 0xc000, 0x0 } }, // [142 143]
    // idx: 200
    .{ .data = .{ 0x0, 0x0, 0x30000, 0x0 } }, // [144 145]
    // idx: 201
    .{ .data = .{ 0x0, 0x0, 0xc0000, 0x0 } }, // [146 147]
    // idx: 202
    .{ .data = .{ 0x0, 0x0, 0x300000, 0x0 } }, // [148 149]
    // idx: 203
    .{ .data = .{ 0x0, 0x0, 0xc00000, 0x0 } }, // [150 151]
    // idx: 204
    .{ .data = .{ 0x0, 0x0, 0x3000000, 0x0 } }, // [152 153]
    // idx: 205
    .{ .data = .{ 0x0, 0x0, 0xc000000, 0x0 } }, // [154 155]
    // idx: 206
    .{ .data = .{ 0x0, 0x0, 0x30000000, 0x0 } }, // [156 157]
    // idx: 207
    .{ .data = .{ 0x0, 0x0, 0xc0000000, 0x0 } }, // [158 159]
    // idx: 208
    .{ .data = .{ 0x0, 0x0, 0x300000000, 0x0 } }, // [160 161]
    // idx: 209
    .{ .data = .{ 0x0, 0x0, 0xc00000000, 0x0 } }, // [162 163]
    // idx: 210
    .{ .data = .{ 0x0, 0x0, 0x3000000000, 0x0 } }, // [164 165]
    // idx: 211
    .{ .data = .{ 0x0, 0x0, 0xc000000000, 0x0 } }, // [166 167]
    // idx: 212
    .{ .data = .{ 0x0, 0x0, 0x30000000000, 0x0 } }, // [168 169]
    // idx: 213
    .{ .data = .{ 0x0, 0x0, 0xc0000000000, 0x0 } }, // [170 171]
    // idx: 214
    .{ .data = .{ 0x0, 0x0, 0x300000000000, 0x0 } }, // [172 173]
    // idx: 215
    .{ .data = .{ 0x0, 0x0, 0xc00000000000, 0x0 } }, // [174 175]
    // idx: 216
    .{ .data = .{ 0x0, 0x0, 0x3000000000000, 0x0 } }, // [176 177]
    // idx: 217
    .{ .data = .{ 0x0, 0x0, 0xc000000000000, 0x0 } }, // [178 179]
    // idx: 218
    .{ .data = .{ 0x0, 0x0, 0x30000000000000, 0x0 } }, // [180 181]
    // idx: 219
    .{ .data = .{ 0x0, 0x0, 0xc0000000000000, 0x0 } }, // [182 183]
    // idx: 220
    .{ .data = .{ 0x0, 0x0, 0x300000000000000, 0x0 } }, // [184 185]
    // idx: 221
    .{ .data = .{ 0x0, 0x0, 0xc00000000000000, 0x0 } }, // [186 187]
    // idx: 222
    .{ .data = .{ 0x0, 0x0, 0x3000000000000000, 0x0 } }, // [188 189]
    // idx: 223
    .{ .data = .{ 0x0, 0x0, 0xc000000000000000, 0x0 } }, // [190 191]
    // idx: 224
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3 } }, // [192 193]
    // idx: 225
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc } }, // [194 195]
    // idx: 226
    .{ .data = .{ 0x0, 0x0, 0x0, 0x30 } }, // [196 197]
    // idx: 227
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc0 } }, // [198 199]
    // idx: 228
    .{ .data = .{ 0x0, 0x0, 0x0, 0x300 } }, // [200 201]
    // idx: 229
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc00 } }, // [202 203]
    // idx: 230
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3000 } }, // [204 205]
    // idx: 231
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc000 } }, // [206 207]
    // idx: 232
    .{ .data = .{ 0x0, 0x0, 0x0, 0x30000 } }, // [208 209]
    // idx: 233
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc0000 } }, // [210 211]
    // idx: 234
    .{ .data = .{ 0x0, 0x0, 0x0, 0x300000 } }, // [212 213]
    // idx: 235
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc00000 } }, // [214 215]
    // idx: 236
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3000000 } }, // [216 217]
    // idx: 237
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc000000 } }, // [218 219]
    // idx: 238
    .{ .data = .{ 0x0, 0x0, 0x0, 0x30000000 } }, // [220 221]
    // idx: 239
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc0000000 } }, // [222 223]
    // idx: 240
    .{ .data = .{ 0x0, 0x0, 0x0, 0x300000000 } }, // [224 225]
    // idx: 241
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc00000000 } }, // [226 227]
    // idx: 242
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3000000000 } }, // [228 229]
    // idx: 243
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc000000000 } }, // [230 231]
    // idx: 244
    .{ .data = .{ 0x0, 0x0, 0x0, 0x30000000000 } }, // [232 233]
    // idx: 245
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc0000000000 } }, // [234 235]
    // idx: 246
    .{ .data = .{ 0x0, 0x0, 0x0, 0x300000000000 } }, // [236 237]
    // idx: 247
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc00000000000 } }, // [238 239]
    // idx: 248
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3000000000000 } }, // [240 241]
    // idx: 249
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc000000000000 } }, // [242 243]
    // idx: 250
    .{ .data = .{ 0x0, 0x0, 0x0, 0x30000000000000 } }, // [244 245]
    // idx: 251
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc0000000000000 } }, // [246 247]
    // idx: 252
    .{ .data = .{ 0x0, 0x0, 0x0, 0x300000000000000 } }, // [248 249]
    // idx: 253
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc00000000000000 } }, // [250 251]
    // idx: 254
    .{ .data = .{ 0x0, 0x0, 0x0, 0x3000000000000000 } }, // [252 253]
    // idx: 255
    .{ .data = .{ 0x0, 0x0, 0x0, 0xc000000000000000 } }, // [254 255]
};