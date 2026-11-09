// The HTML bubble shown in the chat (Telegram widget profile 1, SDK v1:
// github.com/TelegramMessenger/widget-sandbox). Widgets get no keyboard, so
// everything is a tap: a recent merchant and a keypad, or a new purchase as
// amount and currency, then category and account (the category's name is the
// merchant). Requests to the bot, at most 64 bytes:
//   q|<amount>|<recent index>|<merchant hash>        a recent merchant again
//   a|<amount>|<currency>|<category>|<account>|<v>   a new purchase
//   r                                                refresh
// The bot writes chatData (1024 bytes at most): {t: today, m: month, l: Mini
// App t.me link or "", r: [[merchant, currency, hash]], c: [category names],
// a: [[account name, currency]], d: default account index, v: lists version}.
// The bubble is at most 600 px tall: the account is one button that steps to the next.
// "Подробнее" appears only with a t.me link. The server limits the HTML to
// 4096 bytes after zlib level 9.
export const WIDGET_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font:14px/1.35 system-ui,sans-serif;color:var(--tg-theme-text-color,#111)}
.w{padding:10px 12px 12px}.s{font-size:12px;color:var(--tg-theme-hint-color,#888)}
.t{font-size:19px;font-weight:600;margin:2px 0 10px}.a{font-size:28px;font-weight:600;margin:4px 0 6px}
.c{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
button{font:inherit;border:0;border-radius:10px;padding:8px 11px;background:var(--tg-theme-secondary-bg-color,#eef1f5);color:inherit}
button.p{background:var(--tg-theme-button-color,#2a8bf2);color:var(--tg-theme-button-text-color,#fff)}
.k{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:6px}.k button{padding:11px 0;font-size:18px}
.h{display:none}#msg{margin-top:8px}.l{margin-top:10px}#cats button{padding:6px 9px;font-size:13px}
</style></head><body><div class="w">
<div id="home"><div class="s">Сегодня · месяц</div><div class="t" id="tot">—</div>
<div class="s" id="hint">Быстро записать</div><div class="c" id="rec"></div>
<div class="c"><button class="p" id="more">＋ Новая трата</button><button id="ref">↻</button></div></div>
<div id="pad" class="h"><div class="s" id="who"></div><div class="a" id="amt">0</div><div class="c" id="curs"></div><div class="k" id="keys"></div>
<div class="c"><button id="back">Назад</button><button id="det">Подробнее</button><button class="p" id="ok">Записать</button></div></div>
<div id="cat" class="h"><div class="s" id="sum"></div><div class="s l">Категория</div><div class="c" id="cats"></div>
<div class="s l">Счёт · нажмите, чтобы сменить</div><div class="c"><button id="acc"></button></div>
<div class="c l"><button id="back2">Назад</button><button class="p" id="save">Записать</button></div></div>
<div class="s" id="msg"></div></div>
<script>
var TW=typeof TelegramWidget!=='undefined'?TelegramWidget:null,S={},cur=-1,a='',busy=0,mode='r',cc='',ci=-1,ai=0;
function $(i){return document.getElementById(i)}
function load(){try{S=JSON.parse(TW&&TW.chatData||'{}')||{}}catch(e){S={}}S.r=S.r||[];S.c=S.c||[];S.a=S.a||[]}
function show(p){['home','pad','cat'].forEach(function(x){$(x).className=x==p?'':'h'})}
function chips(id,list,sel,fn){var e=$(id);e.textContent='';list.forEach(function(x,i){var b=document.createElement('button');b.textContent=x;if(i===sel)b.className='p';b.onclick=function(){fn(i)};e.appendChild(b)})}
function home(){$('tot').textContent=(S.t||'0')+' · '+(S.m||'0');chips('rec',S.r.map(function(x){return x[0]}),-1,pick);
$('hint').className=S.r.length?'s':'h';$('more').className=S.a.length?'p':'h';show('home')}
function open(m,label){mode=m;a='';$('msg').textContent='';$('who').textContent=label;$('ok').textContent=m=='n'?'Дальше':'Записать';
$('det').className=S.l&&m=='r'?'':'h';drawc();draw();show('pad')}
function pick(i){cur=i;open('r',S.r[i][0])}
function newp(){ai=S.d||0;cc=(S.a[ai]||[])[1]||'';ci=-1;open('n','Новая трата')}
function curs(){var l=[];S.a.forEach(function(x){if(l.indexOf(x[1])<0)l.push(x[1])});return l}
function drawc(){if(mode!='n'){$('curs').textContent='';return}var l=curs();chips('curs',l,l.indexOf(cc),function(i){cc=l[i];drawc();draw()})}
function draw(){$('amt').textContent=(a||'0')+' '+(mode=='n'?cc:S.r[cur][1])}
function drawCat(){$('sum').textContent=a+' '+cc;chips('cats',S.c,ci,function(i){ci=i;drawCat()});
var x=S.a[ai]||['',''];$('acc').textContent=x[0]+' · '+x[1]+(S.a.length>1?' ›':'')}
function key(k){if(k=='⌫')a=a.slice(0,-1);else if(k=='.'){if(a.indexOf('.')<0)a=(a||'0')+'.'}
else if(/\\.\\d\\d$/.test(a)||a.replace('.','').length>=9)return;else a=(a=='0'?'':a)+k;draw()}
function link(p){if(!TW||!S.l)return;try{TW.openTelegramLink(S.l+(p?'?startapp='+p:''))}catch(e){}}
function ask(d,done){if(busy||!TW)return;busy=1;$('msg').textContent='Отправляю…';
TW.request(d).then(function(x){busy=0;var t=x&&x.result||'';$('msg').textContent=t;if(t.charAt(0)=='✓')show('home');done&&done(t)},
function(e){busy=0;$('msg').textContent='Ошибка: '+(e&&e.code||e)})}
'123456789.0⌫'.split('').forEach(function(k){var b=document.createElement('button');b.textContent=k;b.onclick=function(){key(k)};$('keys').appendChild(b)});
$('more').onclick=newp;
$('det').onclick=function(){link('r'+cur+'_'+a.replace('.','d'))};
$('back').onclick=function(){$('msg').textContent='';show('home')};
$('acc').onclick=function(){ai=(ai+1)%S.a.length;drawCat()};
$('back2').onclick=function(){$('msg').textContent='';show('pad')};
$('ref').onclick=function(){ask('r')};
$('ok').onclick=function(){if(!(+a>0))return;if(mode=='n'){$('msg').textContent='';drawCat();show('cat')}else ask('q|'+a+'|'+cur+'|'+S.r[cur][2])};
$('save').onclick=function(){if(ci<0){$('msg').textContent='Выберите категорию';return}ask('a|'+a+'|'+cc+'|'+ci+'|'+ai+'|'+S.v)};
if(TW){TW.onEvent('chatDataChanged',function(){load();if(!$('home').className)home()});if(TW.ready)TW.ready()}
load();home();
</script></body></html>`;
