const std = @import("std");
pub var gAllocator: std.mem.Allocator = undefined;
var gGpa: std.heap.DebugAllocator(.{}) = undefined;
const AssertEql = std.testing.expectEqual;

///////////////////////////////////////////////////////////////////////////

const DoValidation: bool = false;

///////////////////////////////////////////////////////////////////////////

const ARTILLARY_CAN_MOVE_DIAG: bool = false;

///////////////////////////////////////////////////////////////////////////

pub const BitBoard = u128;

///////////////////////////////////////////////////////////////////////////

const BB_ONE: BitBoard = 1;

//Origin is bottom left
const OH_RIGHT: u4 = 0b0001; //+x
const OH_UP: u4 = 0b0010; //+y
const OH_LEFT: u4 = 0b0100; //-x
const OH_DOWN: u4 = 0b1000; //-y

const PADDEDBOARDLEN = 11;

const SHR = 1;
const SHU = 11;
const SHL = -SHR;
const SHD = -SHU;

const WHITE = 0;
const BLACK = 1;

const REGBITPOS = 2;

pub const ATKPOW = [8] u8 { 2, 4, 7, 2, 3, 5, 8, 3 };
const MOVSPD = [4]comptime_int{ 1, 2, 0, 0 }; //Move speed minus the attack

const OH_DIRS = [4]u4{ OH_RIGHT, OH_UP, OH_LEFT, OH_DOWN };
const DIRS = [4] comptime_int {SHR, SHU, SHL, SHD};

const PLAYABLE = b: {
    var bb: BitBoard = 0;
    for (0..9) |x| for (0..9) |y| {
        bb |= 1 << (11 * y + x);
    };
    break :b bb;
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
    atkdir: u2 = undefined, //Undefined if kind does not attack
    doRet: bool,
};
const SingleMoveBuffer = std.BoundedArray(Move, 128);

pub const PackedMove = packed struct (u32) {
    kind: MoveKind,
    orig: u7,
    dest: u7,
    atkdir: u2,
    doRet: bool,
    _: u12 = undefined,
};

pub const FullMove = struct {
    moves: [2]Move,
};

test "Default board" {
    const truedefault = @as(Board, .{ .lockright = 0, .lockup = 0, .pieces = .{ 167804996, 82050, 40, 0, 0, 0, 0, 16, 21047401470969745725162782720, 40239095905872932080095068160, 12379400392853802748991242240, 0, 0, 0, 0, 4951760157141521099596496896 }, .toPlay = 0 });
    try AssertEql(truedefault, Board.default);
}

