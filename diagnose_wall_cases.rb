#!/usr/bin/env ruby
# frozen_string_literal: true
# Duvar teşhisi — GERÇEK duvar sayfaları üzerinde sınıflandırma doğruluğu.
#
# Neden ayrı koşum: yukarıdaki diagnose_wall.rb ana sayfaları ölçtü ve
# sahibinden dışındaki tüm hedefler temiz çıktı. Sınıflandırıcının asıl sınavı
# temiz sayfa değil, DUVAR sayfası — yanlış pozitif de yanlış negatif de
# burada ortaya çıkar.
#
# Her hedef için:
#   - araç kararı (challenge_page?)
#   - ham gerçek (bağımsız kalıp + iframe/canvas + metin uzunluğu)
#   - iki karar çelişiyor mu
#
# Koşum: ruby diagnose_wall_cases.rb

require "json"
require_relative "browser"

VAKALAR = [
  # [etiket, url, beklenen]  beklenen = "DUVAR" | "TEMIZ"
  ["cloudflare-sahibinden", "https://www.sahibinden.com", "DUVAR"],
  ["cloudflare-nowsecure",  "https://nowsecure.nl",      "DUVAR"],
  ["cf-clean-g2",           "https://www.g2.com",        "TEMIZ"],
  # footsites.com park edilmiş bir domain satış sayfası — DataDome örneği değil.
  # stockx.com (DataDome): 2. koşumda "Please login to continue / verify you are
  # not a bot" duvarı geldi. Davranış değişken (bazen açık, bazen duvar), bu yüzden
  # İKİ beklenen de meşru: ölçüm "duvar VARSA yakalanmalı" ekseninde okunur.
  ["datadome-stockx",       "https://stockx.com",          "DUVAR"],
  ["letgo",                 "https://www.letgo.com",     "TEMIZ"],
  ["arabam",                "https://www.arabam.com",    "TEMIZ"],
  ["temiz-hepsiemlak",      "https://www.hepsiemlak.com", "TEMIZ"],
  ["temiz-letgo",           "https://www.letgo.com",     "TEMIZ"],
  ["temiz-github",          "https://github.com",        "TEMIZ"]
].freeze

HAM_JS = <<~JS
  var t = document.body ? (document.body.innerText || '') : '';
  var html = (document.documentElement ? document.documentElement.outerHTML : '').slice(0, 30000);
  var kisa = t.slice(0, 1500);
  var izler = [];
  var kaliplar = {
    'bir-dakika': /bir dakika lütfen/i,
    'just-a-moment': /just a moment/i,
    'checking-browser': /checking your browser/i,
    'attention-required': /attention required/i,
    'access-denied': /access denied/i,
    'cloudflare': /cloudflare/i,
    'datadome': /datadome/i,
    'captcha': /captcha/i,
    'turnstile': /turnstile/i,
    'verify-human': /verify.{0,20}(you are|that you)/i,
    'cf-ray': /ray id/i,
    'cf-challenge-js': /challenge-platform|cf-browser-verification|__cf_chl/i,
    'dd-iframe': /dd\\.datadome|datadome\\.co/i
  };
  for (var k in kaliplar) {
    if (kaliplar[k].test(kisa) || kaliplar[k].test(html)) izler.push(k);
  }
  var ifr = Array.from(document.querySelectorAll('iframe')).map(function(f){ return f.src || ''; });
  return {
    metin_uzunluk: t.length,
    metin_ilk400: kisa.slice(0, 400),
    baslik: document.title || '',
    url: location.href,
    izler: izler,
    iframe_sayisi: ifr.length,
    iframe_datadome: ifr.some(function(s){ return /datadome/i.test(s); }),
    iframe_cf: ifr.some(function(s){ return /challenges\\.cloudflare/i.test(s); }),
    link_sayisi: document.querySelectorAll('a').length,
    canvas_sayisi: document.querySelectorAll('canvas').length
  };
JS

def chrome_temizle
  system("pkill -f 'chrome-profile-' 2>/dev/null")
  sleep 1.5
end

sonuc = []

VAKALAR.each_with_index do |(etiket, url, beklenen), i|
  chrome_temizle
  port = (19_800 + i).to_s
  k = { "vaka" => etiket, "url" => url, "beklenen" => beklenen }

  begin
    b = SelenitBrowser.new(port: port)
    b.ensure_session
    d = b.driver
    d.manage.timeouts.page_load = 45
    t0 = Time.now
    d.navigate.to(url)
    20.times { break if d.execute_script("return document.readyState") == "complete"; sleep 0.4 }
    sleep 4  # duvar JS'i gecikmeli basar
    k["yukleme_sn"] = (Time.now - t0).round(1)

    ham = d.execute_script(HAM_JS)
    k["ham"] = ham
    k["arac"] = b.challenge_page? ? "DUVAR" : "TEMIZ"
    k["probe"] = b.challenge_probe.inspect[0, 220]
    k["snapshot_satir"] = b.snapshot.to_s.lines.size
    k["snapshot_ilk"] = b.snapshot.to_s.lines.first.to_s.strip[0, 80]
    k["webdriver"] = d.execute_script("return navigator.webdriver").to_s
    b.close
  rescue StandardError => e
    k["hata"] = "#{e.class}: #{e.message.to_s[0, 160]}"
    # Hata olsa bile sayfada ne olduğunu kaydet: navigasyon iptali mi, duvar mı?
    begin
      d = b.driver
      k["hata_url"] = d.current_url rescue nil
      k["hata_title"] = d.title rescue nil
      k["hata_metin"] = d.execute_script("return (document.body?document.body.innerText:'').slice(0,300)") rescue nil
    rescue StandardError
      nil
    end
  ensure
    b.close rescue nil
  end

  sonuc << k
  puts JSON.pretty_generate(k)
  puts "---"
end

chrome_temizle
File.write("artifacts/duvar-vaka-#{Time.now.strftime('%Y%m%d-%H%M')}.json", JSON.pretty_generate(sonuc))

puts "\n=== SINIFLANDIRMA DOĞRULUĞU ==="
dogru = 0
sonuc.each do |k|
  next if k["hata"]
  arac = k["arac"]
  ok = arac == k["beklenen"]
  dogru += 1 if ok
  ham = k["ham"] || {}
  printf("%-22s beklenen=%-5s araç=%-5s %-10s metin=%-6s satır=%-3s izler=%s\n",
         k["vaka"], k["beklenen"], arac, ok ? "✓" : "✗ YANLIŞ",
         ham["metin_uzunluk"], k["snapshot_satir"],
         (ham["izler"] || []).first(4).join(","))
end
gecerli = sonuc.count { |k| !k["hata"] }
# Ölçülemeyen vakayı "doğru" saymak raporu şişirir; ayrı say.
puts "\n#{dogru}/#{gecerli} doğru · #{sonuc.count { |k| k['hata'] }} vaka ÖLÇÜLEMEDİ"
