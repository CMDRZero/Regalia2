const std = @import("std");

///////////////////////////////////////////////////////////////////////////

const BitBoard = @import("engine.zig").BitBoard;

///////////////////////////////////////////////////////////////////////////

const ONE: BitBoard = 1;
const gBlockTarget = 3 + 9*3;
const gBlockMask: u64 = Convolve(ONE << gBlockTarget) & ~(ONE<<gBlockTarget);

const CANLEFTMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE << (9 * i));
    break :b mask;
};

const CANRIGHTMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE << (8 + 9 * i));
    //@compileLog(mask);
    break :b mask;
};

const CANUPMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE << (9 * 8 + i));
    break :b mask;
};

const CANDOWNMASK: BitBoard = b: {
    var mask = ~@as(BitBoard, 0);
    for (0..9) |i| mask = mask & ~(ONE << (i));
    break :b mask;
};

var gRawMoveMap: [81] BitBoard = undefined;
///Is a lookup map which turns a set into a colvolved move around blockers which can be shifted
var gBlockersMap: [16] BitBoard = undefined; 

///////////////////////////////////////////////////////////////////////////

pub fn Init() void {
    InitRawMoveMap();
    InitBlockersMap();
}

pub fn MoveMap(pos: u7, blockers: BitBoard, spd: u2) BitBoard {
    if (spd == 0) return 0;
    if (spd == 1) return gRawMoveMap[pos] & ~blockers;
    return Convolve(gRawMoveMap[pos] & ~blockers) & ~blockers;
}

pub inline fn CaptureConvolve(moveset: BitBoard, piece: u2) BitBoard {
    if (piece == 2) return BigConvolve(moveset); //If the piece is Artillary
    return Convolve(moveset);
}

///////////////////////////////////////////////////////////////////////////

fn InitRawMoveMap() void {
    for (0..81) |pos| {
        var dests: BitBoard = ONE << @intCast(pos);
        dests = Convolve(dests);
        gRawMoveMap[pos] = dests;
    }
}

fn InitBlockersMap() void {
    for (0..16) |bits| {
        const blocks = NativePdep(bits, gBlockMask);
        const front = (ONE << gBlockTarget | gBlockMask) & ~blocks;
        const nfront = Convolve(front) & ~blocks;
        gBlockersMap[bits] = nfront;
    }
    //std.debug.panic("Blockers is {b}\n", .{gBlockersMap[0b0010]});
}

pub inline fn ConvolveDir(front: BitBoard, comptime dir: u2) BitBoard {
    return switch (dir) {
        inline 0 => (front & CANRIGHTMASK) << 1,
        inline 1 => (front & CANUPMASK) << 9,
        inline 2 => (front & CANLEFTMASK) >> 1,
        inline 3 => (front & CANDOWNMASK) >> 9,
    };
}

///Plus Shaped convolution
fn Convolve(front: BitBoard) BitBoard {
    var res = front;
    res |= (front & CANRIGHTMASK) << 1;
    res |= (front & CANUPMASK) << 9;
    res |= (front & CANLEFTMASK) >> 1;
    res |= (front & CANDOWNMASK) >> 9;
    return res;
}

///Square shaped convolution
fn BigConvolve(front: BitBoard) BitBoard {
    var res = front;
    res |= (res & CANRIGHTMASK) << 1;
    res |= (res & CANUPMASK) << 9;
    res |= (res & CANLEFTMASK) >> 1;
    res |= (res & CANDOWNMASK) >> 9;
    return res;
}

///////////////////////////////////////////////////////////////////////////

//Thanks to: https://gist.github.com/Validark/a45d57c18f290031cd41126ef142fe3e
inline fn NativePext(src: anytype, mask: @TypeOf(src)) @TypeOf(src) {
    switch (@TypeOf(src)) {
        u32, u64 => {},
        else => @compileError(std.fmt.comptimePrint("pext called with a bad type: {}\n", .{@TypeOf(src)})),
    }

    return asm ("pext %[mask], %[src], %[ret]"
        : [ret] "=r" (-> @TypeOf(src)),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}

inline fn NativePdep(src: anytype, mask: @TypeOf(src)) @TypeOf(src) {
    switch (@TypeOf(src)) {
        u32, u64, usize => {},
        else => @compileError(std.fmt.comptimePrint("pdep called with a bad type: {}\n", .{@TypeOf(src)})),
    }

    return asm ("pdep %[mask], %[src], %[ret]"
        : [ret] "=r" (-> @TypeOf(src)),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}