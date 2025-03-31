import pygame
from math import sqrt, cos, pi
from zigwrap import *

type Num = int | float

gInitTicksPerAnimMove = 60

gTicksPerAnimMove = None #Set

gAnimVars = {}
gAnimQueue = []

def DrawPiece(piece, x, y):
    screen.blit(piece, (latoff + 80*x, veroff + 80*y))

def Smooth(x: float):
    if x > .5: return 1-Smooth(1-x)
    return 2*x*x

def Pointed(x: float):
    if x > .5: return Pointed(1-x)
    return 4*x*x

def SmoothInto(x: float):
    return 1-(1-x)*(1-x)

# Return the moves nesisary to get to the target. If the target is an edge, it moves to the free cell and makes `atk` the occupied cell
# Turns multiple moves in the same direction into one
def CalcAnimMove(origPos, movTar):
    if type(movTar[0]) == float:
        movTars = [(int(movTar[0]-.5), movTar[1]), (int(movTar[0]+.5), movTar[1])]
    elif type(movTar[1]) == float:
        movTars = [(movTar[0], int(movTar[1]-.5)), (movTar[0], int(movTar[1]+.5))]
    else:
        movTars = [movTar]

    #print(movTars)

    front = [(origPos, -1, ((origPos, -1),))]
    while front != []:
        nmov = front[0]
        del front[0]
        ndirs = [0, 1, 2, 3]
        
        if nmov[1] in ndirs:
            ndirs.remove(nmov[1])
            dir = nmov[1]
            dx, dy = [(1, 0), (0, 1), (-1, 0), (0, -1)][dir]
            npos = (nmov[0][0]+dx, nmov[0][1]+dy)
            if npos not in board or npos in movTars:
                nnmov = (npos, dir, nmov[2]+((npos, dir),))
                if npos in movTars: break
                front.append(nnmov)


        for dir in ndirs:
            dx, dy = [(1, 0), (0, 1), (-1, 0), (0, -1)][dir]
            npos = (nmov[0][0]+dx, nmov[0][1]+dy)
            if npos not in board or npos in movTars:
                nnmov = (npos, dir, nmov[2]+((npos, dir),))
                if npos in movTars: break
                front.append(nnmov)
        else: continue
        break
    else: assert False
    movs = []
    dir = None
    atk = [x for x in movTars if x != nnmov[0]]
    for (ndest, ndir) in nnmov[2]:
        #if ndest in board and ndest in movTars: break
        if dir == ndir:
            del movs[-1]
        movs.append(ndest)
        dir = ndir
    return movs, atk
    #print(movs, atk)

def SetupAnimMove(decrown: bool, origPos: tuple[Num, Num], movTar: tuple[Num, Num]):
    global gTicksPerAnimMove, gAnimCounter
    gIsAnimating = True

    movs, atk = CalcAnimMove(origPos, movTar)
    tScale = sqrt(len(movs))
    gTicksPerAnimMove = int(gInitTicksPerAnimMove / tScale)

    animQueue = []

    if decrown:
        animQueue.append(('dc', origPos))
        assert movTar != origPos
    if movTar == origPos: #Code for adding a crown
        animQueue.append(('ac', origPos))
    else:
        pmov = movs[0]
        for mov in movs[1:]:
            animQueue.append(('mov', (pmov, mov)))
            pmov = mov
        if board.get(mov, '  ')[0] == board[origPos][0]: #Capturing own piece, aka combat swap
            animQueue[-1] = ('swp', (origPos, mov))

        if atk != []:
            animQueue.append(('atk', (pmov, atk[0])))
    return animQueue

