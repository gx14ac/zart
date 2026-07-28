extern fn kernel_panic(msg: [*:0]const u8) callconv(.c) noreturn;

pub fn panicImpl(msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    const len = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..len], msg[0..len]);
    buf[len] = 0;
    kernel_panic(@ptrCast(&buf));
}
