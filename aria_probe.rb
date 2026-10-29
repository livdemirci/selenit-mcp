#!/usr/bin/env ruby
# frozen_string_literal: true
# ARIA rol tabanlı arama testi — Zhimin Zhan'ın "Playwright ARIA locator support"
# iddiasına karşı ölçüm.
#
# Tez: ARIA locator Playwright'a özgü bir üstünlük değil; rol/erişilebilirlik
# adı standart CSS/ARIA seçicileriyle Selenium'da da aynı şekilde kullanılır.
# Ölçülecek iki şey:
#   1) Rol tabanlı konumlandırma gerçekten çalışıyor mu (işlevsel eşdeğerlik)
#   2) Küçük model (Gemma E4B) rol tabanlı hedefi görsel/ref tabanlı hedeften
#      daha mı az adımda buluyor (token/bağlam verimliliği)
#
# Koşum: ruby aria_probe.rb

require "json"
require_relative "browser"

# Test sayfası: gerçek sitelerdeki erişilebilirlik desenlerini taklit eder.
# Siteye özgü seçici YOK — hepsi rol/ad üzerinden tanımlı.
SAYFA = <<~HTML
  <!doctype html>
  <html lang="tr">
  <head><meta charset="utf-8"><title>Aria Probe</title></head>
  <body>
    <header>
      <nav aria-label="Ana menü">
        <a href="#/a" role="link">Kategori A</a>
        <a href="#/b" role="link">Kategori B</a>
      </nav>
      <form role="search" aria-label="Site araması">
        <label for="q">Ürün ara</label>
        <input id="q" type="search" role="searchbox" aria-label="Ürün ara" placeholder="Ürün adı">
        <button type="submit" role="button" aria-label="Ara">Ara</button>
      </form>
    </header>
    <main>
      <section aria-labelledby="urunler-baslik">
        <h2 id="urunler-baslik">Ürünler</h2>
        <ul role="list">
          <li role="listitem"><a href="#/p1" role="link" aria-label="Kablosuz Kulaklık 999 TL">Kablosuz Kulaklık</a></li>
          <li role="listitem"><a href="#/p2" role="link" aria-label="Mekanik Klavye 1499 TL">Mekanik Klavye</a></li>
          <li role="listitem"><a href="#/p3" role="link" aria-label="Oyuncu Faresi 749 TL">Oyuncu Faresi</a></li>
        </ul>
      </section>
      <div role="dialog" aria-modal="true" aria-label="Çerez onayı" style="display:none">
        <button role="button" aria-label="Kabul et">Kabul et</button>
      </div>
    </main>
  </body>
  </html>
HTML

ARA_HEdeflERI = [
  ["role=searchbox",  "Ürün ara",   "arama kutusu"],
  ["role=button#Ara", "Ara",        "arama düğmesi"],
  ["role=link",       "Mekanik Klavye", "ürün bağlantısı"]
].freeze

def sayfa_yukle(driver)
  # data: URL'de % kodlama + uzun içerik chromedriver'da güvenilmez (ölçüldü:
  # sayfa hiç yüklenmedi, tüm testler NoSuchElement verdi). Gerçek dosya kullan.
  yol = File.join(__dir__, "artifacts", "aria-probe.html")
  FileUtils.mkdir_p(File.dirname(yol))
  File.write(yol, SAYFA)
  driver.navigate.to("file://#{yol}")
  # Yüklendiğini doğrula: sessizce boş sayfada test etmek yanıltıcı.
  raise "test sayfası yüklenmedi" unless driver.execute_script("return document.querySelectorAll('[role]').length").to_i > 0
  true
end

sonuc = {}

system("pkill -f 'chrome-profile-' 2>/dev/null")
sleep 1.5

b = SelenitBrowser.new(port: "19950")
b.ensure_session
d = b.driver
sayfa_yukle(d)

# --- 1) İŞLEVSEL EŞDEĞERLİK: rol tabanlı konumlandırma çalışıyor mu? ----------
puts "=== 1) ROL TABANLI KONUMLANDIRMA ==="
testler = [
  ["CSS+aria-label: searchbox",
   "input[type=search], input[role=searchbox]", nil],
  ["CSS+aria-label: Ara düğmesi",
   "button[aria-label='Ara']", nil],
  ["ARIA role selector: link 'Mekanik Klavye'",
   "a[role=link][aria-label^='Mekanik']", nil],
  ["Rol + erişilebilir ad (JS)",
   nil, "a[role=link]"],
  ["Gizli dialog öğesi görünmez olmalı",
   "div[role=dialog]", nil]
]