pub const Board = struct {
    const Self = @This();
    const cwhite = 0;
    const cblack = 1;

    lockright: BitBoard,
    lockup: BitBoard,
    pieces: [16]BitBoard, //{color}{regalia}{pieceID}2 //00 -> Inf, 01 -> Cav, 10 -> Art, 11 -> Kng //Color: 0 -> white, 1 -> black
    toPlay: u1,

    const default: Self = .{
        .lockright = 0,
        .lockup = 0,
        .pieces = b: {
            const white = [16]BitBoard{
                BitAt(2, 0) | BitAt(6, 0) | BitAt(4, 1) | BitAt(3, 2) | BitAt(5, 2), //Basic Inf
                BitAt(1, 0) | BitAt(7, 0) | BitAt(3, 1) | BitAt(5, 1), //Basic Calv
                BitAt(3, 0) | BitAt(5, 0), //Basic Art
                0,
                0,
                0,
                0,
                BitAt(4, 0), //King
                0, //Black starts here and we fill in them as a copy of white
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            };
            var board = white;
            @setEvalBranchQuota(2000);
            for (0..9) |x| for (0..9) |y| for (0..8) |piece| {
                board[8 + piece] |= BitAt(x, 8 - y) * ((board[piece] >> (x + 11 * y)) & 1);
            };
            break :b board;
        },
        .toPlay = 0,
    };

    const zoneMasks: [9]BitBoard = b: {
        const ll = 0b111 | 0b111 << 11 | 0b111 << 22;
        var masks: [9]BitBoard = undefined;
        for (0..3) |x| for (0..3) |y| {
            masks[3 * y + x] = ll << (3 * x + 33 * y);
        };
        break :b masks;
    };

    /////////////////////////////////////////////
    
    fn GenInitStr(self: Self, buf: *[162]u8) void {
        for (0..81) |idx_| {
            const x = idx_ % 9;
            const y = (idx_ / 9);
            const idx = 11 * y + x;
            for (0..16) |piece| {
                if (Has(self.pieces[piece], BB_ONE << @intCast(idx))) {
                    const hasReg: u8 = @intCast(piece>>2 & 1);
                    buf[idx_] = 'a' + @as(u8, @intCast(hasReg << 3 | (piece & 8)>>1 | (piece % 4)));
                    break;
                }
            } else buf[idx_] = 'z';
        }
        for (0..81) |idx_| {
            const x = idx_ % 9;
            const y = (idx_ / 9);
            const idx: u7 = @intCast(11 * y + x);
            const coml: u8 = @truncate(((self.lockright >> idx) & 1) + (((self.lockup >> idx) & 1) << 1) + (((self.lockright >> 1 >> idx) & 1) << 2));
            //std.debug.print("{}", .{coml});
            buf[idx_ + 81] = 'a' + coml;
        }
        std.debug.print("\n", .{});
    }

    /////////////////////////////////////////////

    inline fn GetBoard(self: Self, comptime piecename: []const u8, comptime hasRegalia: bool, comptime color: comptime_int) BitBoard {
        return self.pieces[comptime Board.GetBoardIdx(piecename, hasRegalia, color)];
    }

    fn GetBoardIdx(comptime piecename: anytype, comptime hasRegalia: bool, comptime color: comptime_int) u4 {
        if (!(color == 0 or color == 1)) @compileError("Bad color");
        const idx = b: {
            if (comptime std.mem.eql(u8, piecename, "inf")) {
                break :b 0;
            } else if (comptime std.mem.eql(u8, piecename, "infantry")) {
                break :b 0;
            } else if (comptime std.mem.eql(u8, piecename, "cav")) {
                break :b 1;
            } else if (comptime std.mem.eql(u8, piecename, "cavl")) {
                break :b 1;
            } else if (comptime std.mem.eql(u8, piecename, "cavalry")) {
                break :b 1;
            } else if (comptime std.mem.eql(u8, piecename, "art")) {
                break :b 2;
            } else if (comptime std.mem.eql(u8, piecename, "artillary")) {
                break :b 2;
            } else if (comptime std.mem.eql(u8, piecename, "kng")) {
                break :b 3;
            } else if (comptime std.mem.eql(u8, piecename, "king")) {
                break :b 3;
            } else {
                @compileError("Unknown piece abbr/name `" ++ piecename ++ "`.");
            }
            if (DoValidation) @panic("Shouldnt get here. GetBoardIdx");
            unreachable;
        };
        return idx + (if (hasRegalia) 4 else 0) + 8 * color;
    }

    test "GetBoard" {
        try AssertEql(4, GetBoardIdx("inf", true, cwhite));
        try AssertEql(8 + 0 + 1, GetBoardIdx("cavalry", false, cblack));
    }

    fn BitAt(x: comptime_int, y: comptime_int) BitBoard {
        return 1 << (x + PADDEDBOARDLEN * y);
    }
    /// Piece at a given position orelse null
    fn PieceAt(self: Self, pos: u7) ?u4 {
        for (0..16) |piece|
            if (Bit(self.pieces[piece], pos) != 0)
                return @intCast(piece);
        return null;
    }

    /// Slower, dont use
    fn SimdAssumedPieceAt(self: Self, pos: u7) u4 {
        var piecevec: @Vector(16, BitBoard) = self.pieces;
        piecevec >>= @splat(pos);
        piecevec &= @splat(1);
        piecevec *= @TypeOf(piecevec) {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
        return @intCast(@reduce(.Or, piecevec));
    }

    /// Maybe faster than `PieceAt(...).?`
    fn AssumedPieceAt(self: Self, pos: u7) u4 {
        for (0..16) |piece|
            if (Bit(self.pieces[piece], pos) != 0)
                return @intCast(piece);
        if (DoValidation) std.debug.panic("Pos `{}` has no piece", .{pos});
        unreachable;
    }

    /// Get the power of the piece at position. Assumes there is a piece there.
    fn PowerAt(self: Self, pos: u7) u8 {
        if (DoValidation and self.PieceAt(pos) == null) std.debug.panic("Self ({}) is null, cannot get power\n", .{pos});

        const piece = self.AssumedPieceAt(pos);
        return ATKPOW[piece % 8];
    }

    /// Sum of strength of combat lockers
    fn AttackersOn(self: Self, pos: u7) u8 {
        var sum: u8 = 0;
        //std.debug.print("pos: {} vs SHU: {}\n", .{pos, SHU});
        const right = Bit(self.lockright, pos);
        const up = Bit(self.lockup, pos);
        const left = Bit(self.lockright, pos -% SHR);
        const down = Bit(self.lockup, pos -% SHU);
        sum += if (right != 0) self.PowerAt(pos + SHR) else 0;
        sum += if (up != 0) self.PowerAt(pos + SHU) else 0;
        sum += if (left != 0) self.PowerAt(pos - SHR) else 0;
        sum += if (down != 0) self.PowerAt(pos - SHU) else 0;
        return sum;
    }

    /// Check validity of board
    /// TODO
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
            else => if (DoValidation) @panic("Shouldnt Get Here _ValidateMove") else unreachable,
        }
    }

    fn ApplyMove(self: *Self, move: Move) void {
        ValidateMove(self.*, move);

        const moveKind: MoveKind = move.kind;
        if (moveKind == .null) return;

        var ownPiece = self.PieceAt(move.orig).?; //Checked by validate

        if (move.doRet) {
            self._RemoveRegalia(move.orig, ownPiece);
            self._RemoveLocksAt(move.orig);
            ownPiece = ownPiece & @as(u4, @truncate(INV_REGBUT));
        }

        const destPiece = self.PieceAt(move.dest); //May be null, but if so is never used.
        switch (moveKind) {
            .capture => {
                self._RemovePiece(move.dest, destPiece.?); //Checked by validate
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddRegalia(move.dest, ownPiece);
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
                self._AddRegalia(move.orig, ownPiece);
            },
            .swap => {
                self._SwapPieces(move.orig, move.dest, ownPiece, destPiece.?); //Checked by validate
            },
            .kingweaken => {
                self._MovePiece(move.orig, move.dest, ownPiece);
                self._AddLockInDir(move.dest, move.atkdir);
                self._RemoveRegalia(Offset(move.dest, move.atkdir), ownPiece);
            },
            .sacrifice => {
                self._RemovePiece(move.dest, destPiece.?);
                self._RemoveLocksAt(move.orig);
            },
            else => if (DoValidation) @panic("Shouldnt get Here ApplyMove") else unreachable,
        }
        self.Validate();
    }

    pub fn ApplyFullMove(self: *Self, move: FullMove) void {
        self.ApplyMove(move.moves[0]);
        self.ApplyMove(move.moves[1]);
        self.toPlay = ~self.toPlay;
    }

    fn _RemoveLocksAt(self: *Self, pos: u7) void {
        self.lockright &= ~std.math.shl(BitBoard, 1 << 1 | 1, pos - 1);
        self.lockup &= ~std.math.shl(BitBoard, 1 << 11 | 1, pos - 11);
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

    const OH_REGBIT = 1 << REGBITPOS;
    const INV_REGBUT = ~@as(usize, OH_REGBIT);

    fn _AddRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece & INV_REGBUT] &= ~(BB_ONE << pos); //Toggle off origin
        self.pieces[piece | OH_REGBIT] |= (BB_ONE << pos); //Toggle on
    }

    fn _RemoveRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece | OH_REGBIT] &= ~(BB_ONE << pos); //Toggle off
        self.pieces[piece & INV_REGBUT] |= (BB_ONE << pos); //Toggle on
    }

    fn _ToggleRegalia(self: *Self, pos: u7, piece: u4) void {
        self.pieces[piece] ^= (BB_ONE << pos); //Toggle off origin
        self.pieces[(1 << 4) ^ piece] ^= (BB_ONE << pos); //Toggle on
    }

    fn _AddLockInDir(self: *Self, pos: u7, dir: u2) void {
        switch (dir) {
            0 => self.lockright |= BB_ONE << (pos),
            1 => self.lockup |= BB_ONE << (pos),
            2 => self.lockright |= BB_ONE << (pos - SHR),
            3 => self.lockup |= BB_ONE << (pos - SHU),
        }
    }

    fn GenerateLockerMask(self: Self, bit: BitBoard) BitBoard {
        return (self.lockright & bit) << SHR
            | (self.lockright & (bit >> SHR))
            | (self.lockup & bit) << SHU
            | (self.lockup & (bit >> SHU));
    }

    ///////////////////////////////////////////////////////////////////////

    fn StreamAllSingleMoves(self: Self, comptime color: comptime_int, context: anytype, comptime Handle: fn (@TypeOf(context), Move) void) !void {
        const precalc = b: {
            var _precalc: Moves.PreCalc = undefined;
            _precalc.allies = BlockersForColor(self, color);
            _precalc.enemies = BlockersForColor(self, 1-color);
            _precalc.blockers = _precalc.allies | _precalc.enemies | ~PLAYABLE;

            _precalc.zoneExc = 0;
            inline for (0..9) |i| {
                if ((_precalc.allies & zoneMasks[i]) != 0) _precalc.zoneExc ^= zoneMasks[i];
                if ((_precalc.enemies & zoneMasks[i]) != 0) _precalc.zoneExc ^= zoneMasks[i];
            }
            
            break :b _precalc;
        };

        try Moves.Artillary(self, precalc, context, Handle, self.GetBoard("artillary", true, color), 1, false);
        try Moves.Artillary(self, precalc, context, Handle, self.GetBoard("artillary", false, color), 0, false);

        try Moves.Cavalry(self, precalc, context, Handle, self.GetBoard("cavalry", true, color), 1, false);
        try Moves.Cavalry(self, precalc, context, Handle, self.GetBoard("cavalry", false, color), 0, false);

        try Moves.Infantry(self, precalc, context, Handle, self.GetBoard("infantry", true, color) & precalc.zoneExc, 1, false, true);
        try Moves.Infantry(self, precalc, context, Handle, self.GetBoard("infantry", false, color) & precalc.zoneExc, 0, false, true);
        try Moves.Infantry(self, precalc, context, Handle, self.GetBoard("infantry", true, color) & ~precalc.zoneExc, 1, false, false);
        try Moves.Infantry(self, precalc, context, Handle, self.GetBoard("infantry", false, color) & ~precalc.zoneExc, 0, false, false);

        try Moves.King(self, precalc, context, Handle, self.GetBoard("king", true, color), 1, false);
        try Moves.King(self, precalc, context, Handle, self.GetBoard("king", false, color), 0, false);
    }

    fn StreamAllFullMoves(self: Self, comptime color: comptime_int, context: anytype, comptime Handle: fn (@TypeOf(context), FullMove) void) !void {
        var buffer = SingleMoveBuffer.init(0) catch unreachable;
        const Locals = struct {
            buffptr: *SingleMoveBuffer,

            fn BufferAppend(locals: @This(), item: Move) void {
                locals.buffptr.appendAssumeCapacity(item);
            }
        };

        try self.StreamAllSingleMoves(color, Locals {.buffptr = &buffer}, Locals.BufferAppend);

        const WrapContext = struct {
            handleContext: @TypeOf(context),
            firstmove: Move,

            fn PreHandle(outercontext: @This(), secondmove: Move) void {
                if (secondmove.orig == outercontext.firstmove.dest) return;
                const fullmove = FullMove {.moves = [2] Move {outercontext.firstmove, secondmove}};
                Handle(outercontext.handleContext, fullmove);
            }
        };

        for (buffer.slice()) |firstmove| {
            var newstate = self;
            newstate.ApplyMove(firstmove);
            try newstate.StreamAllSingleMoves(color, WrapContext{.handleContext = context, .firstmove = firstmove}, WrapContext.PreHandle);
        }
    }

    const Moves = struct {
        const PreCalc = struct {
            allies: BitBoard,
            enemies: BitBoard,
            blockers: BitBoard,
            zoneExc: BitBoard,
        };

        fn Cavalry (
                board: Board, 
                precalc: PreCalc, 
                context: anytype, 
                comptime Handle: fn (@TypeOf(context), Move) void, 
                pieces: BitBoard, 
                comptime regalia: 
                comptime_int, 
                comptime didRet: bool
        ) !void {
            var instakillable: BitBoard = 0; //defined as having netHP less than 0. Means can kill even if in lock. Subset of killable
            var killable: BitBoard = 0; //defined as having netHP less than to the atk power of attack. Means can kill if new attacker

            const atkPow: u8 = ATKPOW[Board.GetBoardIdx("cavalry", regalia != 0, 0) % 8];

            var enemies = precalc.enemies;
            while (enemies != 0) {
                const hsb = LogHSB(enemies);
                const bit = BB_ONE << hsb;
                enemies ^= bit;

                const sumAtk = board.AttackersOn(hsb);
                const hp = board.PowerAt(hsb);
                instakillable ^= if (hp < sumAtk) bit else 0; //(hp - sumAtk < 0)  -->  (hp <= sumatk)
                killable ^= if (hp < sumAtk + atkPow) bit else 0; //(hp - sumAtk < atkPow)  -->  (hp <= sumatk + atkPow)
            }

            var sacMask: BitBoard = 0;

            var bitset = pieces;
            while (bitset != 0) {
                const hsb = LogHSB(bitset);
                const bit = BB_ONE << hsb;
                bitset ^= bit;

                const locker = board.GenerateLockerMask(bit);
                const lockbit = if (!didRet and locker != 0) bit else 0;
                sacMask |= lockbit;
                const capturable = (killable & ~locker) | instakillable; //You can capture any target thats either killable or instakillable if its locking you
                //std.debug.print("lockers: {x}\nkillable: {x}\ninsta: {x}\ncapable: {x}\n", .{locker, killable, instakillable, capturable});

                var dests_ = bit;
                if (lockbit == 0) dests_ = MoveConvolve(dests_) & ~precalc.blockers;
                if (lockbit == 0) dests_ = MoveConvolve(dests_) & ~precalc.blockers | bit;
                const move3 = MoveConvolve(dests_);

                const movedests = move3 & ~precalc.blockers;
                const captars = move3 & capturable;

                
                //Do captures
                var tarset: BitBoard = if (locker != 0) captars & locker else captars;
                while (tarset != 0) {
                    const thsb = LogHSB(tarset);
                    const tarbit = BB_ONE << thsb;
                    tarset ^= tarbit;

                    Handle(context, Move{
                        .kind = .capture,
                        .orig = hsb,
                        .dest = thsb,
                        .doRet = didRet,
                    });
                }

                if (lockbit == 0) {
                    //Do attacks
                    inline for (DIRS, 0..) |diroffset, diridx| {
                        tarset = dests_ & std.math.shl(BitBoard, (precalc.enemies ^ capturable) , -diroffset); 
                        while (tarset != 0) {
                            const thsb = LogHSB(tarset);
                            const tarbit = BB_ONE << thsb;
                            tarset ^= tarbit;

                            Handle(context, Move{
                                .kind = .attack,
                                .orig = hsb,
                                .dest = thsb,
                                .doRet = didRet,
                                .atkdir = diridx,
                            });
                        }
                    }

                    //Do moves
                    tarset = movedests;
                    while (tarset != 0) {
                        const thsb = LogHSB(tarset);
                        const tarbit = BB_ONE << thsb;
                        tarset ^= tarbit;

                        Handle(context, Move{
                            .kind = .move,
                            .orig = hsb,
                            .dest = thsb,
                            .doRet = didRet,
                        });
                    }
                } else if (regalia == 0) {
                    //Otherwise allow sacrifice
                    Handle(context, Move{
                        .kind = .sacrifice,
                        .orig = hsb,
                        .dest = hsb,
                        .doRet = didRet,
                    });
                }
            }

            if (regalia != 0) {
                // std.debug.print("Do sac check.\n", .{});
                //try Moves.Cavalry(board, precalc, context, Handle, sacMask, 1-regalia, true);
            }
        }
        
        fn Infantry (
                board: Board, 
                precalc: PreCalc, 
                context: anytype, 
                comptime Handle: fn (@TypeOf(context), Move) void, 
                pieces: BitBoard, 
                comptime regalia: 
                comptime_int, 
                comptime didRet: bool,
                comptime zoneExc: bool,
        ) !void {
            var instakillable: BitBoard = 0; //defined as having netHP less than 0. Means can kill even if in lock. Subset of killable
            var killable: BitBoard = 0; //defined as having netHP less than to the atk power of attack. Means can kill if new attacker

            const atkPow: u8 = ATKPOW[Board.GetBoardIdx("inf", regalia != 0, 0) % 8];

            var enemies = precalc.enemies;
            while (enemies != 0) {
                const hsb = LogHSB(enemies);
                const bit = BB_ONE << hsb;
                enemies ^= bit;

                const sumAtk = board.AttackersOn(hsb);
                const hp = board.PowerAt(hsb);
                instakillable ^= if (hp < sumAtk) bit else 0; //(hp - sumAtk < 0)  -->  (hp <= sumatk)
                killable ^= if (hp < sumAtk + atkPow) bit else 0; //(hp - sumAtk < atkPow)  -->  (hp <= sumatk + atkPow)
            }

            var sacMask: BitBoard = 0;

            var bitset = pieces;
            while (bitset != 0) {
                const hsb = LogHSB(bitset);
                const bit = BB_ONE << hsb;
                bitset ^= bit;

                const locker = board.GenerateLockerMask(bit);
                const lockbit = if (!didRet and locker != 0) bit else 0;
                sacMask |= lockbit;
                const capturable = (killable & ~locker) | instakillable; //You can capture any target thats either killable or instakillable if its locking you
                //std.debug.print("lockers: {x}\nkillable: {x}\ninsta: {x}\ncapable: {x}\n", .{locker, killable, instakillable, capturable});

                var dests_ = bit;
                if (lockbit == 0) dests_ = MoveConvolve(dests_) & ~precalc.blockers | bit;
                if (zoneExc and lockbit == 0) dests_ = MoveConvolve(dests_) & ~precalc.blockers | bit;
                const move3 = MoveConvolve(dests_);

                const movedests = move3 & ~precalc.blockers;
                const captars = move3 & capturable;

                
                //Do captures
                var tarset: BitBoard = if (locker != 0) captars & locker else captars;
                while (tarset != 0) {
                    const thsb = LogHSB(tarset);
                    const tarbit = BB_ONE << thsb;
                    tarset ^= tarbit;

                    Handle(context, Move{
                        .kind = .capture,
                        .orig = hsb,
                        .dest = thsb,
                        .doRet = didRet,
                    });
                }

                if (regalia != 0) {
                    inline for (DIRS) |dir| {
                        const dest = if (dir > 0) hsb +% dir else hsb -% -dir;
                        if (Bit(precalc.allies, dest) != 0) {
                            Handle(context, Move {
                                .kind = .swap,
                                .orig = hsb,
                                .dest = dest,
                                .doRet = didRet,
                            });
                        }
                    }
                }

                if (lockbit == 0) {
                    //Do attacks
                    inline for (DIRS, 0..) |diroffset, diridx| {
                        tarset = dests_ & std.math.shl(BitBoard, (precalc.enemies ^ capturable) , -diroffset); 
                        while (tarset != 0) {
                            const thsb = LogHSB(tarset);
                            const tarbit = BB_ONE << thsb;
                            tarset ^= tarbit;

                            Handle(context, Move{
                                .kind = .attack,
                                .orig = hsb,
                                .dest = thsb,
                                .doRet = didRet,
                                .atkdir = diridx,
                            });
                        }
                    }

                    //Do moves
                    tarset = movedests;
                    while (tarset != 0) {
                        const thsb = LogHSB(tarset);
                        const tarbit = BB_ONE << thsb;
                        tarset ^= tarbit;

                        Handle(context, Move{
                            .kind = .move,
                            .orig = hsb,
                            .dest = thsb,
                            .doRet = didRet,
                        });
                    }
                } else if (regalia == 0) {
                    //Otherwise allow sacrifice
                    Handle(context, Move{
                        .kind = .sacrifice,
                        .orig = hsb,
                        .dest = hsb,
                        .doRet = didRet,
                    });
                }
            }

            if (regalia != 0) {
                // std.debug.print("Do sac check.\n", .{});
                // try Moves.Cavalry(board, precalc, context, Handle, sacMask, 1-regalia, true);
            }
        }

        fn Artillary (
                board: Board, 
                precalc: PreCalc, 
                context: anytype, 
                comptime Handle: fn (@TypeOf(context), Move) void, 
                pieces: BitBoard, 
                comptime regalia: 
                comptime_int, 
                comptime didRet: bool
        ) !void {
            var instakillable: BitBoard = 0; //defined as having netHP less than 0. Means can kill even if in lock. Subset of killable
            var killable: BitBoard = 0; //defined as having netHP less than to the atk power of attack. Means can kill if new attacker

            const atkPow: u8 = ATKPOW[Board.GetBoardIdx("art", regalia != 0, 0) % 8];

            var enemies = precalc.enemies;
            while (enemies != 0) {
                const hsb = LogHSB(enemies);
                const bit = BB_ONE << hsb;
                enemies ^= bit;

                const sumAtk = board.AttackersOn(hsb);
                const hp = board.PowerAt(hsb);
                instakillable ^= if (hp < sumAtk) bit else 0; //(hp - sumAtk < 0)  -->  (hp <= sumatk)
                killable ^= if (hp < sumAtk + atkPow) bit else 0; //(hp - sumAtk < atkPow)  -->  (hp <= sumatk + atkPow)
            }

            var sacMask: BitBoard = 0;

            var bitset = pieces;
            while (bitset != 0) {
                const hsb = LogHSB(bitset);
                const bit = BB_ONE << hsb;
                bitset ^= bit;

                const locker = board.GenerateLockerMask(bit);
                const lockbit = if (!didRet and locker != 0) bit else 0;
                sacMask |= lockbit;
                const capturable = (killable & ~locker) | instakillable; //You can capture any target thats either killable or instakillable if its locking you
                //std.debug.print("lockers: {x}\nkillable: {x}\ninsta: {x}\ncapable: {x}\n", .{locker, killable, instakillable, capturable});

                const dests_ = bit;
                const move3 = MoveConvolve(dests_);

                const movedests = move3 & ~precalc.blockers;
                const captars = MoveWideConvolve(dests_) & capturable;

                
                //Do captures
                var tarset: BitBoard = if (locker != 0) captars & locker else captars;
                while (tarset != 0) {
                    const thsb = LogHSB(tarset);
                    const tarbit = BB_ONE << thsb;
                    tarset ^= tarbit;

                    Handle(context, Move{
                        .kind = .capture,
                        .orig = hsb,
                        .dest = thsb,
                        .doRet = didRet,
                    });
                }

                if (lockbit == 0) {
                    //Do attacks
                    inline for (DIRS, 0..) |diroffset, diridx| {
                        tarset = dests_ & std.math.shl(BitBoard, (precalc.enemies ^ capturable) , -diroffset); 
                        while (tarset != 0) {
                            const thsb = LogHSB(tarset);
                            const tarbit = BB_ONE << thsb;
                            tarset ^= tarbit;

                            Handle(context, Move{
                                .kind = .attack,
                                .orig = hsb,
                                .dest = thsb,
                                .doRet = didRet,
                                .atkdir = diridx,
                            });
                        }
                    }

                    //Do moves
                    tarset = movedests;
                    while (tarset != 0) {
                        const thsb = LogHSB(tarset);
                        const tarbit = BB_ONE << thsb;
                        tarset ^= tarbit;

                        Handle(context, Move{
                            .kind = .move,
                            .orig = hsb,
                            .dest = thsb,
                            .doRet = didRet,
                        });
                    }
                } else if (regalia == 0) {
                    //Otherwise allow sacrifice
                    Handle(context, Move{
                        .kind = .sacrifice,
                        .orig = hsb,
                        .dest = hsb,
                        .doRet = didRet,
                    });
                }
            }

            if (regalia != 0) {
                // std.debug.print("Do sac check.\n", .{});
                // try Moves.Cavalry(board, precalc, context, Handle, sacMask, 1-regalia, true);
            }
        }

        fn King (
                board: Board, 
                precalc: PreCalc, 
                context: anytype, 
                comptime Handle: fn (@TypeOf(context), Move) void, 
                pieces: BitBoard, 
                comptime regalia: 
                comptime_int, 
                comptime didRet: bool
        ) !void {
            var instakillable: BitBoard = 0; //defined as having netHP less than 0. Means can kill even if in lock. Subset of killable
            var killable: BitBoard = 0; //defined as having netHP less than to the atk power of attack. Means can kill if new attacker

            const atkPow: u8 = ATKPOW[Board.GetBoardIdx("kng", regalia != 0, 0) % 8];

            var enemies = precalc.enemies;
            while (enemies != 0) {
                const hsb = LogHSB(enemies);
                const bit = BB_ONE << hsb;
                enemies ^= bit;

                const sumAtk = board.AttackersOn(hsb);
                const hp = board.PowerAt(hsb);
                instakillable ^= if (hp < sumAtk) bit else 0; //(hp - sumAtk < 0)  -->  (hp <= sumatk)
                killable ^= if (hp < sumAtk + atkPow) bit else 0; //(hp - sumAtk < atkPow)  -->  (hp <= sumatk + atkPow)
            }

            var sacMask: BitBoard = 0;

            var bitset = pieces;
            while (bitset != 0) {
                const hsb = LogHSB(bitset);
                const bit = BB_ONE << hsb;
                bitset ^= bit;

                const locker = board.GenerateLockerMask(bit);
                const lockbit = if (!didRet and locker != 0) bit else 0;
                sacMask |= lockbit;
                const capturable = (killable & ~locker) | instakillable; //You can capture any target thats either killable or instakillable if its locking you
                //std.debug.print("lockers: {x}\nkillable: {x}\ninsta: {x}\ncapable: {x}\n", .{locker, killable, instakillable, capturable});

                const dests_ = bit;
                const move3 = MoveConvolve(dests_);

                const movedests = move3 & ~precalc.blockers;
                const captars = move3 & capturable;

                
                //Do captures
                var tarset: BitBoard = if (locker != 0) captars & locker else captars;
                while (tarset != 0) {
                    const thsb = LogHSB(tarset);
                    const tarbit = BB_ONE << thsb;
                    tarset ^= tarbit;

                    Handle(context, Move{
                        .kind = .capture,
                        .orig = hsb,
                        .dest = thsb,
                        .doRet = didRet,
                    });
                }

                if (lockbit == 0) {
                    //Do attacks
                    inline for (DIRS, 0..) |diroffset, diridx| {
                        tarset = dests_ & std.math.shl(BitBoard, (precalc.enemies ^ capturable) , -diroffset); 
                        while (tarset != 0) {
                            const thsb = LogHSB(tarset);
                            const tarbit = BB_ONE << thsb;
                            tarset ^= tarbit;

                            Handle(context, Move{
                                .kind = .attack,
                                .orig = hsb,
                                .dest = thsb,
                                .doRet = didRet,
                                .atkdir = diridx,
                            });
                        }
                    }

                    //Do moves
                    tarset = movedests;
                    while (tarset != 0) {
                        const thsb = LogHSB(tarset);
                        const tarbit = BB_ONE << thsb;
                        tarset ^= tarbit;

                        Handle(context, Move{
                            .kind = .move,
                            .orig = hsb,
                            .dest = thsb,
                            .doRet = didRet,
                        });
                    }
                } else if (regalia == 0) {
                    //Otherwise allow sacrifice
                    Handle(context, Move{
                        .kind = .sacrifice,
                        .orig = hsb,
                        .dest = hsb,
                        .doRet = didRet,
                    });
                }
            }

            if (regalia != 0) {
                // std.debug.print("Do sac check.\n", .{});
                // try Moves.Cavalry(board, precalc, context, Handle, sacMask, 1-regalia, true);
            }
        }
    };
};

