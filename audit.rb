# Denetim kaydı: her araç çağrısı JSONL olarak yazılır.
# Hassas metinler (parola vb.) maskelenir; tam değer değil, kısaltılmış özet tutulur.

require "json"
require "fileutils"
require "time"

module Audit
  MASK_KEYS = %w[password parola sifre şifre token secret otp cvv].freeze

  class << self
    def dir
      ENV["BROWSER_MCP_ARTIFACT_DIR"] || File.expand_path("artifacts", __dir__)
    end

    def file
      FileUtils.mkdir_p(dir)
      File.join(dir, "audit-#{Time.now.strftime('%Y%m%d')}.jsonl")
    end

    def log(tool:, args:, ok:, detail:, seconds: nil, url: nil)
      entry = {
        at: Time.now.iso8601,
        tool: tool,
        args: sanitize(args),
        ok: ok,
        seconds: seconds,
        url: url,
        detail: detail.to_s[0, 300]
      }
      File.open(file, "a") { |f| f.puts(JSON.generate(entry)) }
    rescue StandardError
      # denetim yazımı asla ana işlemi bozmasın
    end

    def sanitize(args)
      (args || {}).each_with_object({}) do |(k, v), out|
        key = k.to_s.downcase
        if MASK_KEYS.any? { |m| key.include?(m) }
          out[k] = "[MASKED]"
        elsif v.is_a?(String) && v.length > 80
          out[k] = "#{v[0, 80]}… (#{v.length} karakter)"
        else
          out[k] = v
        end
      end
    end
  end
end
