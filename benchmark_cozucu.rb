require "json"
require "time"
require "net/http"

# MODEL SÜRÜCÜLÜ ÇÖZÜCÜ — benchmark.rb ile aynı akış, aynı araçlar, aynı ölçüt.
#
# Fark: model her adımda TÜM sayfa metnini değil, araç listesini + sayfanın
# KISA durum özetini (snapshot satırları) görür ve döngü koruması istemci
# tarafında uygulanır. Amaç: 3-4B modellerin uzun bağlamda kaybolmasını
# ayırmak — "araç yüzeyi + ölçüt" aynı kalır, yalnızca modelin gördüğü bağlam
# sadeleşir. Ölçüm sonuçları JSONL'e yazılır (makale için ham veri).
#
# Kullanım:
#   ruby benchmark_cozucu.rb filtre2 [kosum_sayisi]
#   SELENIT_TARGET_URL=... SELENIT_FILTER_MIN=... SELENIT_FILTER_MAX=... \
#   SELENIT_SORT_LABEL=... ruby benchmark_cozucu.rb filtre2 5

require_relative "mcp_client"
require_relative "tasks"

LM_STUDIO = ENV["LM_STUDIO_URL"] || "http://127.0.0.1:1234"
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"
MAX_ADIM = (ENV["BENCH_MAX_STEPS"] || 18).to_i
KOSUM = (ARGV[1] || 1).to_i

