#!/usr/bin/env ruby
# selenit yaklaşımıyla çalışan, Playwright MCP benzeri tarayıcı MCP sunucusu.
#
# - Mevcut Chrome'a CDP (remote debugging) ile bağlanır; yeni tarayıcı açmaz.
# - Çıktılar küçük modeller (Gemma E4B) için kompakt ve kısa tutulur.
# - Taşıma: stdio, satır başına bir JSON-RPC 2.0 mesajı.

require "json"
require "timeout"
require_relative "browser"
require_relative "audit"

# LM Studio gibi LANG/LC_ALL vermeyen istemcilerde varsayılan kodlama US-ASCII olur;
# Türkçe metin ve UTF-8 JSON için açıkça UTF-8'e sabitle.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

PROTOCOL_VERSION = "2024-11-05"

SERVER_VERSION = begin
  JSON.parse(File.read(File.expand_path("package.json", __dir__)))["version"].to_s
rescue StandardError
  "0.0.0"
end

# Tek araç çağrısı için üst sınır. Chromedriver bir pencere kapanınca bazen
# HTTP cevbInı asılı bırakabilir; asistan cevapsız beklemesin.
OP_TIMEOUT = (ENV["BROWSER_MCP_OP_TIMEOUT"] || 120).to_i

# Protokol kanalını koru: kütüphanelerin stdout çıktısı protokolü bozmasın
REAL_STDOUT = STDOUT.dup
$stdout.reopen($stderr)
REAL_STDOUT.set_encoding("UTF-8")
REAL_STDOUT.sync = true
STDIN.set_encoding("UTF-8")
STDIN.sync = true

