#!/usr/bin/env ruby
# frozen_string_literal: true
# Duvar TEŞHİS kolu: aracın engel sınıflandırması doğru mu?
# Ölçülen her site için hem araç katmanının kararını (challenge_page?) hem de
# ham sinyalleri (satır sayısı, metin uzunluğu, başlık, bilinen duvar izleri)
# yan yana yaz. Amaç: aracın kararı ile ham gerçeğin çeliştiği yerleri bulmak.
#
# Koşum: ruby diagnose_wall.rb
# Not: her site ayrı port + koşum öncesi chrome-profile temizliği (bilinen sızıntı).

require "json"
require_relative "browser"

SITELER = {
  "sahibinden"  => "https://www.sahibinden.com",
  "arabam"      => "https://www.arabam.com",
  "hepsiemlak"  => "https://www.hepsiemlak.com",
  "letgo"       => "https://www.letgo.com"
}.freeze

# Ham gerçek: sayfada duvar/koruma izleri var mı? (araç kalıplarından BAĞIMSIZ)
HAM_DUVAR_JS = <<~JS
  var t = document.body ? (document.body.innerText || '') : '';
  var html = document.documentElement ? document.documentElement.outerHTML : '';
  var kisa = t.slice(0, 1200);
  var izler = [];
  var kaliplar = {
    'Bir dakika': /bir dakika lütfen/i,
    'Just a moment': /just a moment/i,
    'Checking browser': /checking your browser/i,
    'Attention required': /attention required/i,
    'Access denied': /access denied/i,
    'Cloudflare': /cloudflare/i,
    'DataDome': /datadome/i,
    'captcha': /captcha/i,
    'g-recaptcha': /g-recaptcha/i,
    'turnstile': /turnstile/i,
    'hcaptcha': /hcaptcha/i,
    'doğrulama': /doğrulama|guvenlik|güvenlik/i
  };
  for (var k in kaliplar) {
    if (kaliplar[k].test(kisa) || kaliplar[k].test(html.slice(0, 20000))) izler.push(k);
  }
  return {
    metin_uzunluk: t.length,
    metin_ilk300: kisa.slice(0, 300),
    baslik: document.title || '',
    url: location.href,
    izler: izler,
    // iframe içinde mi? (DataDome genelde iframe içine hapseder)
    iframe_sayisi: document.querySelectorAll('iframe').length,
    iframe_src: Array.from(document.querySelectorAll('iframe')).map(function(f){ return (f.src||'').slice(0,80); }).slice(0,4),
    // görünür içerik var mı: ana içerik işaretleri
    link_sayisi: document.querySelectorAll('a').length,
    girdi_sayisi: document.querySelectorAll('input,textarea,select').length,
    // canvas duvarı (DataDome bazı sürümleri)
    canvas_sayisi: document.querySelectorAll('canvas').length
  };
JS

def chrome_temizle
  system("pkill -f 'chrome-profile-' 2>/dev/null")
  sleep 1
end

sonuclar = []

SITELER.each_with_index do |(ad, url), i|
  chrome_temizle
  port = (19_600 + i).to_s
  env_yedek = ENV["BROWSER_MCP_PORT"]
  ENV["BROWSER_MCP_PORT"] = port
  kayit = { "site" => ad, "url" => url }

  begin
    b = SelenitBrowser.new(port: port)
    b.ensure_session
    d = b.driver

    t0 = Time.now
    d.navigate.to(url)
    # Sabit bekleme yok: hazır olana kadar kısa poll, en fazla 15 sn
    15.times do
      break if d.execute_script("return document.readyState") == "complete"
      sleep 0.5
    end
    sleep 3 # duvar JS'i sonradan basıyor; kısa yerleşme
    kayit["yukleme_sn"] = (Time.now - t0).round(1)

    ham = d.execute_script(HAM_DUVAR_JS)
    kayit["ham"] = ham
    kayit["arac_challenge"] = b.challenge_page?
    kayit["arac_snapshot_satir"] = b.snapshot.to_s.lines.size
    kayit["arac_snapshot_ilk"] = b.snapshot.to_s.lines.first.to_s.strip[0, 90]
    kayit["navigator_webdriver"] = d.execute_script("return navigator.webdriver").to_s
    kayit["cookie_sayisi"] = d.manage.all_cookies.size
    b.close
  rescue StandardError => e
    kayit["hata"] = "#{e.class}: #{e.message.to_s[0, 200]}"
  ensure
    ENV["BROWSER_MCP_PORT"] = env_yedek
  end

  sonuclar << kayit
  puts JSON.pretty_generate(kayit)
  puts "---"
end

chrome_temizle

File.write("artifacts/duvar-teshis-#{Time.now.strftime('%Y%m%d-%H%M')}.json",
           JSON.pretty_generate(sonuclar))

# Özet: araç kararı vs ham gerçek çelişkisi
puts "\n=== ARAÇ KARARI vs HAM GERÇEK ==="
sonuclar.each do |k|
  ham = k["ham"] || {}
  ham_duvar = (ham["izler"] || []).any?
  arac = k["arac_challenge"] ? "DUVAR" : "TEMIZ"
  ham_s = ham_duvar ? "DUVAR" : "TEMIZ"
  uyum = (arac == ham_s) ? "UYUMLU" : "*** ÇELİŞKİ ***"
  printf("%-11s araç=%-6s ham=%-6s %-14s metin=%-5s izler=%s\n",
         k["site"], arac, ham_s, uyum, ham["metin_uzunluk"],
         (ham["izler"] || []).join(","))
end
