const std = @import("std");
var gAllocator: std.mem.Allocator = undefined;
var gGpa: std.heap.DebugAllocator(.{}) = undefined;

///////////////////////////////////////////////////////////////////////////

const DoValidation: bool = true;

///////////////////////////////////////////////////////////////////////////

const BitBoard = u81;
const Connection = u4; //{-y}{-x}{+y}{+x}
const Vec = std.ArrayList;

///////////////////////////////////////////////////////////////////////////

const RIGHT: u4 = 0b0001;   //+x
const UP: u4 = 0b0010;      //+y
const LEFT: u4 = 0b0100;    //-x
const DOWN: u4 = 0b1000;    //-y

const WHITE: u1 = 0;
const BLACK: u1 = 1;

const ONE: BitBoard = 1;

const ATKPOW = [4]u8{2, 4, 8, 2};
const MOVSPD = [4]u4{1, 2, 0, 0}; //Move speed minus the attack

const DIRS = [4]u4{1, 2, 4, 8};

const ANULLMOVE = Move{.orig = 127, .dest = undefined, .doCap = undefined, .doAtk = undefined};

const CANLEFTMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE<<(9*i));
    break :b mask;
};

const CANRIGHTMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE<<(8+9*i));
    //@compileLog(mask);
    break :b mask;
};

const CANUPMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE<<(9*8+i));
    break :b mask;
};

const CANDOWNMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE<<(i));
    break :b mask;
};

///////////////////////////////////////////////////////////////////////////

const Move = packed struct (u32) {
    doRet: u1 = 0,
    orig: u7,
    doCap: u1,
    dest: u7,
    doAtk: u1,
    atkDir: u3 = 0, //Only u3 because Artillary can capture diagonally
    capVal: u2 = 0, //Captured Piece kind
    capReg: u1 = 0, //Captured Piece has regalia
    oldLock: u4 = 0, //Old Combat locks before clearing
    capOldLock: u4 = 0, //Old Combat locks before clearing
    _: u1 = 0,
};