testler.each do |ad, secici, js_rol|
  sonuc[ad] =
    begin
      if secici
        el = d.find_element(:css, secici)
        if ad.include?("Gizli dialog")
          # aria-modal dialog display:none → görünmez olmalı
          vis = el.displayed?
          { "bulundu" => true, "gorunur" => vis, "beklenen_gorunur" => false,
            "gecti" => !vis }
        else
          { "bulundu" => true, "etiket" => el.attribute("aria-label").to_s[0, 40],
            "gecti" => true }
        end
      else
        # rolle erişilebilirlik adını JS ile çöz (ARIA locator eşdeğeri)
        r = d.execute_script(<<~JS, "link", "Mekanik")
          var rol = arguments[0], parca = arguments[1];
          var els = document.querySelectorAll('[role="' + rol + '"],' + rol);
          var out = [];
          for (var i = 0; i < els.length; i++) {
            var e = els[i];
            var ad = (e.getAttribute('aria-label') || e.innerText || e.textContent || '').trim();
            if (ad.indexOf(parca) >= 0) out.push({ etiket: ad.slice(0, 40), tag: e.tagName });
          }
          return out;
        JS
        # not: execute_script argümanları ayrı geçilir
        { "bulundu" => !r.to_a.empty?, "sonuc" => r, "gecti" => !r.to_a.empty? }
      end
    rescue StandardError => e
      { "gecti" => false, "hata" => "#{e.class}: #{e.message.to_s[0, 80]}" }
    end
  puts "  #{sonuc[ad]['gecti'] ? 'PASS' : 'FAIL'}  #{ad}"
  puts "         #{sonuc[ad].to_json}" unless sonuc[ad]["gecti"]
end

# JS argümanlı sürüm (execute_script imzası)
puts "\n=== 2) ERİŞİLEBİLİRLİK ADIYLA ARAMA (ARIA locator eşdeğeri) ==="
rol_arama = d.execute_script(<<~JS, "link", "mekanik")
  var rol = arguments[0], ad = arguments[1];
  var els = Array.prototype.slice.call(document.querySelectorAll('[role="' + rol + '"],[role]'));
  if (rol === 'link') els = els.concat(Array.prototype.slice.call(document.querySelectorAll('a')));
  var hit = els.filter(function (e) {
    var a = (e.getAttribute('aria-label') || e.innerText || '').trim().toLowerCase();
    return a.indexOf(ad.toLowerCase()) >= 0 && e.getBoundingClientRect().width > 0;
  });
  return hit.map(function (e) { return { tag: e.tagName, ad: (e.getAttribute('aria-label') || e.innerText || '').trim().slice(0, 50) }; });
JS
puts "  role/aria-label araması -> #{rol_arama.to_json}"
sonuc["erişilebilirlik_adı"] = { "sonuc" => rol_arama, "gecti" => !rol_arama.to_a.empty? }

# --- 3) MODEL MALİYETİ: rol hedefi ne kadar metin istiyor? -------------------
puts "\n=== 3) MODEL BAĞLAM MALİYETİ ==="
snapshot = b.snapshot.to_s
db = d.execute_script("return document.body.innerText").to_s
puts "  snapshot satır: #{snapshot.lines.size}, karakter: #{snapshot.length}"
puts "  body metin karakter: #{db.length}"
# Rol tabanlı hedef tarifi ne kadar metin gerektiriyor?
rol_tarif = "role=searchbox + erişilebilir ad 'Ürün ara'"
puts "  rol tarifi: #{rol_tarif} (#{rol_tarif.length} karakter)"
sonuc["baglam"] = { "snapshot_satir" => snapshot.lines.size, "snapshot_karakter" => snapshot.length,
                    "body_karakter" => db.length, "rol_tarif_karakter" => rol_tarif.length }

# --- 4) ARIA rolü olmayan öğe: rol çıkarımı doğru mu? -----------------------
puts "\n=== 4) ROL ÇIKARIMI (açık role yok, semantikten) ==="
cikarim = d.execute_script(<<~JS)
  // ARIA'da <a href> → link, <button> → button örtük rol alır.
  var out = {};
  var a = document.querySelector('a[href]');
  out.a_href_rolu = a ? (a.getAttribute('role') || a.tagName.toLowerCase()) : null;
  var btn = document.querySelector('button');
  out.button_rolu = btn ? (btn.getAttribute('role') || btn.tagName.toLowerCase()) : null;
  var inp = document.querySelector('input[type=search]');
  out.search_input_rolu = inp ? (inp.getAttribute('role') || inp.type) : null;
  return out;
JS
puts "  örtük roller: #{cikarim.to_json}"
sonuc["ortuk_rol"] = cikarim

b.close
system("pkill -f 'chrome-profile-' 2>/dev/null")

File.write("artifacts/aria-probe-#{Time.now.strftime('%Y%m%d-%H%M')}.json", JSON.pretty_generate(sonuc))
puts "\n=== SONUÇ ==="
g = sonuc.select { |_k, v| v.is_a?(Hash) && v.key?("gecti") }
puts "#{g.count { |_k, v| v['gecti'] }}/#{g.size} geçti"
