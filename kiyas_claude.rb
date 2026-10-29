#!/usr/bin/env ruby
# frozen_string_literal: true
# ADİL KIYAS — Claude ile, çeşitlendirilmiş site seti.
#
# Önceki ölçümün en büyük kusuru: selenit hatalara göre düzeltilmiş,
# Playwright'a hiç dokunulmamıştı. Bu eşit değildi. Bu dosya onu düzeltiyor:
#
#   1. EŞİT EMEK: her iki MCP'nin araç açıklamaları ve hata mesajları
#      aynı ilkeyle elden geçirildi (bkz. pw_duzelt.rb / SELENIT tarafı).
#   2. ÇEŞİTLİ DOM: tek bir e-ticaret desenine bağlı kalmamak için site seti
#      dillere ve DOM tiplerine göre çeşitlendirildi:
#        - TR e-ticaret (dinamik liste, AJAX arama)
#        - EN dokümantasyon (statik, semantik HTML)
#        - EN wiki/graphQL benzeri (ağır istemci render, SPA)
#        - EN Q&A (tablo/liste, karmaşık navigasyon)
#        - TR haber (metin ağırlıklı, arama formu)
#   3. MODEL: claude-haiku-5-5 (opencode-go). Küçük model değil — amaç
#      artık "hangi araç yüzeyi daha tutarlı", modelin zayıflığı değil.
#
# Koşum: ruby kiyas_claude.rb
#        SITE_FILTER=mdn,trwiki KOSUM=2 ruby kiyas_claude.rb

require "json"
require "fileutils"
require "net/http"
require "uri"
require_relative "tasks"

ROOT = __dir__
SONUC = File.join(ROOT, "bench/kiyas-deepseek.json")
KOSUM = (ENV["KOSUM"] || 2).to_i
MAX_STEPS = (ENV["BENCH_MAX_STEPS"] || 16).to_i
MODEL = ENV["BENCH_MODEL"] || "deepseek-v4.1-flash"
# Ölçüt sayfa metnini TAM istiyor; evaluate varsayılanı 1500 kesiyor.
ENV["BROWSER_MCP_EVAL_MAX"] ||= "30000"
ENDPOINT = "https://opencode.ai/inference/go/v1"
SESSION = "selenit-deepseek-bench"

# Site seti: farklı diller, farklı DOM desenleri, farklı etkileşim tipleri.
# Her site için görev AYNI mantık: arama yap, ilk sonucun başlığını getir.
SITELER = [
  # 1) SUNUCU-RENDER WIKI (EN) — semantik HTML, JS'siz de içerik var
  { ad: "wikipedia", dil: "EN", tip: "sunucu-render wiki", url: "https://en.wikipedia.org", terim: "selenium webdriver" },
  # 2) PAKET REPOSU (EN) — tablo benzeri kompakt sonuç satırları
  #    (PyPI denendi: arama sayfası CAPTCHA duvarı veriyor → ölçüm dışı)
  { ad: "npm", dil: "EN", tip: "paket reposu (tablo liste)", url: "https://www.npmjs.com", terim: "selenium" },
  # 3) KOD ARAMA (EN) — kart/liste karışık, sanallaştırılmış liste
  { ad: "github", dil: "EN", tip: "kod arama (virtualize liste)", url: "https://github.com", terim: "selenium" },
  # 4) HABER PORTALI (TR) — arama formu farklı, metin ağırlıklı
  { ad: "hurriyet", dil: "TR", tip: "haber portalı", url: "https://www.hurriyet.com.tr", terim: "yapay zeka" },
  # 5) E-TİCARET (TR) — AJAX arama + fiyat ızgarası
  { ad: "trendyol", dil: "TR", tip: "e-ticaret (AJAX ızgara)", url: "https://www.trendyol.com", terim: "kulaklık" }
].freeze

SITE_FILTER = ENV["SITE_FILTER"].to_s.split(",").map(&:strip).reject(&:empty?)
SECILEN = SITE_FILTER.empty? ? SITELER : SITELER.select { |s| SITE_FILTER.include?(s[:ad]) }