const Board = struct {
    const Self = @This();
    const unused = @compileLog(CANDOWNMASK);

    regalia: BitBoard,
    combatLocks: [81] Connection,
    pieces: [8] BitBoard, //{color}{pieceID}2 //00 -> Inf, 01 -> Cav, 10 -> Art, 11 -> Kng //Color: 0 -> white, 1 -> black
    toPlay: u1 = WHITE,

    fn InitFromStr(self: *Self, initStr: [162]u8) void {
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
        Validate(self);
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

    fn PieceAt(self: Self, pos: u7) ?u3 {
        for (0..8) |piece| {
            if (Bit(self.pieces[piece], pos) != 0) return @intCast(piece);
        } else return null;
    }

    inline fn PowerAt(self: Self, pos: u7) u8 {
        return ATKPOW[self.PieceAt(pos).? % 4] + Bit(self.regalia, pos);
    }

    fn AttackersOn(self: Self, pos: u7) u8 {
        var sum: u8 = 0;
        for (DIRS) |dir| if (Has(self.combatLocks[pos], dir)) {
            sum += self.PowerAt(NewPos(pos, dir));
        };
        return sum;
    }

    inline fn Validate(self: *Self) void {
        if (DoValidation) self._Validate() catch |err| {
            std.log.err("Validation Failure: `{}`", .{err});
            @panic("Validation Failure");
        };
    }

    fn _Validate(self: *Self) !void {
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

    ///Not exaughstive but should catch most cases
    inline fn ValidateMove(self: Self, move: Move) void {
        if (DoValidation) self._ValidateMove(move) catch |err| {
            std.log.err("Validation Failure: `{}`", .{err});
            @panic("Validation Failure");
        };
    }

    fn _ValidateMove(self: Self, move: Move) !void {
        if (move.orig == 127) return //orig = 127 => Null move
        if (move.dest > 81) return error.Destination_too_large;
        if (move.orig > 81) return error.Origin_too_large;
        

        if (move.doRet != 0 and move.orig == move.dest) return error.Retreat_and_Train;
        const doesDie = move.doRet & ~Bit(self.regalia, move.orig); 
        if (doesDie != 0 and move.orig != move.dest) return error.Sacrifice_isnt_static;
        const anyToCap = self.PieceAt(move.dest) != null;
        if (anyToCap) {
            const ownPow = self.PowerAt(move.orig);
            const destPow = self.PowerAt(move.dest);
            const shouldCap = self.AttackersOn(move.dest) + ownPow > destPow;
            if (@intFromBool(shouldCap) != move.doCap) return error.DoCapture_incorrect;
        }
    }

    ///Will update the move to contain accurate information about how to undo the move
    fn ApplyMove(self: *Self, move: *Move) void {
        std.debug.print("Got move orig: {}\n", .{move.orig});
        std.debug.print("Got move dest: {}\n", .{move.dest});
        ValidateMove(self.*, move.*);
        if (move.orig == 127) return;
        const ownPiece = self.PieceAt(move.orig).?;
        if (move.doRet != 0) self._RemoveRegalia(move.orig);
        const fullDest = ToCapturePos(move.dest, move.atkDir);
        if (move.doCap != 0) {
            const destPiece = self.PieceAt(fullDest).?;
            self._RemovePiece(fullDest, destPiece);
            self._MovePiece(move.orig, fullDest, ownPiece);
            self._AddRegalia(fullDest);
        } else if (move.doAtk != 0) {
            self._MovePiece(move.orig, move.dest, ownPiece);
            self._ToggleLockInDir(move.dest, @as(u4, 1) << @intCast(move.atkDir));
        } else if (move.orig == move.dest){
            self._AddRegalia(move.orig);
        } else if (self.PieceAt(move.dest)) |destPiece| { //Despite no capture, dest has piece => Swap
            self._MovePiece(move.orig, move.dest, ownPiece);
            self._MovePiece(move.dest, move.orig, destPiece);
            return;
        } else {
            std.debug.print("Made normal move\n", .{});
            self._MovePiece(move.orig, fullDest, ownPiece);
        }
        if (move.doRet | move.doCap != 0) {
            const oldLocks = self.combatLocks[move.orig];
            move.oldLock = oldLocks;
            for (DIRS) |dir| if (Has(oldLocks, dir)) self._ToggleLockInDir(move.orig, dir);
            if (move.doCap != 0) {
                const capOldLocks = self.combatLocks[fullDest];
                move.capOldLock = capOldLocks;
                for (DIRS) |dir| if (Has(oldLocks, dir)) self._ToggleLockInDir(fullDest, dir);
            }
        }
        self.Validate();
    }

    inline fn _MovePiece(self: *Self, orig: u7, dest: u7, piece: u3) void {
        if (DoValidation and dest == orig) @panic("Destination was Origin for move");
        self.pieces[piece] ^= ONE << orig;
        self.pieces[piece] ^= ONE << dest;
        self.regalia |= @as(u81, Bit(self.regalia, orig)) << dest;
        self.regalia &= ~(ONE << orig);
    }

    ///We dont need to delete regalia since if a piece is killed the occupier always gains regalia
    inline fn _RemovePiece(self: *Self, pos: u7, piece: u3) void {
        self.pieces[piece] &= ~(ONE << pos);
    }

    inline fn _AddRegalia(self: *Self, pos: u7) void {
        self.regalia |= ONE << pos;
    }

    inline fn _RemoveRegalia(self: *Self, pos: u7) void {
        self.regalia &= ~(ONE << pos);
    }

    inline fn _ToggleLockInDir(self: *Self, pos: u7, dir: u4) void {
        self.combatLocks[pos] ^= dir;
        self.combatLocks[NewPos(pos, dir)] ^= ConverseDir(dir);
    }

    fn StandAloneGenMovesFor(self: Self, pos: u7) !PYPTR {
        var array = Vec(Move).init(gAllocator);
        const pieceAt  = self.PieceAt(pos).?;
        std.debug.print("NoNullPiece\n", .{});
        const color: u1 = @intCast(pieceAt >> 2);
        const piece: u2 = @intCast(pieceAt % 4);
        try self.GenerateMovesFor(&array, color, pos, piece);
        std.debug.print("Length of array is {}\n", .{array.items.len});
        const sso = (try array.toOwnedSliceSentinel(ANULLMOVE));
        std.debug.print("Length of moves is {}\n", .{sso.len});
        return @intFromPtr(sso.ptr);
    }

    fn GenerateMovesFor(self: Self, array: *Vec(Move), color: u1, pos: u7, piece: u2) !void {
        var dests: BitBoard = ONE << pos;
        const allies = BlockersForColor(self, color);
        const enemies = BlockersForColor(self, ~color);
        const blockers = allies | enemies;
        
        //TODO movespeed bonus from infantry
        for (0..MOVSPD[piece]) |_| {
            dests |= Convolve(dests, blockers);
            std.debug.print("Dests is {}, blocks is {}\n", .{dests, blockers});
        }
        dests |= ONE << pos;

        std.debug.print("Generated raw moves\n", .{});

        var caps: BitBoard = 0;
        
        const ownPow = ATKPOW[piece] + Bit(self.regalia, pos);

        std.debug.print("Dests is {}\n", .{dests});

        while (dests != 0) {
            const dest: u7 = @intCast(LogHSB(dests));
            dests ^= ONE << dest;
            std.debug.print("Update dests, get {}\n", .{dest});
            if (piece == 0 and dest == pos and Bit(self.regalia, pos) != 0) { //Combat swap
                std.debug.print("Preswap\n", .{});
                for (0.., DIRS) |log, dir| if (CanGoDir(dir, dest)) {
                    const nDest = NewPos(dest, dir);
                    if (Has(allies, ONE << nDest)) {
                        try array.append(Move{.orig = pos, .dest = nDest, .doAtk = 0, .doCap = 0});
                    } else if (Has(enemies, ONE << nDest)) {
                        const destPow = self.PowerAt(nDest);
                        if (self.AttackersOn(nDest) + ownPow > destPow){
                            try array.append(Move{.orig = pos, .dest = nDest, .doAtk = 0, .doCap = 1, .atkDir = @intCast(log)});
                        } else {
                            try array.append(Move{.orig = pos, .dest = dest, .doAtk = 1, .doCap = 0, .atkDir = @intCast(log)});
                        }
                    }
                };
            } else if (piece == 2) { //Do all 8 directions
                unreachable;
            } else {
                for (0.., DIRS) |log, dir| if (CanGoDir(dir, dest)) {
                    std.debug.print("Start Move\n", .{});
                    const nDest = NewPos(dest, dir);
                    if (Has(enemies, ONE << nDest)) {
                        std.debug.print("PrePow\n", .{});
                        const destPow = self.PowerAt(nDest);
                        std.debug.print("PostPow\n", .{});
                        if (self.AttackersOn(nDest) + ownPow > destPow){
                            std.debug.print("Capture\n", .{});
                            if (!Has(caps, ONE << nDest)) {
                                try array.append(Move{.orig = pos, .dest = nDest, .doAtk = 0, .doCap = 1, .atkDir = @intCast(log)});
                                caps |= ONE << nDest;
                            }
                        } else {
                            std.debug.print("Atk\n", .{});
                            try array.append(Move{.orig = pos, .dest = dest, .doAtk = 1, .doCap = 0, .atkDir = @intCast(log)});
                        }
                    } else if (!Has(allies, ONE << nDest)) if (!Has(caps, ONE << nDest)) {
                        try array.append(Move{.orig = pos, .dest = nDest, .doAtk = 0, .doCap = 0});
                        caps |= ONE << nDest;
                    };
                };
            }
            if (!Has(caps, ONE << dest)) {
                std.debug.print("Plan Move\n", .{});
                try array.append(Move{.orig = pos, .dest = dest, .doAtk = 0, .doCap = 0});
                caps |= ONE << dest;
            }
        }
    }
};
///////////////////////////////////////////////////////////////////////////

inline fn BlockersForColor(self: Board, color: u1) BitBoard {
    return self.pieces[4*@as(u4, color)+0] | self.pieces[4*@as(u4, color)+1] | self.pieces[4*@as(u4, color)+2] | self.pieces[4*@as(u4, color)+3];
}

inline fn LogHSB(val: u81) u7 {
    return @intCast(80 - @clz(val));
}

fn CanGoDir(dir: u4, pos: u7) bool {
    return switch (dir) {
        1 => pos % 9 != 8,
        2 => pos / 9 != 8,
        4 => pos % 9 != 0,
        8 => pos / 9 != 0,
        else => unreachable,
    };
}

fn Convolve(front: u81, blockers: u81) u81 {
    var res = front;
    res |= (front & CANRIGHTMASK) << 1;
    res |= (front & CANUPMASK) << 9;
    res |= (front & CANLEFTMASK) >> 1;
    res |= (front & CANDOWNMASK) >> 9;
    return res & ~blockers;
}

fn BigConvolve(front: u81, blockers: u81) u81 {
    var res = front;
    res |= (res & CANRIGHTMASK) << 1;
    res |= (res & CANUPMASK) << 9;
    res |= (res & CANLEFTMASK) >> 1;
    res |= (res & CANDOWNMASK) >> 9;
    return res & ~blockers;
}

// 514
// 2.0
// 637
///Assumes dir 0-3 acts like 1<<dir for NewPos, but if 4+, does NewPos(NewPos(pos, dir-4), dir-3)
fn ToCapturePos(pos: u7, dir: u3) u7 {
    return switch (dir) {
        0 => pos + 1,
        1 => pos + 9,
        2 => pos - 1,
        3 => pos - 9,
        4 => pos + 1 + 9,
        5 => pos + 9 - 1,
        6 => pos - 1 - 9,
        7 => pos - 9 + 1,
    };
}

///Assume connections must not wrap around board
///Assume dir is one hot encoded
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
    ptr.*.Validate();
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
    gGpa = std.heap.GeneralPurposeAllocator(.{}).init;
    gAllocator = gGpa.allocator();
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
    ImportPtr(ptr).InitFromStr(str[0..162].*);
}

export fn PyGenMoves(ptr: PYPTR, pos: u8) PYPTR {
    //std.debug.print("Alignment is {}\n", .{@alignOf(Board)});
    const bptr: *Board = ImportPtr(ptr);
    return bptr.StandAloneGenMovesFor(@intCast(pos)) catch unreachable;
}

export fn PyGenInitStr(ptr: PYPTR, buf: PYPTR) void {
    const bptr: *Board = ImportPtr(ptr);
    const sbuf: *[162]u8 = @ptrFromInt(buf);
    bptr.GenInitStr(sbuf);
}

export fn PyBoardApplyMove(ptr: PYPTR, mov: u32) void {
    var move: Move = @bitCast(mov);
    ImportPtr(ptr).ApplyMove(&move);
}
