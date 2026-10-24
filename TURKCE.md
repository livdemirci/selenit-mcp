# selenit-mcp

> English documentation (npm page): [README.md](README.md)

[![npm](https://img.shields.io/npm/v/selenit-mcp.svg)](https://www.npmjs.com/package/selenit-mcp)
[![license](https://img.shields.io/npm/l/selenit-mcp.svg)](LICENSE)

Küçük yerel modellerle (**Gemma E4B**) verimli çalışmak için tasarlanmış,
Selenium tabanlı hafif bir tarayıcı MCP sunucusu. Playwright MCP'den esinlenilmiştir;
çıktılar kısa, öğeler `e1, e2, ...` referanslarıyla listelenir, ham HTML dökülmez.

## Nasıl çalışır

1. Chrome, `--remote-debugging-port=<port>` ile açılır ve **açık kalır** (`detach`).
2. Sonraki tüm araç çağrıları yeni tarayıcı açmaz; Selenium
   `options.debugger_address = "127.0.0.1:<port>"` ile **mevcut Chrome'a (CDP)** bağlanır.
3. Sayfa dökümü, yalnızca görünür/etkileşimli öğeleri `data-tw-ref` ile işaretleyip kısa metin üretir.
4. Oturum, tarayıcı penceresi ve çerezler araç çağrıları arasında korunur.

## İki Chrome modu

| | Managed (izole) | Existing (kullanıcının oturumu) |
|---|---|---|
| Nasıl | Ajan `--user-data-dir=artifacts/chrome-profile-<port>` ile açar | Chrome önceden `--remote-debugging-port` ile açılmış olmalı |
| Avantaj | Kullanıcının sekmelerine/çerezlerine dokunmaz | Mevcut giriş oturumu kullanılır |
| Ne zaman | Otomasyon, test, asistan sohbeti | Kullanıcının açık portal oturumunda devam eden iş |

`BROWSER_MODE=managed|existing|auto` (varsayılan `auto`: port açıksa bağlan, değilse aç).

**Port ayrımı (çakışmayı önler):**

| Tüketici | Port | Profil |
|---|---|---|
| OpenCode (bu asistan) | `19417` | `artifacts/chrome-profile-19417` |
| LM Studio eklentisi | `19419` | `artifacts/chrome-profile-19419` |
| Benchmark / replay | `19420` | `artifacts/chrome-profile-19420` |
| selenit / kullanıcı Chrome | `19218` | kullanıcının kendi profili |

Aynı porta iki sunucu bağlanmaya çalışırsa Chrome kilitlenir; bu yüzden her tüketici ayrı port kullanır.

> **Uyarı:** 19218 portu selenit'ın kullandığı porttur. Ajanın kullanıcının tarayıcısını
> sürüklemesini istemiyorsanız ayrı port kullanın (varsayılan öneri: **19419**).
> Normal açılmış bir Chrome'a sonradan güvenilir biçimde bağlanılamaz; remote-debugging şarttır.

## Araçlar (23)

| Araç | Açıklama |
|---|---|
| `browser_navigate` | Adrese git, kısa döküm döndür |
| `browser_snapshot` | Etkileşimli öğeleri listele (`e1`, `e2`, ...) |
| `browser_dom` | Kompakt DOM okuması: üst bilgi (URL/başlık/modal/uyarı ~400 kar) veya `q` ile öğe listesi — snapshot'tan hafif, "DOM hızlıysa kullan" için |
| `browser_click` | `ref`, CSS `selector` veya görünen `text` ile tıkla |
| `browser_find` | Metne göre öğe bul, tıklanabilir ref döndür (uzun sayfalar) |
| `browser_read` | Görünür sayfa metnini oku (özet/çeviri) |
| `browser_type` | Alana yaz (`submit: true` → Enter) |
| `browser_select` | Açılır listeden seçenek seç |
| `browser_alert` | JS uyarısını oku/kapat (`text` okur+kapatır, `peek` açık bırakır) |
| `browser_scroll` | Sayfayı kaydır (down/up/top/bottom) |
| `browser_frame` | iframe içine gir / ana sayfaya dön |
| `browser_upload` | Dosya yükleme alanına yerel yol ver |
| `browser_hover` | Öğenin üzerine gel (menüler) |
| `browser_press_key` | enter, tab, escape, arrowdown ... |
| `browser_resize` | Pencere boyutunu ayarla (tutarlı görünüm için) |
| `browser_monitor` | WebDriver BiDi ağ monitörü: istekler/yanıtlar/konsol (`action: start/check/wait/stop`, `filter`) |
| `browser_wait_for` | Explicit wait: metin, seçici, URL, kaybolma, öğe sayısı veya indirme (`type` ile) |
| `browser_screenshot` | PNG kaydet, yolu döndür |
| `browser_evaluate` | Sayfada JS çalıştır (sonuç kısaltılır) |
| `browser_history` | back / forward / reload |
| `browser_tabs` | list / switch / close |
| `browser_status` | Bağlantı durumu |
| `browser_close` | Oturumu kapat |

Küçük modeller için güvenlik ağları:
- **Döngü uyarısı:** aynı araç+argüman 3. kez gelirse çalıştırılmaz, uyarı döner.
- **Anlaşılır hatalar:** "ref her snapshot'ta yenilenir", "öğe kapalı", "uyarı açık" gibi ipuçları;
  select alanına yanlış etiket verilince `bu öğe bir <select> değil, <button>` der, geçersiz
  CSS seçicide örnekli ipucu döner.
- **Uyarı temizliği:** `navigate` açık JS uyarısını kapatır; `snapshot`/`read` açık uyarıyı bildirir.
- **Shadow DOM:** döküm açık shadow root'ları gezer; ref çözümleme JS ile yapılır (Selenium CSS araması shadow'a girmez).
- **Modal odağı:** `role=dialog` / `aria-modal` açıkken yalnızca modal içeriği listelenir; arka plan düğmeleri karışmaz. 2026-10: role taşmayan modallar da (`class*="modal|dialog|popup"` + görünüp ekran merkezini kapatma) yakalanır — Trendyol'un `.modal-container`'ı gibi.
- **Engelleyici overlay önceliklendirmesi:** çerez bandı, bildirim kutusu gibi `position:fixed` + yüksek z-index katmanlarının içeriği ilk MAX'e girer (2026-10: OneTrust düğmeleri döküm dışında kalıyordu).
- **Satır bağlamı:** tablo satırındaki düğmeler `Düzenle | 10 · Ada Lovelace · Londra` gibi ayırt edici bağlamla gösterilir.
  2026-10: **ürün kartı bağlamı** da eklendi — kart içinde tekrar eden `Sepete Ekle` düğmeleri
  `Sepete Ekle | CEPFİT Boostar ... · 57,97 TL` biçiminde ayırt edilebilir (kart başlığı + fiyat).
- **Explicit wait:** tıklama/yazma/seçme/iframe/indirme işlemleri `Selenium::WebDriver::Wait` ile
  görünürlük, tıklanabilirlik, URL, metin veya dosya durumu bekler. Sabit `sleep` yoktur; implicit
  wait kapalıdır (`0`). Zaman aşımı, neyin beklendiğini söyleyen Türkçe bir hata döndürür.
- **Lazy load:** `browser_find` bulamazsa sayfayı sona kaydırır, DOM/metin büyümesini explicit
  bekler ve arar (en fazla `BROWSER_MCP_LAZY_SCROLLS`, varsayılan 8). `browser_scroll` de yeni
  içerik geldiyse bunu bildirir.
- **İndirme:** `browser_wait_for(type: "download", text: "rapor.pdf")`, Chrome'un
  `chrome://downloads` sayfasındaki `downloads-manager` shadow root'undan durumu okur;
  `IN_PROGRESS` bitene kadar bekler ve tamamlanan dosyanın yolunu döndürür. Eski geçmişte
  duran ama dosyası silinmiş bir kayıt başarı sayılmaz; yeni indirme veya dosyası gerçekten
  var olan tamamlanmış kayıt beklenir. Managed modda indirmeler `artifacts/downloads-<port>`
  altına gider.
- **Tıklama sonrası bekleme:** URL değişimi explicit wait ile kısa süre yoklanır; navigasyon
  yoksa bekleme uzamaz. Yeni sekme açıldıysa doğru 0-tabanlı indeks önerilir; birden fazla
  sekme varken snapshot başına `SEKMELER` satırı eklenir.

### `browser_wait_for` türleri

| `type` | Ne bekler | Alanlar |
|---|---|---|
| `text` (varsayılan) | Sayfa gövdesinde metin | `text` |
| `selector` | CSS seçici görünür olana kadar | `selector` |
| `url` | Adres parçası | `value` veya `text` |
| `gone` | Seçici görünmez olana kadar | `selector` |
| `count` | En az N görünür öğe | `selector`, `value` |
| `load` | `document.readyState == complete` (tam yüklenme) | — |
| `download` | Chrome indirme durumu + dosya | `text` (dosya adı parçası) |

## Yetki politikası ve denetim

```bash
BROWSER_MCP_ALLOWED_HOSTS="example.com,portal.sirket.com"   # boş = tümü
BROWSER_MCP_REQUIRE_APPROVAL=true                            # riskli eylemde onay şart
BROWSER_MCP_ALLOW_DATA=true                                  # data: URL'lerine izin (varsayılan true)
```

`BROWSER_MCP_REQUIRE_APPROVAL=true` iken silme/ödeme/gönderme gibi etiketli düğmeler
`confirm=true` olmadan çalışmaz; model kullanıcıdan onay istemek zorunda kalır.

Her araç çağrısı `artifacts/audit-YYYYMMDD.jsonl` dosyasına yazılır
(parola/ token alanları maskelenir, uzun metinler kısaltılır).

## Kurulum / çalıştırma

### Gereksinimler

- Ruby 3.2+ (Ruby'nin herhangi bir kurulumu — rbenv, Homebrew vb.)
- Google Chrome
- Ruby bağımlılığı: `selenium-webdriver` (Gemfile'da tanımlı)

### Tek komutla kurulum

**Tek satır** — Ruby, gem ve Chrome'u kontrol eder/kurar, MCP kaydını yazar:

```bash
curl -fsSL https://raw.githubusercontent.com/livdemirci/selenit-mcp/main/install.sh | bash
```

Ruby 3.2+ zaten varsa (ya da yalnızca npm tercih ediliyorsa):

```bash
npx -y selenit-mcp setup lmstudio --install     # ruby+gem+Chrome kontrol/kurulum + config
npx -y selenit-mcp doctor                       # ruby/gem/Chrome/config/port raporu
```

`--install`, eksikse `brew install ruby` / `gem install selenium-webdriver` dener; Chrome için
`--install-chrome` ekleyin. `--install` vermeden `setup` yalnızca config yazar ve eksikleri söyler.

**npm (npx) ile** (Ruby kaynakları paketle gelir):

```bash
gem install selenium-webdriver        # gereksinim (pakete gelmez)
npx selenit-mcp                        # stdio MCP sunucusu — test: hazır satırı basar
```

MCP istemcisi config'inde `"command": "npx", "args": ["-y", "selenit-mcp"]` doldurun;
Ruby'yi açıkça göstermek için env'e `"SLENIT_RUBY"` eklenebilir.

**Kaynak koddan:**

```bash
git clone https://github.com/livdemirci/selenit-mcp.git
cd selenit-mcp
gem install selenium-webdriver
ruby bin/selenit-mcp        # stdio MCP sunucusu — test: hazır satırı basar
```

### MCP istemcilerine bağlama

Claude Desktop / herhangi MCP istemcisi (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "selenit-browser": {
      "command": "ruby",
      "args": ["/YOL/selenit-mcp/bin/selenit-mcp"],
      "env": { "BROWSER_MCP_PORT": "19420", "BROWSER_MCP_MAX_ELEMENTS": "40" }
    }
  }
}
```

OpenCode (`~/.config/opencode/opencode.json`):

```json
"selenit-browser": {
  "type": "local",
  "command": ["ruby", "/YOL/selenit-mcp/server.rb"],
  "environment": { "BROWSER_MCP_PORT": "19417" }
}
```

### Ortam değişkenleri

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `BROWSER_MCP_PORT` | `19218` | CDP portu (19420 önerilir) |
| `BROWSER_MODE` | `auto` | `managed` / `existing` / `auto` |
| `BROWSER_MCP_PROFILE_DIR` | `artifacts/chrome-profile-<port>` | Managed profil dizini |
| `BROWSER_MCP_MAX_ELEMENTS` | `40` | Dökümde en fazla öğe (Gemma için 20–40) |
| `BROWSER_MCP_HEADLESS` | `false` | Headless managed tarayıcı |
| `BROWSER_MCP_WAIT` | `10` | Explicit wait varsayılan zaman aşımı (saniye) |
| `BROWSER_MCP_LAZY_SCROLLS` | `8` | `browser_find` için lazy-load kaydırma denemesi |
| `BROWSER_MCP_DOWNLOAD_DIR` | `artifacts/downloads-<port>` | Managed indirme klasörü |
| `BROWSER_MCP_SCREENSHOT_DIR` | `./screenshots` | Ekran görüntüsü klasörü |
| `BROWSER_MCP_ARTIFACT_DIR` | `./artifacts` | Denetim kaydı klasörü |
| `BROWSER_MCP_ATTACH_TIMEOUT` | `13` | Attach üst sınıfı; takılırsa izole Chrome kapatıp yeniden başlatır |
| `BROWSER_MCP_FAILFAST` | `1.25` | Sayfa yüklüyse olmayan seçiciyi bu sürede reddet |
| `BROWSER_MCP_TOAST_WAIT` | `0.6` | Eylem sonrası toast toplama penceresi ("0" kapatır) |

### Test / doğrulama

```bash
python3 testapp/server.py 8765 &        # test sayfaları (bench gereksinim)
ruby smoke_test.rb                      # 32/32 kontrol
ruby replay.rb sepet                    # senaryo tekrarı (gerçek site)
```

## OpenCode kaydı

```json
"selenit-browser": {
  "type": "local",
  "command": [
    "/Users/mustafalivdemirci/.rbenv/versions/3.4.8/bin/ruby",
    "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp/server.rb"
  ],
  "environment": {
    "BROWSER_MCP_PORT": "19417",
    "BROWSER_MCP_MAX_ELEMENTS": "40"
  }
}
```

## LM Studio kaydı

Paket kendini config'e ekleyebilir (mutlak ruby yolunu ve paket yolunu çözer, mevcut dosyayı
`mcp.json.backup-<zaman>` olarak yedekler):

```bash
npx -y selenit-mcp setup lmstudio              # varsayılan port 19419
npx -y selenit-mcp setup lmstudio --port 19418 --max-elements 20
npx -y selenit-mcp setup print                 # yalnızca JSON bas
```

Sonra LM Studio'da **🔌 Integrations**'ı kapat-aç veya uygulamayı yeniden başlat.

Elle yapmak isterseniz `~/.lmstudio/mcp.json` (mutlak ruby yolu + `cwd` kullanın; LM Studio
GUI'den başlatıldığında rbenv shim'i PATH'te olmayabilir):

```json
{
  "mcpServers": {
    "selenit-browser": {
      "command": "/Users/mustafalivdemirci/.rbenv/versions/3.4.8/bin/ruby",
      "args": ["/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp/server.rb"],
      "cwd": "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp",
      "env": { "BROWSER_MCP_PORT": "19419", "BROWSER_MCP_MAX_ELEMENTS": "40" }
    }
  }
}
```

Not: Aynı makinede birden çok tarayıcı MCP eklentisi varsa her biri ayrı port
kullanmalı (ör. testwise-browser 19418, selenit 19419); aksi halde ikisi aynı
Chrome'a bağlanıp sekmeleri çiğner.

LM Studio'da sohbet kutusunun solundaki **🔌 Integrations** düğmesinden açılıp kapatılır.
Ayar değişikliği LM Studio yeniden başlatılınca (veya yeni sohbet oturumunda) yüklenir.

## Ölçüm (benchmark)

`benchmark.rb`, LM Studio'nun yerel OpenAI uyumlu API'sine araç şemalarını verir, modelin
ürettiği çağrıları gerçek MCP sunucusunda çalıştırır ve sonucu sayfa durumuna göre doğrular.

```bash
ruby benchmark.rb                 # tüm görevler
ruby benchmark.rb deep select     # seçili görevler
BENCH_MODEL=google/gemma-4-e4b BENCH_MAX_STEPS=10 ruby benchmark.rb
# Düşünmeli şablonlu modellerde (Gemma 4 "Thinking Process") düşünme kapalı koşturmak:
BENCH_THINKING=0 BENCH_MAX_TOKENS=1600 ruby benchmark.rb sepet
```

Temel görevler: `link, form, wiki, hn, deep, read, select, alert, stale`
(bağlantı tıklama, form doldurma, arama, listeleme, metne göre bulma, okuma/özetleme,
select, JS uyarısı, sayfa değişiminden sonra ref kullanımı).

Gerçek site görevi: `sepet` — Trendyol'da arama → en düşük fiyat sıralaması →
sepete ekle → sepette fiyat doğrulama. Gemma E4B (düşünme kapalı) ile **1/1 geçti**
(13 adım, ~439 sn); kaydı `replay.rb sepet` ile modelsiz **~30 sn**'de oynatılır.

Zor senaryolar (`testapp/` — yerel uygulama, port 8765):

| Görev | Ne test eder |
|---|---|
| `login` | oturum açma (form + yönlendirme + localStorage) |
| `filter` | tabloda arama, satır düzenleme modalı, select, kaydetme |
| `frame` | iframe içine gir, form doldur, ana sayfaya dön |
| `shadow` | shadow DOM içindeki input + buton |
| `upload` | dosya yükleme alanına yerel dosya |
| `newtab` | `target=_blank` sekme açma ve sekmeye geçme |
| `dynamic` | gecikmeli içerik + sonsuz kaydırma |
| `download` | PDF indirmeyi bekleme ve dosya adını doğrulama |

```bash
python3 testapp/server.py 8765 &   # zor senaryo uygulaması
ruby benchmark.rb login filter frame shadow upload newtab dynamic download

# Benchmark Chrome'u 19420'de açık bırakır; aynı tarayıcıda doğrulama:
BROWSER_MCP_PORT=19420 rspec spec/generated
BENCH_MCP_PORT=19420 ruby replay.rb filter
```

### Ölçülen sonuç (Gemma E4B, google/gemma-4-e4b, 20 araç, max_tokens 800, 17 görev)

**17/17 görev geçti** (görev başına 1–7 adım, 22–78 sn; toplam ~13 dk):

| Görev | Adım | Süre | Görev | Adım | Süre |
|---|---|---|---|---|---|
| link | 2 | 28s | login | 4 | 43s |
| form | 3 | 52s | filter | 5 | 69s |
| wiki | 4 | 46s | frame | 7 | 76s |
| hn | 1 | 22s | shadow | 4 | 54s |
| deep | 3 | 30s | upload | 4 | 64s |
| read | 2 | 36s | newtab | 5 | 68s |
| select | 2 | 25s | dynamic | 5 | 78s |
| alert | 3 | 32s | stale | 3 | 35s |
| download | 3 | 34s | — | — | — |

> Not: Tam benchmark koşusundan sonra `browser_type` için stale-element retry eklendi;
> wiki tekrarı **2 adım / 23,6 sn** oldu. 17 spec ve 17 replay final kodla yeniden **17/17** geçti.

Yol boyunca düzeltilen gerçek zayıflıklar: ref → kalıcı seçici dönüşümü, `execute_script`
gövdesinde `return` zorunluluğu, sabit uyku yerine **explicit wait**, tıklama/yazma sonrası
koşul beklemesi, stale input yeniden deneme, lazy-load taraması, eski indirme geçmişini yok sayan indirme beklemesi,
uyarı temizliği, shadow DOM ref çözümleme, modal odağı, satır bağlamı, dinamik içerik için
bekleme ipucu, iframe için ref/index kabulü, görevler arası iframe bağlamı sıfırlama,
çoklu sekmede `SEKMELER` ipucu ve port izolasyonu.
2026-10 koşusu (Trendyol senaryosu) yakalanıp düzeltilenler: role taşımayan modal tespiti,
engelleyici overlay'lerin döküm önceliği, metin eşleştirmede **tam eşleşme önceliği**,
tıklanabilir özel dropdown seçeneklerinin (`.select-option` gibi) döküme girmesi,
`browser_tabs(close, index)`'in index'i doğru kullanması, `target=_blank` sonrası otomatik
sekme geçişi, araç çağrısı işlemlerine üst sınır (`BROWSER_MCP_OP_TIMEOUT`) ve `browser_resize`
+ `wait_for(type: load)` araçları.
2026-10-23 koşuları (Trendyol sepet senaryosu):
- **Ref alanına metin:** ref yerine etiket metni yazıldıysa (Gemma koşusunda `ref="Sepete Ekle"`)
  hata artık yönlendirir: "bir ref değil; text: parametresini kullan" (smoke G1 ile testli).
- **Ölü pencere toparlaması:** `ensure_session` artık bayat sürücüyü provala (`window_handle`)
  ve "no such window" da bir kez tamamını yeniden kurar — ilk `browser_navigate` artık
  kendiliğinden iyileşir.
- **Ürün kartı bağlamı:** snapshot'ta kart içindeki `Sepete Ekle` düğmeleri
  `Sepete Ekle | CEPFİT ... · 57,97 TL` gibi başlık+fiyatla ayırt edilir.
- **WebDriver BiDi entegrasyonu:** sürücü `web_socket_url = true` ile kurulur; yeni
  `browser_monitor` aracı `network.beforeRequestSent` / `network.responseCompleted` /
  `log.entryAdded` (konsol) olaylarını tamponlar (maks ~200 kayıt, Mutex'li).
  Not: Selenium gem'inin `BiDi::Network#on` sarmalayıcısı bozuk (geçersiz imza) — doğrudan
  `session.subscribe([events])` + `add_callback` kullanılır.
Doğrulama: `smoke_test.rb` 23/23 ve 18/18 replay (17 hız senaryosu + gerçek site `sepet`).
Benchmark'ta düşünmeli şablonlu modeller için `BENCH_THINKING=0` — Gemma E4B'de
adım başı maliyet ~2,3× düştü (13 adımda sepet görevi 1/1 geçti).

Ortam değişkenleri (alert/attach kurtarma, 5. tur):
- `BROWSER_MCP_ATTACH_TIMEOUT` (varsayılan 13): attach üst sınırı; askıda
  kalırsa yalnızca izole profillı Chrome kapatılır ve auto modda sonraki
  denemede taze Chrome ile ~14 sn'de toparlanır.
- Açık JS uyarısı `click`/`type`'ı çarparsa alert kabul edilip eylem bir kez
  yeniden denenir; metin bir sonraki snapshot başında "not: … otomatik kabul
  edildi (metin: …)" ile modele yansır.

2026-10-23 (2. tur, Hepsiburada senaryosundan çıkanlar):
- **Anlık toast yakalama:** eylem (click/type/hover/press_key) çıktısına `harvest_toasts`
  eklendi — 0,6 sn açık beklemeyle (`BROWSER_MCP_TOAST_WAIT`, "0" kapatır) başarı/hata
  toast'ları "toast hata: ... / toast başarı: ..." biçiminde toplanır ve aynı metin
  tekrar basılmaz (`@last_toast_sig`). Neden: HBI toast'ları ~2,5 sn'de DOM'dan
  kalkıyor; modelin ikinci snapshot'ını kaçırıyor ve model döngüye giriyordu.
- **Snapshot'a toast öğeleri:** döküm q'suna `[role=alert],[role=status],[class*="toast" i]`
  eklendi. HBI toast'ları role taşımaz (`hb-toast-notifier-*`) — sınıf taraması zorunlu.
- **Stale öğe için tek yeniden deneme:** `click` bayat öğe hatasında
  (StaleElementReferenceError) ref'i bir kez yeniden çözer (`@click_retry`).
  Dikkat: Selenium 4.45'te `ObsoleteElementError` sabiti yok — kullanılmamalı.
- **HBI keşif notları:** arama `input[aria-label='Site içinde ara']` — dikkat! "site arama
  inputu" hafif sayfa'da sațe bir kopya ile gelmiş olabilir; yazmadan önce tıklamak
  gerekir; sıralama `div[class*='dropdown-cf']` → "En düşük fiyat" →
  `siralama=artanfiyat`; sepete ekleme ikonu `<button>` değil labelsız SVG —
  `[class*='productListContent-'] li article svg[class*='spinnerIcon']` ile bulunur;
  en ucuzda ilk organik kart stoksuz olabilir ("geçici olarak temin edilemiyor" toast)
  → ilk satılabilir ürüne geç.
- **`hepsi` görevi:** `tasks.rb`'de HBI senaryosu (benchmark/replay için).

### 3. tur: çoklu e-ticaret antrenmanı (`egitim.rb`) ve maliyet tablosu

`ruby egitim.rb [max_elements]` — n11, Amazon.tr ve Çiçeksepeti'nde karmaşık akış
koşar; her adımın **ms** ve **karakter** boyutunu ölçer. Aynı "durum okuma"
snapshot (ref'li) ve `browser_dom` (sade JSON) olarak **ikili** koşulur.

2026-10-23 bulguları (n11 + amazon + çiçeksepeti):

| Bulgu | Düzeltme |
|---|---|
| n11 arama inputu id/name'siz (`searchData` kaldırılmış) | `input[placeholder*='ara' i]` + tıkla-yaz |
| n11'de yanlış seçici **10 sn** (wait_timeout) yaktı — koşumun %40'ı | **fail-fast:** seçici DOM'da hiç yoksa ve sayfa yüklüyse `BROWSER_MCP_FAILFAST` (1,25 sn) içinde reddet; adım 10 sn → 35 ms |
| Amazon arama kartları artık `data-component-type=s-search-result` DEĞİL; `div[data-asin]` (133 kart) ve ilkl sponsored redirect (HBI reklâm kartı gibi) | organik seçim: `div[data-asin]:not([data-asin='']) a[href^='https://www.amazon.com.tr/dp/']` — sepete ekleme `#add-to-cart-button` |
| Çiçeksepeti "Bir dakika lütfen..." anti-bot bantı | `browser_dom` 2 ms'de tespit; senaryo ATLANDI raporluyor |
| DOM okuma 1-79 ms / 141-867 kar; snapshot 8-45 ms / 1058-3288 kar | durum soruları için `browser_dom`; tıklama/hedefleme adımları için snapshot ref'leri |

max_elements etkisi: 40 → snapshot ort 2494 kar; **20 → 1116 kar** (hız aynı).
Hafif koşum için BROWSER_MCP_MAX_ELEMENTS=20 önerilir; amazon listesinde 867 kar'lık
`browser_dom(q=...)` fiyat/ad listesi için yeterli.

### 4. tur: "Sepete ekle ikonu" kart bağlamı (Gemma `hepsi` koşusundan)

İlk Gemma `hepsi` koşusu 0/1 oldu, çünkü: HBI'da sepete ekleme `<button>` değil
**metinsiz SVG** (`spinnerIcon`) — snapshot'ta hiç görünmüyordu; model 6. adıma
kadar harikaydı (arama+sıralama ✓), sonra 13 adım scroll/read döngüsüne girdi.

Düzeltme (`snapshot.js`):
- Metinsiz `svg[class*="spinnerIcon" i] / addToCart` ikonlarına `Sepete ekle ikonu`
  adı + kart bağlamı veriliyor: `e2 svg Sepete ekle ikonu | Technomax HY-014 … · 104,80 TL`
- Bu ikonlar yalnızca kart (`article/li/[class*=card]`) içinde listelenir; header
  spinner'ları atlanır.
- Kart bağlamı seçicisi `[class*="productCard"]` ile genişletildi (HBI kartları).

Doğrulama: smoke **31/31** (J1 ikon+başlık+fiyat, J2 kart dışı ikon atlama,
J3 kart-önce, K1/K2 alert kurtarma), replay 18/18 (58,4 sn). Gemma `hepsi`
2. koşum: adım 6'ya kadar çalıştı (arama kutusuna tıklandı), sonra sayfada bir
JS uyarısı açıldı → **tüm komutlar "Tarayıcı açılamadı" ile çöktü** (17 adım
boşa) → 5. tur düzeltmeleri: aşağıda.

### Gemma `hepsi` koşum maratonu (6 deneme → PASS)

| Koşum | Durum | Ana engel | Çare |
|---|---|---|---|
| 1 | FAIL (0/1) | snapshot'ta ikon hiç görünmüyordu → 13 scroll/read döngüsü | 4. tur: kart-ikonu |
| 2 | FAIL | JS alert tüm komutları öldürdü ("Tarayıcı açılamadı", 17 adım boşa) | 5. tur: alert kurtarma + attach timeout |
| 3 | FAIL (26 adım) | "Sepete ekle ikonu" svg'si 4× click intercepted (ürün link örtüsü) | 6. tur: JS click yedeği |
| 4 | FAIL (LM) | Net::ReadTimeout 60 sn default → koşum çekip gitti, 0 adım raporlandı | 7. tur: 120 sn + 3 deneme + kısmi trace |
| 5 | FAIL (26 adım) | *koşumdan bağımsız:* benim smoke koşumum aynı Chrome'a girip adım 22-26'yı zehirledi (+ sessiz e14 ikonu) | yasak kural + 7. tur ata-DIV click |
| **6** | **PASS (13 adım, 528 sn)** | — | `scenarios/hepsi.json` yazıldı |

Final cevap: `ürün | Apple Airpods 4. Nesil (MXP63TU/A) | 6.365,00 TL | eşleşme: evet | toast: okuma`,
final URL `https://checkout.hepsiburada.com/sepetim`. Akış: navigate → arama
(click→type, 1 not-interactable atlandı) → sıralama aç → **En düşük fiyat** →
organik kart ikonları → sepet → fiyat doğrulama.

### 5. tur: JS uyarısı kurtarma + attach kilitlenmesi (Gemma `hepsi` 2. koşumdan)

İki zincirleme kilitlenme bulundu ve çözüldü:

1. **Açık JS uyarısı tüm komutları bloklar.** `click`/`type` sırasında uyarı
   açılırsa artık **kendiliğinden kabul edilip eylem bir kez yeniden denenir**;
   karşılık yield: `UYARI: tıklama bir JS uyarı penceresi açtı ve kabul
   edildi (metin). Tıklama bir kez yeniden denendi; …` (eskisi 90 sn askıydı).
   Uyarı metni `@alert_recovered`'da saklanır ve bir sonraki snapshot başında
   `not: … otomatik kabul edildi (metin: …)` olarak modele yansır — Gemma
   karanlıkta kalmıyor.
2. **Önceki oturumdan kalan uyarı, YENİ oturum açmayı bile kilitler.**
   chromedriver attach aşamasında sonsuz askıda kalır (gözlem: 90 sn'de
   "execution expired"). `attach` artık `BROWSER_MCP_ATTACH_TIMEOUT` (13 sn)
   ile sarmalı; askıda kalırsa **yalnızca servera ait izole profillı Chrome**
   (`chrome-profile-PORT`) kapatılır ve auto modda sonraki denemede taze
   başlatılır. Kurtarma toplam ~14 sn (eskisi: kalıcı 90 sn+).
   Kullanıcının kendi Chrome'una pgrep+ps profil filtresiyle dokunulmaz.
3. Smoke yeni **K bölümü** bu iki davranışı ölçer: K1 uyarı-Nazik mesaj,
   K2 sonraki çağrının kendiliğinden toparlanması. Smoke artık **31 madde**.

### 6. tur: örtülü öğeye JS tıklaması yedeği (Gemma `hepsi` 3. koşumdan)

3. koşum büyük adım attı: uyarı kumbarası çalıştı, adım 1-12 sorunsuz
(arama → "En düşük fiyat" sıralaması ✓). Kalan tek engel: "Sepete ekle
ikonu" svg'sine tıklama **4 kez `element click intercepted`** kaldı — HBI
ürün kartının görünmez link örtüsü ikonu örter; scrollIntoView + 3 doğal
deneme de çözmedi.

Düzeltme (`click_element`): 3 doğal denemeden sonra **gerçek click olayını
JS ile tetikle** (`el.click()` — hit-test bypass). Çıktıya net not:
`not: öğe bir katmanla kapalıydı; JS tıklaması kullanıldı.`
Doğrulama: smoke **32/32** (yeni L1: örtülü düğmeye JS tıklaması), replay
18/18 (57,5 sn).

### 7. tur: sessiz sepet ikonu + LM-studio direnci (Gemma `hepsi` 5. koşumdan)

Koşum 5 "0 adım/0 sn" bıraktı — iki ayrı ders:

1. **LM Studio okuma timeouts sürükledi koşumu:** `Net::HTTP.post` varsayılan
   60 sn read timeout; istisna `run_task`'ı yıktı (audit'te 20 adım vardı,
   rapor "0 adım" gösterdi). Düzeltme: LLM çağrısı açık client (open 10 sn /
   read 120 sn) + geçici ağ hataları için 3 deneme; `llm.chat` istisnası
   koşumu yıkmaz — `trace << "LM hatası"` ile kısmi sonuç raporlanır.
2. **"Sessiz" sepet-ikonu kökunuzun îzeline ulaştı.** Elle teşhis (LM boşta):
   - Hapşıran handler: HBI'da sepete ekleyen element `div.price-module_priceAreaRoot[role=button]`;
     `svg[class*=spinnerIcon]` yalnızca dekor. Diğer yandan `SVGElement.click()`
     YOKTUR — `arguments[0].click()` svg'de sessiz no-op. Intercept yedeği
     artık `dispatchEvent(new MouseEvent('click', {bubbles:true}))` ile
     yayınlanır ve sepet-ikonu svg'lerde **tıklanabilir ata**
     (`closest('button,[role=button]')`) hedeflenecek.
   - Elle doğrulama: ata-DIV tıklamasını diğerlerirken "Ürün sepete eklendi"
     toast'ları tekrar geldi, /sepetim rozetinde 8 ürün birikti ✓.
   - `click` çıktısı, sepet ikonuna basıldı ama toast gelmezse uyarır:
     `not: ... toast GELMEDİ — sıradaki 'Sepete ekle ikonu' ref'ine geç`
     (aynı ref'e tekrar tıklama döngü hatası); görev prompt'una da 6-a adım
     eklendi.
3. *(yöntem dersi)* Benchmark sürerken aynı Chrome'u kullanan smoke/replay
   koşturmak Yasak: Gemma'nın adım 22'yi smoke sayfalarımda geçirmesi bu
   yüzden benim hatamdı. Smoke'a baştan `browser_tabs close_others` temizliği
   eklendi (D2-D4 deterministik oldu).

Doğrulama: smoke **32/32**, replay 18/18 (57,9 sn).

## Keşif → dondurma → tekrar (selenit sinerjisi)

LLM her koşuda para/zaman harcamasın diye başarılı keşif **deterministik** hale getirilir:

1. `benchmark.rb` başarılı görevde adımları ve her öğe için kalıcı CSS seçiciyi
   `scenarios/<görev>.json` dosyasına yazar (shadow DOM için `shadow::host||inner`).
2. `replay.rb` aynı adımları **model olmadan** tekrar oynatır ve aynı kontrolü uygular.
3. `export_rspec.rb` aynı senaryoyu Selenium + RSpec spec'ine çevirir; selenit'da
   **F11 (Run Selected Scripts Against Current Browser)** ile veya CI'da `rspec` ile koşar.
   Üretilen spec Zhan'ın **Maintainable Automated Test Design** yaklaşımını izler:
   - ham Selenium sözdizimi, framework yok;
   - her sayfa için **Page Object** (seçici değişince tek yer);
   - `spec/support/tw_helper.rb` içinde ortak **explicit wait**, `find_deep`, `try_for`;
   - `try_for(5)` ile AJAX/gecikmeli assertion tekrarı; sabit `sleep` yok;
   - test bağımsızlığı için her test kendi navigasyonunu yapar, frame/alert sızıntısı temizlenir;
   - `browser_wait_for(type: download)` adımı dosya sistemi beklemesine çevrilir.

```bash
ruby replay.rb filter                 # LLM'siz tekrar
ruby export_rspec.rb filter           # spec/generated/filter_spec.rb
BROWSER_MCP_PORT=19419 rspec spec/generated/filter_spec.rb
```

Bu üçlü, Playwright MCP'de olmayan şeyi verir: **keşfi bir kez yap, sonra sıfır maliyetle
tekrar et ve regresyon testine dönüştür.** UI değişince test kırılır; ajan yalnızca kırılan
adımı yeniden keşfeder.

**Ölçüm:** 18 senaryonun tamamı `replay.rb` ile modelsiz geçti; tek koşumda toplam **~60 sn**
(ağ koşullarına göre; süreç başına ~0,6–4 sn, gerçek site `sepet` 16 sn, LLM yok).
LLM'li keşif aynı görevlerde 22–78 sn sürüyor. Üretilen 17 spec `rspec` ile **6,7 sn**'de
17/17 geçti. Benchmark Chrome'u 19420'de bırakır; spec/replay aynı tarayıcıya bağlanır.
Sekme geçişleri indeks yerine URL parçasıyla kaydedilir (`tab_url`), böylece sekme sırası
değişse de replay doğru sekmeye gider; replay başında fazla sekmeler kapatılır.

### Hızlı doğrulama (smoke)

Yeni davranışların ucuz doğrulaması: `smoke_test.rb` (Chrome 19420'de, testapp 8765'te).
Rol taşmayan modal yakalanması, overlay önceliği, tam eşleşme önceliği + tıklama,
`target=_blank` otomatik geçiş, `close(index)`, `type=load`, BiDi `browser_monitor`
(istek/yanıt yakalama, filtre, durdurma), `ref=metin` yönlendirmesi,
**eylem anında toast toplama** (hata/başarı; görünürken snapshot'ta da var,
kaybolunca çıkar), **kompakt `browser_dom` aracı**, **var olmayan seçicide
hızlı reddetme (<3 sn)**, **metinsiz sepete-ekleme ikonuna kart bağlamı**,
**ürün-kart önceliği**, **JS uyarısı otomatik kurtarma**, **örtülü öğeye
JS tıklaması yedeği** — 32 kontrol:

```bash
python3 testapp/server.py 8765 &
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=19420 \
  --user-data-dir="artifacts/chrome-profile-19420" --no-first-run --new-window about:blank &
ruby smoke_test.rb          # 32/32 kontrol
```

Notlar:
- Replay, tarayıcı profilindeki oturum durumunu (çerez/localStorage) kullanır. Panel gibi
  oturum gerektiren senaryolardan önce `ruby replay.rb login` çalıştırın veya tarayıcıyı
  oturum açmış halde bırakın.
- Seçiciler kayıt anındaki DOM'a göre üretilir; sayfa yapısı değişirse replay kırılır —
  bu istenen davranıştır (kırılan adımı ajana yeniden keşfettirir).

Not: Benchmark kendi portunu (`BENCH_MCP_PORT`, varsayılan 19420) kullanır; kullanıcının
açık tarayıcısına dokunmaz. Model yavaşsa ilk çağrı 20–40 sn sürebilir.

## Zhimin Zhan makalelerinden uygulananlar

- **Explicit wait / “auto-waiting” tartışması:** sabit `sleep` ve örtük bekleme yerine koşul
  bekleyen `Selenium::WebDriver::Wait`; hata erken ve açıklayıcı.
  ([Selenium is Flaky, Part 2](https://zhiminzhan.medium.com/expose-a-common-lie-selenium-is-flaky-part-2-clarify-automated-waiting-bb8469e92f13))
- **Lazy load:** öğe yoksa sona kaydır → içerik artışını bekle → tekrar ara.
  ([Lazy Load](https://courtneyzhan.medium.com/automated-testing-elements-on-a-lazy-load-page-with-selenium-webdriver-d8ff4d2ec166))
- **İndirme:** `chrome://downloads` içindeki `downloads-manager` shadow root'undan
  `state` oku; `IN_PROGRESS` bitene kadar bekle.
  ([Wait for File Download](https://agileway.substack.com/p/case-study-wait-for-file-download))
- **Locator chaining:** tablo satırını `data-id` ile sabitle, satır içindeki düğmeyi ona göre seç;
  bağlantılarda sıra numarası yerine `a[href="..."]` kullan.
  ([Locator Chaining](https://zhiminzhan.medium.com/case-study-locator-chaining-in-selenium-webdriver-b0bbcb51d640))
- **Tam eşleşme önceliği (By.linkText > By.partialLinkText ilkesi):** `browser_click(text:)`,
  `browser_find` önce tam eşleşmeye bakar; partial yalnızca tam eşleşme yokken kullanılır
  ('En Düşük Fiyat' araması ürün etiketindeki 'Son 10 Günün En Düşük Fiyatı' metnine yanlış
  vurup ürün sayfası açmıştı).
- **Özel açılır menü seçenekleri:** tıklanabilir `div/li[class*="option|menu-item"]` öğeleri
  döküme ve metin taramasına girer (role taşımayan `.select-option` gibi öğeler için).
- **`browser_tabs(action:"close", index:)` artık index'i kullanır** ve aktif sekme kapatıldıysa
  kalan ilk sekmeye geçip döküm basar (önceden index yok sayılıyordu — yanlış sekme kapanırdı).
- **`target=_blank` otomatik geçiş:** tıklama yeni sekme açarsa aktif sekme otomatik değişir ve
  bu açıkça bildirilir; Chrome pop-up'ı anında kapattıysa eski sekmede kalınır.
- **İşlem üst sınırı:** her araç çağrısı `BROWSER_MCP_OP_TIMEOUT` (varsayılan 120 sn) ile
  korunur; chromedriver takıldığında cevapsız asistan yerine anlaşılır hata döner.
- **Maintainable test design:** Page Object + ortak helper + `try_for`; test gövdesi okunabilir,
  seçici değişikliği tek yerde.
  ([Maintainable Automated Test Design](https://agileway.substack.com/p/maintainable-automated-test-design))

## Playwright MCP ile karşılaştırma (dürüst tablo)

**Bizim önde olduğumuz yerler**

| Konu | Bu sunucu | Playwright MCP |
|---|---|---|
| Mevcut tarayıcıya bağlanma | CDP ile kullanıcının açık Chrome'una bağlanır (selenit F11 yaklaşımı) | Kendi tarayıcı örneğini yönetir |
| Küçük model (4B) verimliliği | 40 öğelik ref listesi, ~4 KB sınırı, satır bağlamı, modal odağı | Büyük a11y ağacı, daha fazla token |
| Denetim / güvenlik | `audit-*.jsonl` + host allowlist + riskli eylemde onay | Politikalar istemcide |
| Döngü koruması | Aynı çağrı 3. kez gelirse uyarı, kilitlemez | Yok |
| Keşif → regresyon | `scenarios/*.json` → `replay.rb` → `export_rspec.rb` (selenit/CI) | Yok (her koşu model/senaryo gerekir) |
| Shadow DOM / iframe | Döküm + ref + `browser_frame`, `shadow::host||inner` seçicileri | Destekler (ref tabanlı) |
| Bekleme / indirme | Koşul bazlı explicit wait, lazy-load taraması, `download` durumu | Otomatik bekleme güçlü; indirme tamamlanmasını ayrıca bekleme yok |
| Ağ gözlemi | `browser_monitor` (WebDriver BiDi): istek/yanıt/konsol + filtre + kayıt bekleme (2026-10) | Interception'da istek mocklama/durdurma daha zengin |

**Playwright MCP'nin önde olduğu yerler**

- Trace viewer, video/screenshot artefaktları; ağ interception'da request mocking (BiDi `browser_monitor`
  yalnızca gözlem yapar, istek durdurmaz).
- Çoklu tarayıcı (Firefox/WebKit), olgunlaşmış auto-wait, büyük bulut modelleriyle daha az disiplin gerektirir.
- Geniş ekosistem ve bakım sürekliliği.

Özet: **genel amaçlı bulut modeli + zengin artefakt** senaryosunda Playwright MCP daha güçlü;
**yerel küçük model + mevcut oturum + denetim + deterministik regresyon** senaryosunda bu sunucu daha uygun.

## Gemma E4B için ipuçları

- Modelden **tek adım** isteyin: `browser_navigate` → `browser_snapshot` → `browser_click`.
- Öğe seçerken `ref` kullanın (`e3`); CSS selector'ı yalnızca gerektiğinde verin.
- Sayfa uzunsa `browser_find` veya `browser_read` kullanın; tüm HTML'i okutmayın.
- `BROWSER_MCP_MAX_ELEMENTS` değerini 20–40 arasında tutun.
- Kısa sistem istemi:

```text
Sen tarayıcı otomasyonu yapan bir ajansın. Her adımda tek araç çağır.
Sayfayı anlamak için browser_snapshot kullan ve öğeleri e1, e2 gibi ref'lerle seç.
Uzun HTML veya tüm sayfa metnini isteme; kısa yanıt ver.
```
