import ctypes
from zigtypes import *

parent = '\\'.join(__file__.split('\\')[:-2])
_enginelib = ctypes.CDLL(f'{parent}\\engine.dll')

# _enginelib.Test.argtypes = (u32,)
# def ztest(x):
#     return int(_enginelib.Test(u32(x)))