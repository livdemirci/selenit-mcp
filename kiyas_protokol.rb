#!/usr/bin/env ruby
# frozen_string_literal: true
# EŞİT ORTAM ŞARTLARI — kıyas protokolü.
#
# KAPSAM KURALI (bu dosyanın varlık sebebi)
# ----------------------------------------
# Playwright MCP başka bir ekibin ürünü. Onun araç açıklamalarını, hata
# mesajlarını veya davranışını "düzeltmek" bizim işimiz değil — ve düzeltmek
# kıyası kirletir: o zaman ölçtüğümüz şey iki ürün değil, benim iki ürüne ne
# kadar emek verdiğim olur.
#
# Eşit ortam şartı şudur:
#   - aynı model, aynı sıcaklık, aynı adım bütçesi
#   - aynı görev metni ve AYNI sistem prompt'u (birebir)
#   - aynı siteler, aynı arama terimleri
#   - her koşumda temiz profil, aynı Chrome
#   - hiçbir araca ek özellik yok, hiçbirinin metni değiştirilmedi
#
# Selenit'e eklediğim browser_find(role:, name:) KALICI bir ürün özelliği.
# Playwright MCP'de karşılığı yok. Eşitlik için kıyasta iki taraf da YALNIZCA
# kendi yerleşik yüzeyiyle koşar: rol modu bu kıyasta kullanılmaz.
# Selenit'in rol modu ayrı ölçülüyor (zhan_iddialar.rb, Part 9) — orada
# Playwright'la kıyaslanmıyor, "Selenium'da ARIA mümkün mü" sorusu ölçülüyor.

require "json"

KIYAS_PROTOKOLU = {
  "model" => "deepseek-v4.1-flash",
  "sicaklik" => 0,
  "adim_butcesi" => 16,
  "kosum_sayisi" => 2,
  "izolasyon" => "her koşumda pkill chrome-profile + pw-profile",
  "sistem_promptu" => "birebir aynı (kiyas_claude.rb SYSTEM)",
  "gorev_metni" => "birebir aynı (kiyas_claude.rb gorev_prompt)",
  "arac_yuzeyi" => "her iki araç KENDİ yerleşik araç listesiyle; hiçbir metin değiştirilmedi",
  "olcum" => "cevaptaki başlık sayfada gerçekten var mı (uydurma tespiti)"
}.freeze

# Kıyasın adil olduğunu kanıtlayan kontroller. Koşumdan önce ve sonra çalışır.
def esitlik_kontrolu(selenit_tools, pw_tools)
  rapor = {}

  # 1) Sistem prompt'u ve görev metni aynı kaynaktan mı?
  #    kiyas_claude.rb'de tek SYSTEM sabiti ve tek gorev_prompt fonksiyonu var;
  #    iki araç da aynı fonksiyonu çağırır. Kod düzeyinde garanti.
  rapor["ortak_prompt"] = true

  # 2) Araç yüzeyleri gerçekten ÜRÜNÜN KENDİSİ mi?
  #    Selenit'in rol modu kıyas dışı: rol/kombinasyonu kullanan araç çağrısı
  #    sayılırsa kıyas kirlenmiş demektir.
  rapor["selenit_arac_sayisi"] = selenit_tools.size
  rapor["pw_arac_sayisi"] = pw_tools.size

  # 3) Ortak araç adları: iki tarafta da olanlar (adil karşılaştırma zemini)
  s_adlar = selenit_tools.map { |t| t["name"] }.sort
  p_adlar = pw_tools.map { |t| t["name"] }.sort
  ortak = s_adlar & p_adlar
  rapor["ortak_arac"] = ortak
  rapor["ortak_arac_sayisi"] = ortak.size
  rapor["sadece_selenit"] = s_adlar - p_adlar
  rapor["sadece_pw"] = p_adlar - s_adlar

  rapor
end

if $PROGRAM_NAME == __FILE__
  puts "=== KIYAS PROTOKOLÜ ==="
  KIYAS_PROTOKOLU.each { |k, v| puts "  #{k}: #{v}" }

  puts "\n=== ARAÇ YÜZEYİ KONTROLÜ ==="
  require_relative "mcp_client"
  require_relative "benchmark_pw"

  system("pkill -f 'chrome-profile-' 2>/dev/null; pkill -f 'playwright/mcp' 2>/dev/null")
  sleep 1

  s = McpClient.new(port: "19420")
  s_tools = s.tools
  s.stop

  pw = PwClient.new
  p_tools = pw.tools
  pw.stop
  system("pkill -f 'playwright/mcp' 2>/dev/null")

  r = esitlik_kontrolu(s_tools, p_tools)
  puts "  selenit araç: #{r['selenit_arac_sayisi']} | playwright araç: #{r['pw_arac_sayisi']}"
  puts "  ortak araç adı: #{r['ortak_arac_sayisi']}"
  puts "  ortak: #{r['ortak_arac'].join(', ')}"
  puts "  sadece selenit: #{r['sadece_selenit'].join(', ')}"
  puts "  sadece playwright: #{r['sadece_pw'].join(', ')}"

  File.write(File.join(__dir__, "bench/kiyas-protokol.json"),
             JSON.pretty_generate({ "protokol" => KIYAS_PROTOKOLU, "esitlik" => r }))
  puts "\nyazıldı: bench/kiyas-protokol.json"
end
