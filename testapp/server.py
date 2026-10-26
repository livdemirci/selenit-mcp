#!/usr/bin/env python3
"""Zorlu senaryo test uygulaması (bağımlılıksız).

Senaryolar:
  /login       oturum açma (localStorage tabanlı)
  /dashboard   30 satırlık tablo + arama + sayfalama + düzenleme modalı
  /dynamic     2.5 sn gecikmeli içerik + sonsuz kaydırma
  /frame       iframe içinde form
  /shadow      shadow DOM içinde input + buton
  /upload      dosya yükleme
  /tabs        yeni sekmede açılan bağlantı
  /alerts      alert / confirm / prompt
  /magaza      sıralama menüsü (aria-haspopup) + sepet adedi — e-ticaret provası

Çalıştırma: python3 server.py [port]
"""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOGIN = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Giriş</title></head>
<body>
<h1>Müşteri Portalı</h1>
<form id="f">
  <label>Kullanıcı <input name="user" id="user" autocomplete="off"></label>
  <label>Parola <input name="pass" id="pass" type="password"></label>
  <button type="submit">Giriş Yap</button>
</form>
<p id="err" style="color:#b00"></p>
<script>
document.getElementById('f').addEventListener('submit', function (e) {
  e.preventDefault();
  var u = document.getElementById('user').value.trim();
  var p = document.getElementById('pass').value;
  if (u === 'demo' && p === 'demo123') {
    localStorage.setItem('auth', '1');
    location.href = '/dashboard';
  } else {
    document.getElementById('err').textContent = 'Hatalı giriş';
  }
});
</script>
</body></html>"""

DASHBOARD = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Panel</title>
<style>
 body{font-family:system-ui;margin:24px} table{border-collapse:collapse;width:100%}
 td,th{border:1px solid #ddd;padding:6px;text-align:left} .modal{position:fixed;inset:0;background:#0006;display:none;align-items:center;justify-content:center}
 .modal.open{display:flex} .box{background:#fff;padding:20px;border-radius:8px;min-width:280px}
 #toast{position:fixed;right:20px;bottom:20px;background:#222;color:#fff;padding:10px 16px;border-radius:6px;opacity:0;transition:.3s}
</style></head>
<body>
<h1>Müşteriler</h1>
<input id="search" placeholder="Müşteri ara">
<button id="prev">Önceki</button> <span id="pageinfo"></span> <button id="next">Sonraki</button>
<table><thead><tr><th>#</th><th>Ad</th><th>Şehir</th><th>Durum</th><th></th></tr></thead><tbody id="tbody"></tbody></table>
<div class="modal" id="modal" role="dialog" aria-modal="true"><div class="box">
  <h3 id="mtitle">Kayıt</h3>
  <label>Durum <select id="status"><option>Beklemede</option><option>Aktif</option><option>Pasif</option></select></label>
  <p><button id="save">Kaydet</button> <button id="cancel">Vazgeç</button></p>
</div></div>
<div id="toast"></div>
<script>
if (!localStorage.getItem('auth')) location.href = '/login';
var names = ['Ada Lovelace','Alan Turing','Grace Hopper','Edsger Dijkstra','Barbara Liskov','Linus Torvalds','Margaret Hamilton','Dennis Ritchie','Frances Allen','Tim Berners-Lee'];
var cities = ['Londra','Manchester','New York','Rotterdam','Boston','Helsinki','Los Angeles','Murray Hill','New York','Cenevre'];
var rows = [];
for (var i = 1; i <= 30; i++) {
  rows.push({id:i, name:names[i%10] + ' ' + i, city:cities[i%10], status:['Beklemede','Aktif','Pasif'][i%3]});
}
var page = 0, per = 8, q = '', editing = null;
function visible(){ return rows.filter(function(r){ return (r.name + ' ' + r.city).toLowerCase().indexOf(q.toLowerCase()) >= 0; }); }
function render(){
  var list = visible(), start = page * per, slice = list.slice(start, start + per);
  document.getElementById('tbody').innerHTML = slice.map(function(r){
    return '<tr data-id="' + r.id + '"><td>' + r.id + '</td><td>' + r.name + '</td><td>' + r.city +
           '</td><td class="st">' + r.status + '</td><td><button onclick="edit(' + r.id + ')">Düzenle</button></td></tr>';
  }).join('');
  document.getElementById('pageinfo').textContent = 'sayfa ' + (page+1) + ' / ' + Math.max(1, Math.ceil(list.length/per));
}
function edit(id){ editing = rows.find(function(r){return r.id===id}); document.getElementById('mtitle').textContent = editing.name; document.getElementById('status').value = editing.status; document.getElementById('modal').classList.add('open'); }
document.getElementById('save').onclick = function(){
  if (editing) { editing.status = document.getElementById('status').value; }
  document.getElementById('modal').classList.remove('open'); render();
  var t = document.getElementById('toast'); t.textContent = 'Kaydedildi: ' + (editing ? editing.name : ''); t.style.opacity = 1;
  setTimeout(function(){ t.style.opacity = 0; }, 1500);
};
document.getElementById('cancel').onclick = function(){ document.getElementById('modal').classList.remove('open'); };
document.getElementById('prev').onclick = function(){ if (page>0) { page--; render(); } };
document.getElementById('next').onclick = function(){ if ((page+1)*per < visible().length) { page++; render(); } };
document.getElementById('search').addEventListener('input', function(e){ q = e.target.value; page = 0; render(); });
render();
</script></body></html>"""

