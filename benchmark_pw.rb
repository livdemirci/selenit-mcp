# Head-to-head kıyas: Playwright MCP (resmi @playwright/mcp) ile aynı Gemma
# modeli, aynı hepsi görevi. Sistem mesajı her hedefe deyimli (kendi araç
# adlarıyla aynı kurallar), görev prompt'u birebir tasks.rb'den kopya.
#
# Koşum:  PROBE=1 ruby benchmark_pw.rb   (tek koşum)
#         PROBE=3 ruby benchmark_pw.rb   (3 koşum ort.)
require "json"
require "fileutils"
require "net/http"
require "open3"
require_relative "tasks"

LM_STUDIO = ENV["LM_STUDIO_URL"] || "http://127.0.0.1:1234"
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"
MAX_STEPS = (ENV["BENCH_MAX_STEPS"] || 26).to_i unless defined?(MAX_STEPS)
KOSUM = (ENV["PROBE"] || 1).to_i

# --- hepsi görevi (tasks.rb'den birebir; prompt aynı metin) ---------------
# Görev seçimi: BENCH_TASK ortam değişkeni (varsayılan site-nötr görev).
# Site-nötr görev hedefini SELENIT_TARGET_URL / SELENIT_TARGET_TERM'den okur;
# repoda site adı veya siteye özgü CSS seçici bulunmaz.
GOREV_KEY = ENV["BENCH_TASK"] || "sitenotr"
HEPSI = TASKS[GOREV_KEY] or raise "bilinmeyen görev: #{GOREV_KEY}"

PW_SYSTEM_PROMPT = <<~S
  Sen bir tarayıcı otomasyon ajanısın. Kurallar:
  - Her adımda TEK araç çağır, sonucu bekle.
  - Sayfayı anlamak için browser_snapshot kullan; öğeleri ekran metni + ref ile seç.
  - Ref geçersizse yeniden browser_snapshot çağır.
  - Modal açıksa yalnızca modal içindeki öğeleri kullan.
  - Form alanlarına yazmak için browser_type, tek tuş için browser_press_key kullan.
  - Dinamik içerik veya URL değişimi için browser_wait_for kullan. Sabit bekleme yapma.
  - Sayfada açık uyarı kutusu çıkarsa browser_handle_dialog ile kapat.
  - Görev bitince araç çağırmayı bırak ve en fazla 2 cümlelik kısa Türkçe cevap ver.
S

class Llm
  def initialize(model)
    @model = model
  end

  def chat(messages, tools)
    uri = URI("#{LM_STUDIO}/v1/chat/completions")
    body = {
      model: @model,
      messages: messages,
      temperature: 0,
      max_tokens: (ENV["BENCH_MAX_TOKENS"] || 1600).to_i,
      **(ENV.fetch("BENCH_THINKING", "0") == "0" ? { chat_template_kwargs: { enable_thinking: false } } : {}),
      tools: tools.map do |t|
        { type: "function", function: { name: t["name"], description: t["description"],
                                        parameters: t["inputSchema"] } }
      end,
      tool_choice: "auto"
    }
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 120
    req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    deneme = 0
    begin
      deneme += 1
      res = http.request(req)
    rescue StandardError => e
      retryable = [Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::EPIPE,
                   EOFError, OpenSSL::SSL::SSLError].any? { |k| e.is_a?(k) }
      raise unless retryable && deneme < 3

      warn("[pw-bench] LM hatası #{e.class}, deneme #{deneme}/3") if $stderr
      sleep 2
      retry
    end
    raise "LM Studio #{res.code}" unless res.code == "200"

    JSON.parse(res.body)
  end
end

