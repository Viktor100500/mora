// Yar the cat kisses Nastya after a purchase is recorded: in the widget and in
// the Mini App form (cloud/telegram/miniapp keeps its own copy of the scene).
// Drawn in Mora's palette: leaf ivory, the icon's greens and the launch mint.
export const YAR_SCENE = `<svg viewBox="0 0 200 110" width="100%" height="120" aria-label="Котик Яр целует Настеньку">
<g class="nas"><path d="M110 72a28 30 0 0 1 56 0v30h-56z" fill="#1c4f3b"/><circle cx="138" cy="66" r="22" fill="#f2ead8" stroke="#336e57" stroke-width="1.5"/>
<path d="M115 63c4-21 42-25 46 0c-11-9-32-11-46 0z" fill="#1c4f3b"/><path d="M128 66q4 3 8 0M142 66q4 3 8 0M134 78q4 4 8 0" stroke="#1c4f3b" stroke-width="2" fill="none"/>
<circle cx="126" cy="74" r="4" fill="#70b88f" opacity=".55"/><circle cx="151" cy="74" r="4" fill="#70b88f" opacity=".55"/></g>
<g class="cat"><path d="M45 54l5-24 15 15zM95 54l-5-24-15 15z" fill="#edf2de" stroke="#336e57" stroke-width="1.5" stroke-linejoin="round"/><ellipse cx="70" cy="67" rx="27" ry="23" fill="#edf2de" stroke="#336e57" stroke-width="1.5"/>
<path d="M58 63q4-4 8 0M74 63q4-4 8 0M70 74q-4 5-8 2M70 74q4 5 8 2" stroke="#1c4f3b" stroke-width="2" fill="none"/><path d="M67 70h6l-3 4z" fill="#70b88f"/>
<path d="M38 71h15M38 77h15M87 71h15M87 77h15" stroke="#40826a"/></g>
<path class="ht" d="M108 34c-4-8-16-4-12 4l12 12 12-12c4-8-8-12-12-4z" fill="#70b88f"/></svg>`;
export const YAR_STYLE = `.cat{transform-box:fill-box;transform-origin:center;animation:kiss 1.3s ease-in-out 2}
@keyframes kiss{0%,100%{transform:none}50%{transform:translateX(30px) rotate(10deg)}}
.ht{transform-box:fill-box;transform-origin:center;opacity:0;animation:up 1.3s ease-out .45s 2}
@keyframes up{0%{opacity:0;transform:scale(.4)}40%{opacity:1;transform:translateY(-6px) scale(1.25)}100%{opacity:0;transform:translateY(-24px)}}`;

