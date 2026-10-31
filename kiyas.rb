# kiyas.rb — harici okunabilir head-to-head sürücü.
#
# Amaç: bir dış geliştiricinin kendi makinesinde `SITE_FILTER=wikipedia ruby kiyas.rb`
# diyerek Selenit MCP ile Playwright MCP'yi AYNI model + AYNI görev + AYNI ölçütle
# koşturabilmesi. Depodaki mevcut kiyas_claude.rb iç kullanım içindir (Türkçe
# alanlar, kişisel dosya yolları); bu dosya yayın için temizlenmiş sürümdür.
#
# Gereksinimler: Ruby 3.2+, selenium-webdriver gem, Chrome, LM Studio (OpenAI uyumlu
# sunucu 1234'te), node + npx (@playwright/mcp otomatik çekilir).
#
# Kullanım:
#   ruby kiyas.rb                                   # 5 site, 1 koşum
#   KOSUM=3 ruby kiyas.rb                           # 3 koşum, medyan
#   SITE_FILTER=wikipedia,npm ruby kiyas.rb
#   BENCH_MODEL=google/gemma-4-e4b ruby kiyas.rb
#   SADECE=selenit ruby kiyas.rb                    # yalnız bir taraf
#
# Çıktı: bench/kiyas-<model>-<zaman>.json (ham trace dahil) + konsola tablo.
require "json"
require "fileutils"
require "net/http"
require "open3"
require "time"
require "uri"
require_relative "mcp_client"

LM = ENV["LM_STUDIO_URL"] || "http://127.0.0.1:1234"
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"
KOSUM = (ENV["KOSUM"] || 1).to_i
MAX_STEPS = (ENV["BENCH_MAX_STEPS"] || 16).to_i
MAX_TOKENS = (ENV["BENCH_MAX_TOKENS"] || 1200).to_i
THINKING = ENV.fetch("BENCH_THINKING", "0")
PAUSE = (ENV["PAUSE"] || 20).to_f
SECILEN_ARAC = ENV["SADECE"].to_s.split(",").map(&:strip).reject(&:empty?)
STAMP = Time.now.strftime("%Y%m%d-%H%M")
OUT = File.join(__dir__, "bench", "kiyas-#{MODEL.gsub(/[^a-z0-9]+/i, '-')}-#{STAMP}.json")

# Site seti: farklı diller, farklı DOM desenleri, farklı etkileşim tipleri.
# Görev HER sitede aynı mantık: arama yap, ilk sonucun başlığını getir.
SITES = [
  { name: "wikipedia", lang: "EN", kind: "server-rendered wiki", url: "https://en.wikipedia.org", term: "selenium webdriver" },
  { name: "npm",       lang: "EN", kind: "package registry",      url: "https://www.npmjs.com",   term: "selenium" },
  { name: "github",    lang: "EN", kind: "code search",           url: "https://github.com",      term: "selenium" },
  { name: "hurriyet",  lang: "TR", kind: "news portal",           url: "https://www.hurriyet.com.tr", term: "yapay zeka" },
  { name: "trendyol",  lang: "TR", kind: "e-commerce (AJAX grid)", url: "https://www.trendyol.com", term: "kulaklık" }
].freeze

FILTER = ENV["SITE_FILTER"].to_s.split(",").map(&:strip).reject(&:empty?)
SELECTED = FILTER.empty? ? SITES : SITES.select { |s| FILTER.include?(s[:name]) }
raise "hiç site seçilmedi (#{FILTER.join(',')})" if SELECTED.empty?

