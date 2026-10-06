import glob, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

patron = '\u00ef\u00bf\u00bd'   # secuencia "ï¿½" (doble codificacion)
archivos = glob.glob('lib/**/*.dart', recursive=True) + glob.glob('test/*.dart')
total = 0
for f in sorted(archivos):
    txt = io.open(f, encoding='utf-8').read()
    n = txt.count(patron)
    if n:
        print("%-52s %d" % (f, n))
        total += n
print("TOTAL:", total)
