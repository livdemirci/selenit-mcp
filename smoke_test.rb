# Düzeltmelerin ucuz smoke doğrulaması (data: URL'lerle, model yok).
# Ön koşul: Chrome 19420'de açık. Kullanım: ruby smoke_test.rb
require "erb"
require "uri"
require_relative "mcp_client"

PASS = []; FAIL = []
def check(name, cond, detail = "")
  (cond ? PASS : FAIL) << name
  puts(cond ? "PASS #{name}" : "FAIL #{name} — #{detail}")
end

def durl(html)
  "data:text/html;charset=utf-8," + ERB::Util.url_encode(html)
end

def page(inner, bg_links: 8)
  bg = (1..bg_links).map { |i| "<a href='#bg#{i}' style='display:inline-block;padding:4px'>Zemin bağlantı #{i}</a>" }.join(" ")
  durl("<html><head><meta charset='utf-8'><title>smoke</title></head><body style='margin:0;padding:40px'>#{bg}#{inner}</body></html>")
end

c = McpClient.new(port: ENV["BENCH_MCP_PORT"] || "19420", max_elements: "40")
st = c.call("browser_status", {})
check("sunucu bağlandı", st.include?("bağlı") || st.include?("port"), st)

# Önceki test/koşum atıkları: Chrome'da kalan sekmeler smoke'un sekme
# index varsayımlarını (D2-D4) bozar → tüm diğer sekmeleri kapat.
c.call("browser_tabs", { "action" => "close_others" }) rescue nil

# --- A) role taşmayan modal: snapshot modal içeriğini göstermeli ----------
modal_page = page(<<~HTML)
  <div class="modal-container" style="position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:9999;display:flex;align-items:center;justify-content:center">
    <div class="gender-modal-content" style="background:#fff;padding:30px;text-align:center">
      <div class="gender-modal-content-header-title">Aradığın her şey burada!</div>
      <button class="gender-modal-btn-kadin">Kadın</button>
      <button class="gender-modal-btn-erkek">Erkek</button>
      <div class="modal-section-close" style="cursor:pointer">× kapat</div>
    </div>
  </div>
HTML
r = c.call("browser_navigate", { url: modal_page })
check("A1 modal algılandı", r.include?("MODAL AÇIK"), r.lines.take(6).join(" | "))
check("A2 modal düğmeleri görünüyor", r.include?("Kadın") && r.include?("Erkek"), r.lines.take(10).join(" | "))
check("A3 zemin bağlantısı gizlendi", !r.include?("Zemin bağlantı"), "")

# --- B) çerez bandı tarzı overlay: overlay öğeleri önce listelenir --------
banner_page = page(<<~HTML, bg_links: 30)
  <div class="cookie-banner" style="position:fixed;bottom:0;left:0;right:0;background:#111;z-index:2147483646;padding:20px">
    <button id="onetrust-reject-all-handler">Tümünü Reddet</button>
    <button id="onetrust-accept-btn-handler">Tüm Tanımlama Bilgilerini Kabul Et</button>
  </div>
HTML
r = c.call("browser_navigate", { url: banner_page })
overlay_first = r.index("Tümünü Reddet").is_a?(Integer) &&
                r.index("Tümünü Reddet") < r.index("Zemin bağlantı 1")
check("B1 önce overlay öğeleri", overlay_first, r.lines.take(8).join(" | "))
check("B2 iki banner düğmesi listelendi", r.include?("Tümünü Reddet") && r.include?("Kabul Et"), "")

# --- C) tam eşleşme önceliği: seçenek bul, partial etiketi değil ----------
menu_page = page(<<~HTML, bg_links: 2)
  <a href='#p' style='display:block;margin:400px 0'>TARÇIN Air Pro · Son 10 Günün En Düşük Fiyatı</a>
  <div style="margin:20px">
    <button class="select-box">Önerilen Sıralama</button>
    <div class="select-option" onclick="window.__clicked='opt'">En Düşük Fiyat</div>
    <div class="select-option" onclick="window.__clicked='asc2'">En Yüksek Fiyat</div>
  </div>