COZUCU_SYSTEM = <<~S
  Sen bir tarayıcı otomasyon ajanısın. Her turda TEK araç çağrısı üretirsin.
  Cevabın SADECE şu JSON olmalı, başka metin YOK:
  {"tool": "<araç adı>", "args": {...}, "not": "<kısa gerekçe>"}
  Görev bittiyse: {"tool": "BITIR", "answer": "<istenen biçimde cevap>"}
  Kurallar:
  - Sayfayı görmek için browser_snapshot kullan (e1, e2 ... ref'leri).
  - Aynı öğe için iki satır varsa (a ... ve button[button] ...) BUTON satırını seç.
  - Aynı çağrıyı tekrarlama; sonuç gelmediyse farklı öğe/araç dene.
  - Fiyat/ilan no gibi değerleri UYDURMA; sayfada yoksa "yok" yaz.
S

def llm(messages)
  uri = URI("#{LM_STUDIO}/v1/chat/completions")
  body = {
    model: MODEL,
    messages: messages,
    temperature: 0,
    max_tokens: (ENV["BENCH_MAX_TOKENS"] || 400).to_i,
    **(ENV.fetch("BENCH_THINKING", "0") == "0" ? { chat_template_kwargs: { enable_thinking: false } } : {})
  }
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 180
  req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
  req.body = JSON.generate(body)
  res = http.request(req)
  raise "LM Studio #{res.code}: #{res.body[0, 200]}" unless res.code == "200"

  JSON.parse(res.body).dig("choices", 0, "message", "content").to_s
end

def json_al(metin)
  s = metin.to_s
  i = s.index("{")
  j = s.rindex("}")
  return nil unless i && j && j > i

  JSON.parse(s[i..j])
rescue JSON::ParserError
  nil
end

def kosum(task_key, spec, mcp, tools)
  basladi = Time.now
  gorev = spec[:prompt].respond_to?(:call) ? spec[:prompt].call : spec[:prompt]
  arac_listesi = tools.map { |t| t["name"] }.join(", ")
  mesajlar = [
    { role: "system", content: COZUCU_SYSTEM },
    { role: "user", content: "KULLANILABİLİR ARAÇLAR: #{arac_listesi}\n\nGÖREV:\n#{gorev}" }
  ]
  gecmis = []
  tekrar = Hash.new(0)
  cevap = nil
  adim = 0
  trace = []

  # görevler arası temizlik (benchmark.rb ile aynı)
  %w[browser_frame browser_alert browser_tabs].each do |t|
    mcp.call(t, { "action" => (t == "browser_frame" ? "main" : (t == "browser_alert" ? "accept" : "close_others")) }) rescue nil
  end

  MAX_ADIM.times do
    adim += 1
    ham = llm(mesajlar)
    istek = json_al(ham)
    if istek.nil?
      trace << "#{adim}. (JSON çözülemedi) #{ham.lines.first.to_s.strip[0, 60]}"
      gecmis << "model geçersiz JSON üretti, formatı tekrar hatırlat"
      mesajlar << { role: "assistant", content: ham }
      mesajlar << { role: "user", content: "Sadece JSON döndür: {\"tool\": ..., \"args\": {...}}" }
      next
    end

    if istek["tool"].to_s == "BITIR"
      cevap = istek["answer"].to_s
      trace << "#{adim}. BITIR: #{cevap[0, 120]}"
      break
    end

    ad = istek["tool"].to_s
    args = istek["args"].is_a?(Hash) ? istek["args"] : {}
    imza = "#{ad}:#{JSON.generate(args)}"
    tekrar[imza] += 1

    if tekrar[imza] > 2
      trace << "#{adim}. #{ad}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 20]}" }.join(', ')}) -> ENGELLENDİ (aynı çağrı 3.)"
      mesajlar << { role: "assistant", content: ham }
      mesajlar << { role: "user", content: "Bu çağrıyı 3. kez yaptın ve ÇALIŞTIRILMADI. Farklı bir öğe/araç dene ya da bilgi yetiyorsa BITIR." }
      next
    end

    cikti = begin
      mcp.call(ad, args)
    rescue StandardError => e
      "HATA: #{e.class}: #{e.message.to_s[0, 100]}"
    end
    trace << "#{adim}. #{ad}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 24]}" }.join(', ')}) -> #{cikti.lines.first.to_s.strip[0, 70]}"
    gecmis << "#{ad} #{args.map { |k, v| "#{k}=#{v.to_s[0, 24]}" }.join(' ')} => #{cikti.lines.first.to_s.strip[0, 80]}"
    mesajlar << { role: "assistant", content: ham }
    mesajlar << { role: "user", content: "SONUÇ:\n#{cikti[0, 2200]}\n\nSıradaki TEK adımı JSON olarak ver (ya da BITIR)." }
    # bağlamı sınırla: yalnızca son 8 tur tutulur
    mesajlar = mesajlar[0, 2] + mesajlar[2..][-8..-1].to_a if mesajlar.size > 12
  end

  gecti = begin
    spec[:check].call(mcp, cevap)
  rescue StandardError => e
    trace << "kontrol hatası: #{e.message}"
    false
  end

  kayit = {
    "at" => Time.now.iso8601,
    "task" => task_key,
    "model" => MODEL,
    "passed" => gecti,
    "adim" => adim,
    "sure" => (Time.now - basladi).round(1),
    "cevap" => cevap.to_s[0, 300],
    "hedef" => ENV["SELENIT_TARGET_URL"].to_s,
    "trace" => trace
  }
  File.open(File.expand_path("artifacts/cozucu_#{Time.now.strftime('%Y%m%d')}.jsonl", __dir__), "a") do |f|
    f.puts(JSON.generate(kayit))
  end
  kayit
end

key = ARGV[0] or abort("görev adı gerekli (ör. filtre2)")
spec = TASKS[key] or abort("bilinmeyen görev: #{key}")

sonuclar = KOSUM.times.map do |i|
  mcp = McpClient.new(port: (19_420 + i).to_s)
  r = begin
    kosum(key, spec, mcp, mcp.tools)
  rescue StandardError => e
    { "passed" => false, "adim" => 0, "sure" => 0, "cevap" => "", "trace" => ["HATA: #{e.class}: #{e.message[0, 120]}"] }
  ensure
    mcp.stop rescue nil
  end
  puts "koşum #{i + 1}/#{KOSUM}: #{r['passed'] ? 'PASS' : 'FAIL'} (#{r['adim']} adım, #{r['sure']}s) cevap=#{r['cevap'].to_s.gsub("\n", ' ')[0, 110]}"
  $stdout.flush
  r
end

gecen = sonuclar.count { |r| r["passed"] }
puts
puts "SONUÇ (#{MODEL} / #{key}): #{gecen}/#{KOSUM} geçti"
sonuclar.last(1).each { |r| r["trace"].each { |t| puts "  #{t}" } }
exit(gecen == KOSUM ? 0 : 1)