module Tools
  # --minimal: küçük yerel modeller (Gemma 4 E4B, Qwen 4B, MiniCPM) 23 araçlık
  # şemayla ilk turda BOŞ cevap veriyor (ölçüm: n11 görevinde 10 adımın
  # hiçbirinde araç çağrısı yok). Araç sayısı 7'ye indirilince çağrı başlıyor.
  # Ölçüt "site" değil "model yeteneği": şema bütçesi dar olan her model için.
  MINIMAL_ADLAR = %w[
    browser_navigate browser_snapshot browser_type browser_click
    browser_read browser_scroll browser_wait_for
  ].freeze

  def self.minimal?
    ENV["SELENIT_MINIMAL"].to_s == "1" || ARGV.include?("--minimal")
  end

  def self.liste
    return LIST unless minimal?
    LIST.select { |t| MINIMAL_ADLAR.include?(t[:name]) }
  end

  LIST = [
    {
      name: "browser_navigate",
      description: "Verilen adrese git ve kısa sayfa dökümü döndür. Bot doğrulama ekranı " \
                   "(Cloudflare 'Bir dakika lütfen' vb.) görülürse kalkmasını bekler.",
      inputSchema: {
        type: "object",
        properties: { url: { type: "string", description: "Adres, örn. https://www.google.com" } },
        required: ["url"]
      }
    },
    {
      name: "browser_snapshot",
      description: "Aktif sayfanın etkileşimli öğelerini kısa listele (e1, e2, ...).",
      inputSchema: { type: "object", properties: {} }
    },
    {
      name: "browser_dom",
      description: "Kompakt DOM okuması: q yokken URL/başlık/modal/uyarı durumu (üst bilgi ~400k); q verirken seçilen öğelerin kısa listesi. Ucuz görünüm — snapshot'tan hafif.",
      inputSchema: {
        type: "object",
        properties: {
          q: { type: "string", description: "CSS selector (opsiyonel). Verilirse eşleşen görünen öğeler listelenir." },
          limit: { type: "number", description: "En fazla kaç öğe, varsayılan 8" }
        }
      }
    },
    {
      name: "browser_click",
      description: "ref (örn. e3), CSS selector veya görünen metin ile öğeye tıkla. " \
                   "selector + text birlikte verilirse aynı seçiciden gelen öğeler metne göre daraltılır.",
      inputSchema: {
        type: "object",
        properties: {
          ref: { type: "string", description: "snapshot'taki ref" },
          selector: { type: "string", description: "CSS selector (opsiyonel)" },
          text: { type: "string", description: "Görünen metin (örn. 'Turing Award')" },
          confirm: { type: "boolean", description: "Riskli eylemlerde kullanıcı onayı alındıysa true" }
        }
      }
    },
    {
      name: "browser_find",
      description: "Sayfada metne göre öğe bul, tıklanabilir ref döndür (uzun sayfalar için).",
      inputSchema: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"]
      }
    },
    {
      name: "browser_read",
      description: "Sayfadaki görünür metni oku (özetleme/çeviri görevleri için).",
      inputSchema: {
        type: "object",
        properties: { max: { type: "number", description: "En fazla karakter, varsayılan 1500" } }
      }
    },
    {
      name: "browser_select",
      description: "Açılır listeden seçenek seç. Normal <select> alanları ve role/class tabanlı " \
                   "özel açılır menüler (combobox, b-select, dropdown) desteklenir.",
      inputSchema: {
        type: "object",
        properties: {
          ref: { type: "string" },
          selector: { type: "string" },
          value: { type: "string", description: "option value" },
          label: { type: "string", description: "görünen metin" }
        }
      }
    },
    {
      name: "browser_alert",
      description: "JS uyarı penceresini kapat ve metnini döndür. text: okuyup kapatır; peek: açık bırakır.",
      inputSchema: {
        type: "object",
        properties: { action: { type: "string", enum: %w[text peek accept dismiss], description: "varsayılan: accept" } }
      }
    },
    {
      name: "browser_scroll",
      description: "Sayfayı kaydır (aşağı/yukarı/başa/sona).",
      inputSchema: {
        type: "object",
        properties: {
          direction: { type: "string", enum: %w[down up top bottom] },
          amount: { type: "number", description: "piksel, varsayılan 600" }
        }
      }
    },
    {
      name: "browser_frame",
      description: "iframe içine gir veya ana sayfaya dön (action=main). Snapshot'taki iframe ref'i (ör. e1) veya index kullan.",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string", enum: %w[main enter], description: "varsayılan: main" },
          ref: { type: "string", description: "iframe öğesinin ref'i (ör. e1)" },
          selector: { type: "string", description: "iframe CSS seçicisi" },
          index: { type: "number", description: "iframe sırası (0'dan)" }
        }
      }
    },
    {
      name: "browser_upload",
      description: "Dosya yükleme alanına yerel dosya yolu ver.",
      inputSchema: {
        type: "object",
        properties: {
          ref: { type: "string" },
          selector: { type: "string" },
          path: { type: "string" }
        },
        required: ["path"]
      }
    },
    {
      name: "browser_hover",
      description: "Öğenin üzerine gel (menüler için).",
      inputSchema: {
        type: "object",
        properties: {
          ref: { type: "string" },
          selector: { type: "string" },
          text: { type: "string" }
        }
      }
    },
    {
      name: "browser_type",
      description: "Bir alana yaz; submit=true ise Enter'a basar.",
      inputSchema: {
        type: "object",
        properties: {
          ref: { type: "string" },
          selector: { type: "string" },
          text: { type: "string" },
          submit: { type: "boolean" },
          confirm: { type: "boolean", description: "Form gönderimi için kullanıcı onayı" }
        },
        required: ["text"]
      }
    },
    {
      name: "browser_press_key",
      description: "Klavye tuşu gönder (enter, tab, escape, arrowdown ...).",
      inputSchema: {
        type: "object",
        properties: { key: { type: "string" } },
        required: ["key"]
      }
    },
    {
      name: "browser_resize",
      description: "Pencere boyutunu ayarla (tutarlı görünüm için). Döküm döndürür.",
      inputSchema: {
        type: "object",
        properties: {
          width: { type: "number", description: "varsayılan 1280" },
          height: { type: "number", description: "varsayılan 800" }
        }
      }
    },
    {
      name: "browser_monitor",
      description: "WebDriver BiDi ağ monitörü: istekler, yanıtlar ve konsol kaydedilir. Önce action:start, sonra check/wait; Playwright MCP'nin network aracının karşılığı.",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string", enum: %w[start check wait stop], description: "start: kaydı başlat; check: kayıtları göster; wait: filtreye uyan kaydı bekle; stop: durdur" },
          filter: { type: "string", description: "URL/metin filtresi (ör. \"api\" ya da \"8765\")" },
          timeout: { type: "number", description: "action:wait için üst sınır, sn (varsayılan 10)" }
        },
        required: ["action"]
      }
    },
    {
      name: "browser_wait_for",
      description: "Explicit wait: metin, seçici, URL, kaybolma, öğe sayısı veya indirme tamamlanması. " \
                   "Sabit bekleme yerine koşul bekler; zaman aşımında anlaşılır hata döndürür.",
      inputSchema: {
        type: "object",
        properties: {
          type: { type: "string", enum: %w[text selector url gone count load download], description: "varsayılan: text" },
          text: { type: "string", description: "Beklenecek metin veya indirme dosya adı" },
          selector: { type: "string", description: "type=selector/gone/count için CSS seçici" },
          value: { type: "string", description: "type=url için URL parçası, type=count için en az öğe sayısı" },
          timeout: { type: "number", description: "Saniye; varsayılan metin/seçici 10, indirme 30" }
        }
      }
    },
    {
      name: "browser_screenshot",
      description: "Ekran görüntüsü al, dosya yolunu döndür.",
      inputSchema: { type: "object", properties: {} }
    },
    {
      name: "browser_evaluate",
      description: "Sayfada JavaScript çalıştır, sonucu kısa döndür.",
      inputSchema: {
        type: "object",
        properties: { script: { type: "string" } },
        required: ["script"]
      }
    },
    {
      name: "browser_history",
      description: "Sayfa geçmişinde geri/ileri git veya yenile.",
      inputSchema: {
        type: "object",
        properties: {
          direction: { type: "string", enum: %w[back forward reload] }
        },
        required: ["direction"]
      }
    },
    {
      name: "browser_tabs",
      description: "Sekmeleri listele, seç veya kapat. close_others: aktif dışındakileri kapatır.",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string", enum: %w[list switch close close_others], description: "varsayılan: list" },
          index: { type: "number" },
          url: { type: "string", description: "switch için URL parçası (index yerine)" }
        }
      }
    },
    {
      name: "browser_status",
      description: "Tarayıcı bağlantı durumunu göster.",
      inputSchema: { type: "object", properties: {} }
    },
    {
      name: "browser_close",
      description: "Tarayıcı oturumunu kapat.",
      inputSchema: { type: "object", properties: {} }
    }
  ].freeze