DYNAMIC = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Dinamik</title></head>
<body style="min-height:150vh"><h1>Dinamik liste</h1><p id="wait">Yükleniyor...</p><ul id="list"></ul>
<script>
setTimeout(function(){
  document.getElementById('wait').textContent = 'Hazır';
  for (var i = 1; i <= 5; i++) { add('Kayıt ' + i); }
}, 2500);
function add(text){ var li = document.createElement('li'); li.textContent = text; document.getElementById('list').appendChild(li); }
var n = 5, loading = false;
function maybeLoad(){
  if (loading || n >= 15) return;
  if (window.scrollY > 40) {
    loading = true;
    setTimeout(function(){
      for (var i = 0; i < 5; i++) { n++; add('Kayıt ' + n); }
      loading = false;
    }, 300);
  }
}
window.addEventListener('scroll', maybeLoad);
document.addEventListener('scroll', maybeLoad, true);
setInterval(maybeLoad, 400);
</script></body></html>"""

FRAME = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Frame</title></head>
<body><h1>Iframe formu</h1><iframe id="frm" src="/inner" width="420" height="220"></iframe>
<p id="result">sonuç yok</p>
<script>
window.addEventListener('message', function(e){ document.getElementById('result').textContent = 'Sonuç: ' + e.data; });
</script></body></html>"""

INNER = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>İç form</title></head>
<body><form id="f"><label>Ad <input name="ad" id="ad"></label>
<button type="submit">Gönder</button></form>
<script>
document.getElementById('f').addEventListener('submit', function(e){
  e.preventDefault();
  parent.postMessage(document.getElementById('ad').value, '*');
});
</script></body></html>"""

SHADOW = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Shadow</title></head>
<body><h1>Shadow DOM bileşeni</h1><my-widget></my-widget><p id="result">sonuç yok</p>
<script>
customElements.define('my-widget', class extends HTMLElement {
  constructor(){ super(); var r = this.attachShadow({mode:'open'});
    r.innerHTML = '<label>Mesaj <input id="msg"></label><button id="ok">Onayla</button>';
    r.getElementById('ok').onclick = function(){
      document.getElementById('result').textContent = 'Shadow sonuç: ' + r.getElementById('msg').value;
    };
  }
});
</script></body></html>"""

UPLOAD = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Yükleme</title></head>
<body><h1>Dosya yükleme</h1><input type="file" id="file"><button id="up">Yükle</button>
<p id="out">dosya seçilmedi</p>
<script>
document.getElementById('up').onclick = function(){
  var f = document.getElementById('file').files[0];
  document.getElementById('out').textContent = f ? ('Dosya: ' + f.name + ' (' + f.size + ' bayt)') : 'dosya seçilmedi';
};
</script></body></html>"""

TABS = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Sekmeler</title></head>
<body><h1>Sekme testi</h1><a id="new" href="/tab2" target="_blank">Yeni sekmede aç</a>
<button id="popup" onclick="window.open('/tab2','_blank')">Popup aç</button></body></html>"""