# --- LLM: LM Studio, OpenAI uyumlu ----------------------------------------
class Llm
  def chat(messages, tools)
    uri = URI("#{LM}/v1/chat/completions")
    body = {
      model: MODEL,
      messages: messages,
      temperature: 0,
      max_tokens: MAX_TOKENS,
      tools: tools.map do |t|
        { type: "function",
          function: { name: t["name"], description: t["description"], parameters: t["inputSchema"] } }
      end,
      tool_choice: "auto"
    }
    # THINKING KAPATMA — ÇALIŞAN YOL (ölçüldü: enable_thinking artık etkisiz,
    # model thinking'i reasoning_content'e koyup content'i boş bırakıyor).
    # reasoning_effort=none 6/6 temiz sonuç verdi.
    if THINKING == "0"
      body[:reasoning_effort] = "none"
      body[:chat_template_kwargs] = { enable_thinking: false }
    end
    body[:stream] = true if ENV["BENCH_STREAM"] == "1"
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 180
    req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    res = http.request(req)
    raise "LLM #{res.code}: #{res.body.to_s[0, 200]}" unless res.code == "200"

    data = JSON.parse(res.body)
    @last_prompt_tokens = data.dig("usage", "prompt_tokens").to_i
    @last_completion_tokens = data.dig("usage", "completion_tokens").to_i
    data
  end

  def prompt_tokens = @last_prompt_tokens.to_i

  def completion_tokens = @last_completion_tokens.to_i
end

def wait_llm_ready!(tries = 24)
  tries.times do
    begin
      res = Net::HTTP.get_response(URI("#{LM}/v1/models"))
      return true if res.code == "200"
    rescue StandardError
      nil
    end
    sleep 2
  end
  raise "LM Studio sunucusu #{LM} yanıt vermiyor (OpenAI uyumlu sunucu açık mı?)"
end

SYSTEM = <<~S
  You are a browser automation agent. Rules:
  - Call exactly ONE tool per step and wait for its result.
  - Use browser_snapshot to understand the page; use browser_find(role:, name:) for ARIA targeting.
  - If a ref is invalid, take a new browser_snapshot; never retry the same ref.
  - Use browser_type for form fields and browser_press_key for single keys.
  - When the task is done, stop calling tools and answer in at most 2 short sentences.
S

def task_prompt(site)
  <<~PROMPT
    Go to: #{site[:url]}
    1) If the page has a search field, type '#{site[:term]}' into it and submit.
    2) If there is no search field, find a visible link matching '#{site[:term]}' and click it.
    3) On the result page, read the first meaningful heading.
    4) Answer in the form 'title | url'. Do not invent; report what you see.
    Strategy (in order): 1) browser_find(role: 'searchbox') for the search box; 2) otherwise browser_snapshot and browser_type(ref:, text:, submit: true); 3) for links try browser_find(role: 'link', name: '...') then browser_find(text: '...'); 4) read the result page with browser_read(max: 2000).
  PROMPT
end

# --- scoring: a claimed title must actually exist in the page text ---------
def norm(s) = s.to_s.downcase.gsub(/[^\p{Alnum}\p{Space}]/, " ").gsub(/\s+/, " ").strip

# ŞABLON ARTIKLARI — modele verilen "title | url" biçiminin kendisi.
# ÖLÇÜLDÜ (npm, gemma-4-e4b): model şablonu birebir kopyalayıp "title | url"
# döndürdü; ölçüt "title" kelimesini başlık sanıp "hallucinated" dedi.
# Oysa model aramayı doğru yapmıştı (sayfa başlığı: "selenium - npm search").
# Bu kelimeler ASLA başlık adayı olamaz.
SABLON_ARTIKLARI = %w[title url baslik başlık link href adres sonuc sonuç heading result].freeze

def sablon_mu?(s)
  norm(s).split.all? { |k| SABLON_ARTIKLARI.include?(k) }
end

