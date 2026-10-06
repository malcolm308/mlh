import io, sys, unicodedata, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
txt = io.open('lib/screens/driver_home_screen.dart', encoding='utf-8').read()
i = txt.find('VIAJE EN CURSO')
frag = txt[i:i+30]
print("fragmento:", repr(frag))
print("codepoints:")
for ch in frag:
    if ord(ch) > 127:
        print("  U+%04X  %s" % (ord(ch), unicodedata.name(ch, '?')))
