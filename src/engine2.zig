const std = @import("std");
const MoveLib = @import("moves.zig");
pub var gAllocator: std.mem.Allocator = undefined;
var gGpa: std.heap.DebugAllocator(.{}) = undefined;
const AssertEql = @import("std").testing.expectEqual;

///////////////////////////////////////////////////////////////////////////

const DoValidation: bool = true;

///////////////////////////////////////////////////////////////////////////

const ARTDIAGMOVE: bool = false;

///////////////////////////////////////////////////////////////////////////

pub const BitBoard = u128;
//const ArrayList = std.ArrayList;

///////////////////////////////////////////////////////////////////////////

const BB_ONE: BitBoard = 1;

//Origin is bottom left
const OH_RIGHT: u4 = 0b0001; //+x
const OH_UP: u4 = 0b0010; //+y
const OH_LEFT: u4 = 0b0100; //-x
const OH_DOWN: u4 = 0b1000; //-y

const SHR = 1;
const SHU = 11;
const SHL = -SHR;
const SHD = -SHU;

const WHITE = 0;
const BLACK = 1;

pub const ATKPOW = [4] comptime_int { 2, 4, 7, 2, 
                                                       3, 5, 8, 3};
const MOVSPD = [4] comptime_int { 1, 2, 0, 0 }; //Move speed minus the attack

const DIRS = [4]u4{ OH_RIGHT, OH_UP, OH_LEFT, OH_DOWN };

const PLAYABLE = b: {
    var bb: BitBoard = 0;
    for(0..9) |x| for (0..9) |y| {
        bb |= 1 << (11 * y + x);
    };
    break: b bb;
};

test {
    if (PLAYABLE != 0x1ff3fe7fcff9ff3fe7fcff9ff) @compileError("Playable board generated wrong");
}

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

pub const Move = struct {
    kind: MoveKind,
    orig: u7,
    dest: u7,
    atkdir: u2, //Undefined if kind does not attack
    doRet: bool,
};
const SingleMoveBuffer = std.BoundedArray(Move, 128);

pub const FullMove = struct {
    moves: [2]Move,
};
const FullMoveBuffer = std.BoundedArray(FullMove, 128*128);