HTML
c.call("browser_navigate", { url: menu_page })
f = c.call("browser_find", { text: "En Düşük Fiyat" })
exact_ok = f.include?("f1") && f.include?("En Düşük Fiyat") && !f.include?("Son 10")
check("C1 tam eşleşme öncelikli (partial değil)", exact_ok, f.lines.join(" | "))
c.call("browser_evaluate", { script: "window.__clicked=''; return 'ok'" })
c.call("browser_click", { text: "En Düşük Fiyat" })
clicked = c.call("browser_evaluate", { script: "return window.__clicked" })
check("C2 text-click doğru öğeyi vurdu", clicked.strip == "opt", "clicked=#{clicked.inspect}")

# --- D) target=_blank: yeni sekmeye otomatik geçiş + close(index) ---------
# Not: Chrome opaque origin'den (data:, file:) pop-up gezinmesini engellediği
# için gerçekçi http senaryosu testapp üzerinden koşturulur.
r = c.call("browser_navigate", { url: "http://127.0.0.1:8765/tabs" })
r = c.call("browser_click", { text: "Yeni sekmede aç" })
check("D1 otomatik sekme geçişi bildirildi", r.include?("otomatik geçildi"), r.lines.take(4).join(" | "))
check("D2 döküm yeni sekmede", r.include?("İkinci Sekme") && !r.include?("Sekme testi"), r.lines.take(4).join(" | "))
lst = c.call("browser_tabs", { action: "list" })
check("D3 2 sekme listelendi", lst.scan(/^\s?[* ]\d \S/).size == 2, lst)
r = c.call("browser_tabs", { action: "close", index: 1 })
check("D4 close(index): doğru sekme kapandı, kalan sekmeye döndü",
      r.include?("sekme kapatıldı") && r.include?("aktif: 0") && !r.include?("gizli-deger-42"),
      r.lines.take(4).join(" | "))

# --- E) wait_for type=load ------------------------------------------------
load_page = page("<h1>Yüklenen sayfa</h1>", bg_links: 1)
c.call("browser_navigate", { url: load_page })
r = c.call("browser_wait_for", { type: "load" })
check("E1 type=load çalıştı", r.include?("tam yüklendi"), r)

# --- F) browser_monitor (WebDriver BiDi): istek/yanıt yakalama ------------
c.call("browser_monitor", { action: "start" })
c.call("browser_navigate", { url: "http://127.0.0.1:8765/dynamic" })
w = c.call("browser_monitor", { action: "wait", filter: "8765", timeout: 5 })
check("F1 BiDi istek/yanıt kaydedildi", w.match?(/^(istek|yanıt) /), w.lines.take(3).join(" | "))
check("F2 BiDi yanıt kaydedildi", w.include?("yanıt 200"), w.lines.take(4).join(" | "))
chk = c.call("browser_monitor", { action: "check" })
check("F3 tamponda istek+yanıt", chk.scan(/^(istek|yanıt) /).size >= 2, chk.lines.take(4).join(" | "))
fl = c.call("browser_monitor", { action: "check", filter: "yok-boyle-bir-kayit" })
check("F4 filtre boş döner", fl.include?("eşleşen kayıt yok"), fl)
st = c.call("browser_monitor", { action: "stop" })
check("F5 monitör durduruldu", st.include?("durduruldu"), st)

# --- G) ref alanına metin: küçük moda dost yönlendirme -------------------
c.call("browser_navigate", { url: page("<button id='kaydet'>Kaydet</button>", bg_links: 1) })
g = c.call("browser_click", { ref: "Kaydet" })
check("G1 ref=metin için text: yönlendirmesi", g.include?("bir ref değil") && g.include?("text:"), g.lines.take(3).join(" | "))

