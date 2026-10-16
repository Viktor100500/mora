from pathlib import Path
import re,json

def expr_end(s,i):
 depth=1
 while i<len(s):
  if s[i]=='"': i=string_end(s,i)[0];continue
  if s[i]=='(':depth+=1
  if s[i]==')':
   depth-=1
   if not depth:return i+1
  i+=1
 raise ValueError('expression')

def string_end(s,i):
 triple=s.startswith('"""',i);quote='"""' if triple else '"';i+=len(quote);key='';n=0
 while i<len(s):
  if s.startswith(quote,i):return i+len(quote),key
  if s.startswith('\\(',i):
   i=expr_end(s,i+2);key+='{'+str(n)+'}';n+=1;continue
  if s[i]=='\\' and i+1<len(s):
   c=s[i+1];key+= {'n':'\n','t':'\t','r':'\r'}.get(c,c);i+=2;continue
  key+=s[i];i+=1
 raise ValueError('string')

def literals(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   end=s.find('\n',i);i=len(s) if end<0 else end;continue
  if s.startswith('/*',i):
   end=s.find('*/',i+2);i=len(s) if end<0 else end+2;continue
  if s[i]=='"':
   end,key=string_end(s,i);yield i,end,key
   j=i+1
   while j<end:
    if s.startswith('\\(',j):
     ex=expr_end(s,j+2)
     for a,b,k in literals(s[j+2:ex-1]):yield j+2+a,j+2+b,k
     j=ex;continue
    if s[j]=='\\':j+=2
    else:j+=1
   i=end;continue
  i+=1

root=Path(__file__).resolve().parent.parent
files=list((root/'Sources/Mora').glob('*.swift'))+list((root/'Sources/FinanceCore').glob('*.swift'))
keys={}
for p in files:
 for a,b,key in literals(p.read_text()):
  if re.search('[А-Яа-яЁё]',key):keys.setdefault(key,[]).append(str(p.relative_to(root)))
(root/'build/localization-all-keys.json').write_text(json.dumps([{'id':i,'ru':k,'files':v} for i,(k,v) in enumerate(keys.items())],ensure_ascii=False,indent=2))
print(len(keys))