end

$browser = nil
$recent_calls = []

# Salt-okuma araçları döngü sayacına girmez: model "değişti mi?" diye aynı
# snapshot/dom/wait_for'u tekrar çağırabilmelidir.
SALT_OKUMA = %w[
  browser_screenshot browser_status browser_snapshot browser_dom
  browser_read browser_find browser_wait_for browser_evaluate
].freeze

# Sayfayı değiştirebilen araçlar: döngü koruması bunlarda eylem sonrası
# durum imzasını da karşılaştırır.
DURUM_IZLEYEN = %w[
  browser_navigate browser_click browser_type browser_select browser_press_key
  browser_scroll browser_history browser_tabs browser_upload browser_frame
].freeze

def browser
  $browser ||= SelenitBrowser.new
end

# Küçük modeller aynı çağrıyı döngüye alabilir. Aynı araç+argüman 3. kez
# geldiğinde, son iki sonuç BİREBİR AYNIYSA gerçek döngüdür. "+" düğmesine
# dört kez basmak gibi meşru tekrarlarda çıktı değişir (adet 2 → 3), engellenmez.
def loop_warning?(name, signature)
  return false if SALT_OKUMA.include?(name)

  gecmis = $recent_calls.select { |s, _| s == signature }
  return false if gecmis.size < 2

  onceki, simdiki = gecmis[-2], gecmis[-1]
  # Sonuç VEYA sayfa durumu değiştiyse ilerleme var → döngü değil.
  onceki[1] == simdiki[1] && onceki[2] == simdiki[2]
end

def record_call(signature, result, state)
  $recent_calls << [signature, result.to_s, state]
  $recent_calls.shift while $recent_calls.size > 8
end

# Döngü uyarısı: aynı çağrının 3. tekrarında modele NE YAPACAĞINI söyle ve
# sayfa durumunu yine de ver ki körsüz kalmasın.
def dongu_uyarisi(name)
  baslik = begin
    $browser&.driver&.title.to_s
  rescue StandardError
    ""
  end
  url = begin
    $browser&.driver&.current_url.to_s
  rescue StandardError
    ""
  end
  öneri =
    case name
    when "browser_snapshot", "browser_dom", "browser_read"
      "Sayfa zaten yukarıda listelendi. Aynı bilgiyi tekrar isteme: " \
        "görevi TAMAMLA ve araç çağırmayı bırakarak cevabını yaz."
    when "browser_scroll"
      "Kaydırma sonuç vermiyor. Kaydırmayı BIRAK; yukarıdaki dökümde/metinde " \
        "gereken bilgi zaten var. Görevi tamamla ve cevabı yaz."
    when "browser_click"
      "Bu tıklama zaten yapıldı. Farklı bir öğe seç ya da görevi tamamla."
    when "browser_type"
      "Bu alana zaten yazıldı. Alanın değerini kontrol et; submit gerekiyorsa " \
        "browser_press_key(key: \\\"enter\\\") dene, yoksa görevi tamamla."
    else
      "Farklı bir araç dene ya da görevi tamamla."
    end

  "DÖNGÜ UYARISI: aynı çağrı 3. kez geldi (#{name}) ve ÇALIŞTIRILMADI.\n" \
    "DURUM: #{baslik[0, 70]} | #{url[0, 80]}\n" \
    "YAPILACAK: #{öneri}"
end