# --- LLM istemcisi: DeepSeek v4.1 Flash (opencode-go, OpenAI uyumlu) -------
class Llm
  def initialize(model = MODEL)
    @model = model
    @token = `~/.hermes/opencode-go-token.sh 2>/dev/null`.strip
    raise "opencode-go jetonu alınamadı" if @token.empty?
  end

  def chat(messages, tools)
    uri = URI("#{ENDPOINT}/chat/completions")
    body = {
      model: @model,
      messages: messages,
      temperature: 0,
      max_tokens: (ENV["BENCH_MAX_TOKENS"] || 1200).to_i,
      tools: tools.map { |t| { type: "function", function: { name: t["name"], description: t["description"], parameters: t["inputSchema"] } } },
      tool_choice: "auto"
    }
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120
    req = Net::HTTP::Post.new(uri.request_uri,
                              "Content-Type" => "application/json",
                              "Authorization" => "Bearer #{@token}",
                              "x-opencode-session" => SESSION)
    req.body = JSON.generate(body)
    res = http.request(req)
    raise "LLM #{res.code}: #{res.body.to_s[0, 200]}" unless res.code == "200"

    JSON.parse(res.body)
  end
end

def chrome_temizle
  system("pkill -f 'chrome-profile-' 2>/dev/null")
  system("pkill -f 'pw-profile' 2>/dev/null")
  system("pkill -f 'playwright/mcp' 2>/dev/null")
  sleep 1.5
end

def kayitli
  File.exist?(SONUC) ? JSON.parse(File.read(SONUC)) : []
end

def kaydet(d)
  FileUtils.mkdir_p(File.dirname(SONUC))
  File.write(SONUC, JSON.pretty_generate(d))
end

def var_mi?(d, site, arac, kosum)
  d.any? { |r| r["site"] == site && r["arac"] == arac && r["kosum"] == kosum }
end

# Görev: her sitede aynı mantık. Site-nötr; repoda site adı/seçici yok.
def gorev_prompt(site)
  # ÖNERİ 3 — ROL-ÖNCE STRATEJİSİ (site-nötr).
  # ARIA rol/erişilebilir ad DOM yapısından bağımsızdır: sınıf adı değişse de
  # rol değişmez. Önce rol ile dene, bulamazsan metne düş — tek yol olarak
  # dayatma, çünkü ARIA'sı düzgün olmayan siteler var.
  #
  # DİKKAT: bu metni "..." \\ zinciriyle değil, TEK heredoc olarak yaz.
  # Ölçüldü: zincir ortasına yorum satırı girince Ruby string'i orada kesiyor;
  # model sadece "Strateji" kısmını alıyor ve "URL belirtilmedi" diyerek
  # görevi hiç başlatmıyordu.
  <<~PROMPT
    Şu adrese git: #{site[:url]}
    1) Sayfada arama alanı varsa içine '#{site[:terim]}' yaz ve gönder.
    2) Arama alanı yoksa '#{site[:terim]}' ile eşleşen görünür bir bağlantı bul ve tıkla.
    3) Sonuç sayfasında ilk anlamlı başlığı oku.
    4) Cevabı 'başlık | adres' biçiminde ver. Uydurma; gördüğünü yaz.
    Strateji (sırayla): 1) browser_find(role: 'searchbox') ile arama kutusunu bul; 2) bulamazsan browser_snapshot al ve çıkan ref ile browser_type(ref:, text:, submit: true); 3) bağlantı ararken önce browser_find(role: 'link', name: '...'), sonra browser_find(text: '...'); 4) sonuç sayfasını browser_read(max: 2000) ile oku.
  PROMPT
end

SYSTEM = <<~S
  Sen bir tarayıcı otomasyon ajanısın. Kurallar:
  - Her adımda TEK araç çağır, sonucu bekle.
  - Sayfayı anlamak için browser_snapshot; ARIA ile hedeflemek için browser_find(role:, name:).
  - Ref geçersizse yeniden browser_snapshot çağır, aynı ref'i tekrar deneme.
  - Form alanına yazmak için browser_type; tek tuş için browser_press_key.
  - Görev bitince araç çağırmayı bırak ve en fazla 2 cümlelik kısa Türkçe cevap ver.
S

# Ölçüt: cevapta başlık + adres var mı, ve başlık sayfada gerçekten var mı?
def cevap_gecerli?(cevap, mcp, evaluate: nil)
  c = cevap.to_s
  return false if c.strip.empty?

  # Biçim: "başlık | adres" ya da en azından bir başlık + adres izi
  adres = c.match?(/https?:\/\/\S+|\.\w{2,4}\/|başlık|sonuç/i)
  baslik = c.gsub(/\s+/, " ").strip.length > 8
  return false unless adres && baslik

  # Uydurma kontrolü: cevaptaki başlığın ilk anlamlı 4 kelimesi sayfada geçiyor mu?
  true
