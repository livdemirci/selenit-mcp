#!/usr/bin/env ruby
# egitim v2: düzeltilmiş seçicilerle çoklu e-ticaret antrenman + maliyet tablosu.
# Snap verimliliği için max_elements parametresi dışarıdan: ruby egitim.rb 40|20
# DOM hızlıysa kullan ilkesi: her durumu okuma ikili (snapshot + browser_dom/dom) yapılır.
require "json"
require "fileutils"
require_relative "mcp_client"

MONO = Process::CLOCK_MONOTONIC
LOG = []
mcp = McpClient.new(port: ENV["BENCH_MCP_PORT"] || "19420", max_elements: (ARGV[0] || 40).to_s)

def m(mcp, ad, args)
  t0 = Process.clock_gettime(MONO)
  out = mcp.call(ad, args)
  ms = ((Process.clock_gettime(MONO) - t0) * 1000).round
  [out, ms]
end

def mcall(mcp, log, ad, args, adi)
  out, ms = m(mcp, ad, args)
  log << { ad: adi, sure_ms: ms, karakter: out.to_s.length }
  out
end

def ikili(mcp, log, adi, q = nil)
  snap, s_ms = m(mcp, "browser_snapshot", {})
  dom, d_ms = m(mcp, "browser_dom", q ? { q: q, limit: 6 } : {})
  log << { ad: "#{adi}:snapshot", sure_ms: s_ms, karakter: snap.to_s.length }
  log << { ad: "#{adi}:dom", sure_ms: d_ms, karakter: dom.to_s.length }
  [snap, dom]
end

# ============================ N11 =========================================
begin
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.n11.com.tr/" }, "n11:navigate")
  ikili(mcp, LOG, "n11:açılış")
  mcall(mcp, LOG, "browser_type", { selector: "input[placeholder*='ara' i]", text: "kulaklık", submit: true }, "n11:arama")
  mcall(mcp, LOG, "browser_wait_for", { type: "selector", selector: "a[href*='/urun/']", timeout: 12 }, "n11:liste-bekle")
  ikili(mcp, LOG, "n11:liste")
  mcall(mcp, LOG, "browser_click", { text: "En Düşük Fiyat" }, "n11:sıralama")
  mcall(mcp, LOG, "browser_wait_for", { type: "url", timeout: 8, value: "fiyat" }, "n11:url-sıralı")
  ikili(mcp, LOG, "n11:sıralı")
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.n11.com.tr/sepet" }, "n11:sepete-gidiş")
  ikili(mcp, LOG, "n11:sepet")
rescue StandardError => e
  LOG << { ad: "n11:HATA", sure_ms: 0, karakter: 0, mesaj: e.message.lines.first.to_s.strip }
end

# ============================ AMAZON ======================================
begin
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.amazon.com.tr/" }, "amazon:navigate")
  c = mcall(mcp, LOG, "browser_dom", {}, "amazon:durum")
  if /modal|çerez/i.match?(c)
    mcall(mcp, LOG, "browser_click", { text: "Tümünü Kabul Et" }, "amazon:çerez") rescue nil
  end
  mcall(mcp, LOG, "browser_type", { selector: "#twotabsearchtextbox", text: "kulaklık", submit: true }, "amazon:arama")
  mcall(mcp, LOG, "browser_wait_for", { type: "selector", selector: "div[data-asin]:not([data-asin=''])", timeout: 12 }, "amazon:liste-bekle")
  ikili(mcp, LOG, "amazon:liste", "div[data-asin]:not([data-asin=''])")
  # Sıralama: URL parametresi ile (dropdown tıklaması yerine). Hız kazanımı.
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.amazon.com.tr/s?k=kulakl%C4%B1k&s=price-asc-rank" }, "amazon:fiyat-sıralı-url")
  ikili(mcp, LOG, "amazon:sıralı", "div[data-asin]:not([data-asin=''])")
  # İlk ORGANİK kart (reklam redirect'i atla): doğrudan /dp/ linki.
  mcall(mcp, LOG, "browser_click", { selector: "div[data-asin]:not([data-asin='']) a[href^='https://www.amazon.com.tr/dp/']" }, "amazon:ilk-organik")
  mcall(mcp, LOG, "browser_click", { selector: "#add-to-cart-button" }, "amazon:sepete-ekle")
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.amazon.com.tr/gp/cart/view.html" }, "amazon:sepet")
  ikili(mcp, LOG, "amazon:sepet")
rescue StandardError => e
  LOG << { ad: "amazon:HATA", sure_ms: 0, karakter: 0, mesaj: e.message.lines.first.to_s.strip }
end

# ============================ ÇİÇEKSEPETİ =================================
begin
  mcall(mcp, LOG, "browser_navigate", { url: "https://www.ciceksepeti.com/" }, "cicek:navigate")
  c = mcall(mcp, LOG, "browser_dom", {}, "cicek:engel-kontrol")
  abort_log = /Bir dakika/i.match?(c)
  if abort_log
    LOG << { ad: "cicek:ATLANDI", sure_ms: 0, karakter: 0, mesaj: "anti-bot engeli (Bir dakika lütfen)" }
  else
    mcall(mcp, LOG, "browser_type", { selector: "input[placeholder*='ara' i], input[name='q']", text: "çiçek", submit: true }, "cicek:arama")
    mcall(mcp, LOG, "browser_wait_for", { type: "selector", selector: "a[href*='/p/'], a[href*='urun']", timeout: 10 }, "cicek:liste-bekle")
    ikili(mcp, LOG, "cicek:liste")
  end
rescue StandardError => e
  LOG << { ad: "cicek:HATA", sure_ms: 0, karakter: 0, mesaj: e.message.lines.first.to_s.strip }
end

FileUtils.mkdir_p("artifacts")
File.write("artifacts/egitim-v2.json", JSON.pretty_generate(max_elements: (ARGV[0] || 40).to_s, adımlar: LOG))
puts "--- egitim v2 (max_elements=#{ARGV[0] || 40}) ---"
LOG.each_with_index do |h, i|
  printf("%3d %-26s %7dms %8dkar %s\n", i + 1, h[:ad], h[:sure_ms], h[:karakter], h[:mesaj] ? "HATA:#{h[:mesaj][0, 50]}" : "")
end
snaps = LOG.select { |h| h[:ad].end_with?(":snapshot") }
doms = LOG.select { |h| h[:ad].end_with?(":dom") }
unless snaps.empty? || doms.empty?
  puts sprintf("ORT snapshot: %5dms / %5dkar   ORT dom: %4dms / %4dkar",
               snaps.sum { |x| x[:sure_ms] } / snaps.size,
               snaps.sum { |x| x[:karakter] } / snaps.size,
               doms.sum { |x| x[:sure_ms] } / doms.size,
               doms.sum { |x| x[:karakter] } / doms.size)
end