def candidates(answer)
  c = answer.to_s
  out = []
  c.scan(/\*\*(.+?)\*\*/m) { |m| out << m[0] }
  c.scan(/"([^"]{8,140})"/) { |m| out << m[0] }
  c.scan(/'([^']{8,140})'/) { |m| out << m[0] }
  c.scan(/(?:title|heading|result|başlık|sonuç)\s*(?:is|was)?\s*[:：]\s*(.{8,180})/i) { |m| out << m[0] }
  c.split("|").each { |p| out << p if p.strip.length >= 8 }
  out.map { |a| a.to_s.gsub(/[*_`]/, "").gsub(/\s+/, " ").strip }
     .reject { |a| a.length < 8 }
     .reject { |a| sablon_mu?(a) }
     .uniq
end

FAIL_RE = /could not|couldn't|unable|failed|not found|i can't|cannot|tamamlayamad|bulunamad|ulaşamad|başarısız/i

def words(a) = norm(a).split.select { |k| k.length >= 3 }

def score(answer, page, thinking_leak: false)
  c = answer.to_s.strip
  if c.empty?
    # Thinking sızması ayrı sınıf: araç hatası DEĞİL, model yapılandırma sorunu.
    return { "ok" => false, "class" => "thinking_leak" } if thinking_leak

    return { "ok" => false, "class" => "empty_answer" }
  end
  return { "ok" => false, "class" => "not_completed" } if c.match?(FAIL_RE)

  pn = norm(page)
  return { "ok" => false, "class" => "page_unreadable" } if pn.length < 50

  cand = candidates(c)

  # URL KANITI — ÖLÇÜLDÜ (hurriyet, gemma-4-e4b): model "title | <doğru URL>"
  # döndürdü; başlık alanını doldurmadı ama URL sonuç sayfasının ta kendisiydi
  # ve sayfa başlığı da doğruydu. Yalnızca başlık metnine bakmak bu gerçek
  # başarıyı "hallucinated" sayıyordu. Cevaptaki URL sayfada geçiyorsa
  # (adres çubuğu ya da içerik) kanıt sayılır: model doğru sayfaya gitmiş.
  cevap_url = c[%r{https?://[^\s\)\]\}"']+}]
  if cevap_url && !cevap_url.empty?
    temiz_url = cevap_url.sub(%r{/+$}, "")
    if pn.include?(norm(temiz_url)) || norm(page).include?(norm(temiz_url.split("/").last.to_s))
      return { "ok" => true, "class" => "verified_url", "title" => temiz_url[0, 90] }
    end
  end

  return { "ok" => false, "class" => "title_unparsable" } if cand.empty?

  pw = pn.split
  hit, ratio = cand.lazy.map do |a|
    ws = words(a)
    next [nil, 0.0] if ws.empty?

    got = ws.count { |k| pw.any? { |w| w == k || w.include?(k) } }
    [a, got.to_f / ws.size]
  end.find { |a, r| a && r >= 0.6 && words(a).size >= 2 }

  if hit
    { "ok" => true, "class" => "verified", "title" => hit[0, 90], "word_ratio" => ratio.round(2) }
  else
    concrete = cand.select { |a| norm(a).length >= 15 }
    concrete.empty? ? { "ok" => false, "class" => "title_unparsable" } : { "ok" => false, "class" => "hallucinated", "claim" => concrete.first[0, 90] }
  end
end

# --- shared agent loop ------------------------------------------------------
def run_loop(llm, tools, call_tool, site)
  messages = [{ role: "system", content: SYSTEM }, { role: "user", content: task_prompt(site) }]
  trace = []
  out_chars = 0
  prompt_tokens = 0
  completion_tokens = 0
  answer = nil
  empty_retry = 0
  thinking_leak = false
  started = Time.now

  MAX_STEPS.times do |i|
    data = begin
      llm.chat(messages, tools)
    rescue StandardError => e
      trace << "LLM error: #{e.class}: #{e.message.to_s[0, 100]}"
      break
    end
    prompt_tokens += llm.prompt_tokens
    completion_tokens += llm.completion_tokens
    msg = data.dig("choices", 0, "message") || {}
    calls = msg["tool_calls"] || []
    if calls.empty?
      answer = msg["content"].to_s.strip
      # TEŞHİS: içerik boş ama reasoning dolu ise model THINKING moduna
      # kaçmıştır. Bunu "empty_answer" diye saymak yanıltıcı: araç değil
      # model yapılandırması bozuk demektir. Açıkça sınıflandır.
      if answer.empty? && msg["reasoning_content"].to_s.strip.length > 20
        answer = ""
        thinking_leak = true
      end
      if answer.empty? && empty_retry.zero?
        empty_retry += 1
        messages << { role: "user", content: "Your reply was empty. Continue the task with ONE tool call." }
        next
      end
      break
    end
    messages << { role: "assistant", content: msg["content"].to_s, tool_calls: calls }
    c = calls.first
    name = c.dig("function", "name").to_s
    args = begin
      JSON.parse(c.dig("function", "arguments").to_s)
    rescue StandardError
      {}
    end
    out = begin
      call_tool.call(name, args)
    rescue StandardError => e
      "ERROR: #{e.message.to_s[0, 120]}"
    end
    trace << "#{i + 1}. #{name}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 24].inspect}" }.join(', ')}) -> #{out.lines.first.to_s.strip[0, 80]}"
    out_chars += [out.to_s.length, 2000].min
    messages << { role: "tool", tool_call_id: c["id"], content: out.to_s[0, 2000] }
  end

  { trace: trace, out_chars: out_chars, answer: answer.to_s,
    prompt_tokens: prompt_tokens, completion_tokens: completion_tokens,
    thinking_leak: thinking_leak,
    seconds: (Time.now - started).round(1) }
end

# --- selenit side -----------------------------------------------------------
def selenit_run(site, llm, run_no)
  mcp = McpClient.new(port: ENV["BENCH_MCP_PORT"] || "19420")
  tools = mcp.tools
  r = run_loop(llm, tools, ->(n, a) { mcp.call(n, a) }, site)
  final_url = begin
    mcp.call("browser_evaluate", { "script" => "return location.href" }).to_s.strip
  rescue StandardError
    ""
  end
  page = begin
    # ÖLÇÜT İÇİN TAM METİN. 20000 karakter büyük listelerde yetmiyor:
    # ÖLÇÜLDÜ (trendyol): sayfa 31705 karakter, modelin verdiği DOĞRU başlık
    # kesilen kısımda kaldı ve "hallucinated" damgası yedi. Araç hatası değil,
    # ölçüt körlüğüydü. BROWSER_MCP_EVAL_MAX ile sınırsız oku.
    ENV["BROWSER_MCP_EVAL_MAX"] ||= "60000"
    mcp.call("browser_evaluate", { "script" => "return (document.body?document.body.innerText:'').slice(0,60000)" }).to_s
  rescue StandardError
    ""
  end
  s = score(r[:answer], page, thinking_leak: r[:thinking_leak])
  mcp.stop
  { "site" => site[:name], "tool" => "selenit", "run" => run_no, "pass" => s["ok"],
    "reason" => s["class"], "title" => s["title"].to_s, "claim" => s["claim"].to_s,
    "steps" => r[:trace].size, "output_chars" => r[:out_chars], "seconds" => r[:seconds],
    "prompt_tokens" => r[:prompt_tokens], "completion_tokens" => r[:completion_tokens],
    "answer" => r[:answer][0, 300], "final_url" => final_url,
    "page_text" => page[0, 4000], "trace" => r[:trace] }
end

# --- playwright side --------------------------------------------------------
require "open3"
class PwClient
  def initialize
    @in, @out, @wait = Open3.popen2(
      { "PLAYWRIGHT_BROWSERS_PATH" => ENV["PLAYWRIGHT_BROWSERS_PATH"] || "#{Dir.home}/Library/Caches/ms-playwright",
        "BROWSER_MCP_ARTIFACT_DIR" => File.join(__dir__, "artifacts") },
      "npx", "-y", "@playwright/mcp@latest", "--headless", "--isolated", err: "/tmp/pw_mcp.err"
    )
    @id = 0
    request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "bench", version: "0" } })
    write({ jsonrpc: "2.0", method: "notifications/initialized" })
  end

  def tools = request("tools/list", {})["tools"]

  def call(n, a)
    res = request("tools/call", { name: n, arguments: a })
    res.dig("content", 0, "text").to_s
  end

  def stop
    @in.close rescue nil
    @out.close rescue nil
    @wait.kill rescue nil
  end

  private

  def request(m, p)
    id = (@id += 1)
    write({ jsonrpc: "2.0", id: id, method: m, params: p })
    loop do
      line = Timeout.timeout(180) { @out.gets }
      raise "playwright MCP closed" if line.nil?

      msg = JSON.parse(line)
      return msg["result"] if msg["id"] == id && msg.key?("result")
      raise "playwright MCP error: #{msg['error']}" if msg["id"] == id && msg["error"]
    end
  end

  def write(o)
    @in.puts(JSON.generate(o))
    @in.flush
  end
end

def pw_run(site, llm, run_no)
  pw = PwClient.new
  tools = pw.tools
  r = run_loop(llm, tools, ->(n, a) { pw.call(n, a) }, site)
  # Sayfa metni MCP üzerinden: playwright MCP'de evaluate yok, snapshot metni en yakın karşılık.
  page = begin
    pw.call("browser_snapshot", {})
  rescue StandardError
    ""
  end
  final_url = page[%r{https?://[^\s\])"']+}].to_s
  # Sayfa metni: asıl ölçüt canlı sayfanın innerText'i olmalı; yoksa snapshot'a düş.
  # (Playwright MCP'de evaluate yok — ama navigate'in döndürdüğü snapshot metni yeterli değil,
  #  çünkü öğe listesi başlıkları eksik gösterebilir.)
  # Ölçüldü: navigate sonrası ilk evaluate "Execution context was destroyed" dönebiliyor
  # (sayfa hâlâ yükleniyor). İkinci deneme gerçek metni veriyor — bir kez yeniden dene.
  body = ""
  2.times do
    # Playwright tarafı da aynı sınırla (eşitlik: iki araç aynı genişlikte okunur)
    body = pw.call("browser_evaluate", { "function" => "() => document.body ? document.body.innerText.slice(0,60000) : ''" }).to_s
    break if body.length > 200

    sleep 1
  end
  page = body.to_s.length > 200 ? body.to_s : page
  s = score(r[:answer], page, thinking_leak: r[:thinking_leak])
  pw.stop
  { "site" => site[:name], "tool" => "playwright", "run" => run_no, "pass" => s["ok"],
    "reason" => s["class"], "title" => s["title"].to_s, "claim" => s["claim"].to_s,
    "steps" => r[:trace].size, "output_chars" => r[:out_chars], "seconds" => r[:seconds],
    "prompt_tokens" => r[:prompt_tokens], "completion_tokens" => r[:completion_tokens],
    "answer" => r[:answer][0, 300], "final_url" => final_url,
    "page_text" => page[0, 4000], "trace" => r[:trace] }
end

# --- main -------------------------------------------------------------------
FileUtils.mkdir_p(File.dirname(OUT))
wait_llm_ready!
rows = []
llm = Llm.new
puts "model=#{MODEL} thinking=#{THINKING} runs=#{KOSUM} max_steps=#{MAX_STEPS} sites=#{SELECTED.map { |s| s[:name] }.join(',')}"
puts "output: #{OUT}"

(1..KOSUM).each do |k|
  SELECTED.each do |site|
    %w[selenit playwright].each do |tool|
      next if !SECILEN_ARAC.empty? && !SECILEN_ARAC.include?(tool)

      # Koşumlar arası izolasyon. DİKKAT: desen mutlaka chrome-profile-<port> içermeli —
      # çıplak "chrome-profile-" deseni, komutu çalıştıran kabuğun kendi komut satırında da
      # geçtiği için pkill kendi süreç grubunu (ve harness'i) öldürüyor.
      port = ENV["BENCH_MCP_PORT"] || "19420"
      system("pkill -f 'chrome-profile-#{port}' >/dev/null 2>&1")
      system("pkill -f 'pw-profile-#{port}' >/dev/null 2>&1")
      sleep 1
      row = begin
        tool == "selenit" ? selenit_run(site, llm, k) : pw_run(site, llm, k)
      rescue StandardError => e
        { "site" => site[:name], "tool" => tool, "run" => k, "pass" => false,
          "reason" => "driver_error: #{e.message.to_s[0, 120]}", "steps" => 0,
          "output_chars" => 0, "seconds" => 0, "prompt_tokens" => 0,
          "completion_tokens" => 0, "trace" => [] }
      end
      rows << row
      File.write(OUT, JSON.pretty_generate(rows))
      puts format("  run %d %-10s %-11s %-5s steps=%-2d %6.1fs  out=%-6d tok=%-6d %s",
                  k, site[:name], tool, row["pass"] ? "PASS" : "FAIL",
                  row["steps"], row["seconds"], row["output_chars"],
                  row["prompt_tokens"].to_i + row["completion_tokens"].to_i, row["reason"])
      sleep PAUSE if PAUSE.positive?
    end
  end
end

# --- summary ----------------------------------------------------------------
def median(values)
  a = values.sort
  return 0 if a.empty?

  ((a[(a.size - 1) / 2] + a[a.size / 2]) / 2.0)
end

summary = {}
%w[selenit playwright].each do |t|
  rs = rows.select { |r| r["tool"] == t }
  next if rs.empty?

  pts = rs.map { |r| r["prompt_tokens"].to_i }
  cts = rs.map { |r| r["completion_tokens"].to_i }
  steps = rs.map { |r| r["steps"].to_f }
  summary[t] = {
    "tasks_passed" => rs.count { |r| r["pass"] },
    "tasks_total" => rs.size,
    "median_steps" => median(steps).round(1),
    "median_seconds" => median(rs.map { |r| r["seconds"].to_f }).round(1),
    "median_output_chars" => median(rs.map { |r| r["output_chars"].to_f }).round(0),
    "median_prompt_tokens" => median(pts.map(&:to_f)).round(0),
    "median_completion_tokens" => median(cts.map(&:to_f)).round(0),
    "median_tokens_per_step" => median(rs.map { |r| r["steps"].to_i.zero? ? 0.0 : (r["prompt_tokens"].to_i + r["completion_tokens"].to_i).to_f / r["steps"].to_i }).round(0)
  }
end

data = { "meta" => { "model" => MODEL, "runs" => KOSUM, "max_steps" => MAX_STEPS,
                     "max_tokens" => MAX_TOKENS, "thinking" => THINKING,
                     "temperature" => 0, "date" => Time.now.iso8601,
                     "sites" => SELECTED.map { |s| s[:name] }, "complete" => true,
                     "tool_output_cap_chars" => 2000 },
         "summary" => summary, "rows" => rows }
File.write(OUT, JSON.pretty_generate(data))

puts "\nsummary"
summary.each do |t, s|
  puts format("  %-11s %d/%d pass  median %s steps  %ss  out %s chars  tokens %s+%s (%s/step)",
              t, s["tasks_passed"], s["tasks_total"], s["median_steps"], s["median_seconds"],
              s["median_output_chars"], s["median_prompt_tokens"], s["median_completion_tokens"],
              s["median_tokens_per_step"])
end

# --- markdown report (paste-ready for README / Medium) ----------------------
md_path = OUT.sub(/\.json$/, ".md")
lines = []
lines << "## Head-to-head: Selenit MCP vs Playwright MCP"
lines << ""
lines << "- model: `#{MODEL}` (temperature 0, thinking #{THINKING == '0' ? 'off' : 'on'}, max_tokens #{MAX_TOKENS})"
lines << "- runs per site: #{KOSUM}, step budget: #{MAX_STEPS}, tool-output cap per call: 2,000 chars"
lines << "- date: #{Time.now.utc.iso8601}"
lines << "- task (identical for both): open the site, search for a term, report the first result heading as `title | url`"
lines << ""
lines << "| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |"
lines << "|---|---|---|---|---|---|---|"
%w[selenit playwright].each do |t|
  s = summary[t] or next
  lines << format("| %s | %d/%d | %s | %ss | %s | %s | %s |", t, s["tasks_passed"], s["tasks_total"],
                  s["median_steps"], s["median_seconds"], s["median_output_chars"],
                  s["median_prompt_tokens"].to_i + s["median_completion_tokens"].to_i,
                  s["median_tokens_per_step"])
end
lines << ""
lines << "### Per task"
lines << ""
lines << "| Site | Tool | Result | Reason | Steps | Time |"
lines << "|---|---|---|---|---|---|"
rows.each do |r|
  lines << format("| %s | %s | %s | %s | %s | %ss |", r["site"], r["tool"],
                  r["pass"] ? "PASS" : "FAIL", r["reason"], r["steps"], r["seconds"])
end
lines << ""
lines << "Failures are reported, not hidden: every row above is a real headless run on a live site."
lines << "Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly."
File.write(md_path, lines.join("\n"))
puts "wrote #{md_path}"