const std = @import("std");
var gAllocator: std.mem.Allocator = undefined;

///////////////////////////////////////////////////////////////////////////

const BitBoard = u81;
const Connection = u4; //{-y}{-x}{+y}{+x}

///////////////////////////////////////////////////////////////////////////

const RIGHT: u4 = 0b0001;   //+x
const UP: u4 = 0b0010;      //+y
const LEFT: u4 = 0b0100;    //-x
const DOWN: u4 = 0b1000;    //-y

const WHITE: u1 = 0;
const BLACK: u1 = 1;

const ONE: BitBoard = 1;

const CANLEFTMASK: BitBoard = b: {
    var mask: BitBoard = ~0;
    for (0..9) |i| mask = mask & ~1<<(9*i);
    break :b mask;
};

const CANRIGHTMASK: BitBoard = b: {
    var mask: BitBoard = ~0;
    for (0..9) |i| mask = mask & ~1<<(8+9*i);
    break :b mask;
};

const CANUPMASK: BitBoard = b: {
    var mask: BitBoard = ~0;
    for (0..9) |i| mask = mask & ~1<<(9*8+i);
    break :b mask;
};

const CANDOWNMASK: BitBoard = b: {
    var mask: BitBoard = ~0;
    for (0..9) |i| mask = mask & ~1<<(i);
    break :b mask;
};

///////////////////////////////////////////////////////////////////////////

const Move = packed struct {
    retreat: u1,
    orig: u7,
    dest: u8, //3*destpos + edge or cell (0-2)
};

const Board = struct {
    const Self = @This();
    const unused = @compileLog(CANDOWNMASK);

    regalia: BitBoard,
    combatLocks: [81] Connection,
    pieces: [8] BitBoard, //{color}{pieceID}2 //00 -> Inf, 01 -> Cav, 10 -> Art, 11 -> Kng //Color: 0 -> white, 1 -> black
    toPlay: u1 = WHITE,

    fn InitFromStr(self: *Self, initStr: [162]u8) !void {
        //std.debug.print("Got initstr {s}\n", .{initStr});
        self.regalia = 0;
        self.combatLocks = [1]Connection{0} ** 81;
        self.pieces = [1]BitBoard{0} ** 8;
        for (0.., initStr[0..81]) |_idx, c| {
            if (c == 'z') continue;
            const val = c - 'a';
            const idx: u7 = @intCast(_idx);
            const pieceIdx = val % 8;
            const hasReg = (val / 8) & 1;
            self.pieces[pieceIdx] |= ONE << idx;
            self.regalia |= @as(BitBoard, hasReg) << idx;
        }
        for (0.., initStr[81..162]) |_idx, c| {
            if (c == 'z') continue;
            const conn: u4 = @intCast(c - 'a');
            const idx: u7 = @intCast(_idx);
            self.combatLocks[idx] = conn;
        }
        try Validate(self);
    }

    fn GenInitStr(self: Self, buf: *[162] u8) void {
        for (0..81) |idx| {
            for (0..8) |piece| {
                if (Has(self.pieces[piece], ONE<<@intCast(idx))) {
                    const hasReg: u8 = @intCast((self.regalia >> @intCast(idx)) & 1);
                    buf[idx] = 'a' + @as(u8, @intCast(hasReg << 3 | piece));
                    break;
                }
            } else buf[idx] = 'z';
        }
        for (0..81) |idx| {
            const coml = self.combatLocks[idx];
            buf[idx+81] = 'a' + @as(u8, coml);
        }
    }

    fn Validate(self: *Self) !void {
        var haspiece: BitBoard = 0;
        inline for (0..8) |idx| {
            if (Has(haspiece, self.pieces[idx])) return error.Overlapping_Pieces;
            haspiece |= self.pieces[idx];
        }
        
        for (0..9) |x| for (0..9) |y| {
            const pos: u7 = @intCast(9*x + y);
            const conn = self.combatLocks[pos];
            errdefer std.debug.print("x: {}, y: {}\n", .{x, y});
            if (x == 0 and Has(conn, LEFT)) return error.Invalid_Connection_Left;
            if (x == 8 and Has(conn, RIGHT)) return error.Invalid_Connection_Right;
            if (y == 0 and Has(conn, DOWN)) return error.Invalid_Connection_Down;
            if (y == 8 and Has(conn, UP)) return error.Invalid_Connection_Up;

            for ([_]u4{1, 2, 4, 8}) |dir| if (Has(conn, dir)){
                const nPos = NewPos(pos, dir);
                const nConn: u4 = self.combatLocks[nPos];
                if (!Has(nConn, ConverseDir(dir))) return error.Asymetric_Connection;
                if (Bit(haspiece,nPos) == 0) return error.Connection_to_Blank; 
            };

            if (Implies(Bit(self.regalia, pos), Bit(haspiece, pos)) == 0) return error.Floating_Regalia;
        };
    }
};

///////////////////////////////////////////////////////////////////////////

//Assume connections must not wrap around board
//Assume dir is one hot encoded
fn NewPos(pos: u7, dir: u4) u7 {
    return switch (dir) {
        1 => pos + 1,
        2 => pos + 9,
        4 => pos - 1,
        8 => pos - 9,
        else => unreachable,
    };
}

///////////////////////////////////////////////////////////////////////////

inline fn ConverseDir(dir: u4) u4 {return dir << 2 | dir >> 2;}

inline fn Implies(x: u1, y: u1) u1 {return ~x | y;}

inline fn Has(x: anytype, y: anytype) bool {return x & y != 0;}

inline fn Bit(x: anytype, y: anytype) u1 {return @intCast((x >> y) & 1);}

///////////////////////////////////////////////////////////////////////////

fn GenMoves(ptr: *Board) !void {
    try ptr.*.Validate();
}

///////////////////////////////////////////////////////////////////////////

const PYPTR = usize;

fn ExportPtr(ptr: *Board) PYPTR {
    return @intFromPtr(ptr);
}

fn ImportPtr(ptr: PYPTR) *Board {
    return @as(*Board, @ptrFromInt(ptr));
}

export fn PyInitAlloc() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    gAllocator = gpa.allocator();
}

export fn PyNewBoardHandle() PYPTR {
    const handle = _NewBoardHandle() catch unreachable;
    //std.debug.print("Exporting {*} as {x}\n", .{handle, ExportPtr(handle)});
    return ExportPtr(handle);
}
    fn _NewBoardHandle() !*Board {
        const boardPtr = try gAllocator.create(Board);
        return boardPtr;
    }

export fn PyInitBoardFromStr(ptr: PYPTR, str: [*c]u8) void {
    ImportPtr(ptr).InitFromStr(str[0..162].*) catch unreachable;
}

export fn PyGenMoves(ptr: PYPTR) void {
    //std.debug.print("Alignment is {}\n", .{@alignOf(Board)});
    const bptr: *Board = ImportPtr(ptr);
    GenMoves(bptr) catch unreachable;
}

export fn PyGenInitStr(ptr: PYPTR, buf: PYPTR) void {
    const bptr: *Board = ImportPtr(ptr);
    const sbuf: *[162]u8 = @ptrFromInt(buf);
    bptr.GenInitStr(sbuf);
}