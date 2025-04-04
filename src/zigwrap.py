import ctypes
from zigtypes import *
import typing

def AutoAnnot(func):
    assert func.__name__.startswith('Zig')
    pyname = 'Py'+func.__name__[3:]
    annots = typing.get_type_hints(func)
    
    pyfunc = _enginelib.__getattr__(pyname)
    pyfunc.argtypes = ()
    for annot, val in annots.items():
        if annot == 'return':
            pyfunc.restype = val
        else:
            pyfunc.argtypes = pyfunc.argtypes + (val,)
    def inner(*args):
        return func(*args)
    return inner

PyPtr = u64

parent = '\\'.join(__file__.split('\\')[:-2])
_enginelib = ctypes.CDLL(f'{parent}\\engine.dll')

_enginelib.PyGenMoves.argtypes = (PyPtr, u8)
_enginelib.PyGenMoves.restype = POINTER(u32)
#@AutoAnnot
def ZigGenMoves(ptr: PyPtr, pos: u8) -> list[int]:
    retptr = _enginelib.PyGenMoves(ptr, pos)
    res = []
    for i in range(100):
        if (retptr[i] >> 0 % (1 << 3)) == 0:
            break
        res.append([DecodeMove(retptr[i]), retptr[i]])
    return res

_enginelib.PyNewBoardHandle.argtypes = ()
_enginelib.PyNewBoardHandle.restype = PyPtr
#@AutoAnnot
def ZigNewBoardHandle() -> PyPtr:
    return int(_enginelib.PyNewBoardHandle())

_enginelib.PyInitAlloc.argtypes = ()
_enginelib.PyInitAlloc.restype = void
#@AutoAnnot
def ZigInitAlloc() -> None:
    _enginelib.PyInitAlloc()

_enginelib.PyInitBoardFromStr.argtypes = (PyPtr, cStr)
_enginelib.PyInitBoardFromStr.restype = void
def ZigInitBoardFromStr(ptr: PyPtr, board: str) -> None:
    _enginelib.PyInitBoardFromStr(ptr, cStr(bytes(board)))

_enginelib.PyGenInitStr.argtypes = (PyPtr, PyPtr)
_enginelib.PyGenInitStr.restype = void
def ZigGenInitStr(ptr: PyPtr) -> str:
    buf = Pointer((u8 * 162)(0))
    _enginelib.PyGenInitStr(ptr, ctypes.addressof(buf.contents))
    return ''.join([chr(x) for x in buf.contents])


_enginelib.PyBoardApplyMove.argtypes = (PyPtr, u32)
_enginelib.PyBoardApplyMove.restype = void
#@AutoAnnot
def ZigBoardApplyMove(ptr, move) -> None:
    _enginelib.PyBoardApplyMove(ptr, move)

def DecodeMove(move: int) -> int:
    ret = {}
    args = {
        'kind': 3,
        'orig': 7,
        'dest': 7,
        'atkDir': 2,
        'doRet': 1,
        'capPiece': 2 ,
        'capReg': 1,
        'origLock': 4,
        'destLock': 4,}
    vs = list(args.values())
    vs = [(list(args.keys())[i], sum(vs[:i]), sum(vs[:1+i])) for i in range(len(vs))]

    for v, l, u in vs:
        ret[v] = (move>>l) % (1<<(u-l))

    # ret['orig'] = (move >> 1) % (1<<7)
    # ret['dest'] = (move >> 9) % (1<<7)
    # ret['doRet'] = (move >> 0) % (1<<1)
    # ret['doCap'] = (move >> 8) % (1<<1)
    # ret['doAtk'] = (move >> 16) % (1<<1)
    # if ret['doAtk'] or ret['doCap']:
    #     ret['atkDir'] = (move >> 17) % (1<<3)
    return ret


class Board:
    class Cell:
        NONE = -1
        INF = 0
        CAV = 1
        ART = 2
        KIN = 3
        WHITE = 0
        BlACK = 1
        def __init__(self):
            self.piece = self.NONE
            self.regalia = False
            self.comLocks = 0
            self.color = self.WHITE
    def __init__(self):
        self.body = [[self.Cell() for i in range(9)] for j in range(9)]
        self.handle = None
        
    def AddNewHandle(self):
        self.handle = ZigNewBoardHandle()
        pass


    def FromInitStr(self, initstr: str):
        self.LocFromInitStr(initstr)
        ZigInitBoardFromStr(self.handle, initstr.encode())
        
    def PullState(self):
        initstr = ZigGenInitStr(self.handle)
        print(initstr)
        self.LocFromInitStr(initstr)

    def ApplyMove(self, move):
        print(f'Apply move {move}')
        ZigBoardApplyMove(self.handle, move)
        #self.PullState() #Theoretically not needed

    def LocFromInitStr(self, initstr: str):
        self.body = [[self.Cell() for i in range(9)] for j in range(9)]
        for i, c in enumerate(initstr[:81]):
            if c == 'z': continue
            bv = ord(c) - ord('a')
            row, col = divmod(i, 9)
            cCell = self.body[row][col]
            cCell.piece = bv % 4
            cCell.color = bv & 4 != 0
            cCell.regalia = bv & 8 != 0
        for i, c in enumerate(initstr[81:]):
            if c == 'z': continue
            bv = ord(c) - ord('a')
            row, col = divmod(i, 9)
            cCell = self.body[row][col]
            cCell.comLocks = bv

    def RegenRender(self):
        pieces = []
        deco = []
        board = {}
        for col in range(9):
            for row in range(9):
                cCell = self.body[row][col]
                if cCell.piece != cCell.NONE:
                    color = 'wb'[cCell.color]
                    kind = 'icak'[cCell.piece]
                    pos = (col, row)
                    pieces.append([color+kind, pos, cCell.regalia])
                    board[pos] = color+kind
                    coml = cCell.comLocks
                    for i, e in enumerate([1, 2]):
                        if e & coml:
                            off = [(1, 0), (0, 1), (-1, 0), (0, -1)][i]
                            cs = ['vl', 'hl'][i % 2]
                            deco.append((cs, (col + off[0]/2, row + off[1]/2)))
        return pieces, deco, board