///////////////////////////////////////////////////////////////////////////

inline fn MoveConvolve(x: BitBoard) BitBoard {
    return x | x << SHR | x << SHU | x >> SHR | x >> SHU;
}

inline fn MoveWideConvolve(x: BitBoard) BitBoard {
    var ret = x | x << SHR | x >> SHR;
    ret = ret | ret << SHU | ret >> SHU;
    return ret;
}

fn BlockersForColor(self: Board, comptime color: comptime_int) BitBoard {
    var sum: BitBoard = 0;
    inline for (0..8) |i| {
        sum |= self.pieces[8 * color + i];
    }
    return sum;
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
        1 => pos + 11,
        2 => pos - 1,
        3 => pos - 11,
        4 => pos + 1 + 11,
        5 => pos + 11 - 1,
        6 => pos - 1 - 11,
        7 => pos - 11 + 1,
    };
}

///Assume connections must not wrap around board
///Assume dir is one hot encoded
fn NewPos(pos: u7, dir: u4) u7 {
    return switch (dir) {
        1 => pos + 1,
        2 => pos + 11,
        4 => pos - 1,
        8 => pos - 11,
        else => if (DoValidation) std.debug.panic("Tried to use dir: {}\n", .{dir}) else unreachable,
    };
}

fn Offset(pos: u7, dir: u2) u7 {
    return @intCast(@as(i8, pos) + @as(i8, switch (dir) {
        0 => SHR,
        1 => SHU,
        2 => SHL,
        3 => SHD,
    }));
}

