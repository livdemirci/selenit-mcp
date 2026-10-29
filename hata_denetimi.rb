#!/usr/bin/env ruby
# frozen_string_literal: true
# ÖNERİ 4 — HATA MESAJI DENETİMİ (site-nötr, sade ve doğru).
#
# Kural: Bir hata mesajı modele BİR SONRAKİ ADIMI söylemeli.
# "HATA: bir şeyler ters gitti" model için işe yaramaz.
#
# Yöntem: her aracın GÖVDESİNDE geçen yönlendirme işaretlerini say.
# Bir araçta en az bir yönlendirme varsa, o aracın hata yolları modele
# ne yapacağını söylüyor demektir. Satır satır oran hesabı çok satırlı
# mesajlarda (`\` ile birleşen) yanlış pozitif üretiyordu.
#
# Koşum: ruby hata_denetimi.rb

require "json"

KOD = File.read(File.join(__dir__, "browser.rb"))

ARACLAR = %w[
  navigate snapshot type click find read select alert scroll frame upload
  hover press_key resize monitor wait_for screenshot evaluate history tabs
  status close dom
].freeze

# Yönlendirme işaretleri: mesaj modelin ne yapacağını söylüyor mu?
YONLENDIRME = [
  /browser_(snapshot|find|read|type|click|wait_for|navigate|scroll|select|alert)/,
  /İpucu:/i, /ÖNCE/i, /DENEME/i, /tekrar deneme/i,
  /kullan/i, /çağır/i, /dene\b/i, /kontrol et/i, /doğrula/i,
  /görevi bu yolla başarısız say/i
].freeze

sonuc = []
puts "=== HATA MESAJI DENETİMİ ===\n\n"

ARACLAR.each do |ad|
  govde = KOD[/^  def #{Regexp.escape(ad)}\(.*?(?=\n  def |\n  private\b|\z)/m].to_s
  next if govde.empty?

  # error() yardımcısını kullanan araç ZATEN yönlendirici: error() her
  # çağrıda Selenium hata tipine göre "İpucu: ..." ekliyor.
  yardimci = govde.match?(/error\(/)
  isaretler = YONLENDIRME.count { |re| govde.match?(re) }
  yonlendirici = yardimci || isaretler.positive?

  sonuc << { "arac" => "browser_#{ad}", "error_yardimcisi" => yardimci,
             "isaret_sayisi" => isaretler, "yonlendirici" => yonlendirici }
  puts format("%-22s error():%-5s işaret:%-2d %s",
              "browser_#{ad}", yardimci ? "var" : "yok", isaretler,
              yonlendirici ? "YÖNLENDİRİCİ" : "*** ZAYIF ***")
end

zayif = sonuc.reject { |r| r["yonlendirici"] }

puts "\n=== SONUÇ ==="
puts "  araç: #{sonuc.size} | yönlendirici: #{sonuc.count { |r| r['yonlendirici'] }} | zayıf: #{zayif.size}"
if zayif.any?
  puts "  ZAYIFLAR: #{zayif.map { |r| r['arac'] }.join(', ')}"
  puts "  Bu araçların hata mesajları modele sonraki adımı söylemiyor."
else
  puts "  Tüm araçların hata yolları modele sonraki adımı söylüyor."
end

File.write(File.join(__dir__, "bench/hata-denetimi.json"),
           JSON.pretty_generate({ "araclar" => sonuc, "zayif" => zayif.map { |r| r["arac"] } }))
puts "\nyazıldı: bench/hata-denetimi.json"
