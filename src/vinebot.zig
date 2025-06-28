const Engine = @import("engine.zig");
const std = @import("std");

const Board = Engine.Board;
const DoubleMoveBuffer = Engine.DoubleMoveBuffer;

const gWinValue = std.math.maxInt(isize);

pub fn RootNegaMax(board: *Board, depth: usize, color: u1) isize {
    const ncolor: i2 = if (color == 1) -1 else 1;
    var bmove: [2]Engine.Move = undefined;
    const eval = PrunedNegaMax(board, true, &bmove, depth, std.math.minInt(isize)+2, std.math.maxInt(isize)-2, ncolor) catch unreachable;
    std.debug.print("Best move is {any}\n", .{bmove});
    return eval;
}

fn PrunedNegaMax(board: *Board, isroot: bool, bmove: *[2]Engine.Move, depth: usize, _alpha: isize, beta: isize, color: i2) !isize {
    if (depth == 0 or board.IsTerminal()) return color * StaticValue(board);
    var alpha = _alpha;

    var buffer = DoubleMoveBuffer{};
    try buffer.Init();
    defer buffer.DeInit();
    
    try board.GenerateAllColorMoves(&buffer, @intCast(color&1));
    var value: isize = std.math.minInt(isize);
    
    for (buffer.GetBuffer()) |_move| {
        //var move = _move;
        const copy = board.*;
        defer board.* = copy; 
        board.ApplyDoubleMove(_move);
        if (depth == 0) std.debug.panic("Depth is 0!\n", .{});
        const eval = try PrunedNegaMax(board, false, bmove, depth - 1, -beta, -alpha, -color);
        value = @max(value, -eval);
        if (isroot and -eval == value) {
            bmove.* = _move;
        }
        alpha = @max(alpha, value);
        if (alpha >= beta) break;
    }

    return value;
}

fn StaticValue(board: *Board) isize {
    if (board.IsTerminal()) {
        if (@popCount(board.pieces[0]) == 0) return std.math.maxInt(isize) - 5
        else return std.math.minInt(isize) + 5;
    }
    var wv: isize = 0;
    for (0..4, Engine.ATKPOW) |i, pow|{
        wv += @as(isize, pow) * @popCount(board.pieces[i]);
        wv += @popCount(board.regalia & board.pieces[i]);
    }

    var bv: isize = 0;
    for (4..8, Engine.ATKPOW) |i, pow|{
        bv += @as(isize, pow) * @popCount(board.pieces[i]);
        bv += @popCount(board.regalia & board.pieces[i]);
    }

    return wv - bv;
}