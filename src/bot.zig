const RegaliaLib = @import("engine.zig");
const std = @import("std");
var Random: std.Random.Xoroshiro128 = undefined;

const Board = RegaliaLib.Board;
const Move = RegaliaLib.Move;
const Vec = std.ArrayList;

var gAllocator: std.mem.Allocator = undefined;

pub fn Init() void {
    gAllocator = RegaliaLib.gAllocator;
    Random = std.Random.Xoroshiro128.init(0);
}

pub fn PlayOutGame(board: Board) i2 {
    var rand = Random.random();
    //std.debug.panic("Rng is {}\n", .{rand.uintLessThanBiased(u32, 100)});

    var mutboard = board;
    var winval: i2 = 0;
    while (winval == 0) : (winval = mutboard.WinVal()) {
        const move = mutboard.GenerateRandomMove(&rand, mutboard.toPlay) catch unreachable;
        mutboard.ApplyDoubleMove(move);
    }
    return winval;
}

pub fn CompMove(board: Board) [2]Move {
    var timer = std.time.Timer.start() catch unreachable;
    var moves = Vec([2]Move).init(gAllocator);
    defer moves.deinit();

    var mutboard = board;
    mutboard.GenerateAllColorMoves(&moves, board.toPlay) catch unreachable;
    var vals = gAllocator.alloc(i16, moves.items.len) catch unreachable;
    
    compute: 
    while (true) for (0..vals.len) |idx| {
        mutboard = board;
        mutboard.ApplyDoubleMove(moves.items[idx]);
        vals[idx] += PlayOutGame(mutboard);
        

        const nsPassed = timer.read();
        if (nsPassed > 1000 * std.time.ns_per_ms) {
            break :compute;
        }
        break;
    };

    var bestMove: [2]Move = undefined;
    var bestVal: i32 = -10000;
    for (0..vals.len) |idx| {
        if (vals[idx] > bestVal) {
            bestMove = moves.items[idx];
            bestVal = vals[idx];
        }
    }

    return bestMove;
}

pub fn PlayOutGameOld(board: Board) i2 {
    var rand = Random.random();
    //std.debug.panic("Rng is {}\n", .{rand.uintLessThanBiased(u32, 100)});

    var mutboard = board;
    var winval: i2 = 0;
    while (winval == 0) : (winval = mutboard.WinVal()) {
        var moves = Vec([2]Move).init(gAllocator);
        mutboard.GenerateAllColorMoves(&moves, mutboard.toPlay) catch unreachable;
        var moveidx: u32 = rand.uintLessThanBiased(u32, @intCast(moves.items.len));
        const secidx: u32 = rand.uintLessThanBiased(u32, @intCast(moves.items.len));
        const val1 = @intFromEnum(moves.items[moveidx][0].kind) + @intFromEnum(moves.items[moveidx][1].kind);
        const val2 = @intFromEnum(moves.items[secidx][0].kind) + @intFromEnum(moves.items[secidx][1].kind);
        
        if (val2 > val1) moveidx = secidx;
        const move = moves.items[moveidx];
        mutboard.ApplyDoubleMove(move);
    }
    return winval;
}

test {
    Init();
    std.testing.refAllDeclsRecursive(@This());
}