def call_tool(name, args)
  signature = [name, args.sort_by { |k, _| k.to_s }.to_s]
  # Aynı çağrı 3. kez gelmiş VE sonuç/sayfa durumu değişmemişse gerçek döngü:
  # modele ne yapacağını söyleyen, sayfa durumunu da içeren uyarıyı döndür.
  return dongu_uyarisi(name) if loop_warning?(name, signature)

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = Timeout.timeout(OP_TIMEOUT) { dispatch_tool(name, args) }
  durum = DURUM_IZLEYEN.include?(name) ? (browser.state_signature rescue nil) : nil
  record_call(signature, result, durum)
  Audit.log(
    tool: name, args: args, ok: !result.to_s.match?(/\A(HATA|ENGELLENİR|ENGELLENDİ|ONAY GEREKLİ)/),
    detail: result, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
  )
  result
rescue StandardError => e
  Audit.log(tool: name, args: args, ok: false, detail: e.message)
  raise
end

def dispatch_tool(name, args)
  case name
  when "browser_navigate"   then browser.navigate(args["url"])
  when "browser_snapshot"   then browser.snapshot
  when "browser_dom"        then browser.dom(q: args["q"], limit: args["limit"])
  when "browser_click"      then browser.click(ref: args["ref"], selector: args["selector"], text: args["text"], confirm: args["confirm"])
  when "browser_find"       then browser.find(args["text"])
  when "browser_read"       then browser.read(max: args["max"] || 1500)
  when "browser_select"     then browser.select(ref: args["ref"], selector: args["selector"], value: args["value"], label: args["label"])
  when "browser_alert"      then browser.alert(action: args["action"] || "accept")
  when "browser_scroll"     then browser.scroll(direction: args["direction"] || "down", amount: args["amount"] || 600)
  when "browser_frame"      then browser.frame(action: args["action"] || "main", selector: args["selector"], index: args["index"], ref: args["ref"])
  when "browser_upload"     then browser.upload(ref: args["ref"], selector: args["selector"], path: args["path"])
  when "browser_hover"      then browser.hover(ref: args["ref"], selector: args["selector"], text: args["text"])
  when "browser_type"       then browser.type(ref: args["ref"], selector: args["selector"], text: args["text"], submit: args["submit"], confirm: args["confirm"])
  when "browser_press_key"  then browser.press_key(args["key"])
  when "browser_resize"     then browser.resize(args["width"] || 1280, args["height"] || 800)
  when "browser_monitor"    then browser.monitor(action: args["action"], filter: args["filter"], timeout: args["timeout"] || 10)
  when "browser_wait_for"   then browser.wait_for(text: args["text"], timeout: args["timeout"] || (args["type"].to_s == "download" ? 30 : 10), type: (args["type"] || (args["selector"] && args["text"].to_s.empty? ? "selector" : "text")), selector: args["selector"], value: args["value"])
  # type=load için timeout aynı metin varsayılanı (10) kullanılır.
  when "browser_screenshot" then browser.screenshot
  when "browser_evaluate"   then browser.evaluate(args["script"])
  when "browser_history"    then browser.history(args["direction"])
  when "browser_tabs"       then browser.tabs(action: args["action"] || "list", index: args["index"], url: args["url"])
  when "browser_status"     then browser.status
  when "browser_close"      then browser.close
  else
    raise "Bilinmeyen araç: #{name}"
  end
end

def respond(id, result)
  REAL_STDOUT.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: result }))
end

def respond_error(id, code, message)
  REAL_STDOUT.puts(JSON.generate({ jsonrpc: "2.0", id: id, error: { code: code, message: message } }))
end

def handle(request)
  id = request["id"]
  method = request["method"].to_s
  params = request["params"] || {}

  case method
  when "initialize"
    respond(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "selenit-mcp", version: SERVER_VERSION }
    })
  when "notifications/initialized", "initialized"
    # bildirim: yanıt yok
  when "ping"
    respond(id, {})
  when "tools/list"
    respond(id, { tools: Tools.liste })
  when "tools/call"
    name = params["name"].to_s
    args = params["arguments"] || {}
    begin
      text = call_tool(name, args)
      respond(id, { content: [{ type: "text", text: text.to_s }], isError: false })
    rescue StandardError => e
      respond(id, { content: [{ type: "text", text: "HATA: #{e.message}" }], isError: true })
    end
  when "resources/list"
    respond(id, { resources: [] })
  when "prompts/list"
    respond(id, { prompts: [] })
  else
    respond_error(id, -32_601, "Desteklenmeyen metot: #{method}") if id
  end
rescue StandardError => e
  respond_error(id, -32_603, "Sunucu hatası: #{e.message}") if id
end

$stderr.puts("[selenit-mcp] hazır (stdio)")

while (line = STDIN.gets)
  line = line.strip
  next if line.empty?

  begin
    request = JSON.parse(line)
  rescue JSON::ParserError => e
    $stderr.puts("[selenit-mcp] geçersiz JSON: #{e.message}")
    next
  end

  handle(request)
end
