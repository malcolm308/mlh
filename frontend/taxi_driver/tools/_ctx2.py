import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
txt = io.open('lib/screens/driver_home_screen.dart', encoding='utf-8').read()
for n, i in enumerate([m for m in range(len(txt)) if txt[m] == '\ufffd'], 1):
    ini = max(0, i - 30); fin = min(len(txt), i + 30)
    print("%d  %s" % (n, txt[ini:fin].replace('\ufffd','<?>').replace('\n',' ')))
