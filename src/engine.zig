const std = @import("std");
const MoveLib = @import("moves.zig");
pub var gAllocator: std.mem.Allocator = undefined;
var gGpa: std.heap.DebugAllocator(.{}) = undefined;
const AssertEql = @import("std").testing.expectEqual;
const Bot = @import("bot.zig");

///////////////////////////////////////////////////////////////////////////

const DoValidation: bool = true;

///////////////////////////////////////////////////////////////////////////

const ARTDIAGMOVE: bool = false;

///////////////////////////////////////////////////////////////////////////

//Speed to generate all moves is ~1.38 ms for 128 bit boards (with ReleaseFast and no Validation)
//Speed for 81 bit boards is ~1.48 - 1.73 ms
//Between a 6 and 20% speed up.
//Might have to investigate
//Still returns correct amount of moves

pub const BitBoard = u128;
const Connection = u4; //{-y}{-x}{+y}{+x}
const Vec = std.ArrayList;

///////////////////////////////////////////////////////////////////////////

const ONE: BitBoard = 1;

const RIGHT: u4 = 0b0001; //+x
const UP: u4 = 0b0010; //+y
const LEFT: u4 = 0b0100; //-x
const DOWN: u4 = 0b1000; //-y

const WHITE: u1 = 0;
const BLACK: u1 = 1;

const ATKPOW = [4]u8{ 2, 4, 7, 2 };
const MOVSPD = [4]u2{ 1, 2, 0, 0 }; //Move speed minus the attack

const DIRS = [4]u4{ 1, 2, 4, 8 };

const ANULLMOVE = Move{ .kind = .null, .orig = 127, .dest = 127 };

///////////////////////////////////////////////////////////////////////////

pub const MoveKind = enum(u3) {
    null = 0,
    move = 1,
    attack = 2,
    capture = 3,
    train = 4,
    swap = 5,
    kingweaken = 6,
    sacrifice = 7,
};

pub const Move = packed struct(u32) {
    kind: MoveKind,
    orig: u7,
    dest: u7,
    atkDir: u2 = 0,
    doRet: u1 = 0,
    capPiece: u2 = 0,
    capReg: u1 = 0,
    origLock: u4 = 0, //Old Combat locks before clearing
    destLock: u4 = 0, //Old Combat locks before clearing
    _: u1 = 0,
};

pub const SingleMoveBuffer = struct {
    const Self = @This();
    const MaxMoves = 128; //Maximum moves a single piece can make, 128 is our conservative estimate but if it fails we'll know

    buffer: *[MaxMoves] Move = undefined,
    count: u7 = 0,

    fn Init(self: *Self) !void {
        self.buffer = try gAllocator.create([MaxMoves]Move);
    }

    fn Append(self: *Self, item: Move) void {
        //if (DoValidation and self.count >= self.buffer.len) std.debug.panic("Overflow of single move buffer sized `{}`\n", .{self.buffer.len});
        //std.debug.print("Add item `{}` = {}\n", .{item, @as(u32, @bitCast(item))});
        self.buffer[self.count] = item;
        if (self.buffer[self.count] != item) @panic("Didnt set");
        self.count += 1;
        //if (self.GetBuffer()[self.GetBuffer().len-1] != item) @panic("Didnt set 3rd");
        //std.debug.print("Array base is {*}\n", .{&self.buffer});
        //for (self.GetBuffer(), 0..) |move, i| {
        //    //std.debug.print("Slice base is {*}\n", .{self.GetBuffer().ptr});
        //    //std.debug.print("Move base is {*}\n", .{&move});
        //    //std.debug.print("Buffer[{}] = {}\n", .{i, @as(u32, @bitCast(move))});
        //    if (i == self.count - 1) {
        //        
        //        //if (move != item)
        //        //std.debug.panic("Move changed from {} to {}", .{item, move});
        //    }
        //}
        //if (self.GetBuffer()[self.GetBuffer().len-1] != item) @panic("Didnt set 2nd");
    }

    fn Clear(self: *Self) void {
        self.count = 0;
    }
    
    fn GetBuffer(self: Self) [] const Move {
        return self.buffer[0..self.count];
    }

};