def DoAnimate():
    global gAnimCounter, gIsAnimating, gTmpRep, deco
    if len(gAnimQueue) > 0:
        if not gIsAnimating: gAnimCounter = 0
        gIsAnimating = True
    
    if not gIsAnimating: return
    startOfAnim = gAnimCounter == 0
    gAnimCounter += 1
    endOfAnim = gAnimCounter == gTicksPerAnimMove
    animProg = gAnimCounter / gTicksPerAnimMove
    anim = gAnimQueue[0]
    if anim[0] == 'mov':
        animVal = Smooth(animProg)
        if startOfAnim:
            idx ,= [i for i,p in enumerate(pieces) if p[1] == anim[1][0]]
            pieces.append(pieces[idx])
            del pieces[idx]
        pieces[-1][1] = Lerp(anim[1][0], anim[1][1], animVal)
        if endOfAnim:
            board[anim[1][1]] = board[anim[1][0]]
            del board[anim[1][0]]
    elif anim[0] == 'atk':
        animVal = .25 * Pointed(animProg)
        if startOfAnim:
            gAnimVars['didHalf'] = False
            idx ,= [i for i,p in enumerate(pieces) if p[1] == anim[1][0]]
            pieces.append(pieces[idx])
            del pieces[idx]
        if animProg > .5:
            if not gAnimVars['didHalf']:
                gAnimVars['didHalf'] = True
                gTmpRep = 'hl' if anim[1][0][0] == anim[1][1][0] else 'vl'
                tmp = psprites['tmp'] = psprites[gTmpRep].copy()
                deco.append(('tmp', Lerp(anim[1][0], anim[1][1], .5)))
            psprites['tmp'].set_alpha(int(Lerp(50, 255, SmoothInto(2*(animProg-.5)))))
        pieces[-1][1] = Lerp(anim[1][0], anim[1][1], animVal)
    elif anim[0] == 'ac':
        if startOfAnim:
            psprites['tmp'] = regalia.copy()
            deco.append(('tmp', anim[1]))
        psprites['tmp'].set_alpha(int(Lerp(50, 255, SmoothInto(animProg))))
        if endOfAnim:
            del deco[-1]
            idx ,= [i for i,p in enumerate(pieces) if p[1] == anim[1]]
            pieces[idx][2] = True
    elif anim[0] == 'dc':
        if startOfAnim:
            idx ,= [i for i,p in enumerate(pieces) if p[1] == anim[1]]
            pieces[idx][2] = False
            psprites['tmp'] = regalia.copy()
            deco.append(('tmp', anim[1]))
        psprites['tmp'].set_alpha(int(Lerp(255, 0, SmoothInto(animProg))))
        if endOfAnim:
            del deco[-1]
    elif anim[0] == 'swp':
        animVal = Smooth(animProg)
        if startOfAnim:
            idx0 ,= [i for i,p in enumerate(pieces) if p[1] == anim[1][0]]
            pieces.append(pieces[idx0])
            del pieces[idx0]
            idx1 ,= [i for i,p in enumerate(pieces) if p[1] == anim[1][1]] 
            pieces.append(pieces[idx1])
            del pieces[idx1]
        pieces[-1][1] = Lerp(anim[1][0], anim[1][1], 1-animVal)
        pieces[-2][1] = Lerp(anim[1][0], anim[1][1], animVal)
        if endOfAnim:
            board[anim[1][1]], board[anim[1][0]] = board[anim[1][0]], board[anim[1][1]]
    else: assert False
    if endOfAnim:
        gAnimCounter = 0
        del gAnimQueue[0]
        gIsAnimating = False
        pieces[-1][1] = tuple([int(x) for x in pieces[-1][1]])
        idxs = [i for i,x in enumerate(deco) if x[0] == 'tmp']
        for idx in idxs:
            deco[idx] = (gTmpRep, deco[idx][1])

def Lerp(a, b, t):
    assert type(a) == type(b)
    isSingle = type(a) in [int, float]
    r_ = [_Lerp(a_, b_, t) for a_, b_ in zip([a] if isSingle else a, [b] if isSingle else b)]
    if isSingle: return r_[0]
    return r_

def _Lerp(a, b, t):
    return a*(1-t) + b*t

def InitStrFromSetup(board: str) -> str:
    initstr = ''
    for i, line in enumerate(boardstr.splitlines()):
        line = line.replace('.', '')
        for col in range(5):
            assert line[col] == line[8-col], f'Board is not laterally symetric: R{i}C{col}({line[col]}) != R{i}C{8-col}({line[8-col]})'
            c = line[col]
            if c == ' ': 
                initstr += 'z'
                continue
            crown = line[col] == 'k'
            initstr += chr(ord('a') + (crown << 3 | 0 << 2 | 'icak'.index(c)))
        initstr += initstr[-5:][:4][::-1]
    initstr += 'z'*27
    initstr += ''.join([chr(ord('a')+((ord(x)-ord('a')) ^ 4)) if x != 'z' else 'z' for x in initstr[:27][::-1]])
    initstr += 'z'*81
    return initstr

