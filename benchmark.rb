#!/usr/bin/env ruby
# selenit Browser MCP — küçük model (Gemma E4B) görev ölçümü ve senaryo kaydı.
#
# LM Studio'nun yerel OpenAI uyumlu API'sine araç şemalarımızı verir,
# modelin ürettiği araç çağrılarını gerçek MCP sunucusunda çalıştırır.
# Başarılı görevlerde adımlar scenarios/<görev>.json dosyasına kaydedilir;
# replay.rb bu dosyayı modelsiz, deterministik olarak tekrar oynatır.
#
# Kullanım:
#   ruby benchmark.rb            # tüm görevler
#   ruby benchmark.rb link form  # seçili görevler

require "json"
require "fileutils"
require "net/http"
require_relative "mcp_client"
require_relative "tasks"
require_relative "recorder"

LM_STUDIO = ENV["LM_STUDIO_URL"] || "http://127.0.0.1:1234"
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"

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
      max_tokens: (ENV["BENCH_MAX_TOKENS"] || 800).to_i,
      # Gemma gibi düşünmeli şablonlarda düşünme VARSAYILAN OLARAK KAPALI:
      # her adımda "Thinking Process" üretilmesin, araç çağrısı bütçesi verime
      # gitsin. Açmak için BENCH_THINKING=1.
      **(ENV.fetch("BENCH_THINKING", "0") == "0" ? { chat_template_kwargs: { enable_thinking: false } } : {}),
      tools: tools.map do |t|
        {
          type: "function",
          function: { name: t["name"], description: t["description"], parameters: t["inputSchema"] }
        }
      end,
      tool_choice: "auto"
    }
    res = nil
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 10
    http.read_timeout = 120
    deneme = 0
    req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    begin
      deneme += 1
      res = http.request(req)
    rescue StandardError => e
      retryable = [Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::EPIPE,
                   EOFError, OpenSSL::SSL::SSLError].any? { |k| e.is_a?(k) }
      raise unless retryable && deneme < 3

      warn("[benchmark] LM Studio bağlant hatası (#{e.class}), deneme #{deneme}/3") if $stderr
      sleep 2
      retry
    end
    raise "LM Studio #{res.code}: #{res.body[0, 300]}" unless res.code == "200"

    JSON.parse(res.body)
  end
end