pub const Board = struct {
    const Self = @This();

    regalia: BitBoard,
    combatLocks: [81]Connection,
    pieces: [8]BitBoard, //{color}{pieceID}2 //00 -> Inf, 01 -> Cav, 10 -> Art, 11 -> Kng //Color: 0 -> white, 1 -> black
    toPlay: u1 = WHITE,

    pub fn WinVal(self: Self) i2 {
        const whiteHasKing: i2 = @intCast(@popCount(self.pieces[3]));
        const blackHasKing: i2 = @intCast(@popCount(self.pieces[7]));
        
        return whiteHasKing - blackHasKing;
    }

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

    fn GenInitStr(self: Self, buf: *[162]u8) void {
        for (0..81) |idx| {
            for (0..8) |piece| {
                if (Has(self.pieces[piece], ONE << @intCast(idx))) {
                    const hasReg: u8 = @intCast((self.regalia >> @intCast(idx)) & 1);
                    buf[idx] = 'a' + @as(u8, @intCast(hasReg << 3 | piece));
                    break;
                }
            } else buf[idx] = 'z';
        }
        for (0..81) |idx| {
            const coml = self.combatLocks[idx];
            //std.debug.print("{}", .{coml});
            buf[idx + 81] = 'a' + @as(u8, coml);
        }
        //std.debug.print("\n", .{});
    }

    fn PieceAt(self: Self, pos: u7) ?u3 {
        for (0..8) |piece| {
            if (Bit(self.pieces[piece], pos) != 0) return @intCast(piece);
        } else return null;
    }

    fn PowerAt(self: Self, pos: u7) u8 {
        if (DoValidation and self.PieceAt(pos) == null) std.debug.panic("Self ({}) is null, cannot get power\n", .{pos});
        return ATKPOW[self.PieceAt(pos).? % 4] + Bit(self.regalia, pos);
    }

    fn AttackersOn(self: Self, pos: u7) u8 {
        var sum: u8 = 0;
        for (DIRS) |dir| if (Has(self.combatLocks[pos], dir)) {
            sum += self.PowerAt(NewPos(pos, dir));
        };
        return sum;
    }

    fn Validate(self: *Self) void {
        if (DoValidation) self._Validate() catch |err| std.debug.panic("Validation Failure: `{}`", .{err});
    }

    fn _Validate(self: *Self) !void {
        var haspiece: BitBoard = 0;
        inline for (0..8) |idx| {
            if (Has(haspiece, self.pieces[idx])) return error.Overlapping_Pieces;
            haspiece |= self.pieces[idx];
        }

        for (0..9) |x| for (0..9) |y| {
            const pos: u7 = @intCast(9 * y + x);
            const conn = self.combatLocks[pos];
            errdefer std.debug.print("x: {}, y: {}\n", .{ x, y });
            if (x == 0 and Has(conn, LEFT)) return error.Invalid_Connection_Left;
            if (x == 8 and Has(conn, RIGHT)) return error.Invalid_Connection_Right;
            if (y == 0 and Has(conn, DOWN)) return error.Invalid_Connection_Down;
            if (y == 8 and Has(conn, UP)) return error.Invalid_Connection_Up;

            for ([_]u4{ 1, 2, 4, 8 }) |dir| if (Has(conn, dir)) {
                const nPos = NewPos(pos, dir);
                const nConn: u4 = self.combatLocks[nPos];
                if (!Has(nConn, ConverseDir(dir))) return error.Asymetric_Connection;
                if (Bit(haspiece, nPos) == 0) return error.Connection_to_Blank;
            };

            if (Implies(Bit(self.regalia, pos), Bit(haspiece, pos)) == 0) return error.Floating_Regalia;
        };
    }

    ///Not exaughstive but should catch most cases
    fn ValidateMove(self: Self, move: Move) void {
        if (DoValidation) self._ValidateMove(move) catch |err| std.debug.panic("Validation Failure: `{}`", .{err});
    }

    fn _ValidateMove(self: Self, move: Move) !void {
        errdefer std.debug.print("Errored move is {}\n", .{move});
        const moveKind: MoveKind = move.kind;
        if (moveKind == .null) return;

        if (move.dest > 81) return error.Destination_too_large;
        if (move.orig > 81) return error.Origin_too_large;

        const ownPiece = self.PieceAt(move.orig) orelse return error.No_Piece_At_Origin_of_Move;
        _ = ownPiece;

        if (move.doRet != 0 and Bit(self.regalia, move.orig) == 0) return error.Does_not_have_Regalia_to_Retreat;
        //std.debug.print("combatlocks is {}\n", .{self.combatLocks[move.orig]});
        //if (self.combatLocks[move.orig] != 0 and (move.doRet | move.doCap)==0) return error.Escape_From_Combat_Without_Retreat_nor_Capture;

        const destPiece = self.PieceAt(move.dest);
        switch (moveKind) {
            .capture => {
                //TODO
                if (destPiece == null) return error.Dest_is_Null;
                return;
            },
            .attack => {
                //TODO
                return;
            },
            .move => {
                //TODO
                return;
            },
            .train => {
                //TODO
                return;
            },
            .swap => {
                //TODO
                if (destPiece == null) return error.Dest_is_Null;
                return;
            },
            .kingweaken => {
                //TODO
                return;
            },
            .sacrifice => {
                //TODO
                return;
            },
            else => unreachable,
        }
    }

    ///Will update the move to contain accurate information about how to undo the move
    fn ApplyMove(self: *Self, move: *Move) void {
        //std.debug.print("Got move orig: {}\n", .{move.orig});
        //std.debug.print("Got move dest: {}\n", .{move.dest});

        ValidateMove(self.*, move.*);

        const moveKind: MoveKind = move.kind;
        //std.debug.print("Got movekind : {}\n", .{moveKind});
        if (moveKind == .null) return;

        const ownPiece = self.PieceAt(move.orig).?; //Checked by validate
        //std.debug.print("Got self\n", .{});
        if (move.doRet != 0) {
            self._RemoveRegalia(move.orig);
            self._RemoveOrigLocks(move);
        }

        const destPiece = self.PieceAt(move.dest);
        switch (moveKind) {
            .capture => {
                self._RemovePiece(move.dest, destPiece.?); //Checked by validate
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddRegalia(move.dest);
                self._RemoveDestLocks(move);
            },
            .attack => {
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._ToggleLockInDir(move.dest, @as(u4, 1) << @intCast(move.atkDir));
            },
            .move => {
                self._MovePiece(move.orig, move.dest, ownPiece);
            },
            .train => {
                //std.debug.print("Train begin\n", .{});
                self._AddRegalia(move.orig);
            },
            .swap => {
                self._SwapPieces(move.orig, move.dest, ownPiece, destPiece.?); //Checked by validate
            },
            .kingweaken => {
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._ToggleLockInDir(move.dest, @as(u4, 1) << move.atkDir);
                self._RemoveRegalia(NewPos(move.dest, @as(u4, 1) << move.atkDir));
            },
            .sacrifice => {
                self._RemovePiece(move.dest, destPiece.?);
                self._RemoveOrigLocks(move);
            },
            else => unreachable,
        }
        //std.debug.print("Validate begin\n", .{});
        self.Validate();
    }

    pub fn ApplyDoubleMove(self: *Self, moves: [2]Move) void {
        var tmov = moves[0];
        self.ApplyMove(&tmov);
        tmov = moves[1];
        self.ApplyMove(&tmov);
        self.toPlay = ~self.toPlay;
    }

    fn _RemoveOrigLocks(self: *Self, move: *Move) void {
        const oldLocks = self.combatLocks[move.orig];
        move.origLock = oldLocks;
        for (DIRS) |dir| if (Has(oldLocks, dir)) self._ToggleLockInDir(move.orig, dir);
    }

    fn _RemoveDestLocks(self: *Self, move: *Move) void {
        const oldLocks = self.combatLocks[move.dest];
        move.destLock = oldLocks;
        for (DIRS) |dir| if (Has(oldLocks, dir)) self._ToggleLockInDir(move.dest, dir);
    }

    fn _SwapPieces(self: *Self, a: u7, b: u7, pieceA: u3, pieceB: u3) void {
        if (DoValidation and a == b) @panic("Destination was Origin for swap");
        self.pieces[pieceA] ^= ONE << a;
        self.pieces[pieceA] ^= ONE << b;
        self.pieces[pieceB] ^= ONE << a;
        self.pieces[pieceB] ^= ONE << b;
        const aReg: u81 = Bit(self.regalia, a);
        const bReg: u81 = Bit(self.regalia, b);
        self.regalia = self.regalia & ~(aReg << a | bReg << b) | (aReg << b | bReg << a);
    }

    fn _MovePiece(self: *Self, orig: u7, dest: u7, piece: u3) void {
        //if (DoValidation and dest == orig) @panic("Destination was Origin for move");
        self.pieces[piece] ^= ONE << orig;
        self.pieces[piece] ^= ONE << dest;
        if (dest != orig) {
            self.regalia |= @as(u81, Bit(self.regalia, orig)) << dest;
            self.regalia &= ~(ONE << orig);
        }
    }

    ///We dont need to delete regalia since if a piece is killed the occupier always gains regalia
    fn _RemovePiece(self: *Self, pos: u7, piece: u3) void {
        self.pieces[piece] &= ~(ONE << pos);
    }

    fn _AddRegalia(self: *Self, pos: u7) void {
        self.regalia |= ONE << pos;
    }

    fn _RemoveRegalia(self: *Self, pos: u7) void {
        self.regalia &= ~(ONE << pos);
    }

    fn _ToggleLockInDir(self: *Self, pos: u7, dir: u4) void {
        self.combatLocks[pos] ^= dir;
        self.combatLocks[NewPos(pos, dir)] ^= ConverseDir(dir);
    }

    fn StandAloneGenMovesFor(self: Self, pos: u7) !PYPTR {
        var array = Vec(Move).init(gAllocator);
        if (DoValidation and self.PieceAt(pos) == null) return error.Cannot_Generate_Moves_for_Null;
        const pieceAt = self.PieceAt(pos).?;
        //std.debug.print("NoNullPiece\n", .{});
        const color: u1 = @intCast(pieceAt >> 2);
        const piece: u2 = @intCast(pieceAt % 4);
        try self.GenerateMovesFor(&array, color, pos, piece);
        //std.debug.print("Length of array is {}\n", .{array.items.len});
        const sso = (try array.toOwnedSliceSentinel(ANULLMOVE));
        //std.debug.print("Length of moves is {}\n", .{sso.len});
        return @intFromPtr(sso.ptr);
    }

    fn GenerateMovesFor(self: Self, array: *Vec(Move), color: u1, pos: u7, piece: u2) !void {
        const allies = BlockersForColor(self, color);
        const enemies = BlockersForColor(self, ~color);
        const blockers = allies | enemies;
        const enemKing = LogHSB(self.pieces[4*@as(u4, ~color) + 3]);
        const locks = self.combatLocks[pos];
        const locked: u1 = @intFromBool(locks != 0);
        var _lockers: BitBoard = 0;
        for (DIRS) |dir| {
            if (Has(locks, dir)) {
                _lockers |= ONE << NewPos(pos, dir);
            }
        }
        const ownRegalia = Bit(self.regalia, pos);
        const stuck: bool = locked == 1 and ownRegalia == 0;
        

        const spd = MOVSPD[piece];
        const ownpow = self.PowerAt(pos);
        //std.debug.print("Got own pow\n", .{});

        const rawmoves = MoveLib.MoveMap(pos, blockers, spd) | ONE << pos;
        const capmap = MoveLib.CaptureConvolve(rawmoves, piece);
        const finalmoves = if (ARTDIAGMOVE) (capmap & ~blockers) else (MoveLib.CaptureConvolve(rawmoves, 0) & ~blockers);
        var threatened = enemies & capmap;

        var _capable: BitBoard = 0;
        var _atkable: BitBoard = 0;
        var _kingCap: u7 = 127;
        //std.debug.print("Pre enemy pow\n", .{});
        //std.debug.print("Enemy map is {b:0>81}, threatens: {b:0>81}\n", .{ enemies, threatened });

        while (threatened != 0) {
            const dest: u7 = LogHSB(threatened);
            threatened ^= ONE << dest;
            const tpow = if (Has(_lockers, ONE << dest)) 0 else ownpow;
            if (self.AttackersOn(dest) + tpow > self.PowerAt(dest)) {
                if (dest == enemKing and Bit(self.regalia, enemKing) == 1) {
                    _kingCap = dest;
                    //std.debug.print("Enemy king capture possible!\n", .{});
                } else {
                    _capable |= ONE << dest;
                }
            } else {
                _atkable |= ONE << dest;
            }
        }
        const capable = _capable & ~_lockers;
        const caplockers = _capable & _lockers;
        const atkable = _atkable;

        //Populate with whatever variable you would like to iterate over and this will be emptied to 0 after usage
        var targetbuf: BitBoard = undefined;

        //Capturable moves from lockers
        targetbuf = caplockers;
        while (targetbuf != 0) {
            const dest: u7 = LogHSB(targetbuf);
            targetbuf ^= ONE << dest;
            try array.append(Move{ .kind = .capture, .orig = pos, .dest = dest });
        }

        if (!stuck) {
            //std.debug.print("Not stuck\n", .{});

            //Combat Swap
            if (piece == 0 and ownRegalia == 1){
                const swaptars = allies & MoveLib.MoveMap(pos, 0, 1);
                targetbuf = swaptars;
                while (targetbuf != 0) {
                    const dest: u7 = LogHSB(targetbuf);
                    targetbuf ^= ONE << dest;
                    try array.append(Move{.kind = .swap, .orig = pos, .dest = dest});
                }
            }

            //King attack
            if (_kingCap != 127) {
                inline for (DIRS) |dir| {
                    const logdir = LogHSB(dir);
                    const atkorig = NewPos(enemKing, ConverseDir(dir));
                    if (Bit(rawmoves, atkorig) != 0)
                        try array.append(Move{ .kind = .kingweaken, .orig = pos, .dest = atkorig, .atkDir = logdir, .doRet = locked});
                }
            }

            //Capturable moves
            targetbuf = capable;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= ONE << dest;
                try array.append(Move{ .kind = .capture, .orig = pos, .dest = dest, .doRet = locked});
            }

            //Train if not combat locked
            if (locked == 0 and ownRegalia == 0) try array.append(Move{ .kind = .train, .orig = pos, .dest = pos});

            inline for (DIRS) |dir| {
                const atkorigs = rawmoves & MoveLib.ConvolveDir(atkable, LogHSB(ConverseDir(dir)));
                //Add regular moves
                targetbuf = atkorigs;
                while (targetbuf != 0) {
                    const dest: u7 = LogHSB(targetbuf);
                    targetbuf ^= ONE << dest;
                    try array.append(Move{ .kind = .attack, .orig = pos, .dest = dest, .atkDir = LogHSB(dir), .doRet = locked});
            }
            }
    
            //Add regular moves
            targetbuf = finalmoves;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= ONE << dest;
                try array.append(Move{ .kind = .move, .orig = pos, .dest = dest, .doRet = locked});
            }
        } else {
            try array.append(Move{ .kind = .sacrifice, .orig = pos, .dest = pos});
        }
    }

    fn BufferedGenerateMovesFor(self: Self, buffer: *SingleMoveBuffer, color: u1, pos: u7, piece: u2) !void {

        const allies = BlockersForColor(self, color);
        const enemies = BlockersForColor(self, ~color);
        const blockers = allies | enemies;
        const enemKing = LogHSB(self.pieces[4*@as(u4, ~color) + 3]);
        const locks = self.combatLocks[pos];
        const locked: u1 = @intFromBool(locks != 0);
        var _lockers: BitBoard = 0;
        for (DIRS) |dir| {
            if (Has(locks, dir)) {
                _lockers |= ONE << NewPos(pos, dir);
            }
        }
        const ownRegalia = Bit(self.regalia, pos);
        const stuck: bool = locked == 1 and ownRegalia == 0;
        

        const spd = MOVSPD[piece];
        const ownpow = self.PowerAt(pos);
        //std.debug.print("Got own pow\n", .{});

        const rawmoves = MoveLib.MoveMap(pos, blockers, spd) | ONE << pos;
        const capmap = MoveLib.CaptureConvolve(rawmoves, piece);
        const finalmoves = if (ARTDIAGMOVE) (capmap & ~blockers) else (MoveLib.CaptureConvolve(rawmoves, 0) & ~blockers);
        var threatened = enemies & capmap;

        var _capable: BitBoard = 0;
        var _atkable: BitBoard = 0;
        var _kingCap: u7 = 127;
        //std.debug.print("Pre enemy pow\n", .{});
        //std.debug.print("Enemy map is {b:0>81}, threatens: {b:0>81}\n", .{ enemies, threatened });

        while (threatened != 0) {
            const dest: u7 = LogHSB(threatened);
            threatened ^= ONE << dest;
            const tpow = if (Has(_lockers, ONE << dest)) 0 else ownpow;
            if (self.AttackersOn(dest) + tpow > self.PowerAt(dest)) {
                if (dest == enemKing and Bit(self.regalia, enemKing) == 1) {
                    _kingCap = dest;
                    //std.debug.print("Enemy king capture possible!\n", .{});
                } else {
                    _capable |= ONE << dest;
                }
            } else {
                _atkable |= ONE << dest;
            }
        }
        const capable = _capable & ~_lockers;
        const caplockers = _capable & _lockers;
        const atkable = _atkable;

        //Populate with whatever variable you would like to iterate over and this will be emptied to 0 after usage
        var targetbuf: BitBoard = undefined;

        //Capturable moves from lockers
        targetbuf = caplockers;
        while (targetbuf != 0) {
            const dest: u7 = LogHSB(targetbuf);
            targetbuf ^= ONE << dest;
            buffer.Append(Move{ .kind = .capture, .orig = pos, .dest = dest });
        }

        if (!stuck) {
            //std.debug.print("Not stuck\n", .{});

            //Combat Swap
            if (piece == 0 and ownRegalia == 1){
                const swaptars = allies & MoveLib.MoveMap(pos, 0, 1);
                targetbuf = swaptars;
                while (targetbuf != 0) {
                    const dest: u7 = LogHSB(targetbuf);
                    targetbuf ^= ONE << dest;
                    buffer.Append(Move{.kind = .swap, .orig = pos, .dest = dest});
                }
            }

            //King attack
            if (_kingCap != 127) {
                inline for (DIRS) |dir| {
                    const logdir = LogHSB(dir);
                    const atkorig = NewPos(enemKing, ConverseDir(dir));
                    if (Bit(rawmoves, atkorig) != 0)
                        buffer.Append(Move{ .kind = .kingweaken, .orig = pos, .dest = atkorig, .atkDir = logdir, .doRet = locked});
                }
            }

            //Capturable moves
            targetbuf = capable;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= ONE << dest;
                buffer.Append(Move{ .kind = .capture, .orig = pos, .dest = dest, .doRet = locked});
            }

            //Train if not combat locked
            if (locked == 0 and ownRegalia == 0) buffer.Append(Move{ .kind = .train, .orig = pos, .dest = pos});

            inline for (DIRS) |dir| {
                const atkorigs = rawmoves & MoveLib.ConvolveDir(atkable, LogHSB(ConverseDir(dir)));
                //Add regular moves
                targetbuf = atkorigs;
                while (targetbuf != 0) {
                    const dest: u7 = LogHSB(targetbuf);
                    targetbuf ^= ONE << dest;
                    buffer.Append(Move{ .kind = .attack, .orig = pos, .dest = dest, .atkDir = LogHSB(dir), .doRet = locked});
            }
            }
    
            //Add regular moves
            targetbuf = finalmoves;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= ONE << dest;
                buffer.Append(Move{ .kind = .move, .orig = pos, .dest = dest, .doRet = locked});
            }
        } else {
            buffer.Append(Move{ .kind = .sacrifice, .orig = pos, .dest = pos});
        }
    }


    fn GenerateAllColorSingleMoves(self: Self, array: *Vec(Move), color: u1) !void {
        for ([_]u2{2, 3, 1, 0}) |piece| {
            var pieces = self.pieces[4*@as(u4, color) + piece];
            while (pieces != 0){
                const pos: u7 = LogHSB(pieces);
                pieces ^= ONE << pos;

                if (self.PieceAt(pos) == null) std.debug.panic("Ahhh, pos is {}\n", .{pos});
                try self.GenerateMovesFor(array, color, pos, piece);
            }
        }
    }

    fn BufferedGenerateAllColorSingleMoves(self: Self, buffer: *SingleMoveBuffer, color: u1) !void {
        for ([_]u2{2, 3, 1, 0}) |piece| {
            var pieces = self.pieces[4*@as(u4, color) + piece];
            while (pieces != 0){
                const pos: u7 = LogHSB(pieces);
                pieces ^= ONE << pos;
                if (DoValidation and pos > 81) std.debug.panic("Bit piece is out of bounds at `{}`", .{pos});

                if (self.PieceAt(pos) == null) std.debug.panic("Ahhh, pos is {}\n", .{pos});
                try self.BufferedGenerateMovesFor(buffer, color, pos, piece);
            }
        }
    }

    pub fn GenerateAllColorMoves(self: *Self, array: *Vec([2]Move), color: u1) !void {
        //var oldsinglemoves = Vec(Move).init(gAllocator);
        var singlemoves = SingleMoveBuffer{};
        try singlemoves.Init();
        //var secmoves = Vec(Move).init(gAllocator);
        var secmoves = SingleMoveBuffer{};
        try secmoves.Init();
        try self.BufferedGenerateAllColorSingleMoves(&singlemoves, color);
        //try self.GenerateAllColorSingleMoves(&oldsinglemoves, color);
        //if (oldsinglemoves.items.len != singlemoves.count) std.debug.panic("Lengths are not the same {} and {}\n", .{oldsinglemoves.items.len, singlemoves.count});
        //std.debug.print("Length is {}\n", .{singlemoves.count});
        //for (singlemoves.GetBuffer(), 0..) |_initmove, i| {
        //    std.debug.print("Move[{}] is {}\n", .{i, @as(u32, @bitCast(_initmove))});
        //    if (!std.meta.eql(oldsinglemoves.items[i], _initmove)) std.debug.panic("i = {}, other is {}, self is {}", .{i, oldsinglemoves.items[i], _initmove});
        //}
        //const first = singlemoves.buffer[1];
        for (singlemoves.GetBuffer()) |_initmove| {
            var initmove = _initmove;
            //if (singlemoves.buffer[1] != first) @panic("Mutation of first\n");
            //if (!std.meta.eql(oldsinglemoves.items[i], initmove)) std.debug.panic("i = {}, {} != {}, rhs is int {}", .{i, oldsinglemoves.items[i], initmove, @as(u32, @bitCast(_initmove))});
            
            //_ = &initmove;

            const copy = self.*;
            defer self.* = copy;
            
            self.ApplyMove(&initmove);
            
            //defer self.UnApplyMove(initmove);
            
            //secmoves.clearAndFree();
            secmoves.Clear();
            try self.BufferedGenerateAllColorSingleMoves(&secmoves, color);
            for (secmoves.GetBuffer()) |secmove| {
                if (secmove.orig != initmove.dest) 
                    try array.append([2]Move{initmove, secmove});
            }
            try array.append([2]Move{initmove, ANULLMOVE});
        }
    }

    pub fn GenerateRandomMove(self: *Self, rand: *std.Random, color: u1) ![2]Move {
        var singlemoves = Vec(Move).init(gAllocator);
        try self.GenerateAllColorSingleMoves(&singlemoves, color);
        const firstidx = rand.uintLessThanBiased(u32, @intCast(singlemoves.items.len));
        const _initmove = singlemoves.items[firstidx];


        var secmoves = Vec(Move).init(gAllocator);
        var initmove = _initmove;

        const copy = self.*;
        defer self.* = copy;
        
        self.ApplyMove(&initmove);

        try self.GenerateAllColorSingleMoves(&secmoves, color);
        const secidx = rand.uintLessThanBiased(u32, @intCast(secmoves.items.len));
        const secmove = singlemoves.items[secidx];

        return [2]Move{_initmove, secmove};
    }
};

