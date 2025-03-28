export fn Test(x: u32) callconv(.c) u32 {
    return x ^ 7;
}