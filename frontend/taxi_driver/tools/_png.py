import struct, zlib, sys
sys.stdout = sys.stdout
p = 'assets/icons/chevron.png'
d = open(p, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "firma PNG invalida"
w, h = struct.unpack('>II', d[16:24])
print("  firma OK  %dx%d  %d bytes" % (w, h, len(d)))
# Cuantos pixeles con alfa
i = 8; idat = b''
while i < len(d):
    ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', d[i+8:i+18])
        print("  IHDR %dx%d profundidad=%d colortipo=%d (6=RGBA)" % (w,h,bd,ct))
    if typ == b'IDAT': idat += d[i+8:i+8+ln]
    i += 12 + ln
raw = zlib.decompress(idat)
n = 0
for y in range(h):
    fila = raw[y*(w*4+1):(y+1)*(w*4+1)]
    assert fila[0] == 0, "filtro inesperado"
    for x in range(w):
        if fila[1+x*4+3] > 0: n += 1
print("  pixeles pintados: %d de %d" % (n, w*h))