///////////////////////////////////////////////////////////////////////////

fn BlockersForColor(self: Board, color: u1) BitBoard {
    return self.pieces[4 * @as(u4, color) + 0] | self.pieces[4 * @as(u4, color) + 1] | self.pieces[4 * @as(u4, color) + 2] | self.pieces[4 * @as(u4, color) + 3];
}

inline fn LogHSB(val: BitBoard) u7 {
    const bitSize = @bitSizeOf(BitBoard);
    return @intCast((bitSize - 1) - @clz(val));
}
test "LogHSB" {
    try AssertEql(LogHSB(ONE << 17), 17);
}

fn CanGoDir(dir: u4, pos: u7) bool {
    return switch (dir) {
        1 => pos % 9 != 8,
        2 => pos / 9 != 8,
        4 => pos % 9 != 0,
        8 => pos / 9 != 0,
        else => if (DoValidation) std.debug.panic("Tried to use dir: {}\n", .{dir}) else unreachable,
    };
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
        else => if (DoValidation) std.debug.panic("Tried to use dir: {}\n", .{dir}) else unreachable,
    };
}

///////////////////////////////////////////////////////////////////////////

fn ConverseDir(dir: u4) u4 {
    return dir << 2 | dir >> 2;
}

fn Implies(x: u1, y: u1) u1 {
    return ~x | y;
}