TAB2 = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>İkinci Sekme</title></head>
<body><h1>İkinci sekme</h1><p id="secret">gizli-deger-42</p></body></html>"""

ALERTS = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Uyarılar</title></head>
<body><h1>Uyarılar</h1>
<button id="a" onclick="alert('basit uyarı')">Alert</button>
<button id="c" onclick="document.getElementById('out').textContent = confirm('Onaylıyor musun?') ? 'onaylandı' : 'reddedildi'">Confirm</button>
<button id="p" onclick="document.getElementById('out').textContent = 'cevap: ' + prompt('Adın?', '')">Prompt</button>
<p id="out">-</p></body></html>"""

MIXED = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Karma Senaryo</title>
<style>
 body{font-family:system-ui;margin:24px;max-width:1000px} [hidden]{display:none!important}
 table{border-collapse:collapse;width:100%;margin:10px 0} td,th{border:1px solid #ddd;padding:6px;text-align:left}
 .modal{position:fixed;inset:0;background:#0006;display:none;align-items:center;justify-content:center}
 .modal.open{display:flex} .box{background:#fff;padding:20px;border-radius:8px;min-width:280px}
 #ready{font-weight:700;color:#555} #mresult,#mframeresult{color:#075}
 #msummary{background:#f4f4f4;padding:8px;white-space:pre-wrap}
 iframe{border:1px solid #bbb}
</style></head>
<body>
<h1>Karma senaryo</h1>
<div id="gate">
  <p>Bu sayfa oturum ister.</p>
  <form id="loginForm">
    <label>Kullanıcı <input id="muser" autocomplete="off"></label>
    <label>Parola <input id="mpass" type="password"></label>
    <button id="mlogin" type="submit">Giriş Yap</button>
  </form>
  <p id="merr" style="color:#b00"></p>
</div>
<div id="app" hidden>
  <p id="ready">Yükleniyor...</p>
  <label>Müşteri ara <input id="msearch" placeholder="Müşteri ara"></label>
  <table><thead><tr><th>#</th><th>Ad</th><th>Şehir</th><th>Durum</th><th></th></tr></thead>
    <tbody id="mtbody"></tbody></table>
  <h2>Shadow bileşeni</h2>
  <my-widget id="mwidget"></my-widget>
  <p id="mresult">shadow sonuç yok</p>
  <h2>Iframe formu</h2>
  <iframe id="mframe" src="/inner" width="420" height="220"></iframe>
  <p id="mframeresult">sonuç yok</p>
  <pre id="msummary"></pre>
</div>
<div class="modal" id="mmodal" role="dialog" aria-modal="true"><div class="box">
  <h3 id="mtitle">Kayıt</h3>
  <label>Durum <select id="mstatus"><option>Beklemede</option><option>Aktif</option><option>Pasif</option></select></label>
  <p><button id="msave">Kaydet</button> <button id="mcancel">Vazgeç</button></p>
</div></div>
<script>
if (location.search.indexOf('fresh=1') >= 0) localStorage.removeItem('mixed_auth');
var rows = [
  {id:1,name:'Ada Lovelace',city:'Londra',status:'Beklemede'},
  {id:2,name:'Ada Byron',city:'Londra',status:'Beklemede'},
  {id:3,name:'Ada King',city:'Londra',status:'Beklemede'},
  {id:4,name:'Alan Turing',city:'Manchester',status:'Aktif'},
  {id:5,name:'Grace Hopper',city:'New York',status:'Pasif'},
  {id:6,name:'Linus Torvalds',city:'Helsinki',status:'Beklemede'}
];
var q = '', editing = null;
function visibleRows(){ return rows.filter(function(r){ return (r.name + ' ' + r.city).toLowerCase().indexOf(q.toLowerCase()) >= 0; }); }
function render(){
  document.getElementById('mtbody').innerHTML = visibleRows().map(function(r){
    return '<tr data-id="' + r.id + '"><td>' + r.id + '</td><td>' + r.name + '</td><td>' + r.city +
           '</td><td class="st">' + r.status + '</td><td><button onclick="editRow(' + r.id + ')">Düzenle</button></td></tr>';
  }).join('');
  updateSummary();
}
function editRow(id){
  editing = rows.find(function(r){ return r.id === id; });
  document.getElementById('mtitle').textContent = editing.name;
  document.getElementById('mstatus').value = editing.status;
  document.getElementById('mmodal').classList.add('open');
}
function updateSummary(){
  var ready = document.getElementById('ready');
  var ada = rows.find(function(r){ return r.id === 1; });
  document.getElementById('msummary').textContent =
    'auth=' + (localStorage.getItem('mixed_auth') || '') + '\n' +
    'ready=' + (ready.dataset.ready || '0') + '\n' +
    'ada=' + (ada ? ada.status : '') + '\n' +
    'shadow=' + document.getElementById('mresult').textContent + '\n' +
    'frame=' + document.getElementById('mframeresult').textContent;
}
document.getElementById('loginForm').addEventListener('submit', function(e){
  e.preventDefault();
  var u = document.getElementById('muser').value.trim();
  var p = document.getElementById('mpass').value;
  if (u === 'demo' && p === 'demo123') { localStorage.setItem('mixed_auth', '1'); start(); }
  else { document.getElementById('merr').textContent = 'Hatalı giriş'; }
});
function start(){
  document.getElementById('gate').hidden = true;
  document.getElementById('app').hidden = false;
  render();
  setTimeout(function(){
    var r = document.getElementById('ready');
    r.textContent = 'Hazır'; r.dataset.ready = '1'; updateSummary();
  }, 2500);
}
document.getElementById('msearch').addEventListener('input', function(e){ q = e.target.value; render(); });
document.getElementById('msave').onclick = function(){
  if (editing) editing.status = document.getElementById('mstatus').value;
  document.getElementById('mmodal').classList.remove('open');
  render();
};
document.getElementById('mcancel').onclick = function(){ document.getElementById('mmodal').classList.remove('open'); };
window.addEventListener('message', function(e){ document.getElementById('mframeresult').textContent = 'Sonuç: ' + e.data; updateSummary(); });
customElements.define('my-widget', class extends HTMLElement {
  constructor(){ super(); var r = this.attachShadow({mode:'open'});
    r.innerHTML = '<label>Mesaj <input id="mmsg"></label><button id="mok">Onayla</button>';
    r.getElementById('mok').onclick = function(){
      document.getElementById('mresult').textContent = 'Shadow sonuç: ' + r.getElementById('mmsg').value;
      updateSummary();
    };
  }
});
if (localStorage.getItem('mixed_auth') === '1') start();
</script></body></html>"""

DOWNLOAD = b"""%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]/Contents 4 0 R>>endobj
4 0 obj<</Length 44>>stream
BT /F1 12 Tf 20 50 Td (selenit indirme testi) Tj ET
endstream
endobj
trailer<</Root 1 0 R>>
%%EOF
"""

FILES = {
    "/download": ("agent_rapor.pdf", "application/pdf", DOWNLOAD),
}

INDEX = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Zor Senaryolar</title></head>
<body><h1>Zor senaryo uygulaması</h1><ul>
<li><a href="/login">Giriş akışı</a></li>
<li><a href="/dashboard">Panel (oturum gerekir)</a></li>
<li><a href="/dynamic">Dinamik liste</a></li>
<li><a href="/frame">Iframe formu</a></li>
<li><a href="/shadow">Shadow DOM</a></li>
<li><a href="/upload">Dosya yükleme</a></li>
<li><a href="/tabs">Yeni sekme</a></li>
<li><a href="/alerts">Uyarılar</a></li>
<li><a href="/download">Rapor indir (PDF)</a></li>
<li><a href="/mixed">Karma senaryo (oturum + AJAX + tablo/modal + shadow + iframe)</a></li>
<li><a href="/magaza">Mağaza (sıralama menüsü + sepet adedi)</a></li>
</ul></body></html>"""

MAGAZA = """<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Mağaza</title>
<style>.kart{border:1px solid #ddd;padding:10px;margin:8px 0;max-width:320px}</style></head>
<body>
<h1>Mağaza</h1>
<div class="b-dropdown">
  <button id="sirala-btn" aria-haspopup="listbox" aria-expanded="false">Önerilen Sıralama</button>
  <ul id="sirala-menu" role="listbox" style="display:none;border:1px solid #ccc;max-width:260px">
    <li role="option" id="opt-varsayilan">Önerilen Sıralama</li>
    <li role="option" id="opt-artan">Fiyat - Düşükten Yükseğe</li>
  </ul>
</div>
<div id="liste"></div>
<div id="sepet" style="margin-top:30px;border-top:2px solid #333;max-width:320px">
  <h2>Sepetim</h2>
  <p><span id="sepet-adet">0</span> ürün</p>
  <p id="sepet-detay"></p>
  <div id="sayac" style="display:none">
    <button id="eksi" type="button">-</button>
    <input id="adet-input" type="number" value="1" min="1" max="5" style="width:60px">
    <button id="arti" type="button">+</button>
  </div>
</div>
<script>
var URUNLER = [
  { ad: 'Derimod Bakım Süngeri', fiyat: 149.99 },
  { ad: 'Aqua Plaj Ayakkabısı', fiyat: 331.55 },
  { ad: 'Sneaker Günlük Ayakkabı', fiyat: 459.00 }
];
var secili = null, adet = 0, artan = false;

function tl(n) { return n.toFixed(2).replace('.', ',') + ' TL'; }

function cizListe() {
  var dizi = URUNLER.slice().sort(function (a, b) { return artan ? a.fiyat - b.fiyat : 0; });
  var liste = document.getElementById('liste');
  liste.innerHTML = '';
  dizi.forEach(function (u) {
    var kart = document.createElement('div');
    kart.className = 'kart';
    var h = document.createElement('h3'); h.textContent = u.ad;
    var p = document.createElement('p'); p.textContent = tl(u.fiyat);
    var b = document.createElement('button');
    b.type = 'button'; b.textContent = 'Sepete Ekle';
    b.onclick = function () {
      if (secili !== u) { secili = u; adet = 1; }
      else if (adet < 5) { adet += 1; }
      cizSepet();
    };
    kart.appendChild(h); kart.appendChild(p); kart.appendChild(b);
    liste.appendChild(kart);
  });
}

function cizSepet() {
  document.getElementById('sepet-adet').textContent = adet;
  document.getElementById('sepet-detay').textContent =
    secili && adet ? secili.ad + ' x ' + adet + ' = ' + tl(secili.fiyat * adet) : '';
  document.getElementById('sayac').style.display = adet ? 'block' : 'none';
  var g = document.getElementById('adet-input');
  if (g && document.activeElement !== g) g.value = adet;
}

document.getElementById('sirala-btn').onclick = function () {
  var m = document.getElementById('sirala-menu');
  var acik = m.style.display === 'block';
  m.style.display = acik ? 'none' : 'block';
  this.setAttribute('aria-expanded', acik ? 'false' : 'true');
};
document.getElementById('opt-varsayilan').onclick = function () {
  artan = false;
  document.getElementById('sirala-btn').textContent = 'Önerilen Sıralama';
  document.getElementById('sirala-menu').style.display = 'none';
  cizListe();
};
document.getElementById('opt-artan').onclick = function () {
  artan = true;
  document.getElementById('sirala-btn').textContent = 'Fiyat - Düşükten Yükseğe';
  document.getElementById('sirala-menu').style.display = 'none';
  document.getElementById('sirala-btn').setAttribute('aria-expanded', 'false');
  cizListe();
};
document.getElementById('arti').onclick = function () {
  if (adet < 5) { adet += 1; cizSepet(); }
};
document.getElementById('eksi').onclick = function () {
  if (adet > 1) { adet -= 1; cizSepet(); }
};
document.getElementById('adet-input').onchange = function () {
  var v = parseInt(this.value, 10);
  adet = isNaN(v) ? 1 : Math.max(1, Math.min(5, v));
  cizSepet();
};
cizListe();
</script>
</body></html>"""

PAGES = {    "/": INDEX, "/login": LOGIN, "/dashboard": DASHBOARD, "/dynamic": DYNAMIC,
    "/frame": FRAME, "/inner": INNER, "/shadow": SHADOW, "/upload": UPLOAD,
    "/tabs": TABS, "/tab2": TAB2, "/alerts": ALERTS, "/mixed": MIXED,
    "/magaza": MAGAZA,
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in FILES:
            filename, content_type, data = FILES[path]
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % filename)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.end_headers()
            self.wfile.write(data)
            return

        body = PAGES.get(path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"bulunamadi")
            return
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print("testapp http://127.0.0.1:%d" % port, flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
