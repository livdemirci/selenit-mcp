#!/usr/bin/env ruby
# frozen_string_literal: true
# ÖNERİ 5 — TOKEN/Bağlam MALİYETİ ölçümü.
#
# Küçük modelde 8K bağlam gerçek sınır; her araç çıktısı bu bütçeden yer.
# Aynı görev için iki aracın modele NE KADAR METİN verdiğini ölç.
#
# Ölçülen: görev boyunca modele giden toplam karakter (sistem + görev +
# her araç çıktısı) ve araç başına ortalama çıktı boyu.
#
# Koşum: ruby token_maliyeti.rb

require "json"

YOL = File.join(__dir__, "bench/kiyas-deepseek.json")
kayitlar = JSON.parse(File.read(YOL))

# Kaba token tahmini: Türkçe/İngilizce karışık metin için ~3.5 karakter/token.
# Kesin sayı değil, ORAN önemli — iki araç aynı kuralla ölçülüyor.
KARAKTER_PER_TOKEN = 3.5  # float: bölme float olmalı

# DİKKAT: argüman KARAKTER SAYISIDIR (Integer), metin değil.
# İlk sürüm "s.to_s.length" yapıyordu: 5405 sayısı "5405" olup uzunluğu 4
# dönüyordu, token hep 1 çıkıyordu. Argümanı doğrudan kullan.
def tahmini_token(karakter)
  n = karakter.to_i.to_f / 3.5
  n = (n + 0.5).floor
  n.positive? ? n : 1
end

puts "=== GÖREV BAŞINA BAĞLAM MALİYETİ ==="
puts format("%-12s %-11s %6s %10s %8s %7s", "site", "araç", "adım", "araç_k", "token~", "süre")
puts "-" * 62

ozet = Hash.new { |h, k| h[k] = { adim: 0, arac_k: 0, token: 0, sure: 0, n: 0 } }

kayitlar.sort_by { |r| [r["site"], r["arac"]] }.each do |r|
  # Araç çıktısı toplamı.
  # DİKKAT: trace satırları 130 karakterde KIRPILMIŞ ("... -> ilk satır[0,80]").
  # Onları toplamak gerçek bağlam yükünü ölçmez (ilk denemede 1 token çıktı).
  # Gerçek yük: kayıttaki "arac_cikti_toplam" alanı (koşum sırasında ölçülür);
  # yoksa trace uzunluğundan ORANSAL tahmin yapılır.
  arac_metni = r["arac_cikti_toplam"].to_i
  kaynak = "ölçüldü"
  if arac_metni.zero?
    # Eski kayıtlarda yok: ortalama araç çıktısı ~1200 karakter kabul et.
    arac_metni = r["adim"].to_i * 1200
    kaynak = "tahmin"
  end
  # Model başına gerçek yük: araç çıktıları + cevap
  toplam_k = arac_metni + r["cevap"].to_s.length
  tok = tahmini_token(toplam_k)

  puts format("%-12s %-11s %6d %10s %8s %6.0fs", r["site"], r["arac"], r["adim"],
              format("%d", arac_metni), format("%d", tok), r["sure"])

  o = ozet[r["arac"]]
  o[:adim] += r["adim"]; o[:arac_k] += arac_metni; o[:token] += tok; o[:sure] += r["sure"]; o[:n] += 1
end

puts "-" * 62
puts "\n=== ARAÇ BAŞINA ÖZET ==="
ozet.each do |arac, o|
  ort_adim = (o[:adim].to_f / o[:n]).round(1)
  ort_token = (o[:token].to_f / o[:n]).round
  ort_sure = (o[:sure].to_f / o[:n]).round
  token_adim = ort_adim.positive? ? (o[:token].to_f / o[:adim]).round : 0
  puts format("%-11s %d görev | ort %.1f adım | ort %s token~ | adım başına %s token~ | ort %ds",
              arac, o[:n], ort_adim, format("%d", ort_token), format("%d", token_adim), ort_sure)
end

# Oran
s = ozet["selenit"]; p = ozet["playwright"]
if s[:n].positive? && p[:n].positive?
  puts "\n=== ORAN (playwright / selenit) ==="
  puts format("  token: %.2fx | adım: %.2fx | süre: %.2fx",
              p[:token].to_f / s[:token], p[:adim].to_f / s[:adim], p[:sure].to_f / s[:sure])
  puts "\n  Yorum: >1 ise Playwright aynı görev için DAHA FAZLA bağlam tüketiyor."
end

File.write(File.join(__dir__, "bench/token-maliyeti.json"),
           JSON.pretty_generate({ "karakter_per_token" => KARAKTER_PER_TOKEN,
                                  "ozet" => ozet.transform_values { |o| { "gorev" => o[:n],
                                                                         "ort_adim" => (o[:adim].to_f / o[:n]).round(1),
                                                                         "ort_token" => (o[:token].to_f / o[:n]).round,
                                                                         "ort_sure" => (o[:sure].to_f / o[:n]).round } } }))
puts "\nyazıldı: bench/token-maliyeti.json"
