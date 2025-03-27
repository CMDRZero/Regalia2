export fn Test(x: u32) callconv(.C) u32 {
    return x ^ 7;
}