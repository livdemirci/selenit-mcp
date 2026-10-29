#!/usr/bin/env ruby
# frozen_string_literal: true
# 4 SİTE × 2 MCP karşılaştırma koşumu — Medium makalesi ham verisi.
#
# Tasarım (kıyasın dürüst olması için):
#   - Aynı model (google/gemma-4-e4b, düşünme kapalı), aynı sıcaklık (0)
#   - Aynı görev metni (tasks.rb "sitenotr", prompt birebir aynı)
#   - Aynı siteler, aynı arama terimleri
#   - Her iki araç için aynı adım bütçesi (BENCH_MAX_STEPS)
#   - Her koşum öncesi chrome-profile temizliği (bilinen port sızıntısı)
#   - Her (site, araç) çifti N kez koşulur; sonuç JSON'a eklenir (yeniden başlatmaya dayanıklı)
#
# Koşum: ruby kiyas_4site.rb            # 4 site × 2 araç × 2 koşum
#        KOSUM=3 ruby kiyas_4site.rb    # 3 koşum

require "json"
require "fileutils"
require "open3"
require "timeout"
require_relative "tasks"

ROOT = __dir__
SONUC_DOSYA = File.join(ROOT, "artifacts/kiyas-4site.json")
KOSUM = (ENV["KOSUM"] || 2).to_i
MAX_STEPS = (ENV["BENCH_MAX_STEPS"] || 20).to_i unless defined?(MAX_STEPS)
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"

TUM_SITELER = [
  { ad: "hepsiemlak", url: "https://www.hepsiemlak.com", terim: "satılık daire" },
  { ad: "arabam",     url: "https://www.arabam.com",     terim: "otomatik dizel" },
  { ad: "letgo",      url: "https://www.letgo.com",      terim: "bisiklet" },
  { ad: "hepsiburada", url: "https://www.hepsiburada.com", terim: "kulaklık" }
].freeze

# SITE_FILTER=hepsiemlak,arabam → yalnızca o siteler koşar (parti parti koşum için)
SITELER = begin
  f = ENV["SITE_FILTER"].to_s.split(",").map(&:strip).reject(&:empty?)
  f.empty? ? TUM_SITELER : TUM_SITELER.select { |s| f.include?(s[:ad]) }
end

KIYAS_SYSTEM_PROMPT = <<~S
  Sen bir tarayıcı otomasyon ajanısın. Kurallar:
  - Her adımda TEK araç çağır, sonucu bekle.
  - Sayfayı anlamak için browser_snapshot kullan; öğeleri ekran metni + ref ile seç.
  - Ref geçersizse yeniden browser_snapshot çağır.
  - Modal açıksa yalnızca modal içindeki öğeleri kullan.
  - Form alanlarına yazmak için browser_type, tek tuş için browser_press_key kullan.
  - Görev bitince araç çağırmayı bırak ve en fazla 2 cümlelik kısa Türkçe cevap ver.
S

def chrome_temizle
  system("pkill -f 'chrome-profile-' 2>/dev/null")
  system("pkill -f 'pw-profile' 2>/dev/null")
  system("pkill -f 'playwright/mcp' 2>/dev/null")
  sleep 1.5
end

def kayitli_sonuclar
  File.exist?(SONUC_DOSYA) ? JSON.parse(File.read(SONUC_DOSYA)) : []
end

def kaydet(sonuclar)
  FileUtils.mkdir_p(File.dirname(SONUC_DOSYA))
  File.write(SONUC_DOSYA, JSON.pretty_generate(sonuclar))
end

def zaten_var?(sonuclar, site, arac, kosum)
  sonuclar.any? { |r| r["site"] == site && r["arac"] == arac && r["kosum"] == kosum }
end

