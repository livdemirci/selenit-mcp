#!/usr/bin/env ruby
# Kaydedilmiş senaryoyu modelsiz (LLM'siz) tekrar oynatır.
# LLM keşfi -> scenarios/<görev>.json -> replay.rb (selenit/CI için deterministik adımlar).
#
# Kullanım:
#   ruby replay.rb filter
#   ruby replay.rb filter --verbose

require "json"
require "fileutils"
require_relative "mcp_client"
require_relative "tasks"

key = ARGV[0]
abort "kullanım: ruby replay.rb <görev>  (ör. ruby replay.rb filter)" if key.nil? || key.empty?
path = File.expand_path("scenarios/#{key}.json", __dir__)
abort "senaryo bulunamadı: #{path}  (önce benchmark.rb ile kaydet)" unless File.exist?(path)

scenario = JSON.parse(File.read(path))
steps = scenario["steps"] || []
mcp = McpClient.new
verbose = ARGV.include?("--verbose")

# Deterministik başlangıç: iframe'den çık, aktif sekme dışındakileri kapat.
begin
  mcp.call("browser_frame", { "action" => "main" })
rescue StandardError
  nil
end
begin
  mcp.call("browser_tabs", { "action" => "close_others" })
rescue StandardError
  nil
end

if key == "download"
  dir = File.expand_path("artifacts/downloads-#{ENV['BENCH_MCP_PORT'] || 19_420}", __dir__)
  FileUtils.mkdir_p(dir)
  Dir[File.join(dir, "*")].each { |f| FileUtils.rm_rf(f) }
end

puts "Replay: #{key} | #{steps.size} adım | kaynak model: #{scenario['model']} | #{scenario['recorded_at']}"

ok = true
steps.each_with_index do |s, i|
  args = (s["args"] || {}).dup
  if s["selector"] && !s["selector"].to_s.empty?
    args.delete("ref")
    args["selector"] = s["selector"]
  end
  if s["tab_url"] && !s["tab_url"].to_s.empty?
    args = { "action" => "switch", "url" => s["tab_url"] }
  end

  out = mcp.call(s["tool"], args)
  failed = !mcp.last_error.nil?
  ok &&= !failed
  label = s["selector"] || args["text"] || args["url"] || args["label"] || ""
  puts format("%2d. %-17s %-38s -> %s", i + 1, s["tool"], label.to_s[0, 38], out.lines.first.to_s.strip[0, 60])
  puts "    #{out.lines[1].to_s.strip}" if verbose
  break if failed
end

passed = ok && begin
  TASKS[key][:check].call(mcp, scenario["answer"].to_s)
rescue StandardError => e
  puts "kontrol hatası: #{e.message}"
  false
end

puts passed ? "REPLAY GEÇTİ (#{steps.size} adım)" : "REPLAY KALDI"
mcp.stop
exit(passed ? 0 : 1)
