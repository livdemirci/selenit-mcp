# CDP (Chrome DevTools Protocol) ile yönetilen tarayıcı katmanı.
#
# selenit yaklaşımının aynısı:
#  - Tarayıcı --remote-debugging-port=<port> ile açılır (detach: açık kalır)
#  - Sonraki çağrılar YENİ tarayıcı açmaz; debugger_address ile mevcut Chrome'a bağlanır
#  - Sayfa elemanları "ref" (e1, e2, ...) ile işaretlenir; küçük modeller için kısa metin dökümü üretilir
#
# İzolasyon: her MCP örneği kendi portunu kullanır. Varsayılan 19218'dir;
# başka bir sohbet/oturumun tarayıcısına dokunmamak için BROWSER_MCP_PORT ile değiştirin.

require "socket"
require "timeout"
require "fileutils"
require "json"
require "selenium-webdriver"

require_relative "policy"

class SelenitBrowser
  DEFAULT_PORT = 19_218
  READY_TIMEOUT = 5
  # Explicit wait varsayılanı. Sabit sleep yerine koşul beklenir (Zhimin Zhan:
  # "auto-waiting" değil, açık koşul; hata erken ve anlaşılır olmalı).
  WAIT_TIMEOUT = (ENV["BROWSER_MCP_WAIT"] || 10).to_f
  POLL_INTERVAL = 0.1
  # Eylem sonrası toast toplama üst sınırı (sn); "0" ile kapatılabilir.
  TOAST_WAIT = (ENV["BROWSER_MCP_TOAST_WAIT"] || 0.6).to_f

  # Bot/kötü niyet doğrulama ara ekranları (Cloudflare "Bir dakika lütfen",
  # DataDome, "Just a moment", "Checking your browser" ...). Bu ekranlar
  # sayfa yüklü görünür ama içerik YOKTUR; modeli linklerle baş başa
  # bırakmak yerine kalkmasını bekle.
  CHALLENGE_PATTERNS = [
    /bir dakika lütfen/i, /just a moment/i, /checking your browser/i,
    /verify(ing)? (that )?you are (a )?human/i, /attention required/i,
    /güvenlik doğrulaması/i, /ddos protection/i,
    /enable javascript and cookies/i, /access denied/i
  ].freeze
  CHALLENGE_WAIT = (ENV["BROWSER_MCP_CHALLENGE_WAIT"] || 20).to_f
  # Seçici DOM'da hiç yoksa (sayfa yüklüyken) bu sürede hızla reddet:
  # yanlış seçici 10 sn (wait_timeout) yanmasın.
  FAILFAST_PRESENCE = (ENV["BROWSER_MCP_FAILFAST"] || 1.25).to_f
  LAZY_SCROLLS = (ENV["BROWSER_MCP_LAZY_SCROLLS"] || 8).to_i
  IGNORED_WAIT_ERRORS = [
    Selenium::WebDriver::Error::NoSuchElementError,
    Selenium::WebDriver::Error::StaleElementReferenceError,
    Selenium::WebDriver::Error::ElementNotInteractableError
  ].freeze

  attr_reader :port, :driver

  def initialize(port: ENV["BROWSER_MCP_PORT"] || DEFAULT_PORT,
                 headless: ENV["BROWSER_MCP_HEADLESS"] == "true",
                 max_elements: (ENV["BROWSER_MCP_MAX_ELEMENTS"] || 40).to_i,
                 wait_timeout: WAIT_TIMEOUT)
    @port = port.to_i
    @headless = headless
    @max_elements = [max_elements, 5].max
    @wait_timeout = wait_timeout.to_f
    @driver = nil
    @alert_recovered = nil
  end

  # --- oturum -------------------------------------------------------------

  # Açık JS uyarısı penceresi tüm komutları öldürür ("unexpected alert open").
  # Alert kendi sekmesine bağlıdır ama chromedriver komutlarını GLOBAL bloklar;
  # yeni oturumun "şu anki penceresi" alert'li sekme olmayabilir → tüm
  # pencereleri gezerek arar. Dönüş: kabul edilen uyarının metni veya nil.
  # Alert yalnızca ŞU AN açıkken hızlı kabul; mevcut pencerede olduğu için
  # window_handles gezme gerektirmez (o yavaş/askı eğilimli). Dönüş: metin|nil.
  def alert_hemen_kabul(driver)
    Timeout.timeout(3) do
      metin = driver.switch_to.alert.text
      driver.switch_to.alert.accept
      metin
    end
  rescue StandardError
    nil
  end

  def stuck_alertı_kapat(driver)
    return nil unless driver
    handles = begin
      driver.window_handles
    rescue StandardError
      [nil]
    end
    handles.each do |h|
      begin
        driver.switch_to.window(h) if h
        metin = driver.switch_to.alert.text
        driver.switch_to.alert.accept
        return metin
      rescue Selenium::WebDriver::Error::NoSuchAlertError
        next
      rescue StandardError
        next
      end
    end
    nil
  end

  def ensure_session
    if @driver && !alive?
      # Ölü pencere: sürücü referansı bayat. BiDi aboneliği ve monitör
      # tamponu eski bağlantıya aitti; yeni sürücüde yeniden kurulacaklar.
      warn("[selenit-mcp] ölü pencere; sürücü yeniden kuruluyor") if $stderr
      @bidi = nil
      @monitor_cbs = nil
      @monitor_buffer = nil
      @monitor_mutex = nil
      @driver = nil
    end

    return @driver if @driver

    mode = (ENV["BROWSER_MODE"] || "auto").to_s
    attempts = 0
    begin
      attempts += 1
      @driver =
        case mode
        when "existing"
          raise "existing modunda 127.0.0.1:#{@port} açık değil (Chrome'u --remote-debugging-port ile başlatın)" unless port_open?(@port)

          attach
        when "managed"
          launch
        else
          port_open?(@port) ? attach : launch
        end
      # İlk komut provası: chromedriver kapanmış bir hedefi önbellekten
      # tutup ilk komutta "no such window" verebiliyor; hata gelirse
      # sürücüyü bir kez yeniden kur (2. deneme kendini toparlıyordu).
      @driver.window_handle
    rescue StandardError => kurulum_err
      alert_kaynakli = /alert/i.match?(kurulum_err.message)
      # Önce açık JS uyarısı denemesi: uyarı tüm komutları öldürür ve yeni
      # oturum attığında da kalıcıdır. Kabul metni @alert_recovered ile bir
      # sonraki snapshot'ta modele yansıtılır.
      if @driver
        engradeli = begin
          Timeout.timeout(6) { stuck_alertı_kapat(@driver) }
        rescue Timeout::Error, StandardError
          warn("[selenit-mcp] uyarı tarama askıda; doğrudan kurtarmaya geçiliyor") if $stderr
          nil
        end
        begin
          @driver.window_handle
          @alert_recovered = engradeli if engradeli
          return @driver
        rescue StandardError => kurtarma_err
          @bidi = nil
          @monitor_cbs = nil
          @monitor_buffer = nil
          @monitor_mutex = nil
          @driver = nil
          # Alert hâlâ açık (kabul edilemedi): auto modda izole profilli
          # Chrome'u kapat; retry'daki launch taze Chrome başlatır.
          if alert_kaynakli || /alert/i.match?(kurtarma_err.message)
            raise if mode == "existing"

            kendi_chromeunu_kapat
          end
        end
      elsif alert_kaynakli && mode != "existing"
        # attach sırasında alert hatası (@driver kurulamadı): aynı çare.
        kendi_chromeunu_kapat
      end

      raise unless attempts < 2
      @driver = nil
      retry
    end
    @driver
  rescue StandardError => e
    @driver = nil
    if /alert/i.match?(e.message)
      raise "Tarayıcı açılamadı (port #{@port}): açık bir JS uyarı penceresi kapatılamadı. " \
            "Tekrar dene; sorun sürerse browser_alert ile metni oku/kapat. " \
            "Ayrıntı: #{e.message.lines.first.to_s.strip}"
    end

    raise "Tarayıcı açılamadı/bağlanamadı (port #{@port}): #{e.message}"
  end

  def alive?
    @driver.window_handle
    true
  rescue StandardError
    false
  end

  # Attach üst sınırı: açık JS uyarısı, chromedriver'ın YENİ oturum açışını
  # bile sonsuz askıda bırakabiliyor (gözlem: 90 sn'de "execution expired").
  ATTACH_LIMIT = (ENV["BROWSER_MCP_ATTACH_TIMEOUT"] || 13).to_f

  # Kilitleyen Chrome'u kapatır; yalnızca SERVERA AİT izole profille
  # koşan süreçlere dokunur (kullanıcının kendi Chrome'u asla): pgrep
  # hem bağlantı portunu hem artifacts profil dizinini arar.
  def kendi_chromeunu_kapat
    out = `/usr/bin/pgrep -f "remote-debugging-port=#{@port}" 2>/dev/null`.to_s
    pids = out.lines.map(&:strip).reject(&:empty?).map(&:to_i).uniq
    pids = pids.select do |pid|
      cmd = `/bin/ps -o command= -p #{pid} 2>/dev/null`.to_s
      cmd.include?("chrome-profile-#{@port}")
    end
    pids.each { |pid| Process.kill("TERM", pid) rescue nil }
    sleep 0.4
    pids.each { |pid| Process.kill("KILL", pid) rescue nil }
    pids
  end

  def attach
    options = Selenium::WebDriver::Chrome::Options.new
    options.debugger_address = "127.0.0.1:#{@port}"
    # BiDi (network/console olayları) WebSocket URL gerektirir; browser_monitor bunu kullanır.
    options.web_socket_url = true
    # JS uyarıları otomatik kapanmasın; model browser_alert ile karar versin
    options.unhandled_prompt_behavior = :ignore
    begin
      Timeout.timeout(ATTACH_LIMIT) do
        driver = Selenium::WebDriver.for(:chrome, options: options)
        # Implicit wait KAPALI: yalnızca açık (explicit) koşul beklemeleri kullanılır.
        driver.manage.timeouts.implicit_wait = 0
        driver
      end
    rescue Timeout::Error
      # Asımada kaldı → port'un izole profilli Chrome'unu kapat; auto moda
      # dönüşte ensure_session taze Chrome'u launch ile başlatır.
      if ENV["BROWSER_MODE"] == "existing"
        raise "attach #{ATTACH_LIMIT.to_i} sn'de tamamlanamadı (açık JS uyarısı attach'i kilitliyor)." \
              " Mevcut modda Chrome'u elle kapatın veya uyarıyı kapatın."
      else
        oldu = kendi_chromeunu_kapat
        warn("[selenit-mcp] attach asıldı; Chrome kapatıldı (#{oldu.join(', ') || 'pid yok'})") if $stderr
        raise "attach #{ATTACH_LIMIT.to_i} sn'de tamamlanamadı (önceki oturumdan kalmış açık JS uyarısı attach'i kilitliyordu);" \
              " port #{@port} Chrome'u kapatıldı, bir sonraki denemede taze başlatılacak."
      end
    end
  end

  def launch
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument("--remote-debugging-port=#{@port}")
    options.add_argument("--headless=new") if @headless
    options.add_argument("--window-size=1280,900")
    # "webdriver" izini azalt: bazı sitelerin bot doğrulaması yalnızca bu
    # bayraklar yüzünden hiç geçilmiyor (Cloudflare challenge döngüsü).
    options.add_argument("--disable-blink-features=AutomationControlled")
    begin
      options.add_experimental_option("excludeSwitches", ["enable-automation"])
      options.add_experimental_option("useAutomationExtension", false)
    rescue StandardError
      nil
    end
    options.unhandled_prompt_behavior = :ignore
    options.detach = true

    # İzole profil: kullanıcının günlük Chrome profiline dokunmaz, çerezler ayrı kalır
    profile = ENV["BROWSER_MCP_PROFILE_DIR"] ||
              File.expand_path("artifacts/chrome-profile-#{@port}", __dir__)
    FileUtils.mkdir_p(profile)
    options.add_argument("--user-data-dir=#{profile}")

    # İndirmeleri bilinen bir klasöre al: test dosya adını ve varlığını doğrulayabilsin.
    dl = download_dir
    FileUtils.mkdir_p(dl)
    options.add_preference("download.default_directory", dl)
    options.add_preference("download.prompt_for_download", false)
    options.add_preference("download.directory_upgrade", true)
    options.add_preference("safebrowsing.enabled", true)
    # BiDi (network/console olayları) WebSocket URL gerektirir; browser_monitor bunu kullanır.
    options.web_socket_url = true

    driver = Selenium::WebDriver.for(:chrome, options: options)
    driver.manage.timeouts.implicit_wait = 0
    driver
  end

  def port_open?(port = @port, host = "127.0.0.1", seconds = 0.6)
    Timeout.timeout(seconds) do
      TCPSocket.new(host, port).close
      true
    end
  rescue StandardError
    false
  end

  def close
    return "Tarayıcı oturumu zaten kapalı." unless @driver

    @driver.quit
    @driver = nil
    "Tarayıcı kapatıldı."
  rescue StandardError => e
    @driver = nil
    "Tarayıcı kapatılırken hata: #{e.message}"
  end

  # --- eylemler -----------------------------------------------------------

  def navigate(url)
    ensure_session
    # Önceki görev iframe içinde kalmış olabilir; yeni gezinme her zaman ana
    # bağlamdan başlar (test bağımsızlığı / görevler arası sızıntı koruması).
    driver.switch_to.default_content rescue nil
    dismissed = dismiss_open_alert
    target = normalize_url(url)
    Policy.check_navigation!(target)
    driver.navigate.to(target)
    wait_ready
    wait_until(timeout: @wait_timeout, message: "sayfa gövdesi yüklenmedi: #{target}") do
      driver.execute_script("return !!(document.body && document.body.nodeType === 1)")
    end
    settle_interactive
    note = dismissed ? "not: açık uyarı kapatıldı (#{dismissed})\n" : ""
    if challenge_page?
      if wait_challenge_clear
        wait_ready(5)
        note += "not: site doğrulama ekranı beklenerek geçildi\n"
      else
        return "HATA (navigate): #{target} bir bot/kötü niyet doğrulama ekranı gösteriyor " \
               "(Cloudflare/DataDome benzeri). Sayfa içeriği henüz yok.\n" \
               "Öneri: birkaç saniye sonra browser_history(direction: reload) ile yenile ya da " \
               "browser_wait_for(text: \"<sayfada beklenen metin>\", timeout: 30) ile doğrulamanın " \
               "kalkmasını bekle. Doğrulama sürüyorsa siteyi normal bir Chrome penceresinde bir kez " \
               "açıp (BROWSER_MODE=existing) aynı oturuma bağlanmak gerekir."
      end
    end
    note + snapshot_text(header: true)
  rescue Policy::Denied => e
    "ENGELLENDİ: #{e.message}"
  rescue StandardError => e
    error("navigate", e)
  end

  # Eylem sonrası sayfa durumu: URL + metin uzunluğu + metin karması.
  # Döngü koruması "aynı çağrı gerçekten bir şey değiştirdi mi?" sorusunu
  # buna bakarak yanıtlar (aynı "+" düğmesine 4 kez basmak meşrudur).
  def state_signature
    ensure_session
    driver.execute_script(<<~JS)
      var t = document.body ? (document.body.innerText || '') : '';
      var h = 0, n = Math.min(t.length, 4000);
      for (var i = 0; i < n; i++) h = ((h << 5) - h + t.charCodeAt(i)) | 0;
      return [location.href, t.length, h].join('|');
    JS
  rescue StandardError
    ""
  end

  def snapshot
    ensure_session
    snapshot_text
  end

  def challenge_page?
    baslik = driver.title.to_s
    uzunluk = begin
      driver.execute_script("return (document.body ? document.body.innerText.length : 0)").to_i
    rescue StandardError
      0
    end
    govde = begin
      driver.execute_script("return (document.body ? document.body.innerText : '').slice(0, 600)").to_s
    rescue StandardError
      ""
    end
    # Doğrulama ekranları kısadır; uzun içerikli bir sayfada geçen
    # "access denied" gibi ifadeler yanlış pozitif üretmesin.
    return false if uzunluk > 2000
    CHALLENGE_PATTERNS.any? { |re| re.match?(baslik) || re.match?(govde) }
  rescue StandardError
    false
  end

  def wait_challenge_clear(timeout = CHALLENGE_WAIT)
    return false unless challenge_page?

    wait_until(timeout: timeout, message: "site doğrulama ekranı kalkmadı") { !challenge_page? }
    true
  rescue Selenium::WebDriver::Error::TimeoutError
    false
  end

  # Kompakt DOM okuması: snapshot'tan çok hafif (URL/başlık/uyarı/modal sayı),
  # ya da q ile seçilen öğelerin kısa listesi. Büyük sayfalarda sayfanın
  # tüm dökümü yerine "durum sorulacağı" zaman için.
  DOM_JS = <<~JS
    var q = arguments[0], limit = arguments[1];
    var out = {
      url: location.href,
      baslik: (document.title || "").slice(0, 90),
      ready: document.readyState,
      girdi: document.querySelectorAll("input,textarea,select").length,
      // Modal tespiti snapshot.js ile AYNI ölçütü kullanmalı: element görünür
      // olmalı VE ekran merkezini kapsamalı. Eski hâli yalnızca "DOM'da
      // modal/dialog class'lı bir şey var mı" diye bakıyordu; Trendyol'da
      // gizli bir modal class'lı element yüzünden modal:true dönüyor ve model
      // "MODAL AÇIK" sanıp yanlış strateji kuruyordu (ölçüldü: gerçek aday
      // cookie-setting-link, 474x40px, merkezi kapsamıyor).
      modal: (function () {
        var cands = document.querySelectorAll(
          '[aria-modal="true"],[role="dialog"],dialog[open],' +
          '[class*="modal" i],[class*="dialog" i],[class*="popup" i]');
        var cx = window.innerWidth / 2, cy = window.innerHeight / 2;
        var hit = null;
        try { hit = document.elementFromPoint(cx, cy); } catch (e) { hit = null; }
        if (!hit) return false;
        for (var i = 0; i < cands.length; i++) {
          var c = cands[i];
          var r = c.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) continue;
          var s = window.getComputedStyle(c);
          if (s.visibility === "hidden" || s.display === "none" || s.opacity === "0") continue;
          if (c === hit || c.contains(hit)) {
            var q2 = "a[href],button,input,textarea,select,[role=button],[role=link],[role=textbox]";
            var ic = c.querySelectorAll(q2), gor = 0;
            for (var j = 0; j < ic.length; j++) {
              var ir = ic[j].getBoundingClientRect();
              if (ir.width > 0 && ir.height > 0) gor++;
            }
            if (gor > 0) return true;
          }
        }
        return false;
      })(),
      alert: (function () {
        var a = document.querySelector("[role=alert],[role=status],.hb-toast-notifier-box,[class*='toast' i]");
        return (a && a.getBoundingClientRect().height > 0) ? (a.innerText || "").replace(/\\s+/g, " ").slice(0, 90) : null;
      })()
    };
    if (q) {
      var nodes = document.querySelectorAll(q);
      var dizi = [];
      for (var i = 0; i < nodes.length && dizi.length < limit; i++) {
        var n = nodes[i];
        var r = n.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) continue;
        dizi.push({
          tag: n.tagName.toLowerCase(),
          metin: (n.innerText || "").replace(/\\s+/g, " ").slice(0, 70),
          href: (n.getAttribute && n.getAttribute("href")) || null,
          sinif: (typeof n.className === "string" ? n.className : "").slice(0, 60) || null,
          rol: n.getAttribute("role") || null
        });
      }
      out.oge = dizi;
      out.toplam = nodes.length;
    }
    return JSON.stringify(out);
  JS

  def dom(q: nil, limit: nil)
    ensure_session
    driver.execute_script(DOM_JS, (q.to_s.empty? ? nil : q.to_s), (limit || 8).to_i)
  rescue StandardError => e
    error("dom", e, q)
  end

  def click(ref: nil, selector: nil, text: nil, confirm: false)
    ensure_session
    element = resolve(ref, selector, text, wait: :clickable)

    if Policy.require_approval? && !confirm
      label = [element.text, element.attribute("aria-label"), element.attribute("value")].compact.join(" ").strip
      return Policy.risky_message(label) if Policy.risky?(label)
    end

    url_before_click = driver.current_url
    tabs_before = driver.window_handles.size
    original_handle = driver.window_handle
    target_blank = element.attribute("target").to_s == "_blank"
    js_click_note = click_element(element)
    wait_after_action(previous_url: url_before_click)
    opened = wait_for_new_tab(tabs_before, timeout: target_blank ? 3 : 0.5)

    note = ""
    if opened
      # target=_blank bağlantısında yeni sekme sessiz kalmayabilir; küçük model
      # aktif sekmeyi hep eski sayfa sanır. Yeni sekmeye otomatik geçilir ve bu
      # açıkça bildirilir. Chrome bazı pop-up'ları (özellikle data: URL hedefli)
      # açıp hemen kapatabilir; o durumda sessiz şekilde eski sekmeye dönüyoruz.
      begin
        new_handle = driver.window_handles.find { |h| h != original_handle }
        if new_handle
          driver.switch_to.window(new_handle)
          driver.switch_to.default_content rescue nil
          wait_ready(3)
          new_index = driver.window_handles.index(new_handle)
          note = "not: yeni sekme açıldı ve otomatik geçildi (index: #{new_index}). " \
                 "Geri dönmek için browser_tabs(action: \"switch\", index: #{tabs_before - 1}) kullan.\n"
        end
      rescue Selenium::WebDriver::Error::NoSuchWindowError, Selenium::WebDriver::Error::WebDriverError
        # Sekme açılır açılmaz kapatıldı: aktif sekmede kal.
        driver.switch_to.window(original_handle) rescue nil
        note = "not: yeni sekme açıldı ama hemen kapandı (Chrome pop-up engelleyebilir); aktif sekme korundu.\n"
      end
    end

    toasts = harvest_toasts
    sessiz = sepet_ikonu_mu?(element) && toasts.empty? ?
      "\nnot: sepete ekleme ikonuna basıldı ama onay/hata toast'u GELMEDİ — ürün satılabilir " \
      "olmayabilir; taze browser_snapshot al ve SIRADAKİ 'Sepete ekle ikonu' ref'ine geç " \
      "(aynı ref'e yeniden tıklamak sonucu değiştirmez)." : ''
    "#{note}tıklandı: #{ref || selector || text.inspect}" \
      "#{js_click_note ? "\n#{js_click_note}" : ''}\n#{snapshot_text}#{toasts}#{sessiz}"
  rescue Selenium::WebDriver::Error::StaleElementReferenceError
    # Öğe tıklama anında bayatladı: ref'i yeni snapshot'tan yeniden çöz ve bir kez daha dene.
    raise if @click_retry.to_i >= 1

    @click_retry = @click_retry.to_i + 1
    retry
  rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError => e
    metin = e.message[/Alert text : (.+?)\}/, 1].to_s
    # Önce alert'i kabul et (retry, accept olmadan yine çarpılır);
    # switch_to.alert yalnızca mevcut pencereye bakar — hızlıdır.
    kabul = alert_hemen_kabul(driver)
    @alert_recovered = kabul || metin
    # retry metot gövdesini BAŞTAN başlatır; sayaç bunu atlar (replace:
    # metot başında sıfırlanan flag ile karıştırma). Sayaç ensure'de sıfırlanır.
    if @alert_retry_i.to_i < 1
      @alert_retry_i = @alert_retry_i.to_i + 1
      retry
    end
    "UYARI: tıklama bir JS uyarı penceresi açtı ve kabul edildi (#{@alert_recovered}). " \
      "Tıklama bir kez yeniden denendi; uyarı tekrar açılırsa browser_alert kullan."
  rescue StandardError => e
    @alert_retry_i = 0
    error("click", e, ref || selector || text)
  ensure
    @click_retry = 0
    @alert_retry_i = 0
  end

  def type(ref: nil, selector: nil, text: "", submit: false, confirm: false)
    ensure_session
    if submit && Policy.require_approval? && !confirm
      return Policy.risky_message("form gönderimi (submit)")
    end

    element = resolve(ref, selector, nil, wait: :visible)
    url_before_type = driver.current_url
    attempts = 0
    begin
      attempts += 1
      begin
        element.clear
      rescue Selenium::WebDriver::Error::InvalidElementStateError
        # salt-okunur alan: temizleme atlanır, yazma denemesi anlamlı hata verir
        nil
      end
      element.send_keys(text.to_s)
      element.send_keys(:enter) if submit
      # JS tabanlı aramalar (form yok, keydown dinleyicisi yok): Enter hiçbir
      # şey yapmaz. n11.com'da ölçüldü — form yok, arama ikonu `I.new-search-icon`
      # input'un kardeşi. Enter denendikten sonra URL değişmediyse ve input
      # içindeysek, en yakın submit-benzeri kontrolü tıkla.
      #
      # n11 ÖLÇÜMÜ (regresyon): Enter URL'yi DEĞİŞTİRİYOR ama yanlış yere
      # götürüyor — arama kutusunun placeholder'ı dinamik bir ürün önerisi
      # taşıyor ("Philips Hue GO , 3851 TL"), otomatik tamamlama o öneriyi
      # seçiyor ve /urun/... açılıyor. Eski kod "URL değişti = başarı" sayıp
      # geçiyordu (3/3 tekrarda aynı hata). Artık URL değişse bile hedefin
      # ARAMA SONUCU olduğu doğrulanır; değilse URL şemasıyla düzeltilir.
      if submit && %w[input textarea].include?(element.tag_name)
        begin
          wait_until(timeout: 1.5) { driver.current_url != url_before_type }
          unless arama_sonucu_sayfasi?(text)
            via = submit_via_url(element, text)
            resume_after_js_action if via
          end
        rescue Selenium::WebDriver::Error::TimeoutError
          # 1) form / submit ikonu
          cozuldu = false
          if (submit_click = js_submit_click(element))
            sleep 0.4
            cozuldu = driver.current_url != url_before_type && arama_sonucu_sayfasi?(text)
          end
          # 2) hâlâ değişmediyse: URL şemasıyla arama (JS event yutuluyorsa)
          unless cozuldu
            via = submit_via_url(element, text)
            resume_after_js_action if via
          end
        end
      end
    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      # Otomatik tamamlama/arama kutusu DOM'u yenileyebilir; öğeyi yeniden
      # çözüp yazmayı bir kez tekrarla.
      # Hepsiburada ölçümü: örtü açılırken DOM yenileniyor ve Selenium
      # "stale element reference" atıyor. Ama işlem çoğu zaman BAŞARILI
      # oluyor (URL /ara?q=... değişmiş) — bu durumda hatayı yut, modele
      # yanlış "HATA" gösterme.
      if driver.current_url.to_s != url_before_type.to_s
        return "yazıldı: #{ref || selector} <- #{text.to_s[0, 60].inspect}#{submit ? ' + Enter' : ''} " \
               "(not: DOM yenilendi, işlem tamamlandı)\n#{snapshot_text}#{harvest_toasts}"
      end
      raise if attempts >= 2

      attempts += 1
      element = yeniden_coz(ref, selector)
      retry
    rescue Selenium::WebDriver::Error::ElementNotInteractableError
      # Hepsiburada ölçümü: arama input'u görünür (rect 418x52, display
      # inline-block) ama pointerEvents:none; merkezinde overlay açan bir DIV
      # var. O DIV'e tıklamak input'u tıklanabilir yapıyor — ama tıklama DOM'u
      # yenilediği için ESKİ ELEMENT REFERANSI GEÇERSİZ oluyor (ölçüldü:
      # tıklama sonrası e1 "seçici DOM'da bulunmadı"). Bu yüzden önce aç,
      # sonra ref'i yeniden çöz.
      raise if attempts >= 2

      attempts += 1
      if type_click_ac(element)
        sleep 0.3
        begin
          element = selector.to_s.empty? ? resolve(ref, nil, nil, wait: :visible) : resolve(nil, selector, nil, wait: :visible)
        rescue StandardError
          nil
        end
      end
      js_yaz(element, text)
      @js_type_used = true
      @son_yazma_notu = " (not: öğe tıklanamaz durumdaydı — pointer-events:none; JS ile yazıldı)"
      # Örtü açıldıysa artık gerçek Enter gönderilebilir: Hepsiburada ölçümü
      # (tıkla → yaz → Enter) /ara?q=kalem sonucunu veriyor. Bu yol URL
      # şeması tahmininden daha güvenilir, önce onu dene.
      unless submit
        nil
      else
        begin
          element.send_keys(:enter)
          wait_until(timeout: 3) { driver.current_url != url_before_type }
          @son_yazma_notu = " (not: örtü açılıp Enter gönderildi)"
        rescue StandardError
          nil
        end
      end
    end
    # Değerin gerçekten yazıldığını explicit bekle; arama/filtre gibi
    # input olaylarıyla DOM'u güncelleyen sayfalarda snapshot yarışını önler.
    if !submit && %w[input textarea].include?(element.tag_name)
      tip = (element.attribute("type") rescue "").to_s.downcase
      yazildi = begin
        wait_until(timeout: 2) do
          driver.execute_script("return (arguments[0].value || '').toString()", element).to_s == text.to_s
        end
        true
      rescue Selenium::WebDriver::Error::TimeoutError
        false
      end
      # Kontrollü (React/Vue) alanlar send_keys'i yutabiliyor: native setter +
      # input/change olayı ile değeri gerçekten yerleştir.
      js_set_value(element, text) unless yazildi
      # Sayı alanları çoğu sitede blur/Enter ile commit edilir; aksi halde
      # yazılan değer sepet/adet modeline geçmez.
      begin
        driver.execute_script("arguments[0].blur()", element) if %w[number tel].include?(tip)
      rescue StandardError
        nil
      end
    end
    # JS ile yazıldıysa Enter hiç gönderilemedi: submit'i URL şemasıyla tamamla.
    if submit && @js_type_used
      @js_type_used = false
      if driver.current_url == url_before_type
        via = submit_via_url(element, text)
        resume_after_js_action if via
      end
    end
    wait_after_action(previous_url: url_before_type)
    "yazıldı: #{ref || selector} <- #{text.to_s[0, 60].inspect}#{submit ? ' + Enter' : ''}#{@son_yazma_notu}\n#{snapshot_text}#{harvest_toasts}"
  rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError => e
    metin = e.message[/Alert text : (.+?)\}/, 1].to_s
    kabul = alert_hemen_kabul(driver)
    @alert_recovered = kabul || metin
    if @alert_retry_i.to_i < 1
      @alert_retry_i = @alert_retry_i.to_i + 1
      retry
    end
    "UYARI: yazma bir JS uyarı penceresi açtı ve kabul edildi (#{@alert_recovered}). " \
      "Yazma bir kez yeniden denendi; uyarı tekrar açılırsa browser_alert kullan."
  rescue StandardError => e
    @alert_retry_i = 0
    error("type", e, ref || selector)
  ensure
    @alert_retry_i = 0
  end

  # Metne göre öğe bulur, ref üretir (uzun sayfalar ve shadow DOM için).
  # Lazy-load sayfalarda Zhan'ın yaklaşımı: bulunamazsa sona kaydır, içerik
  # yüklenince tekrar ara; sabit sayıda denemeden sonra anlaşılır hata döndür.
  def find(text, limit: 5, lazy: true)
    ensure_session
    matches = scan_text(text, limit)

    if matches.empty? && lazy
      no_growth = 0
      LAZY_SCROLLS.times do
        grew = scroll_lazy_step
        matches = scan_text(text, limit)
        break unless matches.empty?

        no_growth = grew ? 0 : no_growth + 1
        break if no_growth >= 2
      end
    end

    return "'#{text}' ile eşleşen öğe bulunamadı. browser_snapshot veya browser_read dene." if matches.empty?

    lines = matches.map do |m|
      href = m["href"].to_s.empty? ? "" : " -> #{truncate(m['href'], 60)}"
      "#{m['ref']} #{m['tag']} #{truncate(m['name'], 70)}#{href}"
    end
    "eşleşmeler:\n#{lines.join("\n")}"
  rescue StandardError => e
    error("find", e, text)
  end

  # Görünür sayfa metni (özetleme/okuma görevleri için)
  def read(max: 1500)
    ensure_session
    if (open_alert = alert_text)
      return "UYARI: açık JS uyarı penceresi var (#{open_alert}). Kapatmak için browser_alert kullan."
    end

    wait_until(timeout: @wait_timeout, message: "sayfa metni okunamadı (body yok)") do
      driver.execute_script("return !!(document.body && document.body.innerText !== undefined)")
    end
    body = driver.find_element(:tag_name, "body")
    text = body.text.to_s.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
    # Ürün listesi en değerli içerik: model arama sonuçlarını arıyorsa onu ver.
    # Hepsiburada ölçümü: [class*="productList"] 8.509 karakterlik gerçek ürün
    # listesi; body.innerText ise header menüsüyle başlayıp max bütçesini
    # tüketiyordu.
    ana = begin
      driver.execute_script(<<~JS)
        var seciciler = ['[class*="productList" i]','[class*="product-list" i]',
                         '[class*="searchResult" i]','[class*="search-result" i]',
                         'main','[role=main]','#content'];
        for (var i = 0; i < seciciler.length; i++) {
          var e = document.querySelector(seciciler[i]);
          if (e && e.innerText && e.innerText.trim().length > 200) return e.innerText;
        }
        return '';
      JS
    rescue StandardError
      ""
    end
    ana = ana.to_s.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
    # Ürün listesi varsa her zaman onu kullan (header gürültüsü yerine).
    text = ana if ana.length > 200
    # Modelin gereksiz kaydırma yapmasını azalt: sayfada kaç kayıt/ürün/bağlantı
    # olduğunu ve kaydırmanın gerekli olup olmadığını tek satırda bildir.
    ipucu = begin
      m = dom_metrics
      toplam_yuk = m && m[0].to_i
      kalan = toplam_yuk.to_i - driver.execute_script("return Math.round(window.scrollY + window.innerHeight)").to_i
      urun = driver.execute_script(
        "return document.querySelectorAll('a[href*=\"/urun/\"],a[href*=\"-p-\"],li[class*=product i]').length"
      ).to_i
      parcalar = []
      parcalar << "#{urun} ürün/kayıt öğesi" if urun.positive?
      parcalar << (kalan <= 40 ? "sayfa sonu" : "aşağıda ~#{kalan}px daha var")
      parcalar.empty? ? "" : "\nDURUM: #{parcalar.join(', ')}. Gerekli bilgi yukarıdaki metinde varsa kaydırma."
    rescue StandardError
      ""
    end
    "BAŞLIK: #{driver.title}\nURL: #{driver.current_url}#{ipucu}\nMETİN:\n#{truncate(text, max.to_i)}"
  rescue StandardError => e
    error("read", e)
  end

  # Açılır listeden seçim
  def select(ref: nil, selector: nil, value: nil, label: nil)
    ensure_session
    raise "value veya label gerekli" if value.nil? && label.nil?

    element = resolve(ref, selector, nil, wait: :visible)
    # Küçük modeller sık sık düğme ref'ini select alanında kullanıyor;
    # Selenium'un ham "unexpected tag name" hatası yerine etiketi söyle.
    tag = (element.tag_name rescue nil).to_s.downcase
    return custom_select(element, (label || value).to_s, ref || selector) if tag != "select"

    sel = Selenium::WebDriver::Support::Select.new(element)
    if label
      sel.select_by(:text, label.to_s)
    else
      begin
        sel.select_by(:value, value.to_s)
      rescue StandardError
        sel.select_by(:text, value.to_s)
      end
    end
    chosen = begin
      o = sel.first_selected_option
      "seçildi: #{o.text} (value=#{o.attribute('value')})"
    rescue Selenium::WebDriver::Error::StaleElementReferenceError,
           Selenium::WebDriver::Error::NoSuchElementError
      # Sayfa seçim anında yenilendi (onchange → navigasyon): eylem başarılı,
      # eski element referansı çöktü. HATA döndürmek modeli gereksiz tekrara
      # sokuyordu; yeni sayfada doğrulaması için not düş.
      wait_after_action
      "seçildi: #{label || value} (sayfa yenilendi; sıralama/filtre yeni yüklemede geçerli)"
    end
    "#{chosen}\n#{snapshot_text}"
  rescue StandardError => e
    error("select", e, ref || selector)
  end

  # role/class tabanlı özel açılır menüler (b-select, combobox, dropdown).
  # <select> olmayan ama listbox açan bileşenlerde: aç → seçeneği metne göre bul → tıkla.
  CUSTOM_OPTION_SELECTOR = '[role=option],li,[class*="option" i],[class*="select-item" i]'

  def custom_select(element, hedef, hedef_adi)
    hedef = hedef.to_s.strip
    raise "value veya label gerekli" if hedef.empty?

    acik = begin
      element.attribute("aria-expanded").to_s == "true" ||
        driver.execute_script("return !!(arguments[0].closest('[aria-expanded=\"true\"]'))", element)
    rescue StandardError
      false
    end
    element.click unless acik
    wait_after_action
    begin
      wait_until(timeout: 2, ignore: []) do
        driver.find_elements(:css, CUSTOM_OPTION_SELECTOR).any? { |el| (el.displayed? rescue false) }
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end

    secenekler = driver.find_elements(:css, CUSTOM_OPTION_SELECTOR).select do |el|
      (el.displayed? rescue false) && !element_metni(el).strip.empty?
    end
    needle = hedef.downcase
    secilen = secenekler.find { |el| element_metni(el).strip.downcase == needle } ||
              secenekler.find { |el| element_metni(el).strip.downcase.include?(needle) }
    if secilen.nil?
      liste = secenekler.map { |el| element_metni(el).strip[0, 24] }.uniq.first(8)
      return "HATA (select #{hedef_adi}): '#{hedef}' seçeneği bulunamadı. " \
             "Görünen seçenekler: #{liste.join(' | ')}. " \
             "Menüyü browser_click ile açıp istediğin seçeneğin ref'ini browser_click ile seç."
    end
    click_element(secilen)
    wait_after_action
    "seçildi (özel menü): #{element_metni(secilen).strip[0, 40]}\n#{snapshot_text}#{harvest_toasts}"
  end

  # JS uyarı penceresi: kapat (varsayılan) veya sadece oku.
  # Not: "text" da pencereyi kapatır; açık bırakmak için "peek" kullan.
  def alert(action: "accept")
    ensure_session
    a = driver.switch_to.alert
    case action.to_s
    when "peek"
      "uyarı metni: #{a.text}\nDİKKAT: pencere hâlâ açık; browser_alert(action: \"accept\") ile kapat."
    when "dismiss"
      text = a.text
      a.dismiss
      "uyarı kapatıldı: #{text}"
    when "text"
      text = a.text
      a.accept
      "uyarı metni: #{text} (kapatıldı)"
    else
      text = a.text
      a.accept
      "uyarı kabul edildi ve kapatıldı: #{text}"
    end
  rescue Selenium::WebDriver::Error::NoSuchAlertError
    "açık uyarı penceresi yok."
  rescue StandardError => e
    error("alert", e)
  end

  # iframe bağlamı: main | index | selector | ref
  # Küçük modeller sık sık snapshot ref'ini (e1) selector sanır; ref gibi görünen değer ref olarak çözülür.
  def frame(action: "main", selector: nil, index: nil, ref: nil)
    ensure_session
    if action.to_s == "main"
      driver.switch_to.default_content
    else
      if ref.to_s.empty? && selector.to_s.match?(/\A[ef]\d+\z/)
        ref = selector
        selector = nil
      end

      target =
        if ref && !ref.to_s.empty?
          resolve(ref, nil, nil, wait: :presence)
        elsif selector && !selector.to_s.empty?
          begin
            wait_until(timeout: @wait_timeout, message: "iframe bulunamadı (#{selector})") do
              driver.find_element(:css, selector.to_s)
            end
          rescue Selenium::WebDriver::Error::TimeoutError
            raise "iframe bulunamadı (#{selector}). Sayfadaki iframe ref'ini kullan (ör. e1) " \
                  "veya browser_frame(action: \"enter\", index: 0) dene."
          end
        else
          wait_until(timeout: @wait_timeout, message: "iframe bulunamadı (index #{index})") do
            driver.find_elements(:tag_name, "iframe")[index.to_i] ||
              raise(Selenium::WebDriver::Error::NoSuchElementError, "iframe index #{index}")
          end
        end
      driver.switch_to.frame(target)
    end
    wait_ready
    "frame: #{action}\n#{snapshot_text}"
  rescue StandardError => e
    error("frame", e, action)
  end

  # Dosya yükleme: input[type=file] öğesine yerel yol gönderir.
  # Gizli file input normalde "görünmez"; bu yüzden yalnızca varlık beklenir.
  def upload(ref: nil, selector: nil, path: nil)
    ensure_session
    raise "path gerekli" if path.nil? || path.to_s.empty?

    full = File.expand_path(path.to_s)
    raise "dosya yok: #{full}" unless File.exist?(full)

    element = resolve(ref, selector, nil, wait: :presence)
    element.send_keys(full)
    "dosya seçildi: #{full}\n#{snapshot_text}"
  rescue StandardError => e
    error("upload", e, ref || selector)
  end

  def hover(ref: nil, selector: nil, text: nil)
    ensure_session
    element = resolve(ref, selector, text, wait: :visible)
    driver.action.move_to(element).perform
    # Sabit sleep yerine gerçek koşul: imleç öğenin üzerinde mi?
    wait_until(timeout: 2, ignore: []) do
      driver.execute_script("return arguments[0].matches(':hover')", element)
    end
    "üzerine gelindi: #{ref || selector || text}#{harvest_toasts}"
  rescue Selenium::WebDriver::Error::TimeoutError
    "üzerine gelindi: #{ref || selector || text} (hover durumu doğrulanamadı)"
  rescue StandardError => e
    error("hover", e, ref || selector || text)
  end

  def press_key(key)
    ensure_session
    driver.action.send_keys(key_for(key)).perform
    wait_ready
    "#{driver.title} | #{driver.current_url}#{harvest_toasts}"
  rescue StandardError => e
    error("press_key", e, key)
  end

  # DOM yenilendikten sonra öğeyi yeniden çöz. Ref varsa ref önceliklidir;
  # tekrar başarısız olursa odaktaki düzenlenebilir alana düşer.
  def yeniden_coz(ref, selector)
    if selector.to_s.empty?
      begin
        return resolve(ref, nil, nil, wait: :visible) unless ref.to_s.empty?
      rescue StandardError
        nil
      end
      active = driver.switch_to.active_element
      return active if %w[input textarea].include?(active.tag_name.to_s)

      raise Selenium::WebDriver::Error::StaleElementReferenceError, "öğe yeniden çözülemedi (#{ref})"
    end
    resolve(ref, selector, nil, wait: :visible)
  end

  # Pointer-events:none / katmanla örtülü input'a JS ile yaz.
  # React/Vue kontrollü input'lar value setter'ı doğrudan atamayı görmez;
  # prototype setter'ı üzerinden yazıp input+change olaylarını yayınlamak gerekir.
  #
  # Hepsiburada ölçümü: input önce pointer-events:none ve merkezinde bir DIV
  # var (arama overlay'ini açan katman). O DIV'e tıklamak input'u
  # pointer-events:auto yapıyor ve merkeze input geçiyor — yani "önce aç,
  # sonra yaz". Bu yüzden yazmadan önce örtüyü açmayı dene.
  def js_yaz(element, text)
    type_click_ac(element)
    driver.execute_script(<<~JS, element, text.to_s)
      var el = arguments[0], metin = arguments[1];
      el.focus();
      var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype
                                            : window.HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(proto, 'value');
      if (setter && setter.set) { setter.set.call(el, metin); } else { el.value = metin; }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return el.value;
    JS
  rescue StandardError
    nil
  end

  # Örtülü input'u aç: merkezdeki katman elementi tıklanır, input tıklanabilir
  # hâle gelir. Tıklama DOM'u yenileyebilir; çağıran taraf ref'i yeniden çözmeli.
  def type_click_ac(element)
    driver.execute_script(<<~JS, element)
      var el = arguments[0];
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      var m = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      if (!m || m === el || el.contains(m)) return false;
      var s = window.getComputedStyle(el);
      if (s.pointerEvents !== 'none') return false;
      try { m.click(); } catch (e) {}
      return true;
    JS
  rescue StandardError
    nil
  end

  # SPA/asenkron render oturması: body hazır olsa da header, arama kutusu ve
  # nav JS ile sonradan gelir. n11.com ölçümü: navigate dump'ı arama kutusunu
  # KAÇIRIYOR, 1 sn sonraki snapshot görüyor. Sabit sleep yerine etkileşimli
  # öğe sayısının iki ölçüm arasında stabil kalmasını bekle.
  # Bütçe: en fazla SETTLE_MS kadar; sayfa zaten stabilsen ~0 ek maliyet.
  SETTLE_MS = 900
  SETTLE_STEP = 0.15

  def settle_interactive
    onceki = -1
    sabit = 0
    bekle = 0.0
    script = "return document.querySelectorAll('a[href],button,input,textarea,select').length"
    while bekle < SETTLE_MS / 1000.0
      simdi = driver.execute_script(script).to_i
      if simdi == onceki && simdi > 0
        sabit += 1
        break if sabit >= 2 # iki ardışık ölçüm aynı → oturdu
      else
        sabit = 0
      end
      onceki = simdi
      sleep SETTLE_STEP
      bekle += SETTLE_STEP
    end
    true
  rescue StandardError
    nil
  end

  # Form submit eden bir form yoksa (JS tabanlı arama): input'un kardeşi olan
  # submit-benzeri kontrolü (button/i[class*=search]) JS ile tıkla. Selenium
  # click'i ikon (I) elementlerinde güvenilir değil; JS click daha geniş.
  # Dönüş: tıklanan elementin kısa tanımı veya nil.
  def js_submit_click(element)
    script = <<~JS
      var el = arguments[0];
      if (!el) return '';
      var form = el.closest('form');
      if (form) { try { form.requestSubmit ? form.requestSubmit() : form.submit(); } catch (e) {} return 'form'; }
      var scope = el.parentElement || el;
      for (var up = 0; up < 3 && scope; up++, scope = scope.parentElement) {
        var aday = scope.querySelector(
          'button[type=submit],input[type=submit],button,' +
          '[class*="search-icon" i],[class*="searchBtn" i],[class*="search-btn" i],' +
          '[class*="ara" i][role=button],[aria-label*="ara" i],[aria-label*="search" i]'
        );
        if (aday && aday !== el) { aday.click(); return aday.tagName + '.' + (aday.className || ''); }
      }
      return '';
    JS
    driver.execute_script(script, element).to_s
  rescue StandardError
    nil
  end

  # Son çare: arama alanını URL şemasıyla doldur.
  # n11.com ölçümü: form yok, buton yok, öneri listesi yok; Enter ve native
  # KeyboardEvent yutuluyor (site Selenium üretimi event'leri kabul etmiyor).
  # Ama /arama?q=<terim> doğrudan çalışıyor (52 ürün, doğru başlık).
  # Genel kural: submit denendikten sonra URL değişmediyse, kök alan adına
  # yaygın arama yollarını dene ve gerçekten sonuç döneni kullan.
  ARAMA_YOLLARI = ["/arama?q=%s", "/ara?q=%s", "/search?q=%s", "/sr?q=%s", "/?q=%s", "/?s=%s", "/search?s=%s"].freeze

  def submit_via_url(element, text)
    kok = begin
      u = URI.parse(driver.current_url.to_s)
      "#{u.scheme}://#{u.host}"
    rescue StandardError
      nil
    end
    return nil if kok.nil? || text.to_s.strip.empty?

    onceki_url = driver.current_url
    terim = URI.encode_www_form_component(text.to_s.strip)
    ARAMA_YOLLARI.each do |yol|
      aday = kok + format(yol, terim)
      begin
        driver.navigate.to(aday)
        wait_ready
        settle_interactive
        next if driver.current_url == onceki_url
        # Soft-404 / yanlış şema kontrolü: URL değişip sayfa dolu olsa bile
        # 404 ya da anasayfaya düşmüş olabilir.
        # Hepsiburada ölçümü: /arama?q=kalem 404 (21 kategori linki var),
        # /?s=kalem ise anasayfaya düşüyor (124 ürün linki var!) — iki durumda
        # da "URL değişti + sayfa dolu" kontrolü yanlış pozitif veriyordu.
        # Gerçek ölçüt: hata sayfası DEĞİL ve arama terimi sayfada görünüyor.
        next if hata_sayfasi?
        next unless arama_terimi_sayfada?(text)
        return aday
      rescue StandardError
        next
      end
    end
    nil
  end

  # Arama sonucu sayfası mı? URL'de arama işareti VEYA sayfada sonuç listesi.
  # Amaç: Enter'ın otomatik tamamlama önerisine gidip /urun/... açmasını
  # "başarı" saymamak (n11 ölçümü: 3/3 aynı hata).
  def arama_sonucu_sayfasi?(text)
    url = driver.current_url.to_s
    # Ürün detay sayfası asla arama sonucu değildir.
    return false if url =~ %r{/(urun|product|dp|p)/}i

    # URL arama işareti taşıyorsa kabul.
    if url =~ /[?&](q|s|query|search|arama)=|(\/arama\/|\/ara\/|\/sr\/|\/search)/i
      return true
    end

    # URL'de işaret yok: terim sayfada görünüyor + liste öğesi varsa kabul.
    arama_terimi_sayfada?(text)
  rescue StandardError
    false
  end

  # Arama terimi sayfada gerçekten görünüyor mu? URL'de olması yetmez:
  # site anasayfaya yönlendirip URL'de terimi bırakabiliyor.
  def arama_terimi_sayfada?(text)
    parcalar = text.to_s.strip.split(/\s+/).reject { |p| p.length < 3 }
    return true if parcalar.empty?

    govde = driver.execute_script(
      "return (document.body ? document.body.innerText : '').slice(0, 3000)"
    ).to_s
    return false if govde.empty?

    normalize = ->(s) { s.to_s.downcase.tr("İI", "ii") }
    govde_n = normalize.call(govde)
    parcalar.any? { |p| govde_n.include?(normalize.call(p)) }
  rescue StandardError
    false
  end

  # 404 / "sayfa bulunamadı" / hata sayfası mı? Başlık + kısa gövde metnine bakar.
  def hata_sayfasi?
    baslik = driver.title.to_s
    return true if baslik =~ /404|bulunamadı|bulunamadi|not found|hata|error/i

    govde = driver.execute_script(
      "return (document.body ? document.body.innerText : '').slice(0, 400)"
    ).to_s
    govde =~ /sayfamız\s*yok|sayfa bulunamadı|sayfa bulunamadi|böyle bir sayfa|404|not found/i ? true : false
  rescue StandardError
    false
  end

  # JS tetiklemeli gezinmeden sonra sayfanın oturmasını bekle (sabit sleep yok).
  def resume_after_js_action
    wait_ready
    begin
      wait_until(timeout: @wait_timeout) { !driver.current_url.to_s.empty? }
    rescue StandardError
      nil
    end
    true
  rescue StandardError
    nil
  end

  # Pencere boyutu: küçük modeller çıktıyı doğrularken kaydırmayı azaltmak
  # için sayfayı genişçe tutmak ister; tutarlı koşul için boyutu sabitleme.
  def resize(width, height)
    ensure_session
    driver.manage.window.resize_to(width.to_i, height.to_i)
    wait_ready
    "pencere boyutu: #{width}x#{height}\n#{snapshot_text}"
  rescue StandardError => e
    error("resize", e, "#{width}x#{height}")
  end
  # --- WebDriver BiDi: ağ + konsol olayları -------------------------------

  # Selenium Ruby gem'inin BiDi::Network#on sarmalayıcısı bozuk (events
  # dizisi doğrulaması hata veriyor); bu yüzden doğrudan
  # session.subscribe + add_callback kullanılır (Chrome 156 ile doğrulandı).
  MONITOR_EVENTS = %w[
    network.beforeRequestSent
    network.responseCompleted
    log.entryAdded
  ].freeze
  MONITOR_MAX = 200
  MONITOR_LINE_LIMIT = 20

  # Playwright MCP'nin network aracının ~karşılığı: monitörü başlat,
  # aksiyonların arasında istek/yanıt/konsol kayıtlarını kontrol et.
  def monitor(action: "check", filter: nil, timeout: 10)
    ensure_session
    case action.to_s
    when "start"
      @monitor_buffer = []
      @monitor_mutex = Mutex.new unless @monitor_mutex
      start_bidi_listener
      "ağ monitörü başladı: istekler, yanıtlar ve konsol kaydediliyor.\n" \
        "Kontrol: browser_monitor(action: \"check\"), filtre için filter: \"...\"."
    when "check"
      recs = monitor_records(filter)
      monitor_lines(recs)
    when "wait"
      raise "önce monitör başlatılmalı (action: \"start\")" unless @monitor_mutex
      recs = nil
      hedef = filter.to_s.empty? ? "herhangi bir kayıt" : "'#{filter}'"
      wait_until(timeout: timeout.to_f, message: "#{hedef} eşleşen kayıt #{timeout.to_f}s içinde gelmedi") do
        recs = monitor_records(filter)
        !recs.empty?
      end
      monitor_lines([recs.last])
    when "stop"
      adet = @monitor_mutex ? monitor_records(nil).size : 0
      begin
        @bidi&.session&.unsubscribe(MONITOR_EVENTS)
      rescue StandardError
        nil
      end
      "ağ monitörü durduruldu (son tampon: #{adet} kayıt)."
    else
      raise "geçersiz action: #{action.inspect} (start|check|wait|stop)"
    end
  rescue StandardError => e
    error("monitor", e, "#{action} #{filter}")
  end

  # BiDi bağlantısı tembel kurulur; callback'ler bu bağlantı için bir kez eklenir.
  def start_bidi_listener
    @bidi = driver.bidi
    unless @monitor_cbs
      MONITOR_EVENTS.each do |event|
        @bidi.add_callback(event) do |ev|
          rec = summarize_event(event, ev)
          next unless rec

          @monitor_mutex.synchronize do
            next unless @monitor_buffer

            @monitor_buffer << rec
            @monitor_buffer.shift while @monitor_buffer.size > MONITOR_MAX
          end
        end
      end
      @monitor_cbs = MONITOR_EVENTS.dup
    end
    # Not: gem Session#subscribe(events[, contexts]) tek dizi ister; splat değil.
    @bidi.session.subscribe(MONITOR_EVENTS)
  rescue StandardError => e
    raise "BiDi kullanılamıyor (web_socket_url gerekli): #{e.message}"
  end

  # Callback başka BiDi iş parçacığında çağrılır; kayıt Mutex altında yazılır.
  def summarize_event(event, ev)
    case event
    when "network.beforeRequestSent"
      req = ev["request"] || {}
      { type: "istek", method: req["method"], url: req["url"].to_s }
    when "network.responseCompleted"
      req = ev["request"] || {}
      res = ev["response"] || {}
      { type: "yanıt", method: req["method"], url: req["url"].to_s, status: res["status"] }
    when "log.entryAdded"
      { type: "konsol", level: ev["level"], text: ev["text"].to_s }
    end
  end

  def monitor_records(filter)
    return [] unless @monitor_mutex && @monitor_buffer

    f = filter.to_s.downcase
    @monitor_mutex.synchronize do
      @monitor_buffer.select do |r|
        f.empty? || "#{r[:type]} #{r[:method]} #{r[:url]} #{r[:level]} #{r[:text]}".downcase.include?(f)
      end
    end
  end

  def monitor_lines(recs)
    return "eşleşen kayıt yok. Monitör başlatıldı mı? (action: \"start\")" if recs.empty?

    toplam = recs.size
    recs.last(MONITOR_LINE_LIMIT).map do |r|
      case r[:type]
      when "yanıt"   then "yanıt #{r[:status]} #{r[:method]} #{short_url(r[:url])}"
      when "konsol"  then "konsol #{r[:level]}: #{r[:text].to_s[0, 80]}"
      else                "istek #{r[:method]} #{short_url(r[:url])}"
      end
    end.join("\n") + (toplam > MONITOR_LINE_LIMIT ? "\n(#{toplam} kayıt; son #{MONITOR_LINE_LIMIT} gösteriliyor)" : "")
  end

  def short_url(url)
    s = url.to_s.sub(%r{^[a-z]+://}, "")
    s = s[0, 70] + "…" if s.length > 70
    s
  end

  def wait_for(text: nil, timeout: 10, type: "text", selector: nil, value: nil)
    ensure_session
    t = timeout.to_f
    kind = (type || "text").to_s
    needle = (value || text).to_s

    case kind
    when "selector"
      raise "selector gerekli (type=selector)" if selector.to_s.empty?
      wait_until(timeout: t, message: "seçici görünmedi: #{selector}") do
        driver.find_element(:css, selector.to_s).displayed?
      end
      "seçici göründü: #{selector} (#{driver.current_url})"
    when "url"
      raise "value veya text gerekli (type=url)" if needle.empty?
      wait_until(timeout: t, message: "URL içinde '#{needle}' görünmedi") do
        driver.current_url.include?(needle)
      end
      "'#{needle}' URL'de göründü (#{driver.current_url})"
    when "gone"
      raise "selector gerekli (type=gone)" if selector.to_s.empty?
      wait_until(timeout: t, message: "öğe kaybolmadı: #{selector}") do
        driver.find_elements(:css, selector.to_s).none?(&:displayed?)
      end
      "öğe kayboldu: #{selector}"
    when "count"
      raise "selector ve value gerekli (type=count)" if selector.to_s.empty? || needle.empty?
      wait_until(timeout: t, message: "#{selector} sayısı #{needle} olmadı") do
        driver.find_elements(:css, selector.to_s).count(&:displayed?) >= needle.to_i
      end
      "#{selector} sayısı #{needle}+ oldu"
    when "load"
      # "Tam yüklendi" koşulu: document.readyState == complete. Sabit bekleme
      # yerine koşul; skeleton ufkuna odaklı sayfalarda "gone" ile birlikte kullanılır.
      wait_until(timeout: t, message: "sayfa tam yüklenmedi (document.readyState)") do
        driver.execute_script("return document.readyState") == "complete"
      end
      "sayfa tam yüklendi: #{driver.current_url}"
    when "download"
      wait_download(needle, timeout: t)
    else
      if needle.empty?
        wait_ready(t)
        "sayfa hazır (#{driver.current_url})"
      else
        wait_until(timeout: t, message: "'#{needle}' görünmedi") do
          driver.execute_script(<<~JS, needle)
            var n = (arguments[0] || '').toLowerCase();
            var body = document.body;
            var metin = ((body && body.innerText) || '') + ' ' + (document.title || '') + ' ' + location.href;
            return metin.toLowerCase().indexOf(n) >= 0;
          JS
        end
        "'#{needle}' göründü (#{driver.current_url})"
      end
    end
  rescue Selenium::WebDriver::Error::TimeoutError => e
    "bekleme zaman aşımı: #{e.message}"
  rescue StandardError => e
    "bekleme hatası: #{e.message}"
  end

  def evaluate(script)
    ensure_session
    result = driver.execute_script(script.to_s)
    truncate(result.is_a?(String) ? result : result.inspect, 1500)
  rescue StandardError => e
    error("evaluate", e)
  end

  def screenshot(dir = nil)
    ensure_session
    dir ||= ENV["BROWSER_MCP_SCREENSHOT_DIR"] || File.expand_path("screenshots", __dir__)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "screenshot-#{Time.now.strftime('%Y%m%d-%H%M%S')}.png")
    driver.save_screenshot(path)
    "ekran görüntüsü: #{path}"
  rescue StandardError => e
    error("screenshot", e)
  end

  def history(direction)
    ensure_session
    %w[back forward].include?(direction.to_s) ? driver.navigate.public_send(direction) : driver.navigate.refresh
    wait_ready
    "geçmiş: #{direction}\n#{snapshot_text}"
  rescue StandardError => e
    error("history", e, direction)
  end

  def scroll(direction: "down", amount: 600)
    ensure_session
    @last_scroll_metrics = dom_metrics
    before_h = @last_scroll_metrics[0]

    case direction.to_s
    when "top"    then driver.execute_script("window.scrollTo(0, 0)")
    when "bottom" then driver.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    when "up"     then driver.execute_script("window.scrollBy(0, -#{amount.to_i})")
    else               driver.execute_script("window.scrollBy(0, #{amount.to_i})")
    end

    # Sabit sleep yerine: kaydırma konumu durana kadar bekle.
    wait_for_scroll_settle
    pos = scroll_position
    new_h = pos ? pos["h"].to_i : before_h

    hint = ""
    if %w[down bottom].include?(direction.to_s)
      # Lazy-load: yükseklik/DOM düğümü/metin artışını sabit bir süre bekle.
      grew = wait_for_dom_growth(@last_scroll_metrics || [before_h, 0, 0], timeout: 2.5)
      if grew
        new_h = scroll_position&.dig("h").to_i
        hint = "\nnot: yeni içerik yüklendi. Devam etmeden önce browser_snapshot/browser_read ile kontrol et."
      end
    end

    if pos && pos["atBottom"] && direction.to_s != "top" && hint.empty?
      hint = "\nnot: sayfa sonundasın (#{pos['y']}/#{pos['h']}px). Yeni içerik gelmiyorsa browser_snapshot yeterli."
    end

    "kaydırıldı: #{direction} (#{pos && pos['y']}/#{new_h}px)#{hint}\n#{snapshot_text}"
  rescue StandardError => e
    error("scroll", e, direction)
  end

  def tabs(action: "list", index: nil, url: nil)
    ensure_session
    case action.to_s
    when "switch"
      handles = driver.window_handles
      original = driver.window_handle

      # URL parçasına göre seç (replay için indeksten daha dayanıklı)
      if url && !url.to_s.empty?
        match = nil
        begin
          wait_until(timeout: 3, message: "sekme bulunamadı (#{url})") do
            handles = driver.window_handles
            match = nil
            handles.each do |handle|
              driver.switch_to.window(handle)
              if driver.current_url.include?(url.to_s)
                match = handle
                break
              end
            end
            !match.nil?
          end
        rescue Selenium::WebDriver::Error::TimeoutError
          driver.switch_to.window(original) rescue nil
          return "sekme bulunamadı (#{url})"
        end

        driver.switch_to.window(match)
        driver.switch_to.default_content rescue nil
        wait_ready
        return "aktif sekme: #{handles.index(match)} (#{truncate(driver.current_url, 80)})\n#{snapshot_text}"
      end

      implicit = index.nil? && handles.size > 1
      index = handles.size - 1 if implicit
      target = handles[index.to_i]
      note = implicit ? "not: index verilmedi, son sekme seçildi (#{index}).\n" : ""
      # Küçük modeller sekmeleri 1 tabanlı sanabilir: 2 sekme varken index=2.
      if target.nil? && index.to_i.positive? && handles[index.to_i - 1]
        target = handles[index.to_i - 1]
        note = "not: index 1 tabanlı yorumlandı (#{index} -> #{index.to_i - 1}); indeksler 0'dan başlar.\n"
      end
      return "sekme yok (index #{index}). İndeksler 0'dan başlar; #{handles.size} sekme var (0..#{handles.size - 1})." unless target

      driver.switch_to.window(target)
      driver.switch_to.default_content rescue nil
      wait_ready
      "#{note}aktif sekme: #{handles.index(target)}\n#{snapshot_text}"
    when "close"
      handles = driver.window_handles
      target = index.nil? ? driver.window_handle : handles[index.to_i]
      if target.nil?
        return "kapatılacak sekme yok (index #{index}; 0..#{handles.size - 1}). " \
               "İndeksler 0'dan başlar; browser_tabs(action: \"list\") ile doğrula."
      end
      closing_current = begin
        target == driver.window_handle
      rescue Selenium::WebDriver::Error::NoSuchWindowError
        false
      end
      closed_url =
        if closing_current
          truncate(driver.current_url, 60)
        else
          driver.switch_to.window(target)
          truncate(driver.current_url, 60)
        end
      driver.close
      remaining = driver.window_handles
      if remaining.empty?
        "son sekme kapatıldı (#{closed_url})"
      else
        # Aktif sekme kapatıldıysa kalan ilk sekmeye geç; öğeler dökülsün.
        driver.switch_to.window(remaining.first) if closing_current
        wait_ready
        live = begin
          driver.window_handle
        rescue Selenium::WebDriver::Error::NoSuchWindowError
          nil
        end
        aktif = live ? remaining.index(live).to_i : 0
        "sekme kapatıldı (#{closed_url}); #{remaining.size} sekme kaldı, aktif: #{aktif}\n#{snapshot_text}"
      end
    when "close_others"
      current = driver.window_handle
      extras = driver.window_handles.reject { |h| h == current }
      extras.each do |handle|
        driver.switch_to.window(handle)
        driver.close
      end
      driver.switch_to.window(current)
      "diğer sekmeler kapatıldı (#{extras.size}); aktif sekme korundu"
    else
      original = driver.window_handle
      lines = driver.window_handles.each_with_index.map do |handle, i|
        current = handle == original ? "*" : " "
        driver.switch_to.window(handle)
        "#{current}#{i} #{driver.title} | #{driver.current_url}"
      end
      driver.switch_to.window(original)
      lines.join("\n")
    end
  rescue StandardError => e
    error("tabs", e)
  end

  def status
    if @driver && alive?
      "bağlı | #{driver.title} | #{driver.current_url} | port #{@port} | bekleme #{@wait_timeout}s"
    elsif port_open?(@port)
      "port açık (henüz bağlanmadı) | port #{@port}"
    else
      "tarayıcı yok | port #{@port}"
    end
  end

  # --- yardımcılar --------------------------------------------------------

  # Anlık toast bildirimleri (başarı/hata/uyarı): sayfa eyleminden sonra
  # birkaç saniye içinde DOM'dan silinir, modelin sonraki snapshot'ı onu
  # göremeyebilir. Bu yüzden eylemden hemen sonra açık bir beklemeyle
  # toplanıp çıktıya eklenir ("toast hata: Ürün geçici olarak temin
  # edilemiyor"). Hepsiburada vb. siteler toast'lara role vermez
  # (hb-toast-notifier-*), o yüzden kaba sınıf taraması da yapılır.
  TOAST_JS = <<~JS
    var out = [];
    var nodes = document.querySelectorAll('[role=alert],[role=status],[class*="toast" i],[class*="notification" i],[class*="notifier" i]');
    for (var i = 0; i < nodes.length && out.length < 6; i++) {
      var el = nodes[i];
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      var st = window.getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden' || st.opacity === '0') continue;
      var t = (el.innerText || '').replace(/\\s+/g, ' ').trim();
      if (!t) continue;
      var c = (el.getAttribute('class') || '').toLowerCase();
      var tip = (c.indexOf('error') !== -1 || c.indexOf('danger') !== -1) ? 'hata'
                : (c.indexOf('success') !== -1) ? 'başarı'
                : (c.indexOf('warn') !== -1) ? 'uyarı'
                : (c.indexOf('info') !== -1) ? 'bilgi' : 'bildirim';
      out.push({ tip: tip, metin: t.slice(0, 110) });
    }
    return JSON.stringify(out);
  JS

  def harvest_toasts
    return "" unless @driver

    raw = ""
    begin
      wait_until(timeout: TOAST_WAIT, ignore: IGNORED_WAIT_ERRORS) do
        raw = driver.execute_script(TOAST_JS)
        (JSON.parse(raw) rescue []).any?
      end
    rescue Selenium::WebDriver::Error::TimeoutError, StandardError
      # Toast yok: en hızlı yol.
      return ""
    end

    recs = JSON.parse(raw) rescue []
    # Aynı metnin konteyner+kutu+geçiş düzenlerine tekrarını küçült.
    recs.uniq! { |r| r["metin"] }
    recs = recs.first(3)
    sig = recs.map { |r| r["metin"] }.join("||")
    return "" if sig == @last_toast_sig

    @last_toast_sig = sig
    "\n" + recs.map { |r| "toast #{r['tip']}: #{r['metin']}" }.join("\n")
  end

  def snapshot_text(header: true)
    if (open_alert = alert_text)
      return "UYARI: açık JS uyarı penceresi var (#{open_alert}). Kapatmak için browser_alert kullan."
    end

    # Uyarılı otomatik toparlama: ensure_session bir JS uyarısını kabul
    # ederek kurtardıysa metini modele bir kere yansıt.
    if @alert_recovered
      metin = @alert_recovered
      @alert_recovered = nil
      return "not: açık bir JS uyarı penceresi otomatik kabul edildi (metin: \"#{metin[0, 80]}\"). " \
             "İstenen davranış buysa sırayla devam edin.\n#{snapshot_text}"
    end

    data = driver.execute_script(File.read(File.expand_path("snapshot.js", __dir__), encoding: "UTF-8"), @max_elements)
    items = data["items"] || []
    body = items.map { |i| format_item(i) }.join("\n")
    more = data["total"].to_i > items.size ? "\n… #{data['total']} etkileşimli öğeden #{items.size} tanesi" : ""
    modal_note = data["modal"] ? "MODAL AÇIK (arka plan gizlendi)\n" : ""
    tabs_note =
      begin
        handles = driver.window_handles
        if handles.size > 1
          active = handles.index(driver.window_handle)
          "SEKMELER: #{handles.size} (aktif #{active}); geçmek için browser_tabs(action: \"switch\", index: <0..#{handles.size - 1}>)\n"
        else
          ""
        end
      rescue StandardError
        ""
      end

    text =
      if header
        "#{truncate(data['title'].to_s, 90)} | #{truncate(data['url'].to_s, 120)}\n#{tabs_note}#{modal_note}#{body}#{more}"
      else
        "#{modal_note}#{body}#{more}"
      end
    truncate(text, 4000)
  end

  def format_item(item)
    tag = item["tag"]
    tag += "[#{item['type']}]" if item["type"] && !item["type"].empty?
    href = item["href"] && !item["href"].empty? ? " -> #{truncate(item['href'], 60)}" : ""
    name = item["name"].to_s.empty? ? "" : " #{truncate(item['name'], 95)}"
    "#{item['ref']} #{tag}#{name}#{href}"
  end

  # Explicit wait: koşul sağlanana kadar bekle; sabit sleep yok.
  def wait_until(timeout: @wait_timeout, message: nil, ignore: IGNORED_WAIT_ERRORS)
    wait = Selenium::WebDriver::Wait.new(timeout: timeout.to_f, interval: POLL_INTERVAL, ignore: ignore)
    wait.until { yield }
  rescue Selenium::WebDriver::Error::TimeoutError => e
    # fail-fast dallarının açıklamasını koru (ör. "hiç bulunmadı"); yalnızca
    # gerçek zaman aşımı genel mesaja sarılsın.
    raise e if e.message[/hiç bulunmadı|bir ref değil/]

    raise Selenium::WebDriver::Error::TimeoutError, (message || "koşul #{timeout}s içinde sağlanmadı")
  end

  # wait: :presence | :visible | :clickable
  def resolve(ref, selector, text, wait: :visible)
    has_selector = !selector.to_s.empty?
    has_text = !text.to_s.empty?
    if has_text && !has_selector
      found = find(text, limit: 1)
      ref = found[/^f\d+/]
      raise "'#{text}' ile eşleşen öğe yok (browser_find kullan)" unless ref
    end

    if (ref.nil? || ref.to_s.empty?) && !has_selector
      raise "ref, selector veya text gerekli"
    end

    # selector + text birlikte verilirse: aynı seçiciden dönen öğeler içinde
    # görünen metne göre daralt (liste/menü seçenekleri, tekrarlayan düğmeler).
    filter_text = has_selector && has_text ? text.to_s : nil
    element = nil
    start = nil
    begin
      wait_until(
        message: "öğe bulunamadı veya #{wait} durumuna gelmedi (#{ref || selector}#{filter_text ? " / metin: #{filter_text}" : ""}). " \
                 "Ref'ler her snapshot'ta yenilenir; önce browser_snapshot/browser_find çağır."
      ) do
        element = begin
          find_element_once(ref, selector, filter_text)
        rescue Selenium::WebDriver::Error::NoSuchElementError
          nil
        end
        if element
          start = nil
          case wait
          when :presence then true
          when :clickable then element.displayed? && element.enabled?
          else element.displayed?
          end
        else
          # Yenilik: seçici DOM'da BÜTÜNÜYLE yoksa 10 sn'yi yanma. SPA'larda
          # öğe sonradan gelebilir; bu yüzden yalnızca (1) sayfa yüklü
          # (readyState complete) ve (2) FINDFAIL süresi geçtiyse kes.
          start ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          hunts = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          if hunts >= FAILFAST_PRESENCE &&
             driver.execute_script("return document.readyState") == "complete"
            raise Selenium::WebDriver::Error::TimeoutError,
                  "seçici DOM'da hiç bulunmadı (#{hunts.round(1)} sn'de, sayfa yüklü): #{ref || selector} — " \
                  "seçiciyi doğrula (browser_snapshot / browser_find) veya BROWSER_MCP_FAILFAST'i büyüt"
          end
          false
        end
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      # Gemma koşusundan: ref alanına etiket metni yazılmıştı (ref="Sepete Ekle").
      # Küçük modelleri doğru parametreye yönlendir.
      if ref && text.to_s.empty? && selector.to_s.empty? && ref.to_s !~ /\A[ef]\d+\z/
        raise Selenium::WebDriver::Error::TimeoutError,
              "'#{ref.to_s.slice(0, 40)}' bir ref değil; etiket metnine benziyor. " \
              "Metne göre seçmek için text: parametresini kullan (ör. browser_click(text: \"#{ref.to_s.slice(0, 20)}\")) " \
              "veya browser_snapshot ile güncel ref'i al."
      end

      raise
    end
    element
  end

  def element_metni(el)
    [el.text, el.attribute("aria-label"), el.attribute("title"), el.attribute("value")]
      .compact.join(" ").strip
  rescue StandardError
    ""
  end

  def find_element_once(ref, selector, filter_text = nil)
    if selector && !selector.to_s.empty?
      sel = selector.to_s
      if sel.start_with?("shadow::")
        host_path, inner = sel.sub("shadow::", "").split("||", 2)
        element = driver.execute_script(SHADOW_QUERY_JS, host_path, inner)
        raise Selenium::WebDriver::Error::NoSuchElementError, sel if element.nil?
        return element
      end
      # Aynı seçici birden çok öğe döndürebilir (menü + gizli kopya). İlk
      # eşleşme gizliyse tıklama hiç yapılamıyordu; GÖRÜNÜR olanı tercih et.
      elements = driver.find_elements(:css, sel)
      raise Selenium::WebDriver::Error::NoSuchElementError, sel if elements.empty?

      gorunen = elements.select do |el|
        begin
          el.displayed?
        rescue StandardError
          false
        end
      end
      adaylar = gorunen.empty? ? elements : gorunen
      unless filter_text.to_s.empty?
        needle = filter_text.to_s.downcase
        adaylar = adaylar.select { |el| element_metni(el).downcase.include?(needle) }
        if adaylar.empty?
          raise Selenium::WebDriver::Error::NoSuchElementError, "#{sel} (metin: #{filter_text})"
        end
      end
      return adaylar.first
    end

    element = driver.execute_script(FIND_BY_REF_JS, ref.to_s)
    raise Selenium::WebDriver::Error::NoSuchElementError, ref.to_s if element.nil?

    element
  end

  # Tıklama engellendiyse bekleme-döngüsüne girmeden hemen JS tıklaması:
  # intercepted istisnasının kendisi hızlıdır (~35 ms); eski 3 denemeli akış
  # her kavşakta ~2-3 sn'lik 1 sn'lik explicit beklemeler yiyordu. Örtü
  # geçiciyse de JS click doğru öğeyi vurur (gerçek click olayı yayınlanır);
  # kalıcı örtü (link örtüsü, bant) beklemeyle zaten çözülmez.
  # Elemetna Sepete ekleme (spinnerIcon/addToCart) ikonu mu? Name labelini
  # snapshot'ta "Sepete ekle ikonu" olarak verdiğimiz sınıflardan tanır.
  def sepet_ikonu_mu?(element)
    /^svg$/i.match?(element.tag_name.to_s) &&
      /spinnerIcon|addToCart/i.match?(element.attribute("class").to_s)
  rescue StandardError
    false
  end

  # SVG dekoru değil KONUŞAN atayı tıkla: HBI'da handler
  # div.price-module_priceAreaRoot[role=button]'da; bare svg tıklaması
  # bazen bubble'ı ıskalıyor ve toast'suz kalıyor (sessik ikon vakası).
  def tıklanabilir_atasi(element)
    driver.execute_script("var el = arguments[0]; return el.closest('button,[role=button]');", element)
  rescue StandardError
    nil
  end

  # Tıklama engellendiyse bekleme-döngüsüne girmeden hemen JS tıklaması
  # (intercepted istisnası ~35 ms; eski 3 denemeli akış 2-3 sn yiyordu).
  # DİKKAT: SVGElement'te click() YOK (yalnızca HTMLElement) — svg hedeflerde
  # arguments[0].click() sessiz no-op olur; gerçek MouseEvent yayınlamak
  # (bubbles: true) hem svg hem HTML'de doğru handler'ı tetikler (Gemma HBI
  # koşumunda sessiz kalan "Sepete ekle ikonu" svg'sinin nedeni buydu).
  def click_element(element)
    # Sepete ekleme ikonu svg ise tıklanabilir atayı (button/[role=button]) hedefle;
    # svg dekorudur — asıl handler ata DIV'de.
    hedef = sepet_ikonu_mu?(element) ? (tıklanabilir_atasi(element) || element) : element
    driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'})", hedef) rescue nil
    hedef.click
    nil
  rescue Selenium::WebDriver::Error::ElementClickInterceptedError,
         Selenium::WebDriver::Error::ElementNotInteractableError
    driver.execute_script("var el = arguments[0]; var ev = new MouseEvent('click', {bubbles: true, cancelable: true, composed: true}); el.dispatchEvent(ev);", hedef)
    "not: öğe bir katmanla kapalıydı; JS tıklaması (MouseEvent) kullanıldı."
  end

  # "shadow::host||inner" seçicisini çözer
  SHADOW_QUERY_JS = <<~JS
    var host = document.querySelector(arguments[0]);
    if (!host || !host.shadowRoot) return null;
    return host.shadowRoot.querySelector(arguments[1]);
  JS

  # Shadow DOM içindeki ref'leri de bulur
  FIND_BY_REF_JS = <<~JS
    function find(root, ref) {
      var el = root.querySelector('[data-sl-ref="' + ref + '"]');
      if (el) return el;
      var hosts = root.querySelectorAll('*');
      for (var i = 0; i < hosts.length; i++) {
        if (hosts[i].shadowRoot) {
          var r = find(hosts[i].shadowRoot, ref);
          if (r) return r;
        }
      }
      return null;
    }
    return find(document, arguments[0]);
  JS

  # Kontrollü (React/Vue) input/textarea için değeri native setter ile yaz ve
  # framework'lerin dinlediği input/change olaylarını yayınla.
  def js_set_value(element, value)
    driver.execute_script(<<~JS, element, value.to_s)
      var el = arguments[0], val = arguments[1];
      var proto = (el.tagName || '').toLowerCase() === 'textarea'
        ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, val);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    JS
    true
  rescue StandardError
    false
  end

  def wait_ready(timeout = READY_TIMEOUT)    # Geçiş anındaki bağlam hatalarını yut ve koşulu tekrar dene; sabit bekleme yok.
    wait_until(timeout: timeout, ignore: [Selenium::WebDriver::Error::WebDriverError]) do
      driver.execute_script("return document.readyState") == "complete"
    end
    true
  rescue Selenium::WebDriver::Error::TimeoutError
    false
  rescue Selenium::WebDriver::Error::WebDriverError
    # Geçiş anında bağlam/sekme okunamayabilir; çağıran akış devam eder.
    false
  end

  # Etkileşimli öğe sayısı kısa süre değişmiyorsa DOM "oturdu" sayılır.
  # Tıklama/yazma sonrası: URL değiştiyse (navigasyon) veya sayfa hazırsa devam et.
  # Navigasyon yoksa explicit wait kısa sürede biter; sabit sleep kullanılmaz.
  def wait_after_action(previous_url: nil, timeout: 3)
    if previous_url
      begin
        wait_until(timeout: [timeout.to_f, 0.6].min, ignore: []) { driver.current_url != previous_url }
      rescue Selenium::WebDriver::Error::TimeoutError
        # URL değişmedi: navigasyon yok veya SPA; hazır durumu kontrol edip dön.
        wait_until(timeout: 0.5, ignore: []) do
          driver.execute_script("return document.readyState") == "complete"
        end
        return
      end
    end
    wait_ready
  end

  def wait_for_new_tab(before_count, timeout: 2)
    wait_until(timeout: timeout, ignore: []) { driver.window_handles.size > before_count }
    true
  rescue Selenium::WebDriver::Error::TimeoutError
    false
  end

  def wait_for_scroll_settle(timeout: 2)
    last = nil
    stable = 0
    wait_until(timeout: timeout, ignore: []) do
      y = driver.execute_script("return Math.round(window.scrollY)")
      if y == last
        stable += 1
      else
        last = y
        stable = 0
      end
      stable >= 2
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    nil
  end

  def scroll_position
    driver.execute_script(<<~JS)
      var b = document.body || document.documentElement;
      return {
        y: Math.round(window.scrollY),
        h: Math.round(b.scrollHeight),
        vh: window.innerHeight,
        atBottom: window.scrollY + window.innerHeight >= b.scrollHeight - 4
      };
    JS
  rescue StandardError
    nil
  end

  # [scrollHeight, DOM düğüm sayısı, body metin uzunluğu]
  def dom_metrics
    driver.execute_script(<<~JS)
      var b = document.body;
      return [b ? b.scrollHeight : 0, document.querySelectorAll('*').length, b ? b.innerText.length : 0];
    JS
  rescue StandardError
    [0, 0, 0]
  end

  # Lazy-load: yükseklik VEYA düğüm/metin artışını bekle. Sabit sleep yok.
  def wait_for_dom_growth(before, timeout: 2.5)
    started = Time.now
    last = before
    grew = false
    stable = 0
    wait_until(timeout: timeout, ignore: []) do
      m = dom_metrics
      grew = true if m[0] > before[0].to_i || m[1] > before[1].to_i || m[2] > before[2].to_i
      if m == last
        stable += 1
      else
        last = m
        stable = 0
      end
      stable >= 3 && (grew || (Time.now - started) > 1.0)
    end
    grew
  rescue Selenium::WebDriver::Error::TimeoutError
    grew
  end

  # Lazy-load sayfada bir adım: sona kaydır, içerik geldiyse true.
  def scroll_lazy_step
    before = dom_metrics
    at_bottom = driver.execute_script(<<~JS)
      var b = document.body || document.documentElement;
      return window.scrollY + window.innerHeight >= b.scrollHeight - 4;
    JS
    driver.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    grew = wait_for_dom_growth(before, timeout: 2.2)
    wait_ready
    grew || !at_bottom
  rescue StandardError
    false
  end

  # Metin taraması (shadow DOM dahil); ref'leri f1, f2... olarak işaretler.
  #
  # Selenium "Effective Locators" ilkesi: tam eşleşme, yerine geçen (partial)
  # eşleşmeden öncedir. 'En Düşük Fiyat' araması partial match ile ürün
  # etiketini ('Son 10 Günün En Düşük Fiyatı') yakalayıp yanlış sayfa açmıştı;
  # artık önce tam eşleşmeler toplanır, hiç yoksa partial denir.
  # Ayrıca özel açılır menü seçenekleri (tıklanabilir div/li) taranır —
  # role taşmayan .select-option gibi öğeler aksi halde bulunamaz.
  def scan_text(text, limit)
    driver.execute_script(<<~JS, text.to_s, limit.to_i)
      var t = (arguments[0] || '').toLowerCase().trim();
      var max = arguments[1] || 5;
      function clear(root) {
        root.querySelectorAll('[data-sl-ref]').forEach(function (el) { el.removeAttribute('data-sl-ref'); });
        root.querySelectorAll('[data-sl-name]').forEach(function (el) { el.removeAttribute('data-sl-name'); el.removeAttribute('data-sl-href'); });
        root.querySelectorAll('*').forEach(function (el) { if (el.shadowRoot) clear(el.shadowRoot); });
      }
      clear(document);

      var q = 'a[href],button,input,textarea,select,summary,' +
              '[role=button],[role=link],[role=textbox],[role=option],[role=menuitem],' +
              '[aria-haspopup],[aria-expanded],[role=combobox],[role=menu],' +
              '[class*="select-option" i],[class*="select__option" i],' +
              'div[class*="option" i],li[class*="option" i],' +
              'div[class*="menu-item" i],li[class*="menu-item" i],[onclick]';
      var exact = [];
      var partial = [];
      var goruldu = [];

      function topla(el) {
        for (var v = 0; v < goruldu.length; v++) { if (goruldu[v] === el) return; }
        goruldu.push(el);
      }
      function ekle(list, el) {
        el.scrollIntoView({ block: 'center', inline: 'center' });
        var ref = 'f' + (list.length + 1);
        el.setAttribute('data-sl-ref', ref);
        list.push({ ref: ref, tag: el.tagName.toLowerCase(), name: el.getAttribute('data-sl-name').slice(0, 80),
                    href: el.getAttribute('data-sl-href') || '' });
      }
      function walk(root) {
        var els = root.querySelectorAll(q);
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          var name = (el.innerText || el.value || el.getAttribute('aria-label') ||
                      el.getAttribute('placeholder') || el.getAttribute('title') || '')
                     .replace(/\\s+/g, ' ').trim();
          if (!name || name.toLowerCase().indexOf(t) === -1) continue;
          topla(el);
          el.setAttribute('data-sl-name', name);
          el.setAttribute('data-sl-href', el.getAttribute('href') || '');
          if (name.toLowerCase() === t) exact.push(el);
          else partial.push(el);
        }
        root.querySelectorAll('*').forEach(function (host) {
          if (host.shadowRoot) walk(host.shadowRoot);
        });
      }
      walk(document);

      var secilen = exact.length ? exact : partial;
      var out = [];
      for (var k = 0; k < secilen.length && out.length < max; k++) {
        ekle(out, secilen[k]);
      }
      return out;
    JS
  end

  def download_dir
    @download_dir ||= ENV["BROWSER_MCP_DOWNLOAD_DIR"] ||
                     File.expand_path("artifacts/downloads-#{@port}", __dir__)
  end

  # Zhan'ın güvenli yöntemi: chrome://downloads sayfasındaki downloads-manager
  # shadow root'undan durumu oku; IN_PROGRESS bitene kadar explicit bekle.
  def wait_download(pattern, timeout: 30)
    pattern = pattern.to_s
    started = Time.now
    original = driver.window_handle
    items = nil
    switched = false

    begin
      driver.switch_to.new_window(:tab)
      switched = true
      driver.navigate.to("chrome://downloads")
      wait_until(timeout: 5, message: "chrome://downloads açılmadı") do
        driver.execute_script("return !!(document.querySelector('downloads-manager') && document.querySelector('downloads-manager').shadowRoot)")
      end

      wait_until(timeout: timeout, message: "indirme tamamlanmadı: #{pattern}") do
        items = driver.execute_script(<<~JS)
          var m = document.querySelector('downloads-manager');
          if (!m || !m.shadowRoot) return [];
          var list = m.shadowRoot.getElementById('downloadsList');
          if (!list) return [];
          return (list.items || []).map(function (i) {
            return { fileName: i.fileName, state: i.state, filePath: i.filePath };
          });
        JS
        matching_download_item(items, pattern)
      end

      item = matching_download_item(items, pattern)
      if item.nil?
        # Yarış: durum tamamlandı ama liste henüz güncellenmedi; dosyayı bekle.
        fallback = wait_download_file(pattern, since: started, timeout: [timeout.to_f, 3].min)
        return fallback if fallback

        return "indirme tamamlandı ancak dosya bulunamadı: #{pattern}"
      end

      path = download_item_path(item)
      "indirme tamamlandı: #{item['fileName']} (#{path})"
    rescue Selenium::WebDriver::Error::TimeoutError => e
      fallback = wait_download_file(pattern, since: started, timeout: [timeout.to_f, 3].min)
      return fallback if fallback

      "indirme zaman aşımı: #{e.message}"
    rescue StandardError
      fallback = wait_download_file(pattern, since: started, timeout: [timeout.to_f, 3].min)
      return fallback if fallback

      "indirme durumu okunamadı; dosya sistemini kontrol et: #{download_dir}"
    ensure
      if switched
        begin
          driver.close
        rescue StandardError
          nil
        end
        begin
          driver.switch_to.window(original)
        rescue StandardError
          nil
        end
      end
    end
  end

  def download_item_path(item)
    path = item["filePath"].to_s
    path = File.join(download_dir, item["fileName"].to_s) if path.empty?
    path
  end

  def download_state_active?(state)
    state.nil? || [0, "0", "IN_PROGRESS"].include?(state)
  end

  def download_state_complete?(state)
    [2, "2", "COMPLETE"].include?(state)
  end

  # Eski indirme geçmişindeki tamamlanmış ama silinmiş dosyayı başarı sayma:
  # aktif indirme varsa bekle; yoksa ancak dosyası gerçekten var olanı döndür.
  def matching_download_item(items, pattern)
    matching = Array(items).select do |i|
      pattern.empty? || i["fileName"].to_s.include?(pattern)
    end
    return nil if matching.any? { |i| download_state_active?(i["state"]) }

    matching.find do |i|
      download_state_complete?(i["state"]) && File.exist?(download_item_path(i))
    end
  end

  # chrome://downloads okunamazsa (ör. bağlı kullanıcı profili): yeni dosyayı bekle.
  def wait_download_file(pattern, since:, timeout: 5)
    dirs = [download_dir, File.expand_path("~/Downloads")].uniq
    found = nil
    wait_until(timeout: timeout, ignore: []) do
      found = dirs.flat_map { |d| Dir.glob(File.join(d, "*")) }.find do |f|
        next false if f.end_with?(".crdownload", ".tmp")

        File.file?(f) && File.basename(f).include?(pattern.to_s) &&
          File.mtime(f) >= (since - 1) && File.size(f).positive?
      end
      !found.nil?
    end
    "indirme tamamlandı (dosya): #{found}"
  rescue Selenium::WebDriver::Error::TimeoutError
    nil
  end

  def alert_text
    driver.switch_to.alert.text
  rescue StandardError
    nil
  end

  # Açık uyarıyı sessizce kapatır (yeni sayfaya geçmeden önce)
  def dismiss_open_alert
    a = driver.switch_to.alert
    text = a.text
    a.accept
    text
  rescue StandardError
    nil
  end

  def normalize_url(url)
    u = url.to_s.strip
    u = "https://#{u}" unless u.match?(%r{\A[a-z]+://}i) || u.start_with?("about:", "data:")
    u
  end

  def key_for(key)
    map = { "enter" => :enter, "tab" => :tab, "escape" => :escape, "esc" => :escape,
            "backspace" => :backspace, "arrowup" => :arrow_up, "arrowdown" => :arrow_down,
            "arrowleft" => :arrow_left, "arrowright" => :arrow_right }
    map[key.to_s.downcase] || key.to_s
  end

  def truncate(text, limit)
    s = text.to_s
    s.length > limit ? "#{s[0, limit]}…" : s
  end

  def error(operation, exception, target = nil)
    hint =
      case exception
      when Selenium::WebDriver::Error::TimeoutError
        "süre aşıldı; sayfa yavaş yüklüyor veya seçici yanlış. browser_snapshot ile durumu kontrol et, " \
        "gerekiyorsa BROWSER_MCP_WAIT değerini artır."
      when Selenium::WebDriver::Error::StaleElementReferenceError
        "sayfa değişti; yeniden browser_snapshot çağır."
      when Selenium::WebDriver::Error::ElementClickInterceptedError
        "öğe başka bir katmanla kapalı (çerez/uyarı olabilir); browser_snapshot ile kapatıcıyı bul."
      when Selenium::WebDriver::Error::ElementNotInteractableError
        "öğe görünür değil; browser_scroll veya browser_find dene."
      when Selenium::WebDriver::Error::UnexpectedAlertOpenError
        "açık JS uyarısı var; önce browser_alert(accept) veya browser_alert(dismiss) çağır."
      when Selenium::WebDriver::Error::InvalidElementStateError, Selenium::WebDriver::Error::InvalidSelectorError
        "geçersiz CSS seçici; q/selector bir CSS seçicidir (örn: button, li, a[title='Aç']). " \
        "Metne göre arama için browser_find(text: ...) kullan."
      else
        "önce browser_snapshot çağırıp ref'i doğrula."
      end
    "HATA (#{operation}#{target ? " #{target}" : ''}): #{exception.message.lines.first.to_s.strip}\nİpucu: #{hint}"
  end
end
