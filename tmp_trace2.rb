require "json"
require "net/http"
require_relative "mcp_client"
require_relative "tasks"

# benchmark.rb'nin adım döngüsünü birebir koşar, her adımı ANINDA basar
# (benchmark.rb yalnızca görev bitince yazdırıyor; bu betik canlı izleme için).
LM_STUDIO = "http://127.0.0.1:1234"
MODEL = ENV["BENCH_MODEL"] || "google/gemma-4-e4b"

class Llm
  def initialize(model)
    @model = model
  end

  def chat(messages, tools)
    uri = URI("#{LM_STUDIO}/v1/chat/completions")
    body = {
      model: @model, messages: messages, temperature: 0, max_tokens: 800,
      chat_template_kwargs: { enable_thinking: false },
      tools: tools.map { |t| { type: "function", function: { name: t["name"], description: t["description"], parameters: t["inputSchema"] } } },
      tool_choice: "auto"
    }
    req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 180
    JSON.parse(http.request(req).body)
  end
end

key = ARGV[0] || "filtre2"
spec = TASKS[key]
llm = Llm.new(MODEL)
mcp = McpClient.new(port: ARGV[1] || "19441")
messages = [
  { role: "system", content: SYSTEM_PROMPT },
  { role: "user", content: spec[:prompt].respond_to?(:call) ? spec[:prompt].call : spec[:prompt] }
]
answer = nil
MAX_STEPS.times do |step|
  t0 = Time.now
  data = llm.chat(messages, mcp.tools)
  msg = data.dig("choices", 0, "message") || {}
  calls = msg["tool_calls"] || []
  if calls.empty?
    answer = msg["content"].to_s.strip
    puts "#{step + 1}. (#{(Time.now - t0).round}s) CEVAP: #{answer[0, 200].inspect}"
    break
  end
  messages << { role: "assistant", content: msg["content"].to_s, tool_calls: calls }
  call = calls.first
  name = call.dig("function", "name").to_s
  args = begin
    JSON.parse(call.dig("function", "arguments").to_s)
  rescue StandardError
    {}
  end
  out = mcp.call(name, args)
  puts "#{step + 1}. (#{(Time.now - t0).round}s) #{name}(#{args.map { |k, v| "#{k}=#{v.to_s[0, 30]}" }.join(', ')}) -> #{out.lines.first.to_s.strip[0, 80]}"
  $stdout.flush
  messages << { role: "tool", tool_call_id: call["id"], content: out[0, 2500] }
end
puts "GECTI: #{spec[:check].call(mcp, answer)} (cevap: #{answer.to_s[0, 140]})"
mcp.stop