# --- Playwright MCP stdio istemcisi (npx @playwright/mcp) ------------------
class PwClient
  def initialize
    komut = %w[npx -y @playwright/mcp@latest --browser chrome
               --user-data-dir=artifacts/pw-profile]
    @stdin, @stdout, @wait = Open3.popen2(*komut, err: "/tmp/pw_mcp.err")
    @id = 0
    @reqs = {}
    initialize_session
  end

  # Görev ölçütü (tasks.rb) iki primitife dayanır: browser_evaluate (JS) ve
  # tarayıcı kontrolü. Playwright MCP'de JS aracının adı sürümle değişiyor
  # (browser_evaluate / browser_evaluate_function); kontrol aracı da
  # browser_evaluate tarafından yapılabiliyorsa aynı ölçüt kullanılabilir.
  # Hangisi yoksa onu gösteren net bir hata ver: sessizce FAIL sayma.
  def capability_check
    adlar = tools.map { |t| t["name"] }
    eksik = []
    eksik << "browser_evaluate" unless adlar.include?("browser_evaluate")
    eksik
  end

  def initialize_session
    request("initialize", { protocolVersion: "2024-11-05", capabilities: {},
                            clientInfo: { name: "pw-bench", version: "0" } })
    @stdin.puts JSON.generate({ jsonrpc: "2.0", method: "notifications/initialized" })
  end

  def tools
    request("tools/list", {})["tools"]
  end

  # Araç argüman adları iki MCP'de aynı tutulmalı ki kıyas araç yüzeyi
  # farkından değil, aracın davranışından gelsin. Playwright MCP'de metin
  # yazma aracı {element, text, submit} alır; selenit {ref, text, submit}
  # alır. Parametre ADI farkı (ref ↔ element) burada köprülenir.
  def call(name, args)
    gercek = args.dup
    # browser_type: selenit {ref|selector, text, submit}; Playwright MCP
    # {element, text, submit}. Yalnızca parametre ADI eşlenir, anlamı aynı kalır.
    if name == "browser_type" && gercek["ref"] && !gercek["element"]
      gercek["element"] = gercek.delete("ref")
    end
    # browser_evaluate: model selenit imzasını {"script" => ...} kullanır.
    # Playwright MCP {"function" => "() => ..."} bekler ve sonucu metne gömer;
    # çeviriyi PwClient#evaluate yapar.
    return evaluate(args["script"]) if name == "browser_evaluate" && args["script"]

    sonuc = request("tools/call", { name: name, arguments: gercek })
    (sonuc.dig("content") || []).filter_map { |c| c["text"] if c["type"] == "text" }.join("\n")
  end

  def request(method, params)
    @id += 1
    line = JSON.generate({ jsonrpc: "2.0", id: @id, method: method, params: params })
    Timeout.timeout(180) do
      @stdin.puts line
      loop do
        yanit = JSON.parse(@stdout.readline)
        return yanit["result"] if yanit["id"] == @id

        warn("[pw-bench] bildirim: #{yanit["method"]}") if $stderr && yanit["method"]
      end
    end
  end

  def stop
    @stdin.close rescue nil
    @stdout.close rescue nil
    @wait.kill rescue nil
  end

  # tasks.rb ÖLÇÜTLERİ mcp.call("browser_evaluate", {"script" => "return X"})
  # biçiminde yazılmıştır. Playwright MCP'nin browser_evaluate'ü ise
  # {"function" => "() => ..."} bekler ve dönen değeri metne gömer.
  # Çeviri BURADA yapılır; modelin kendi araç çağrıları ASLA çevrilmez,
  # yoksa iki aracın araç yüzeyi kıyaslaması bozulur (sadece ölçüt eşitlenir).
  def evaluate(script)
    s = script.strip
    fn = if s.start_with?("return ")
           "() => (#{s.sub(/\Areturn\s+/, '')})"
         else
           "() => { #{s} }"
         end
    # Playwright MCP sonucu metne gömer: '### Result\n "42"\n ### Ran Playwright code'.
    # Tırnaklar ve yeni satır içindeki kaçışlar çözülür ki ölçüt kodu
    # selenit'te gördüğü ham değeri görsün.
    ham = call("browser_evaluate", { function: fn }).to_s
    satir = ham[/Result\s*\n\s*(.*)/, 1].to_s.strip
    if satir.start_with?('"') && satir.end_with?('"')
      begin
        JSON.parse(satir)
      rescue JSON::ParserError
        satir
      end
    else
      satir
    end
  end

  def call(name, args)
    result = request("tools/call", { name: name, arguments: args })
    (result.dig("content") || []).filter_map { |c| c["text"] if c["type"] == "text" }.join("\n")
  end
end