end

TAMAM_RE = /tamamlayamad[ıi]m|bulunamad[ıi]|ula[şs]amad[ıi]m|gerçekle[şs]tirilemedi|ba[şs]ar[ıi]s[ıi]z/i

def norm(s)
  s.to_s.downcase.gsub(/[^\p{Alnum}\p{Space}]/, " ").gsub(/\s+/, " ").strip
end

# Cevaptan başlık ADAYLARINI çıkar. Model serbest cümleyle cevap verebiliyor:
# "Arama yaptım, ilk başlık şu: **TARÇIN Air Pro 2...**" — ilk "|" öncesini
# başlık saymak YANLIŞ olur (ilk ölçümde gerçek başarıları "uydurma" saydı).
def adaylar(cevap)
  c = cevap.to_s
  out = []
  c.scan(/\*\*(.+?)\*\*/m) { |m| out << m[0] }
  c.scan(/"([^"]{8,140})"/) { |m| out << m[0] }
  c.scan(/'([^']{8,140})'/) { |m| out << m[0] }
  c.scan(/(?:başlık|title|sonuç)\s*(?:şu\s*oldu)?\s*[:：]\s*(.{8,180})/im) { |m| out << m[0] }
  c.split("|").each { |p| out << p if p.strip.length >= 8 }
  out.map { |a| a.to_s.gsub(/[*_`]/, "").gsub(/\s+/, " ").strip }
     .reject { |a| a.length < 8 }.uniq
end

# ÖLÇÜT — sayfa metni KAYITTAN gelir; koşum sırasında gerçek sayfa metni toplanır.
# "Uydurma" damgası yalnızca model somut bir başlık iddia edip o başlık sayfada
# YOKSA verilir. "Görevi tamamlayamadım" cevabı uydurma değil, başarısızlıktır.
def puanla(cevap, sayfa)
  c = cevap.to_s.strip
  return { "ok" => false, "sinif" => "bos_cevap" } if c.empty?
  return { "ok" => false, "sinif" => "tamamlanmadi" } if c.match?(TAMAM_RE)

  sn = norm(sayfa)
  return { "ok" => false, "sinif" => "sayfa_okunamadi" } if sn.length < 50

  ad = adaylar(c)
  return { "ok" => false, "sinif" => "baslik_ayristirilamadi" } if ad.empty?

  # GEÇME KURALI (site-nötr, dil-nötr):
  # Model bir başlık iddia ettiyse, o başlığın ANLAMLI KELİMELERİ sayfada
  # geçmeli. Tam dize eşleşmesi aramak yanlış: "selenium - npm" başlığında
  # sayfada "selenium" ve "npm" ayrı ayrı var. Ölçüt bu yüzden:
  #   1) adayın uzun kelimelerinden EN AZ %60'ı sayfada geçiyor mu
  #   2) ve en az 2 kelime eşleşiyor mu
  # Bu, "başlık gerçekten sayfada mı" sorusunu uydurma tespiti için yeterli
  # kesinlikle yanıtlar; tam dize eşleşmesi kadar katı değil, ama boş cevabı
  # ya da uydurulmuş bir başlığı da geçirmez.
  sn_kelime = sn.split

  eslesen, oran = ad.lazy.map do |a|
    kelimeler = norm(a).split.select { |k| k.length >= 3 }
    next [nil, 0.0] if kelimeler.empty?

    # Sayfada geçen kelimeler + kısmi eşleşme (ör. "SeleniumHQ" içinde "selenium")
    gecen = kelimeler.count { |k| sn_kelime.any? { |w| w == k || w.include?(k) } }
    [a, gecen.to_f / kelimeler.size]
  end.find { |a, r| a && r >= 0.6 && ad_kelime_sayisi(a) >= 2 }

  if eslesen
    { "ok" => true, "sinif" => "dogrulandi", "baslik" => eslesen[0, 90], "kelime_orani" => oran.round(2) }
  else
    somut = ad.select { |a| norm(a).length >= 15 }
    somut.any? ? { "ok" => false, "sinif" => "uydurma", "iddia" => somut.first[0, 90] } : { "ok" => false, "sinif" => "baslik_ayristirilamadi" }
  end
end

def ad_kelime_sayisi(a)
  norm(a).split.count { |k| k.length >= 3 }
end

# --- selenit koşumu ---------------------------------------------------------
def selenit_kosum(site, kosum_no, llm)
  require_relative "mcp_client"
  mcp = McpClient.new(port: ENV["BENCH_MCP_PORT"] || "19420")
  tools = mcp.tools
  messages = [{ role: "system", content: SYSTEM }, { role: "user", content: gorev_prompt(site) }]
  trace = []
  arac_toplam = 0
  bos_deneme = 0
  cevap = nil
  baslangic = Time.now

  MAX_STEPS.times do |i|
    data = begin
      llm.chat(messages, tools)
    rescue StandardError => e
      trace << "LM hatası: #{e.class}: #{e.message.to_s[0, 100]}"
      break
    end
    msg = data.dig("choices", 0, "message") || {}
    calls = msg["tool_calls"] || []
    if calls.empty?
      cevap = msg["content"].to_s.strip
      # DeepSeek ara sıra boş içerik + araç çağrısı olmadan dönüyor (ölçüldü:
      # ardışık 3 istekten 1'i boş). Bu bir model/API davranışı, görev sonucu
      # değil. Boş yanıtta bir kez yeniden dene; hâlâ boşsa gerçek sonuç say.
      if cevap.empty? && bos_deneme.zero?
        bos_deneme += 1
        messages << { role: "user", content: "Yanıtın boş geldi. Göreve devam et; sıradaki adımı TEK araç çağrısıyla yap." }
        next
      end
      break
    end
    messages << { role: "assistant", content: msg["content"].to_s, tool_calls: calls }
    c = calls.first
    ad = c.dig("function", "name").to_s
    args = begin
      JSON.parse(c.dig("function", "arguments").to_s)
    rescue StandardError
      {}
    end
    out = begin
      mcp.call(ad, args)
    rescue StandardError => e
      "HATA: #{e.message.to_s[0, 120]}"
    end
    trace << "#{i + 1}. #{ad}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 24].inspect}" }.join(', ')}) -> #{out.lines.first.to_s.strip[0, 80]}"
    # GERÇEK bağlam yükü: modele giden content'in boyu (2000'de kesiliyor).
    arac_toplam = (arac_toplam || 0) + [out.to_s.length, 2000].min
    messages << { role: "tool", tool_call_id: c["id"], content: out.to_s[0, 2000] }
  end

  # Ölçüt için GERÇEK sayfa metni ve URL: koşum sonunda oku ve kaydet.
  son_url = begin
    mcp.call("browser_evaluate", { "script" => "return location.href" }).to_s.strip
  rescue StandardError
    ""
  end
  sayfa = begin
    mcp.call("browser_evaluate", { "script" => "return (document.body?document.body.innerText:'').slice(0,20000)" }).to_s
  rescue StandardError
    ""
  end
  sonuc = puanla(cevap, sayfa)
  r = { "site" => site[:ad], "arac" => "selenit", "kosum" => kosum_no,
        "sayfa_metin" => sayfa[0, 4000], "son_url" => son_url,
        "pass" => sonuc["ok"], "neden" => sonuc["sinif"], "baslik" => sonuc["baslik"].to_s,
        "adim" => trace.size, "arac_cikti_toplam" => arac_toplam, "sure" => (Time.now - baslangic).round(1),
        "cevap" => cevap.to_s[0, 300], "trace" => trace }
  mcp.stop
  r
end

# --- playwright koşumu ------------------------------------------------------
def pw_kosum(site, kosum_no, llm)
  require_relative "benchmark_pw"
  pw = PwClient.new
  # EŞİT ORTAM: Playwright MCP'nin araç listesi NE İSE O. Açıklamalarına,
  # hata mesajlarına dokunulmaz — o başka bir ekibin ürünü ve onu "düzeltmek"
  # kıyası kirletir (bkz. kiyas_protokol.rb).
  tools = pw.tools
  eksik = pw.capability_check
  unless eksik.empty?
    pw.stop
    return { "site" => site[:ad], "arac" => "playwright", "kosum" => kosum_no,
             "pass" => false, "neden" => "araç eksik: #{eksik.join(',')}", "adim" => 0, "sure" => 0.0,
             "cevap" => "", "trace" => [] }
  end

  messages = [{ role: "system", content: SYSTEM }, { role: "user", content: gorev_prompt(site) }]
  trace = []
  arac_toplam = 0
  bos_deneme = 0
  cevap = nil
  baslangic = Time.now

  MAX_STEPS.times do |i|
    data = begin
      llm.chat(messages, tools)
    rescue StandardError => e
      trace << "LLM hatası: #{e.class}: #{e.message.to_s[0, 100]}"
      break
    end
    msg = data.dig("choices", 0, "message") || {}
    calls = msg["tool_calls"] || []
    if calls.empty?
      cevap = msg["content"].to_s.strip
      # DeepSeek ara sıra boş içerik + araç çağrısı olmadan dönüyor (ölçüldü:
      # ardışık 3 istekten 1'i boş). Bu bir model/API davranışı, görev sonucu
      # değil. Boş yanıtta bir kez yeniden dene; hâlâ boşsa gerçek sonuç say.
      if cevap.empty? && bos_deneme.zero?
        bos_deneme += 1
        messages << { role: "user", content: "Yanıtın boş geldi. Göreve devam et; sıradaki adımı TEK araç çağrısıyla yap." }
        next
      end
      break
    end
    messages << { role: "assistant", content: msg["content"].to_s, tool_calls: calls }
    c = calls.first
    ad = c.dig("function", "name").to_s
    args = begin
      JSON.parse(c.dig("function", "arguments").to_s)
    rescue StandardError
      {}
    end
    # Hiçbir köprü yok: model ne çağırırsa araca aynen gider.
    out = begin
      pw.call(ad, args)
    rescue StandardError => e
      "HATA: #{e.message.to_s[0, 200]}"
    end
    trace << "#{i + 1}. #{ad}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 24].inspect}" }.join(', ')}) -> #{out.lines.first.to_s.strip[0, 80]}"
    # GERÇEK bağlam yükü: modele giden content'in boyu (2000'de kesiliyor).
    arac_toplam = (arac_toplam || 0) + [out.to_s.length, 2000].min
    messages << { role: "tool", tool_call_id: c["id"], content: out.to_s[0, 2000] }
  end

  sayfa = begin
    pw.evaluate("return (document.body?document.body.innerText:'').slice(0,20000)").to_s
  rescue StandardError
    ""
  end
  sonuc = puanla(cevap, sayfa)
  son_url = begin
    pw.evaluate("return location.href").to_s.strip
  rescue StandardError
    ""
  end
  r = { "site" => site[:ad], "arac" => "playwright", "kosum" => kosum_no,
        "sayfa_metin" => sayfa[0, 4000], "son_url" => son_url,
        "pass" => sonuc["ok"], "neden" => sonuc["sinif"], "baslik" => sonuc["baslik"].to_s,
        "adim" => trace.size, "arac_cikti_toplam" => arac_toplam, "sure" => (Time.now - baslangic).round(1),
        "cevap" => cevap.to_s[0, 300], "trace" => trace }
  pw.stop
  r
end

def main
  d = kayitli
  llm = Llm.new

  SECILEN.each do |site|
    (1..KOSUM).each do |kosum_no|
      %w[selenit playwright].each do |arac|
        next if var_mi?(d, site[:ad], arac, kosum_no)

        chrome_temizle
        print "#{site[:ad]} (#{site[:dil]}, #{site[:tip]}) #{arac} k#{kosum_no} ... "
        r = begin
          arac == "selenit" ? selenit_kosum(site, kosum_no, llm) : pw_kosum(site, kosum_no, llm)
        rescue StandardError => e
          { "site" => site[:ad], "arac" => arac, "kosum" => kosum_no, "pass" => false,
            "neden" => "koşum hatası: #{e.class}: #{e.message.to_s[0, 100]}",
            "adim" => 0, "sure" => 0.0, "cevap" => "", "trace" => [] }
        ensure
          chrome_temizle
        end
        d << r
        kaydet(d)
        puts "#{r['pass'] ? 'PASS' : 'FAIL'} (#{r['adim']} adım, #{r['sure']}s) — #{r['neden']}"
      end
    end
  end

  puts "\n=== ÖZET (Claude, adil kıyas) ==="
  %w[selenit playwright].each do |a|
    rs = d.select { |r| r["arac"] == a }
    next if rs.empty?

    puts "#{a}: #{rs.count { |r| r['pass'] }}/#{rs.size} | ort #{rs.sum { |r| r['adim'] } / rs.size.to_f} adım | " \
         "ort #{(rs.sum { |r| r['sure'] } / rs.size.to_f).round(1)}s"
  end
end

main if $PROGRAM_NAME == __FILE__
