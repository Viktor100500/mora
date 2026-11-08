// The HTML bubble shown in the chat (Telegram widget profile 1, SDK v1:
// github.com/TelegramMessenger/widget-sandbox). Widgets get no keyboard, so it
// only offers taps: the bot's recent merchants and a keypad for the amount.
// "Записать" sends `q|<amount>|<index>|<merchant hash>` (at most 64 bytes) to
// the bot. Everything else opens the Mini App. The bot writes chatData (1024
// bytes at most): {t: today, m: month, l: Mini App link, r: [[merchant,
// currency, hash]]}. The server limits the HTML to 4096 bytes after zlib level 9.
export const WIDGET_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font:14px/1.35 system-ui,sans-serif;color:var(--tg-theme-text-color,#111)}
.w{padding:10px 12px 12px}.s{font-size:12px;color:var(--tg-theme-hint-color,#888)}
.t{font-size:19px;font-weight:600;margin:2px 0 10px}.a{font-size:28px;font-weight:600;margin:4px 0 6px}
.c{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
button{font:inherit;border:0;border-radius:10px;padding:8px 11px;background:var(--tg-theme-secondary-bg-color,#eef1f5);color:inherit}
button.p{background:var(--tg-theme-button-color,#2a8bf2);color:var(--tg-theme-button-text-color,#fff)}
.k{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:6px}.k button{padding:11px 0;font-size:18px}
.h{display:none}#msg{margin-top:8px}
</style></head><body><div class="w">
<div id="home"><div class="s">Сегодня · месяц</div><div class="t" id="tot">—</div>
<div class="s" id="hint">Быстро записать</div><div class="c" id="rec"></div>
<div class="c"><button class="p" id="more">＋ Новая трата</button><button id="ref">↻</button></div></div>
<div id="pad" class="h"><div class="s" id="who"></div><div class="a" id="amt">0</div><div class="k" id="keys"></div>
<div class="c"><button id="back">Назад</button><button id="det">Подробнее</button><button class="p" id="ok">Записать</button></div></div>
<div class="s" id="msg"></div></div>
<script>
var TW=typeof TelegramWidget!=='undefined'?TelegramWidget:null,S={},cur=-1,a='',busy=0;
function $(i){return document.getElementById(i)}
function load(){try{S=JSON.parse(TW&&TW.chatData||'{}')||{}}catch(e){S={}}if(!S.r)S.r=[]}
function show(p){$('home').className=p=='home'?'':'h';$('pad').className=p=='pad'?'':'h'}
function home(){$('tot').textContent=(S.t||'0')+' · '+(S.m||'0');var r=$('rec');r.textContent='';
S.r.forEach(function(x,i){var b=document.createElement('button');b.textContent=x[0];b.onclick=function(){pick(i)};r.appendChild(b)});
$('hint').className=S.r.length?'s':'h';show('home')}
function pick(i){cur=i;a='';$('msg').textContent='';$('who').textContent=S.r[i][0];draw();show('pad')}
function draw(){$('amt').textContent=(a||'0')+' '+S.r[cur][1]}
function key(k){if(k=='⌫')a=a.slice(0,-1);else if(k=='.'){if(a.indexOf('.')<0)a=(a||'0')+'.'}
else if(/\\.\\d\\d$/.test(a)||a.replace('.','').length>=9)return;else a=(a=='0'?'':a)+k;draw()}
function link(p){if(!TW||!S.l)return;try{TW.openTelegramLink(S.l+(p?'?startapp='+p:''))}catch(e){}}
function ask(d,done){if(busy||!TW)return;busy=1;$('msg').textContent='Отправляю…';
TW.request(d).then(function(x){busy=0;var t=x&&x.result||'';$('msg').textContent=t;done&&done(t)},
function(e){busy=0;$('msg').textContent='Ошибка: '+(e&&e.code||e)})}
'123456789.0⌫'.split('').forEach(function(k){var b=document.createElement('button');b.textContent=k;b.onclick=function(){key(k)};$('keys').appendChild(b)});
$('more').onclick=function(){link('')};
$('det').onclick=function(){link('r'+cur+'_'+a.replace('.','d'))};
$('back').onclick=function(){$('msg').textContent='';show('home')};
$('ref').onclick=function(){ask('r')};
$('ok').onclick=function(){if(!(+a>0))return;ask('q|'+a+'|'+cur+'|'+S.r[cur][2],function(t){if(t.charAt(0)=='✓')show('home')})};
if(TW){TW.onEvent('chatDataChanged',function(){load();if($('pad').className)home()});if(TW.ready)TW.ready()}
load();home();
</script></body></html>`;
