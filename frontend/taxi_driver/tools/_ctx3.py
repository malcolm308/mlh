import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
txt = io.open('lib/screens/driver_home_screen.dart', encoding='utf-8').read()
i = txt.find('\ufffd')
print(repr(txt[max(0,i-70):i+70]))
