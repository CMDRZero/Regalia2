def BoardFormatMore(x):
    bits = bin(x)[2:].zfill(128)[::-1]
    rows = [bits[11*i:][:11].ljust(11, '-') for i in range(12)]
    rows = [f'{row[:3]}|{row[3:6]}|{row[6:9]} . {row[9:11]}'.replace('1', '██').replace('0', '░░').replace('-', '  ') for row in rows]
    rows.insert(9, '      |      |       .     ')
    rows.insert(6, '------+------+------ . ----')
    rows.insert(3, '------+------+------ . ----')
    return '\n'.join(rows[::-1])

def BoardFormat(x):
    bits = bin(x)[2:].zfill(128)[::-1]
    rows = [bits[11*i:][:11].ljust(11) for i in range(12)]
    return '\n'.join(rows[::-1])