# --- selenit tarafı: benchmark.rb mantığını tek koşum için çağırır -----------
def selenit_kosum(site, kosum_no)
  env = {
    "SELENIT_TARGET_URL" => site[:url],
    "SELENIT_TARGET_TERM" => site[:terim],
    "BENCH_MAX_STEPS" => MAX_STEPS.to_s,
    "BENCH_MODEL" => MODEL
  }
  log = "/tmp/kiyas-selenit-#{site[:ad]}-#{kosum_no}.log"
  system(env, "ruby", File.join(ROOT, "benchmark.rb"), "sitenotr", out: log, err: [:child, :out])
  out = File.read(log)
  # benchmark.rb insan-okur metin basıyor; makine-okur kısmı artefactsız.
  # Bu yüzden yapısal sonucu ayrı bir koşumdan almak yerine çıktıyı ayrıştırıyoruz.
  gecen = out.include?("GEÇTİ")
  adim = out[/GEÇTİ \((\d+) adım/, 1] || out[/KALDI \((\d+) adım/, 1] || "0"
  sure = out[/, ([\d.]+)s\)/, 1] || "0"
  cevap = out[/cevap: (.+)/, 1].to_s.strip[0, 200]
  {
    "site" => site[:ad], "arac" => "selenit", "kosum" => kosum_no,
    "pass" => gecen, "adim" => adim.to_i, "sure" => sure.to_f,
    "cevap" => cevap, "ham_cikti" => out.lines.last(12).join
  }
end

def main
  sonuclar = kayitli_sonuclar

  SITELER.each do |site|
    (1..KOSUM).each do |kosum_no|
      %w[selenit playwright].each do |arac|
        if zaten_var?(sonuclar, site[:ad], arac, kosum_no)
          puts "ATLA  #{site[:ad]} #{arac} koşum#{kosum_no} (kayıtlı)"
          next
        end
        chrome_temizle
        print "#{site[:ad]} #{arac} koşum#{kosum_no} ... "
        r = nil
        begin
          r = if arac == "selenit"
                selenit_kosum(site, kosum_no)
              else
                env = {
                  "BENCH_TASK" => "sitenotr",
                  "SELENIT_TARGET_URL" => site[:url],
                  "SELENIT_TARGET_TERM" => site[:terim],
                  "BENCH_MAX_STEPS" => MAX_STEPS.to_s,
                  "BENCH_MODEL" => MODEL,
                  "PROBE" => "1"
                }
                log = "/tmp/kiyas-pw-#{site[:ad]}-#{kosum_no}.log"
                system(env, "ruby", File.join(ROOT, "benchmark_pw.rb"), out: log, err: [:child, :out])
                out = File.read(log)
                gecen = out.include?("PASS")
                {
                  "site" => site[:ad], "arac" => "playwright", "kosum" => kosum_no,
                  "pass" => gecen,
                  "adim" => (out[/PASS \((\d+) adım/, 1] || out[/FAIL \((\d+) adım/, 1] || "0").to_i,
                  "sure" => (out[/, ([\d.]+)s\)/, 1] || "0").to_f,
                  "cevap" => out[/cevap: (.+)/, 1].to_s.strip[0, 200],
                  "ham_cikti" => out.lines.last(12).join
                }
              end
        rescue StandardError => e
          r = { "site" => site[:ad], "arac" => arac, "kosum" => kosum_no,
                "pass" => false, "adim" => 0, "sure" => 0.0,
                "cevap" => "", "ham_cikti" => "KOŞUM HATASI: #{e.class}: #{e.message.to_s[0, 200]}" }
        end
        # "LM hatası" = geçici LM Studio sorunu, araç hatası değil.
        # Böyle bir koşumu başarısız sayıp kaydetmek kıyası bozar: 2 kez yeniden dene.
        deneme = 0
        while r["pass"] == false && r["cevap"].to_s.empty? &&
              r["ham_cikti"].to_s.include?("LM hatası") && deneme < 3
          deneme += 1
          puts "  yeniden deneniyor (#{deneme}/3) — LM hatası"
          sleep 5
          chrome_temizle
          r = if arac == "selenit"
                selenit_kosum(site, kosum_no)
              else
                log = "/tmp/kiyas-pw-#{site[:ad]}-#{kosum_no}-#{deneme}.log"
                system({ "BENCH_TASK" => "sitenotr", "SELENIT_TARGET_URL" => site[:url],
                         "SELENIT_TARGET_TERM" => site[:terim], "BENCH_MAX_STEPS" => MAX_STEPS.to_s,
                         "BENCH_MODEL" => MODEL, "PROBE" => "1" },
                       "ruby", File.join(ROOT, "benchmark_pw.rb"), out: log, err: [:child, :out])
                out = File.read(log)
                { "site" => site[:ad], "arac" => "playwright", "kosum" => kosum_no,
                  "pass" => out.include?("PASS"),
                  "adim" => (out[/PASS \((\d+) adım/, 1] || out[/FAIL \((\d+) adım/, 1] || "0").to_i,
                  "sure" => (out[/, ([\d.]+)s\)/, 1] || "0").to_f,
                  "cevap" => out[/cevap: (.+)/, 1].to_s.strip[0, 200],
                  "ham_cikti" => out.lines.last(12).join }
              end
        end

        sonuclar << r
        kaydet(sonuclar)
        puts(r["pass"] ? "PASS (#{r['adim']} adım, #{r['sure']}s)" : "FAIL (#{r['adim']} adım, #{r['sure']}s)")
      end
    end
  end

  puts "\n=== ÖZET ==="
  %w[selenit playwright].each do |arac|
    rs = sonuclar.select { |r| r["arac"] == arac }
    next if rs.empty?

    puts "#{arac}: #{rs.count { |r| r['pass'] }}/#{rs.size} geçti | " \
         "ort adım #{(rs.sum { |r| r['adim'] } / rs.size.to_f).round(1)} | " \
         "ort süre #{(rs.sum { |r| r['sure'] } / rs.size.to_f).round(1)}s"
  end
end

main if $PROGRAM_NAME == __FILE__
