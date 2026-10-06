import struct, zlib, sys
d = open('assets/icons/chevron.png','rb').read()
i=8; idat=b''
while i < len(d):
    ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]
    if typ==b'IHDR': w,h = struct.unpack('>II', d[i+8:i+16])
    if typ==b'IDAT': idat += d[i+8:i+8+ln]
    i += 12+ln
raw = zlib.decompress(idat)
print("render ASCII (48x48, # = azul, o = borde blanco):")
for y in range(h):
    fila = raw[y*(w*4+1):(y+1)*(w*4+1)]
    s = ''
    for x in range(w):
        r,g,b,a = fila[1+x*4:1+x*4+4]
        if a == 0: s += '.'
        elif (r,g,b) == (255,255,255): s += 'o'
        else: s += '#'
    print('  ' + s)
