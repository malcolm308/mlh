import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_home_screen.dart'
txt = io.open(f, encoding='utf-8').read()
txt = txt.replace('COMUNICACI\ufffdN', 'COMUNICACI?N')
io.open(f, 'w', encoding='utf-8', newline='').write(txt)
print("U+FFFD restantes:", txt.count('\ufffd'))
