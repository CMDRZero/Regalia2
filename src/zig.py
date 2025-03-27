import ctypes
from zigtypes import *
import os

parent = '\\'.join(__file__.split('\\')[:-2])

_ctestlib = ctypes.CDLL(f'{parent}\\src\\test.so')
_ctestlib.Test.argtypes = (u32,)
def ctest(x):
    return int(_ctestlib.Test(u32(x)))


_ztestlib = ctypes.CDLL(f'{parent}\\test.dll')
_ztestlib.Test.argtypes = (u32,)
def ztest(x):
    return int(_ztestlib.Test(u32(x)))

print(ctest(8))
print(ztest(8))