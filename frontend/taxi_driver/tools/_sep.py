import io, sys, unicodedata
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
txt = io.open('lib/screens/driver_home_screen.dart', encoding='utf-8').read()
i = txt.find('VIAJE EN CURSO')
frag = txt[i:i+22]
print("codepoints no-ASCII del fragmento:")
for ch in frag:
    if ord(ch) > 127:
        print("   U+%04X  %s" % (ord(ch), unicodedata.name(ch, '?')))