test "Offset" {
    try AssertEql(12, Offset(11, 0));
    try AssertEql(22, Offset(11, 1));
    try AssertEql(10, Offset(11, 2));
    try AssertEql(0, Offset(11, 3));
}

///////////////////////////////////////////////////////////////////////////

fn Implies(x: u1, y: u1) u1 {
    return ~x | y;
}

fn Has(x: anytype, y: anytype) bool {
    return x & y != 0;
}

fn Bit(x: BitBoard, y: anytype) u1 {
    if (DoValidation) if (y > 121) return 0;
    return @intCast((x >> y) & 1);
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
    //Bot.Init();
}

pub export fn PyNewBoardHandle() PYPTR {
    const handle = _NewBoardHandle() catch if (DoValidation) @panic("New Board Handle failed.\n") else unreachable;
    //std.debug.print("Exporting {*} as {x}\n", .{handle, ExportPtr(handle)});
    return ExportPtr(handle);
}
fn _NewBoardHandle() !*Board {
    const boardPtr = try gAllocator.create(Board);
    return boardPtr;
}

 pub export fn PyInitBoardFromStr(ptr: PYPTR, str: [*c]u8) void {
    _ = str;
    const iptr = ImportPtr(ptr);
    iptr.* = Board.default;
 }

pub export fn PyGenMoves(ptr: PYPTR, pos: u8) PYPTR {
    std.debug.print("Called.\n", .{});
    const bptr: *Board = ImportPtr(ptr);
    var buffer = std.BoundedArray(PackedMove, 128).init(0) catch if (DoValidation) @panic("Buffer Init failed.\n") else unreachable;

    const Locals = struct {
        const Self = @This();
        buffptr: *std.BoundedArray(PackedMove, 128),
        pos: u7,

        fn BufferAppend(locals: Self, item: Move) void {
            // std.debug.print("Found move: {}\n", .{item});
            const pi = PackedMove {
                .orig = item.orig,
                .atkdir = item.atkdir,
                .dest = item.dest,
                .doRet = item.doRet,
                .kind = item.kind,
            };
            if (item.orig == locals.pos)
                locals.buffptr.appendAssumeCapacity(pi);
        }
    };

    const locals = Locals {
        .buffptr = &buffer,
        .pos = @intCast(pos),
    };

    const piece = bptr.AssumedPieceAt(@intCast(pos));
    switch (piece >> 3) {
        inline 0, 1  => |color| bptr.StreamAllSingleMoves(color, locals, Locals.BufferAppend) catch |err| if (DoValidation) std.debug.panic("Stream Single Moves threw `{}`.\n", .{err}) else unreachable,
        else => unreachable,
    }

    
    return @intFromPtr(buffer.slice().ptr);
}