fn Has(x: anytype, y: anytype) bool {
    return x & y != 0;
}

fn Bit(x: BitBoard, y: anytype) u1 {
    if (y > 81) return 0;
    return @intCast((x >> y) & 1);
}

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

pub export fn PyInitAlloc() void {
    gGpa = std.heap.GeneralPurposeAllocator(.{}).init;
    gAllocator = gGpa.allocator();
    MoveLib.Init();
    Bot.Init();
}

pub export fn PyNewBoardHandle() PYPTR {
    const handle = _NewBoardHandle() catch unreachable;
    //std.debug.print("Exporting {*} as {x}\n", .{handle, ExportPtr(handle)});
    return ExportPtr(handle);
}
fn _NewBoardHandle() !*Board {
    const boardPtr = try gAllocator.create(Board);
    return boardPtr;
}

pub export fn PyInitBoardFromStr(ptr: PYPTR, str: [*c]u8) void {
    ImportPtr(ptr).InitFromStr(str[0..162].*);
}

pub export fn PyGenMoves(ptr: PYPTR, pos: u8) PYPTR {
    const bptr: *Board = ImportPtr(ptr);
    return bptr.StandAloneGenMovesFor(@intCast(pos)) catch unreachable;
}

pub export fn PyGenAllMoves(ptr: PYPTR, color: u8) PYPTR {
    const bptr: *Board = ImportPtr(ptr);
    var array = Vec([2]Move).init(gAllocator);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..1000) |_| {
        array.clearRetainingCapacity();
        bptr.GenerateAllColorMoves(&array, @intCast(color)) catch unreachable;
    }
    const passed = timer.read();
    if (array.items.len != 3635) std.debug.panic("Array length was wrong, {} not 3635\n", .{array.items.len});
    //std.debug.print("Total double moves is: {}\n", .{array.items.len});
    std.debug.print("Time took was {d:.6}ms each\n", .{@as(f64, @floatFromInt(passed))/1_000_000_000});
    return @intFromPtr(array.items.ptr);
}

