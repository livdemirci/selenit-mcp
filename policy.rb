# Basit ama gerçek bir yetki politikası katmanı.
#
# Amaç: MCP araçlarının var olması, ajanın her şeyi yapabileceği anlamına gelmesin.
#  - Host allowlist: yalnızca izin verilen sitelere gidilebilir
#  - Riskli eylem onayı: sil/ödeme/gönder gibi düğmelerde insan onayı zorunlu
#
# Ortam değişkenleri:
#   BROWSER_MCP_ALLOWED_HOSTS="example.com,portal.sirket.com"  (boş = tümü)
#   BROWSER_MCP_REQUIRE_APPROVAL="true"                        (varsayılan false)

require "uri"

module Policy
  RISKY_WORDS = %w[
    sil delete kaldır remove
    ödeme öde pay transfer havale
    gönder submit kaydet save
    onayla approve confirm
    satın purchase satinal
    iptal cancel arşivle archive
    yayınla publish
  ].freeze

  class Denied < StandardError; end

  class << self
    def allowed_hosts
      ENV["BROWSER_MCP_ALLOWED_HOSTS"].to_s.split(",").map { |h| h.strip.downcase }.reject(&:empty?)
    end

    def require_approval?
      ENV["BROWSER_MCP_REQUIRE_APPROVAL"].to_s == "true"
    end

    def check_navigation!(url)
      text = url.to_s
      # data: URL'leri yereldir (ağ erişimi yok); test/demo için varsayılan izinli
      return true if text.start_with?("data:") && ENV.fetch("BROWSER_MCP_ALLOW_DATA", "true") == "true"

      uri = URI.parse(text)
      return true unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS) || uri.scheme == "data"

      hosts = allowed_hosts
      return true if hosts.empty?

      host = uri.host.to_s.downcase
      return true if hosts.any? { |h| host == h || host.end_with?(".#{h}") }

      raise Denied, "Bu adrese izin verilmiyor: #{host}. İzinli: #{hosts.join(', ')}"
    rescue URI::InvalidURIError
      raise Denied, "Geçersiz adres: #{url}"
    end

    # Tıklanacak öğenin etiketi riskli mi?
    def risky?(label)
      text = label.to_s.downcase
      RISKY_WORDS.any? { |w| text.include?(w) }
    end

    def risky_message(label)
      "ONAY GEREKLİ: '#{label.to_s[0, 60]}' riskli bir eylem olabilir (silme/ödeme/gönderim). " \
        "Kullanıcıdan onay al; onaylıysa aynı çağrıyı confirm=true ile yap."
    end
  end
end