# --- H) anlık toast bildirimi eylem çıktısına düşsün ---------------------
# Toast 2.5 sn sonra gizlenir; modelin ikinci snapshot'ı onu kaçırır.
# Doğru davranış: tıklama anında çıktıda "toast" satırları olmalı.
toast_page = page(<<~HTML, bg_links: 1)
  <div id='kutu' class='hb-toast-notifier-box hb-toast-notifier-type-error' role='alert'
       style='display:none;position:fixed;right:10px;top:10px;background:#fff;padding:8px'>
    Ürün geçici olarak temin edilemiyor. Daha sonra tekrar deneyebilirsiniz.
  </div>
  <div id='kutu2' class='hb-toast-notifier-box hb-toast-notifier-type-success'
       style='display:none;position:fixed;right:10px;top:60px;background:#fff;padding:8px'>
    Ürün sepete eklendi
  </div>
  <button id='kaydet'>Kaydet</button>
  <button id='kaydet2'>Kaydet2</button>
  <button id='kaydet3'>Kaydet3</button>
  <script>
    <!-- toast sayfasındaki gibi: script düğmelerden SONRA gelmeli, yoksa -->
    <!-- querySelector null döner ve onclick hiç bağlanmaz. -->
    <!-- Gerçek toast UI'ı gibi: yeni gösterim, önceki timer'ı iptal eder. -->
    <!-- (Aksi halde H1'in 2500 ms'lik timer'ı 2.6 sn'de H3'ün -->
    <!--  6000 ms'lik toast'unu kapatır.) -->
    var tmr = {};
    function tost(id, ms) { var d = document.getElementById(id); d.style.display = 'block'; clearTimeout(tmr[id]); tmr[id] = setTimeout(function () { d.style.display = 'none'; }, ms); }
    document.querySelector("#kaydet").onclick = function () { tost('kutu', 2500); };
    document.querySelector("#kaydet2").onclick = function () { tost('kutu2', 2500); };
    // H3, MCP çağrısının kendisi ~2,5 sn sürdüğü için uzun ömürlü toast kullanır:
    document.querySelector("#kaydet3").onclick = function () { tost('kutu', 6000); };
  </script>
HTML
c.call("browser_navigate", { url: toast_page })
h = c.call("browser_click", { selector: "#kaydet" })
check("H1 hata toast'u tıklama çıktısında", h.include?("toast hata:") && h.include?("temin edilemiyor"), h.lines.last(2).join(" | "))
h2 = c.call("browser_click", { selector: "#kaydet2" })
check("H2 başarı toast'u tıklama çıktısında", h2.include?("toast başarı:") && h2.include?("sepete eklendi"), h2.lines.last(2).join(" | "))
# Toast görünürken snapshot onu listeleyebilmeli (döküm seçicileri toast'ı kapsıyor).
c.call("browser_click", { selector: "#kaydet3" })
h3 = c.call("browser_snapshot", {})
check("H3 görünür toast snapshot'ta", h3.include?("temin edilemiyor"), h3.lines.take(4).join(" | "))
w = c.call("browser_wait_for", { type: "gone", selector: "[role='alert']", timeout: 6 })
h4 = c.call("browser_snapshot", {})
check("H4 toast gidince snapshot'tan düşer", !h4.include?("temin edilemiyor") && w.include?("kayboldu"), h4.lines.take(4).join(" | "))

# --- I) kompakt DOM aracı + var olmayan seçicide hızlı reddetme -----------
c.call("browser_navigate", { url: page("<button id='kaydet'>Kaydet</button>", bg_links: 1) })
d = c.call("browser_dom", {})
check("I1 dom: üst bilgi kompakt", d.include?("\"girdi\"") && d.include?("\"url\""), d.slice(0, 120))
d2 = c.call("browser_dom", { q: "button" })
check("I2 dom(q): öğeler listelenir", d2.include?("\"oge\"") && d2.include?("kaydet"), d2.slice(0, 120))

t1 = Time.now
fail = c.call("browser_click", { selector: "#hic-yok" })
sure = Time.now - t1
check("I3 var olmayan seçici hızla reddedilir (<3 sn)", sure < 3 && fail.include?("hiç bulunmadı"),
      sprintf("%.1fs | %s", sure, fail.lines.first&.strip))

