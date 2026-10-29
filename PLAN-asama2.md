# Selenit-mcp — Aşama 2 ölçüm planı ve SONUÇLARI (Makale-2)

Tarih: 2026-10-29 · Model: **google/gemma-4-e4b** (LM Studio, yerel 4B, `enable_thinking=false`)

> Her sayı gerçek koşum çıktısından gelir. Henüz koşulmamış satırlar "—" kalır, uydurulmaz.

## Karar (verilen)

İkinci hedef **sahibinden.com değil**. Gerekçe ölçümle sabit: sahibinden login'siz
koşumda "Bir dakika lütfen..." duvarı veriyor (`navigator.webdriver="false"`
olmasına rağmen) — ajan hatası olmayan bir engel, tabloya FAIL yazmak yanıltıcı olur.
Onun yerine:

- **Hedef 1: otoplus.com** (`/ikinci-el-araba`) — özel menü (button + `role=option`),
  Min/Max alanları, filtre URL'ye yazılıyor, ilan no URL'nin son segmentinde (`-579213`).
- **Hedef 2: arabam.com** (`/ikinci-el/otomobil`) — gerçek `<select id="sortOrderBy">`
  (9 seçenek), "Fiyat" ile açılan `Min TL` / `Max TL` alanları.

## Scenario S2 — `filtre2` (site-nötr)

Görev: sıralama menüsü → "Ucuzdan Pahalıya", fiyat aralığı (min/max) → filtrele,
sponsorlu kartı atla, ilk organik ilanın detayına gir, **ilan no + fiyat** getir.
Cevap biçimi: `ilan | <no> | <fiyat>`.

Ölçüt 3 bağımsız sinyale bakar (cevaba güvenmez):

| # | Sinyal | Neyi yakalar |
|---|---|---|
| A | Filtre değerleri sayfada/URL'de duruyor mu | filtreyi uygulamadan cevap yazmayı |
| B | Cevaptaki ilan no detay sayfasının no'su mu | uydurma/rastgele ilan numarasını |
| C | Cevaptaki fiyat sayfa metninde geçiyor mu | başka ilanın fiyatını veya uydurma fiyatı |

Birim testi `ruby test_filtre2.rb` → **7/7 PASS**.

## Elle doğrulanan site davranışı

```
otoplus  KVKK → Fiyat paneli → Min=500000 / Max=1500000 → Filtrele
         → https://www.otoplus.com/al?min-fiyat=500000&max-fiyat=1500000
         sıralama seçenekleri (role=option): Önerilen / Ucuzdan Pahalıya /
         Pahalıdan Ucuza / Yeniden Eskiye / Eskiden Yeniye
arabam   Fiyat → input[placeholder="Min TL"] / "Max TL"; sıralama: <select id=sortOrderBy>
sahibinden  ENGELLİ (bot duvarı)   ikinciyeni  filtre alanları DOM'da yok → elendi
```

## Koşum sonuçları

| # | Sürücü | Hedef | Adım | Süre | Sonuç |
|---|---|---|---|---|---|
| 1 | `benchmark.rb` | otoplus | 16/16 | 500 s | **FAIL** — 2. adımdan itibaren `private method 'click'` (altyapı hatası) |
| 2 | `benchmark.rb` | otoplus | 6/6 | 310 s | **FAIL** — aynı ref (e22) tekrar tekrar, ilerleme yok |
| 3 | `tmp_trace2.rb` (canlı izleme) | otoplus | 7/12 | ~400 s | **FAIL** — sıralama + detay doğru açıldı, sonra uydurma CSS seçici (`#min-price-input`) denedi |
| 4 | `benchmark.rb` | arabam | — | — | koşulacak |
| 5 | `@playwright/mcp` kıyası | otoplus | — | — | koşulacak |

### Koşum 3 ham izi (model davranışı)

```
1. (41s) browser_navigate(url=otoplus/ikinci-el-araba) -> başlık geldi
2. (49s) browser_click(ref=e22)                        -> tıklandı
3. (92s) browser_find(text=Ucuzdan Pahalıya)           -> eşleşmeler
4. (61s) browser_click(ref=f1)                         -> tıklandı
5. (44s) browser_click(ref=e25)                        -> tıklandı
6. (37s) browser_snapshot()                            -> URL değişti (?...)
7. (75s) browser_type(selector=#min-price-input)       -> HATA: seçici DOM'da yok
```

Yorum: model **doğru akışı kuruyor** (menüyü açıyor, seçeneği buluyor, panele
giriyor) ama **snapshot'taki ref'lerle çalışmak yerine uydurma CSS seçici
üretiyor**. 4B modelde adım gecikmesi 37–92 s.

## Altyapı bulguları (makalenin "yöntem" bölümüne)

1. **Aynı portta ikinci MCP sunucusu Chrome profilini kilitliyor.** Belirti alakasız:
   `private method 'click' called for an instance of SelenitBrowser`. Port ve profil
   görev başına ayrılmalı (`benchmark.rb`, `benchmark_cozucu.rb` düzeltildi).
2. `mcp.stop` Chrome'u kapatmıyor → koşum öncesi `pkill -f "chrome-profile-"` şart.
3. Gemma 4 E4B'de `enable_thinking=false` **JSON metin modunda etkisiz**
   (`finish_reason=length`, içerik boş, reasoning 297–463 token); **araç çağrısı
   verildiğinde düzgün çalışıyor**. Ölçüm: `tools` verilince `finish_reason=tool_calls`,
   tek `browser_navigate` çağrısı üretildi; verilmeyince ham `<|tool_call>` metni.
4. **Snapshot eleme düzeltmesi:** filtre paneli açıldıktan sonra içindeki `Min`/`Max`
   metin alanları dump'a hiç girmiyordu (görünür, boyutlu, disabled değil). Kök neden:
   atalarından biri `role=dialog/aria-modal` taşıyordu ve "modal açıkken yalnızca
   modalı tara" kuralı tarama kökünü daraltıyordu. Form alanları artık bu kuraldan
   muaf (`snapshot.js`). Smoke: **38/38**.

## Koşum komutları

```bash
cd "~/Documents/Varsayılan Proje/selenit_mcp"

# otoplus
SELENIT_TARGET_URL="https://www.otoplus.com/ikinci-el-araba" \
SELENIT_FILTER_MIN=500000 SELENIT_FILTER_MAX=1500000 \
SELENIT_SORT_LABEL="Ucuzdan Pahalıya" BENCH_MAX_STEPS=16 ruby benchmark.rb filtre2

# arabam
SELENIT_TARGET_URL="https://www.arabam.com/ikinci-el/otomobil" \
SELENIT_FILTER_MIN=500000 SELENIT_FILTER_MAX=1500000 \
SELENIT_SORT_LABEL="Fiyat - Ucuzdan Pahalıya" BENCH_MAX_STEPS=16 ruby benchmark.rb filtre2

# kıyas: @playwright/mcp, aynı görev + aynı ölçüt
BENCH_TASK=filtre2 ruby benchmark_pw.rb
```

## Sınırlar (makalede yazılacak)

1. Login, ödeme, dosya yükleme, CAPTCHA ölçülmüyor (Aşama-1 kapsamı).
2. **Bot duvarı ajan hatası değildir** — sahibinden bu yüzden kapsam dışı, bulgu olarak yazılacak.
3. Kıyas için `browser_type`/`browser_evaluate` parametre adları `benchmark_pw.rb`
   içinde köprülenir (ref→element, script→function); modelin gördüğü araç yüzeyi değişmez.