def run_task(key, spec, mcp, llm, tools)
  started = Time.now
  messages = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: spec[:prompt] }
  ]
  trace = []
  steps = []
  answer = nil

  # Görevler arası temizlik: iframe'den çık, açık uyarıyı kapat,
  # aktif sekme dışındakileri kapat.
  begin
    mcp.call("browser_frame", { "action" => "main" })
  rescue StandardError
    nil
  end
  begin
    mcp.call("browser_alert", { "action" => "accept" })
  rescue StandardError
    nil
  end
  begin
    mcp.call("browser_tabs", { "action" => "close_others" })
  rescue StandardError
    nil
  end

  # İndirme görevi: eski dosyayı sil ki "zaten var" yanlış başarı sayılmasın.
  if key == "download"
    dir = File.expand_path("artifacts/downloads-#{ENV['BENCH_MCP_PORT'] || 19_420}", __dir__)
    FileUtils.mkdir_p(dir)
    # Klasörü silme; Chrome indirme hedefini kaybetmesin. Yalnızca eski dosyaları temizle.
    Dir[File.join(dir, "*")].each { |f| FileUtils.rm_rf(f) }
  end

  bos_yanit = 0
  MAX_STEPS.times do |step|
    begin
      data = llm.chat(messages, tools)
    rescue StandardError => e
      # LM Studio yanıt vermediyse koşumu öldürme: şimdiye kadarki adımlar
      # korunarak dur.
      trace << "LM hatası (#{e.class}): #{e.message.to_s[0, 120]}"
      break
    end
    msg = data.dig("choices", 0, "message") || {}
    calls = msg["tool_calls"] || []

    if calls.empty?
      answer = msg["content"].to_s.strip
      # Küçük modeller ara sıra boş içerik + araç çağrısı olmadan durabiliyor;
      # görevi sessizce yarıda bırakmak yerine bir kez nazikçe yönlendir.
      if answer.empty? && bos_yanit.zero?
        bos_yanit += 1
        messages << { role: "user", content: "Yanıtın boş geldi. Göreve devam et ve sıradaki adımı TEK araç çağrısıyla yap." }
        trace << "boş yanıt: model bir kez yönlendirildi"
        next
      end
      break
    end

    messages << { role: "assistant", content: msg["content"].to_s, tool_calls: calls }

    calls.first(1).each do |call|
      name = call.dig("function", "name").to_s
      raw_args = call.dig("function", "arguments")
      args = begin
        raw_args.is_a?(String) ? JSON.parse(raw_args) : (raw_args || {})
      rescue JSON::ParserError
        {}
      end

      selector = ACTION_TOOLS.include?(name) ? selector_for(mcp, args["ref"]) : nil
      output = mcp.call(name, args)

      if ACTION_TOOLS.include?(name) &&
         !output.to_s.match?(/\A(DÖNGÜ UYARISI|HATA|ENGELLENDİ|ONAY GEREKLİ)/)
        record = { "tool" => name, "args" => args, "selector" => selector }
        if name == "browser_tabs" && args["action"].to_s == "switch"
          # Index yerine URL kaydet: replay sırasında sekme sırası değişse de doğru sekmeye gider.
          record["tab_url"] = mcp.call("browser_evaluate", { "script" => "return location.href" }).to_s.strip
        end
        steps << record
      end

      trace << "#{step + 1}. #{name}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 30].inspect}" }.join(', ')}) -> #{output.lines.first.to_s.strip[0, 70]}"
      messages << { role: "tool", tool_call_id: call["id"], content: output[0, 2500] }
    end
  end

  passed = begin
    spec[:check].call(mcp, answer)
  rescue StandardError => e
    trace << "kontrol hatası: #{e.message}"
    false
  end

  if passed && !steps.empty?
    assert_value = spec[:assert_js] ? mcp.call("browser_evaluate", { "script" => spec[:assert_js] }).to_s.strip : nil
    final_url = mcp.call("browser_evaluate", { "script" => "return location.href" }).to_s.strip
    dir = File.expand_path("scenarios", __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.write(File.join(dir, "#{key}.json"), JSON.pretty_generate({
      "task" => key,
      "desc" => spec[:desc],
      "recorded_at" => Time.now.strftime("%Y-%m-%dT%H:%M:%S%z"),
      "model" => MODEL,
      "answer" => answer.to_s,
      "final_url" => final_url,
      "assert_js" => spec[:assert_js],
      "assert_value" => assert_value,
      "steps" => steps
    }))
  end

  {
    key: key, desc: spec[:desc], passed: passed, steps: trace.size,
    seconds: (Time.now - started).round(1), answer: answer.to_s[0, 200], trace: trace
  }
end

selected = ARGV.empty? ? TASKS.keys : ARGV
File.write("/tmp/agent_upload.txt", "ajan test dosyasi\n") rescue nil
llm = Llm.new(MODEL)

probe = McpClient.new
tool_count = probe.tools.size
probe.stop

puts "Model: #{MODEL} | MCP port: #{ENV['BENCH_MCP_PORT'] || '19420'} | araç: #{tool_count} | görev: #{selected.join(', ')}"
puts

results = selected.map do |key|
  spec = TASKS[key] or next
  print "#{key} (#{spec[:desc]}) ... "
  mcp = nil
  r = begin
    # Her görev taze MCP süreci + taze Selenium oturumu kullanır (takılan çağrı diğerlerini zehirlemez).
    mcp = McpClient.new
    run_task(key, spec, mcp, llm, mcp.tools)
  rescue StandardError => e
    { key: key, desc: spec[:desc], passed: false, steps: 0, seconds: 0, answer: "",
      trace: ["HATA: #{e.class}: #{e.message.to_s[0, 160]}"] }
  ensure
    mcp&.stop
  end
  puts(r[:passed] ? "GEÇTİ (#{r[:steps]} adım, #{r[:seconds]}s)" : "KALDI (#{r[:steps]} adım, #{r[:seconds]}s)")
  r
end.compact

puts
results.each do |r|
  puts "--- #{r[:key]} #{r[:passed] ? 'PASS' : 'FAIL'} (#{r[:steps]} adım, #{r[:seconds]}s)"
  puts "    cevap: #{r[:answer].gsub("\n", ' ')}" unless r[:answer].empty?
  r[:trace].each { |line| puts "    #{line}" }
end

puts
puts "SONUÇ: #{results.count { |r| r[:passed] }}/#{results.size} geçti"
exit(results.all? { |r| r[:passed] } ? 0 : 1)