pub const Board = struct {
    const Self = @This();

    lockright: BitBoard,
    lockup: BitBoard,
    pieces: [16] BitBoard, //{color}{pieceID}2 //00 -> Inf, 01 -> Cav, 10 -> Art, 11 -> Kng //Color: 0 -> white, 1 -> black
    toPlay: u1,

    fn InitFromStr(self: *Self, initStr: [162]u8) void {
        //std.debug.print("Got initstr {s}\n", .{initStr});
        self.locks = @splat(0);
        self.pieces = @splat(0);
        for (0.., initStr[0..81]) |_idx, c| {
            if (c == 'z') continue;
            const idx: u7 = 11 * (_idx / 9) + (_idx % 9);

            const val = c - 'a';
            const pieceType = val % 4;
            const pieceColor = (val / 4) & 1;
            const hasReg = (val / 8) & 1;
            self.pieces[pieceType | hasReg<<2 | pieceColor<<3] |= BB_ONE << idx;
        }
        for (0.., initStr[81..162]) |_idx, c| {
            if (c == 'z') continue;
            const idx: u7 = 11 * (_idx / 9) + (_idx % 9);
            self.locks[idx] = @intCast(c - 'a');
        }
        Validate(self);
    }

    fn GenInitStr(self: Self, buf: *[162]u8) void {
        for (0..81) |_idx| {
            const idx = 11 * (_idx / 9) + (_idx % 9);
            for (0..16) |piece| {
                if (Has(self.pieces[piece], BB_ONE << @intCast(idx))) {
                    //The fmt expects reg.color.type_type, but we are given color.reg.type_type :|
                    const sendpiece: u8 = @intCast(((piece >> 2) & 1) << 3 | ((piece >> 3) & 1) << 2 | piece % 4);

                    buf[idx] = 'a' + sendpiece;
                    break;
                }
            } else buf[idx] = 'z';
        }
        for (0..81) |_idx| {
            const idx = 11 * (_idx / 9) + (_idx % 9);
            const coml = self.combatLocks[idx];
            //std.debug.print("{}", .{coml});
            buf[idx + 81] = 'a' + @as(u8, coml);
        }
        //std.debug.print("\n", .{});
    }

    fn PieceAt(self: Self, pos: u7) ?u4 {
        for (0..16) |piece| 
            if (Bit(self.pieces[piece], pos) != 0) 
                return @intCast(piece);
        return null;
    }

    fn PowerAt(self: Self, pos: u7) u8 {
        if (DoValidation and self.PieceAt(pos) == null) std.debug.panic("Self ({}) is null, cannot get power\n", .{pos});
        
        const piece = self.PieceAt(pos).?;
        return ATKPOW[piece % 8];
    }

    fn AttackersOn(self: Self, pos: u7) u8 {
        var sum: u8 = 0;
        const right = Bit(self.lockright, pos);
        const up = Bit(self.lockup, pos);
        const left = Bit(self.lockright, pos + SHL);
        const down = Bit(self.lockup, pos + SHD);
        sum += right * self.PowerAt(pos + SHR);
        sum += up * self.PowerAt(pos + SHU);
        sum += left * self.PowerAt(pos + SHL);
        sum += down * self.PowerAt(pos + SHD);
        return sum;
    }

    fn Validate(self: *Self) void {
        if (DoValidation) self._Validate() catch |err| std.debug.panic("Validation Failure: `{}`", .{err});
    }

    fn _Validate(self: *Self) !void {
        _ = self;
        return;
    }

    /// Not exaughstive but should catch most cases
    /// TODO
    fn ValidateMove(self: Self, move: Move) void {
        if (DoValidation) self._ValidateMove(move) catch |err| std.debug.panic("Validation Failure: `{}`", .{err});
    }

    fn _ValidateMove(self: Self, move: Move) !void {
        errdefer std.debug.print("Errored move is {}\n", .{move});
        const moveKind: MoveKind = move.kind;
        if (moveKind == .null) return; //Always legal


        if (move.orig % 11 > 8) return error.Orig_X_Too_Large;
        if (move.orig / 11 > 8) return error.Orig_Y_Too_Large;
        if (move.dest % 11 > 8) return error.Dest_X_Too_Large;
        if (move.dest / 11 > 8) return error.Dest_Y_Too_Large;
        

        const ownPiece = self.PieceAt(move.orig) orelse return error.No_Piece_At_Origin_of_Move;
        _ = ownPiece;


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

    fn ApplyMove(self: *Self, move: Move) void {
        ValidateMove(self.*, move);

        const moveKind: MoveKind = move.kind;
        if (moveKind == .null) return;

        const ownPiece = self.PieceAt(move.orig).?; //Checked by validate

        if (move.doRet) {
            self._RemoveRegalia(move.orig);
            self._RemoveLocksAt(move.orig);
        }

        const destPiece = self.PieceAt(move.dest); //May be null, but if so is never used.
        switch (moveKind) {
            .capture => {
                self._RemovePiece(move.dest, destPiece.?); //Checked by validate
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddRegalia(move.dest);
                //Note to self, can optimize these former two into a single fused operation
                self._RemoveLocksAt(move.dest);
            },
            .attack => {
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddLockInDir(move.dest, move.atkdir);
            },
            .move => {
                self._MovePiece(move.orig, move.dest, ownPiece);
            },
            .train => {
                self._AddRegalia(move.orig);
            },
            .swap => {
                self._SwapPieces(move.orig, move.dest, ownPiece, destPiece.?); //Checked by validate
            },
            .kingweaken => {
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddLockInDir(move.dest, move.atkDir);
                self._RemoveRegalia(Offset(move.dest, move.atkDir));
            },
            .sacrifice => {
                self._RemovePiece(move.dest, destPiece.?);
                self._RemoveLocksAt(move.orig);
            },
            else => unreachable,
        }
        self.Validate();
    }

    pub fn ApplyFullMove(self: *Self, move: FullMove) void {
        self.ApplyMove(move.moves[0]);
        self.ApplyMove(move.moves[1]);
        self.toPlay = ~self.toPlay;
    }

    fn _RemoveLocksAt(self: *Self, pos: u7) void {
        _ = self;
        _ = pos;
        //TODO
    }

    fn _SwapPieces(self: *Self, a: u7, b: u7, pieceA: u4, pieceB: u4) void {
        if (DoValidation and a == b) @panic("Destination was Origin for swap");
        self._MovePiece(a, b, pieceA);
        self._MovePiece(b, a, pieceB);
    }

    fn _MovePiece(self: *Self, orig: u7, dest: u7, piece: u4) void {
        self.pieces[piece] ^= BB_ONE << orig;
        self.pieces[piece] ^= BB_ONE << dest;
    }

    fn _RemovePiece(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece] &= ~(BB_ONE << pos);
    }

    fn _AddRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece & ~(1<<4)] &= ~(BB_ONE << pos); //Toggle off origin
        self.pieces[piece | (1<<4)] |= (BB_ONE << pos); //Toggle on 
    }

    fn _RemoveRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece | (1<<4)] &= ~(BB_ONE << pos); //Toggle off
        self.pieces[piece & ~(1<<4)] |= (BB_ONE << pos); //Toggle on 
    }

    fn _ToggleRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece] ^= (BB_ONE << pos); //Toggle off origin
        self.pieces[(1<<4) ^ piece] ^= (BB_ONE << pos); //Toggle on 
    }

    fn _AddLockInDir(self: *Self, pos: u7, dir: u2) void {
        switch (dir) {
            0 => self.lockright |= BB_ONE << (pos),
            1 => self.lockup |= BB_ONE << (pos),
            2 => self.lockright |= BB_ONE << (pos - SHL),
            3 => self.lockup |= BB_ONE << (pos - SHD),
        }
    }

    fn StandAloneGenMovesFor(self: Self, pos: u7) !PYPTR {
        var array = ArrayList(Move).init(gAllocator);
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

    ///Deprecated
    fn GenerateMovesFor(self: Self, array: *ArrayList(Move), color: u1, pos: u7, piece: u2) !void {
        const allies = BlockersForColor(self, color);
        const enemies = BlockersForColor(self, ~color);
        const blockers = allies | enemies;
        const enemKing = LogHSB(self.pieces[4*@as(u4, ~color) + 3]);
        const locks = self.combatLocks[pos];
        const locked: u1 = @intFromBool(locks != 0);
        var _lockers: BitBoard = 0;
        for (DIRS) |dir| {
            if (Has(locks, dir)) {
                _lockers |= BB_ONE << NewPos(pos, dir);
            }
        }
        const ownRegalia = Bit(self.regalia, pos);
        const stuck: bool = locked == 1 and ownRegalia == 0;
        

        const spd = MOVSPD[piece];
        const ownpow = self.PowerAt(pos);
        //std.debug.print("Got own pow\n", .{});

        const rawmoves = MoveLib.MoveMap(pos, blockers, spd) | BB_ONE << pos;
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
            threatened ^= BB_ONE << dest;
            const tpow = if (Has(_lockers, BB_ONE << dest)) 0 else ownpow;
            if (self.AttackersOn(dest) + tpow > self.PowerAt(dest)) {
                if (dest == enemKing and Bit(self.regalia, enemKing) == 1) {
                    _kingCap = dest;
                    //std.debug.print("Enemy king capture possible!\n", .{});
                } else {
                    _capable |= BB_ONE << dest;
                }
            } else {
                _atkable |= BB_ONE << dest;
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
            targetbuf ^= BB_ONE << dest;
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
                    targetbuf ^= BB_ONE << dest;
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
                targetbuf ^= BB_ONE << dest;
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
                    targetbuf ^= BB_ONE << dest;
                    try array.append(Move{ .kind = .attack, .orig = pos, .dest = dest, .atkDir = LogHSB(dir), .doRet = locked});
            }
            }
    
            //Add regular moves
            targetbuf = finalmoves;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= BB_ONE << dest;
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
                _lockers |= BB_ONE << NewPos(pos, dir);
            }
        }
        const ownRegalia = Bit(self.regalia, pos);
        const stuck: bool = locked == 1 and ownRegalia == 0;
        

        const spd = MOVSPD[piece];
        const ownpow = self.PowerAt(pos);
        //std.debug.print("Got own pow\n", .{});

        const rawmoves = MoveLib.MoveMap(pos, blockers, spd) | BB_ONE << pos;
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
            threatened ^= BB_ONE << dest;
            const tpow = if (Has(_lockers, BB_ONE << dest)) 0 else ownpow;
            if (self.AttackersOn(dest) + tpow > self.PowerAt(dest)) {
                if (dest == enemKing and Bit(self.regalia, enemKing) == 1) {
                    _kingCap = dest;
                    //std.debug.print("Enemy king capture possible!\n", .{});
                } else {
                    _capable |= BB_ONE << dest;
                }
            } else {
                _atkable |= BB_ONE << dest;
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
            targetbuf ^= BB_ONE << dest;
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
                    targetbuf ^= BB_ONE << dest;
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
                targetbuf ^= BB_ONE << dest;
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
                    targetbuf ^= BB_ONE << dest;
                    buffer.Append(Move{ .kind = .attack, .orig = pos, .dest = dest, .atkDir = LogHSB(dir), .doRet = locked});
            }
            }
    
            //Add regular moves
            targetbuf = finalmoves;
            while (targetbuf != 0) {
                const dest: u7 = LogHSB(targetbuf);
                targetbuf ^= BB_ONE << dest;
                buffer.Append(Move{ .kind = .move, .orig = pos, .dest = dest, .doRet = locked});
            }
        } else {
            buffer.Append(Move{ .kind = .sacrifice, .orig = pos, .dest = pos});
        }
    }

    ///Deprecated
    fn GenerateAllColorSingleMoves(self: Self, array: *ArrayList(Move), color: u1) !void {
        for ([_]u2{2, 3, 1, 0}) |piece| {
            var pieces = self.pieces[4*@as(u4, color) + piece];
            while (pieces != 0){
                const pos: u7 = LogHSB(pieces);
                pieces ^= BB_ONE << pos;

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
                pieces ^= BB_ONE << pos;
                if (DoValidation and pos > 81) std.debug.panic("Bit piece is out of bounds at `{}`", .{pos});

                if (self.PieceAt(pos) == null) std.debug.panic("Ahhh, pos is {}\n", .{pos});
                try self.BufferedGenerateMovesFor(buffer, color, pos, piece);
            }
        }
    }

    pub fn GenerateAllColorMoves(self: *Self, buffer: *DoubleMoveBuffer, color: u1) !void {
        var singlemoves = SingleMoveBuffer{};
        try singlemoves.Init();
        defer singlemoves.DeInit();
        var secmoves = SingleMoveBuffer{};
        try secmoves.Init();
        defer secmoves.DeInit();
        try self.BufferedGenerateAllColorSingleMoves(&singlemoves, color);
        for (singlemoves.GetBuffer()) |_initmove| {
            var initmove = _initmove;
            const copy = self.*;
            defer self.* = copy;
            
            self.ApplyMove(&initmove);

            secmoves.Clear();
            try self.BufferedGenerateAllColorSingleMoves(&secmoves, color);
            for (secmoves.GetBuffer()) |secmove| {
                if (secmove.orig != initmove.dest) 
                    buffer.Append([2]Move{initmove, secmove});
            }
            buffer.Append([2]Move{initmove, ANULLMOVE});
        }
    }

    pub fn GenerateRandomMove(self: *Self, rand: *std.Random, color: u1) ![2]Move {
        var singlemoves = ArrayList(Move).init(gAllocator);
        try self.GenerateAllColorSingleMoves(&singlemoves, color);
        const firstidx = rand.uintLessThanBiased(u32, @intCast(singlemoves.items.len));
        const _initmove = singlemoves.items[firstidx];


        var secmoves = ArrayList(Move).init(gAllocator);
        var initmove = _initmove;

        const copy = self.*;
        defer self.* = copy;
        
        self.ApplyMove(&initmove);

        try self.GenerateAllColorSingleMoves(&secmoves, color);
        const secidx = rand.uintLessThanBiased(u32, @intCast(secmoves.items.len));
        const secmove = singlemoves.items[secidx];

        return [2]Move{_initmove, secmove};
    }

    pub fn IsTerminal(self: Self) bool {
        return @popCount(self.pieces[3]) == 0 or @popCount(self.pieces[7]) == 0;
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
    try AssertEql(LogHSB(BB_ONE << 17), 17);
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

fn Offset(pos: u7, dir: u2) u7 {
    return pos + switch (dir) {
        0 => SHR,
        1 => SHU,
        2 => SHL,
        3 => SHD,
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
    //Bot.Init();
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
    //var array = ArrayList([2]Move).init(gAllocator);
    var buffer = DoubleMoveBuffer{};
    buffer.Init() catch unreachable;
    defer buffer.DeInit();
    var timer = std.time.Timer.start() catch unreachable;
    for (0..1000) |_| {
        buffer.Clear();
        bptr.GenerateAllColorMoves(&buffer, @intCast(color)) catch unreachable;
    }
    const passed = timer.read();
    if (buffer.count != 3635) std.debug.panic("Array length was wrong, {} not 3635\n", .{buffer.count});
    //std.debug.print("Total double moves is: {}\n", .{array.items.len});
    std.debug.print("Time took was {d:.6}ms each\n", .{@as(f64, @floatFromInt(passed))/1_000_000_000});
    return @intFromPtr(buffer.buffer.ptr);
}

pub fn TimeBot(ptr: *Board) void {
    
    var timer = std.time.Timer.start() catch unreachable;
    const iters = 1;
    var value: isize = undefined;
    for (0..iters) |_| {
        value = Bot.RootNegaMax(ptr, 3, 0);
    }
    const passed = timer.read();
    std.debug.print("Recieved value was `{}`\n", .{value});
    std.debug.print("Timebot took was {d:.6}ms each\n", .{@as(f64, @floatFromInt(passed))/std.time.ns_per_ms/iters});
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

//pub export fn PyPlayOutBoard(ptr: PYPTR) i8 {
//    var timer = std.time.Timer.start() catch unreachable;
//    const ret = Bot.PlayOutGame(ImportPtr(ptr).*);
//    const passed = timer.read();
//    std.debug.print("Time took was {d:.3}ms\n", .{@as(f64, @floatFromInt(passed))/1_000_000});
//    return ret;
//}

//pub export fn PyCompMove(ptr: PYPTR) u64 {
//    std.debug.print("Thinking...\n", .{});
//    var timer = std.time.Timer.start() catch unreachable;
//    const ret = Bot.CompMove(ImportPtr(ptr).*);
//    const passed = timer.read();
//    std.debug.print("Time took to decide move was {d:.3}ms\n", .{@as(f64, @floatFromInt(passed))/1_000_000});
//    return @as(u64, @as(u32, @bitCast(ret[0]))) << 32 | @as(u64, @as(u32, @bitCast(ret[1])));
//}

///////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(@This());
}
