import io, sys, unicodedata
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
txt = io.open('lib/screens/driver_home_screen.dart', encoding='utf-8').read()

# Extrae cada fragmento roto: 3 caracteres antes y 18 despues del U+FFFD.
for n, i in enumerate([m for m in range(len(txt)) if txt[m] == '\ufffd'], 1):
    ini = max(0, i - 14)
    fin = min(len(txt), i + 16)
    ctx = txt[ini:fin].replace('\ufffd', '<?>').replace('\n', ' ')
    print("%2d  %s" % (n, ctx))
