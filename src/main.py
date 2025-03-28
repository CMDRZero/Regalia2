import pygame
from math import sqrt

type Num = int | float

gInitTicksPerAnimMove = 30

gTicksPerAnimMove = None


def DrawPiece(piece, x, y):
    screen.blit(piece, (latoff + 80*x, veroff + 80*y))

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
    global gTicksPerAnimMove
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
            animQueue[-1] = ('swp', mov)

        if atk != []:
            animQueue.append(('atk', atk[0]))
    return animQueue


light_cell = pygame.image.load("src/sprites/light_cell.png")
dark_cell = pygame.image.load("src/sprites/dark_cell.png")
crown = pygame.image.load("src/sprites/crown.png")
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

cellwidth = 80
screenwidth = 1000
screenheight = 800

latoff = (screenwidth - 9*cellwidth)//2
veroff = (screenheight - 9*cellwidth)//2

board = {}
pieces = []
isAnimating = False

boardstr = \
' ci.aka.ic '       +'\n'+ \
'   .cic.   '       +'\n'+ \
'   .i i.   '

for i, line in enumerate(boardstr.splitlines()):
    line = line.replace('.', '')
    for col in range(5):
        assert line[col] == line[8-col], f'Board is not laterally symetric: R{i}C{col}({line[col]}) != R{i}C{8-col}({line[8-col]})'
        c = line[col]
        if c == ' ': continue
        pieces.append([f'w{c}', (col, i, )])
        pieces.append([f'w{c}', (8-col, i, )])
        pieces.append([f'b{c}', (col, 8-i, )])
        pieces.append([f'b{c}', (8-col, 8-i, )])

for (piece, pos) in pieces:
    board[pos] = piece

screen = pygame.display.set_mode([screenwidth, screenheight])
clock = pygame.time.Clock()

moves = []

run = True
animQueue = SetupAnimMove(False, (3, 2), (3, 2))
print(animQueue)
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

    for piece, pos in pieces:
        DrawPiece(psprites[piece], *pos)

    #DrawPiece(vlock, *(3.5, 0))
    DrawPiece(vatktar, *(3.5, 0))
    DrawPiece(tarsqr, *(5, 0))
    DrawPiece(tarsqr, *(6, 0))

    pygame.display.update()
    clock.tick(60)