// The HTML bubble shown in the chat (Telegram widget profile 1, SDK v1:
// github.com/TelegramMessenger/widget-sandbox). Widgets get no keyboard, so it
// only offers taps: the bot's recent merchants and a keypad for the amount.
// "Записать" sends `q|<amount>|<index>|<merchant hash>` (at most 64 bytes) to
// the bot, and Yar's scene plays when it is recorded. "Новая трата" and
// "Подробнее" open the Mini App by the bot's t.me link (its Main Mini App:
// https://t.me/<bot>?startapp); without a link `n` asks the bot for a message
// with the form button. The bot writes chatData (1024 bytes at most):
// {t: today, m: month, l: t.me link, r: [[merchant, currency, hash]]}. The
// server limits the HTML to 4096 bytes after zlib level 9.
export const WIDGET_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font:14px/1.35 system-ui,sans-serif;color:var(--tg-theme-text-color,#111)}
.w{padding:10px 12px 12px}.s{font-size:12px;color:var(--tg-theme-hint-color,#888)}
.t{font-size:19px;font-weight:600;margin:2px 0 10px}.a{font-size:28px;font-weight:600;margin:4px 0 6px}
.c{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
button{font:inherit;border:0;border-radius:10px;padding:8px 11px;background:var(--tg-theme-secondary-bg-color,#eef1f5);color:inherit}
button.p{background:#336e57;color:#fff}@media(prefers-color-scheme:dark){button.p{background:#40826a}}
.k{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:6px}.k button{padding:11px 0;font-size:18px}
.h{display:none}#msg{margin-top:8px}#yay{text-align:center}
${YAR_STYLE}
</style></head><body><div class="w">
<div id="home"><div class="s">Сегодня · месяц</div><div class="t" id="tot">—</div>
<div class="s" id="hint">Быстро записать</div><div class="c" id="rec"></div>
<div class="c"><button class="p" id="more">＋ Новая трата</button><button id="ref">↻</button></div></div>
<div id="pad" class="h"><div class="s" id="who"></div><div class="a" id="amt">0</div><div class="k" id="keys"></div>
<div class="c"><button id="back">Назад</button><button id="det">Подробнее</button><button class="p" id="ok">Записать</button></div></div>
<div id="yay" class="h">${YAR_SCENE}<div class="s">Яр целует Настеньку · чмок!</div></div>
<div class="s" id="msg"></div></div>
<script>
var TW=typeof TelegramWidget!=='undefined'?TelegramWidget:null,S={},cur=-1,a='',busy=0;
function $(i){return document.getElementById(i)}
function load(){try{S=JSON.parse(TW&&TW.chatData||'{}')||{}}catch(e){S={}}if(!S.r)S.r=[]}
function show(p){['home','pad','yay'].forEach(function(x){$(x).className=x==p?'':'h'})}
function yay(){var y=$('yay');y.innerHTML=y.innerHTML;show('yay');setTimeout(function(){$('msg').textContent='';home()},3200)}
function home(){$('tot').textContent=(S.t||'0')+' · '+(S.m||'0');var r=$('rec');r.textContent='';
S.r.forEach(function(x,i){var b=document.createElement('button');b.textContent=x[0];b.onclick=function(){pick(i)};r.appendChild(b)});
$('hint').className=S.r.length?'s':'h';show('home')}
function pick(i){cur=i;a='';$('msg').textContent='';$('who').textContent=S.r[i][0];$('det').className=S.l?'':'h';draw();show('pad')}
function draw(){$('amt').textContent=(a||'0')+' '+S.r[cur][1]}
function key(k){if(k=='⌫')a=a.slice(0,-1);else if(k=='.'){if(a.indexOf('.')<0)a=(a||'0')+'.'}
else if(/\\.\\d\\d$/.test(a)||a.replace('.','').length>=9)return;else a=(a=='0'?'':a)+k;draw()}
function link(p){if(!TW||!S.l)return;try{TW.openTelegramLink(S.l+'?startapp'+(p?'='+p:''))}catch(e){}}
function ask(d,done){if(busy||!TW)return;busy=1;$('msg').textContent='Отправляю…';
TW.request(d).then(function(x){busy=0;var t=x&&x.result||'';$('msg').textContent=t;done&&done(t)},
function(e){busy=0;$('msg').textContent='Ошибка: '+(e&&e.code||e)})}
'123456789.0⌫'.split('').forEach(function(k){var b=document.createElement('button');b.textContent=k;b.onclick=function(){key(k)};$('keys').appendChild(b)});
$('more').onclick=function(){if(S.l)link('');else ask('n')};
$('det').onclick=function(){link('r'+cur+'_'+a.replace('.','d'))};
$('back').onclick=function(){$('msg').textContent='';show('home')};
$('ref').onclick=function(){ask('r')};
$('ok').onclick=function(){if(!(+a>0))return;ask('q|'+a+'|'+cur+'|'+S.r[cur][2],function(t){if(t.charAt(0)=='✓')yay()})};
if(TW){TW.onEvent('chatDataChanged',function(){load();if(!$('home').className)home()});if(TW.ready)TW.ready()}
load();home();
</script></body></html>`;
