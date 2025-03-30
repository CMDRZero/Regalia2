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

#_enginelib.PyGenMoves.argtypes = (PyPtr,)
#_enginelib.PyGenMoves.restype = void
@AutoAnnot
def ZigGenMoves(ptr: PyPtr) -> None:
    _enginelib.PyGenMoves(ptr)

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
        self.LocFromInitStr(ZigGenInitStr(self.handle))

    def LocFromInitStr(self, initstr: str):
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
                    pieces.append((color+kind, pos, cCell.regalia))
                    board[pos] = color+kind
                    coml = cCell.comLocks
                    for i, e in enumerate([1, 2]):
                        if e & coml:
                            off = [(1, 0), (0, 1), (-1, 0), (0, -1)][i]
                            cs = ['vl', 'hl'][i % 2]
                            deco.append((cs, (col + off[0]/2, row + off[1]/2)))
        return pieces, deco, board