pub export fn PyGenAllMoves(ptr: PYPTR, color: u8) void {
    const bptr: *Board = ImportPtr(ptr);
    var timer = std.time.Timer.start() catch unreachable;

    const Locals = struct {
        count: usize = 0,
        fn Count(locals: *@This(), item: FullMove) void {
            locals.count += 1;
            _ = item;
        }
    };


    var context = Locals{};
    switch (color) {
        inline 0, 1 => |compColor| for (0..1000) |_| {
            context.count = 0;
            try bptr.StreamAllFullMoves(compColor, &context, Locals.Count);
        },
        else => unreachable,
    }
    

    const passed_ns = timer.read();
    //if (buffer.count != 3635) std.debug.panic("Array length was wrong, {} not 3635\n", .{buffer.count});
    std.debug.print("Total double moves is: {}\n", .{context.count});
    std.debug.print("Time took was {d:.6}ms each\n", .{@as(f64, @floatFromInt(passed_ns))/1000/std.time.ns_per_ms});
    return;
}

//pub export fn PyGenInitStr(ptr: PYPTR, buf: PYPTR) void {
//    const bptr: *Board = ImportPtr(ptr);
//    const sbuf: *[162]u8 = @ptrFromInt(buf);
//    bptr.GenInitStr(sbuf);
//}

pub export fn PyBoardApplyMove(ptr: PYPTR, mov: u32) void {
    const imove: PackedMove = @bitCast(mov);
    const move = Move {
        .orig = imove.orig,
        .atkdir = imove.atkdir,
        .dest = imove.dest,
        .doRet = imove.doRet,
        .kind = imove.kind,
    };
    ImportPtr(ptr).ApplyMove(move);
}

test "Test all" {
    std.testing.refAllDeclsRecursive(@This());
}

////////////////////////////////////////////////////////////////////////

pub export fn PyGenInitStr(ptr: PYPTR, buf: PYPTR) void {
    const bptr: *Board = ImportPtr(ptr);
    const sbuf: *[162]u8 = @ptrFromInt(buf);
    bptr.GenInitStr(sbuf);
}