# --- J) metinsiz sepete ekleme ikonu kart bağlamıyla döküme girer ---------
# HBI/Trendyol: sepete ekleme <button> değil labelsız SVG (spinnerIcon).
# Modeli scroll döngüsüne sokan budur: ikon + ürün adı + fiyat snapshot'ta.
ikon_page = page(<<~HTML, bg_links: 30)
  <ul class='productListContent-abc'>
    <li>
      <article class='productCard-module_articleXYZ'>
        <a href='/urun/technomax-hy-014'>Technomax HY-014 Kulaklık Çoğaltıcı</a>
        <div>104,80 TL</div>
        <svg class='addToCartStatus-module_spinnerIcon__QQ' width='20' height='20'></svg>
      </article>
    </li>
  </ul>
  <svg class='addToCartStatus-module_spinnerIcon__HEADER'></svg>
HTML
c.call("browser_navigate", { url: ikon_page })
js = c.call("browser_snapshot", {})
check("J1 metinsiz kart ikonu: ad + başlık + fiyat", js.include?("Sepete ekle ikonu") && js.include?("Technomax") && js.include?("104,80"), js.lines.take(6).join(" | "))
check("J2 kart dışı header ikonu atlanır", js.lines.grep(/Sepete ekle ikonu/).size == 1, "")
# J3: 30 menü linki + ürün kartı → kart öğeleri menüden ÖNCE listelenmeli
# (arabellek aşımlı sayfalarda model ürünleri görür).
check("J3 kart öğeleri menü linklerinden önce", js.index("Sepete ekle ikonu") < js.index("Zemin bağlantı 2"), js.lines.take(8).join(" | "))

# --- K) açık JS uyarısı otomatik toparlsın + metni yansılsın -------------
# Gemma HBI koşusunda uyarı açık kaldı; tüm komutlar "Tarayıcı açılamadı"
# ile çöktü ve model 17 adımı boşa yaktı.
alert_page = page(<<~HTML, bg_links: 1)
  <button id='tehlikeli' onclick="setTimeout(function(){alert('sepet uyarısı testi');},50);">Tehlikeli</button>
  <button id='k2'>Sonra</button>
HTML
c.call("browser_navigate", { url: alert_page })
uyari = c.call("browser_click", { selector: "#tehlikeli" })
check("K1 alert tıklama çıktısında işaretlenir", uyari.include?("UYARI") && uyari.include?("browser_alert"), uyari.lines.first&.slice(0, 120))
k2 = c.call("browser_click", { selector: "#k2" })
check("K2 sonraki çağrı alert'i kendiliğinden toparlar (metin saklanır)",
      k2.include?("otomatik kabul edildi") && k2.include?("sepet uyarısı testi"), k2.lines.take(3).join(" | "))

# --- L) örtülü öğeye JS tıklaması yedeği ----------------------------------
# HBI ürün kartının link örtüsü "Sepete ekle ikonu" svg'sini örter; 3 doğal
# deneme intercepted kaldıktan sonra JS tıklaması işi bitirir (gerçek olay).
ortulu_page = page(<<~HTML, bg_links: 1)
  <div style='position:relative'>
    <button id='sepetbtn' onclick="var s=document.getElementById('sonuc');s.textContent='sepete eklendi';s.setAttribute('role','alert');">Sepete ekle</button>
    <div style='position:absolute;top:0;left:0;width:100%;height:100%;z-index:10'></div>
  </div>
  <span id='sonuc'></span>
HTML
c.call("browser_navigate", { url: ortulu_page })
l = c.call("browser_click", { selector: "#sepetbtn" })
check("L1 örtülü öğe JS tıklamasıyla vurulur", l.include?("JS tıklaması") && l.include?("toast başarı") || l.include?("sepete eklendi"), l.lines.take(3).join(" | "))

c.stop
puts "\n#{PASS.size} geçti, #{FAIL.size} kaldı"
exit(FAIL.empty? ? 0 : 1)
