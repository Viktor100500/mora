from pathlib import Path
import importlib.util,re
spec=importlib.util.spec_from_file_location('extract',Path(__file__).with_name('localize-ui.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
for p in (m.root/'Sources/Mora').glob('*.swift'):
 if p.name in ['Localization.swift','CloudSettingsView.swift','CloudSync.swift']:continue
 s=p.read_text();insert={}
 for a,b,key in m.literals(s):
  if not re.search('[А-Яа-яЁё]',key):continue
  # Skip strings already using the translation helper.
  if s[max(0,a-2):a]=='L(':continue
  insert.setdefault(a,[]).append('L(');insert.setdefault(b,[]).insert(0,')')
 for at in sorted(insert,reverse=True):s=s[:at]+''.join(insert[at])+s[at:]
 s=s.replace('Money.string(', 'DisplayMoney.string(').replace('Locale(identifier: "ru_RU")','L10n.locale')
 s=re.sub(r'Text\(([^\n;{}]*?\.title)\)',r'Text(L(\1))',s)
 p.write_text(s)