pub export fn PyGenInitStr(ptr: PYPTR, buf: PYPTR) void {
    const bptr: *Board = ImportPtr(ptr);
    const sbuf: *[162]u8 = @ptrFromInt(buf);
    bptr.GenInitStr(sbuf);
}

pub export fn PyBoardApplyMove(ptr: PYPTR, mov: u32) void {
    var move: Move = @bitCast(mov);
    ImportPtr(ptr).ApplyMove(&move);
}

pub export fn PyPlayOutBoard(ptr: PYPTR) i8 {
    var timer = std.time.Timer.start() catch unreachable;
    const ret = Bot.PlayOutGame(ImportPtr(ptr).*);
    const passed = timer.read();
    std.debug.print("Time took was {d:.3}ms\n", .{@as(f64, @floatFromInt(passed))/1_000_000});
    return ret;
}

pub export fn PyCompMove(ptr: PYPTR) u64 {
    std.debug.print("Thinking...\n", .{});
    var timer = std.time.Timer.start() catch unreachable;
    const ret = Bot.CompMove(ImportPtr(ptr).*);
    const passed = timer.read();
    std.debug.print("Time took to decide move was {d:.3}ms\n", .{@as(f64, @floatFromInt(passed))/1_000_000});
    return @as(u64, @as(u32, @bitCast(ret[0]))) << 32 | @as(u64, @as(u32, @bitCast(ret[1])));
}

///////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(@This());
}
