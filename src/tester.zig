const RegaliaLib = @import("engine.zig");

const initstr = "zbaclcabzzzzbabzzzzzzazazzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzezezzzzzzfefzzzzfegpgefzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

pub fn main() void {
    RegaliaLib.PyInitAlloc();
    const handle = RegaliaLib.PyNewBoardHandle();
    RegaliaLib.PyInitBoardFromStr(handle, @ptrCast(@constCast(initstr)));
    _ = RegaliaLib.PyGenAllMoves(handle, 0);
    
    RegaliaLib.TimeBot(@ptrFromInt(handle));
    
    return;
}