def run_one(i, llm, pw, tools)
  started = Time.now
  # Ölçüt tasks.rb'den geldiği için "mcp" olarak, sadece ölçüt JS'ini çeviren
  # bir sarmalayıcı verilir; aksi halde Playwright MCP'ye MCP'de olmayan
  # {"script": ...} imzası gider ve ölçüt sessizce false döner.
  judge = Object.new
  judge.instance_variable_set(:@mcp, pw)
  def judge.call(name, args)
    if name == "browser_evaluate" && args["script"]
      return @mcp.evaluate(args["script"])
    end
    @mcp.call(name, args)
  end
  messages = [
    { role: "system", content: PW_SYSTEM_PROMPT },
    # Prompt her koşumda TAZE üretilmeli: lambda, hedef/filtre değerlerini
  # çalışma anında ENV'den okur. (Tek seferde donduırmak, çoklu hedef koşumunda
  # ikinci hedefe birincinin adresini gönderiyordu.)
  { role: "user", content: HEPSI[:prompt].respond_to?(:call) ? HEPSI[:prompt].call : HEPSI[:prompt] }
  ]
  trace = []
  answer = nil
  son_cagri = []

  MAX_STEPS.times do |step|
    data = begin
      llm.chat(messages, tools)
    rescue StandardError => e
      trace << "LM hatası (#{e.class})"
      break
    end
    msg = data.dig("choices", 0, "message") || {}
    calls = msg["tool_calls"] || []
    if calls.empty?
      answer = msg["content"].to_s.strip
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
    son_cagri << name unless son_cagri.last == name

    output = begin
      pw.call(name, args)
    rescue StandardError => e
      "HATA: #{e.message.lines.first}"
    end
    sonuc = output.lines.first.to_s.strip[0, 120]
    trace << "#{step + 1}. #{name}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 30].inspect}" }.join(', ')}) -> #{sonuc}"
    messages << { role: "tool", tool_call_id: c["id"], content: output[0, 2500] }
  end

  # Başarı ölçütü görev tanımından gelir (TASKS[...][:check]); böylece aynı
  # görev her iki araçta AYNI kuralla değerlendirilir. Görevde check yoksa
  # yedek: URL + cevapta fiyat deseni.
  url = ""
  begin
    url = pw.call("browser_evaluate", { function: "() => location.href" }).to_s
  rescue StandardError
    url = ""
  end
  passed =
    if HEPSI[:check]
      begin
        HEPSI[:check].call(judge, answer.to_s) ? true : false
      rescue StandardError
        false
      end
    else
      url.match?(/[\d.,]+\s*(TL|₺)|[\d.,]+,?\d{1,2}/) && answer.to_s.match?(/\d/)
    end

  {
    pass: passed, adim: trace.size, sure: (Time.now - started).round(1),
    answer: answer.to_s[0, 160], son_url: url, trace: trace, arac_gecis: son_cagri
  }
end

# --- giriş noktası ---------------------------------------------------------
# Dosya require edildiğinde (ör. ölçüt sarmalayıcısını test etmek için) koşum
# başlamamalı: yalnızca doğrudan çalıştırıldığında koşar.
if $PROGRAM_NAME == __FILE__
  results = []
  llm = Llm.new(MODEL)
  pw = nil
  KOSUM.times do |i|
    print "PW koşum #{i + 1}/#{KOSUM} ... "
    pw = PwClient.new
    tools = pw.tools
    eksik = pw.capability_check
    unless eksik.empty?
      pw.stop
      puts "KURULUM HATASI: Playwright MCP'de eksik araç: #{eksik.join(', ')} — araç listesi:"
      puts tools.map { |t| "  - #{t['name']}" }.join("\n")
      exit 2
    end
    r = run_one(i, llm, pw, tools)
    pw&.stop
    puts(r[:pass] ? "PASS (#{r[:adim]} adım, #{r[:sure]}s)" : "FAIL (#{r[:adim]} adım, #{r[:sure]}s)")
    results << r
  rescue StandardError => e
    pw&.stop
    puts "HATA: #{e.class}: #{e.message.lines.first}"
    results << { pass: false, adim: 0, sure: 0, answer: "", son_url: "", trace: ["kurulum hatası: #{e.message}"], arac_gecis: [] }
  end

  puts
  gecmis = results.count { |r| r[:pass] }
  puts "SONUÇ: #{gecmis}/#{KOSUM} geçti | ort adım: #{(results.sum { |r| r[:adim] }) / KOSUM} | ort süre: #{(results.sum { |r| r[:sure] }) / KOSUM}s"
  results.each_with_index do |r, i|
    puts "--- koşum #{i + 1} #{r[:pass] ? 'PASS' : 'FAIL'}"
    puts "    cevap: #{r[:answer].gsub("\n", ' ')}" unless r[:answer].empty?
    r[:trace].last(6).each { |l| puts "    #{l}" }
  end
  # Dosya adı modele göre: claude ile gemma koşumları birbirini ezmesin.
  etiket = ENV["BENCH_TASK"] || "sitenotr"
  File.write(File.expand_path("artifacts/pw-bench-#{etiket}-#{MODEL.gsub(/[^a-z0-9]+/i, '-')}.json", __dir__),
             JSON.pretty_generate({ model: MODEL, task: etiket, kosum: KOSUM, results: results }))
end
