# MCP stdio istemcisi: benchmark ve replay aynı sınıfı kullanır.
require "json"
require "open3"
require "timeout"

class McpClient
  attr_reader :last_error

  def initialize(port: ENV["BENCH_MCP_PORT"] || "19420", max_elements: "40")
    cmd = [RbConfig.ruby, File.expand_path("server.rb", __dir__)]
    @stdin, @stdout, @wait = Open3.popen2(
      { "BROWSER_MCP_PORT" => port, "BROWSER_MCP_MAX_ELEMENTS" => max_elements },
      *cmd, err: "/tmp/bench_mcp.err"
    )
    @id = 0
    initialize_session
  end

  def initialize_session
    request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "bench", version: "0" } })
    write({ jsonrpc: "2.0", method: "notifications/initialized" })
  end

  def tools
    request("tools/list", {})["tools"]
  end

  def call(name, args)
    result = request("tools/call", { name: name, arguments: args })
    text = result.dig("content", 0, "text").to_s
    @last_error = result["isError"] ? text : nil
    text
  end

  def stop
    @stdin.close rescue nil
    @stdout.close rescue nil
    @wait.kill rescue nil
  end

  private

  def request(method, params)
    id = (@id += 1)
    write({ jsonrpc: "2.0", id: id, method: method, params: params })
    loop do
      line = Timeout.timeout(90) { @stdout.gets }
      raise "MCP sunucusu kapandı" if line.nil?

      msg = JSON.parse(line)
      return msg["result"] if msg["id"] == id && msg.key?("result")
      raise "MCP hatası: #{msg['error']}" if msg["id"] == id && msg["error"]
    end
  end

  def write(obj)
    @stdin.puts(JSON.generate(obj))
    @stdin.flush
  end
end