light_cell = pygame.image.load("src/sprites/light_cell.png")
dark_cell = pygame.image.load("src/sprites/dark_cell.png")
regalia = pygame.image.load("src/sprites/crown.png")
hlock = pygame.image.load("src/sprites/Lock.png")
vlock = pygame.transform.rotate(hlock, 90)
hatktar = pygame.image.load("src/sprites/AttackTarget.png")
vatktar = pygame.transform.rotate(hatktar, 90)
tarsqr = pygame.image.load("src/sprites/TargetSquare.png")

vatktar.set_alpha(220)
hatktar.set_alpha(220)
tarsqr.set_alpha(170)


psprites = {}
for color in 'wb':
    for kind in 'icak':
        psprites[f'{color}{kind}'] = pygame.image.load(f"src/sprites/{color}{kind}.png")

psprites['hl'] = hlock
psprites['vl'] = vlock


cellwidth = 80
screenwidth = 1000
screenheight = 800

latoff = (screenwidth - 9*cellwidth)//2
veroff = (screenheight - 9*cellwidth)//2

board = {}
pieces = []
deco = []
gIsAnimating = False
gAnimCounter = None

boardstr = \
' ci.aka.ic '       +'\n'+ \
'   .cic.   '       +'\n'+ \
'   .i i.   '

ZigInitAlloc()

state = Board()
state.AddNewHandle()
state.FromInitStr(InitStrFromSetup(boardstr))

state.ApplyMove(1 << 1 | 37 << 9)
#state.ApplyMove(2 << 1 | 2 << 9)
state.PullState()
print('Moved')
moves = []
moves = ZigGenMoves(state.handle, 38)

pieces, deco, board = state.RegenRender()

#got = ZigGenInitStr(boardptr)
#print(repr(got))

screen = pygame.display.set_mode([screenwidth, screenheight])
clock = pygame.time.Clock()

run = True
while run:
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            pygame.quit()
            run = False
    if not run: break

    for col in range(9):
        for row in range(9):
            idx = (col ^ row) & 1
            sprite = [light_cell, dark_cell][idx]
            #color = (255, 255, 255)
            screen.blit(sprite, (latoff + 80*col, veroff + 80*row))
            #pygame.draw.rect(screen, color, , 80, 80))

    pygame.draw.rect(screen, [40]*3, (latoff+80*3-3, veroff, 6, 80*9))
    pygame.draw.rect(screen, [40]*3, (latoff+80*6-3, veroff, 6, 80*9))
    pygame.draw.rect(screen, [40]*3, (latoff, veroff+80*3-3, 80*9, 6))
    pygame.draw.rect(screen, [40]*3, (latoff, veroff+80*6-3, 80*9, 6))

    DoAnimate()

    for piece, pos, crown in pieces:
        DrawPiece(psprites[piece], *pos)
        if crown:
            DrawPiece(regalia, *pos)

    for piece, pos in deco:
        DrawPiece(psprites[piece], *pos)

    for move in moves:
        #print(move)
        pos = list(divmod(move['dest'], 9))[::-1]
        if move['doAtk']:
            pos[1] += (1, 0, -1, 0, 1, -1, -1, 1)[move['atkDir']]/2
            pos[0] += (0, 1, 0, -1, 1, 1, -1, -1)[move['atkDir']]/2
        #if move['doCap']:
        #    pos[1] += (1, 0, -1, 0, 1, -1, -1, 1)[move['atkDir']]
        #    pos[0] += (0, 1, 0, -1, 1, 1, -1, -1)[move['atkDir']]
        DrawPiece(tarsqr, *pos)

    #DrawPiece(vlock, *(3.5, 0))
    #DrawPiece(vatktar, *(3.5, 0))
    #DrawPiece(tarsqr, *(5, 0))
    #DrawPiece(tarsqr, *(6, 0))

    pygame.display.update()
    clock.tick(60)