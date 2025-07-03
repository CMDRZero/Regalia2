const EngineLib = @import("engine2.zig");
const Board = EngineLib.Board;

const std = @import("std");

pub fn main() !void {
    EngineLib.PyInitAlloc();
    const handle = EngineLib.PyNewBoardHandle();
    var str  = "".*;
    EngineLib.PyInitBoardFromStr(handle, &str);
    _ = EngineLib.PyGenMoves(handle, 1);
    var init: [182] u8 = @splat('\x01');
    _ = EngineLib.PyGenInitStr(handle, @intFromPtr(&init));
    std.debug.print("Got Str `{s}`\n", .{init});
    _ = EngineLib.PyGenMoves(handle, 69);
}