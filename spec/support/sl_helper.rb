# Otomatik üretildi — selenit Browser MCP.
# Explicit wait + try_for + ortak Selenium yardımcıları.
require "selenium-webdriver"
require "rspec"

module TwHelper
  WAIT_TIMEOUT = (ENV["TW_WAIT"] || 10).to_f

  def attach_browser
    options = Selenium::WebDriver::Chrome::Options.new
    options.debugger_address = "127.0.0.1:#{ENV['BROWSER_MCP_PORT'] || '19418'}"
    options.unhandled_prompt_behavior = :ignore
    driver = Selenium::WebDriver.for(:chrome, options: options)
    driver.manage.timeouts.implicit_wait = 0
    driver
  end

  def wait_until(timeout: WAIT_TIMEOUT)
    Selenium::WebDriver::Wait.new(timeout: timeout, interval: 0.1).until { yield }
  end

  def wait_ready(timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) do
      @driver.execute_script("return document.readyState") == "complete"
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    nil
  end

  def open(url)
    # Test bağımsızlığı: önceki testten kalan frame/alert bağlamını temizle.
    @driver.switch_to.default_content rescue nil
    @driver.switch_to.alert.accept rescue nil
    @driver.navigate.to(url)
    wait_ready
  end

  # CSS ve shadow::host||inner seçicilerini explicit wait ile çözer.
  def find_deep(selector, visible: true)
    wait_until do
      el =
        if selector.start_with?("shadow::")
          host, inner = selector.sub("shadow::", "").split("||", 2)
          @driver.execute_script(
            "var h = document.querySelector(arguments[0]); " \
            "return h && h.shadowRoot && h.shadowRoot.querySelector(arguments[1]);",
            host, inner
          )
        else
          begin
            @driver.find_element(:css, selector)
          rescue Selenium::WebDriver::Error::NoSuchElementError
            nil
          end
        end
      visible ? (el if el && el.displayed?) : el
    end
  end

  def click(selector)
    el = find_deep(selector)
    attempts = 0
    begin
      attempts += 1
      el.click
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError,
           Selenium::WebDriver::Error::ElementNotInteractableError
      raise if attempts >= 3

      wait_until(timeout: 1) { el.displayed? } rescue nil
      retry
    end
  end

  def type_into(selector, text)
    el = find_deep(selector)
    el.clear rescue nil
    el.send_keys(text)
  end

  def select_option(selector, label)
    Selenium::WebDriver::Support::Select.new(find_deep(selector)).select_by(:text, label)
  end

  def attach_file(selector, path)
    find_deep(selector, visible: false).send_keys(File.expand_path(path))
  end

  def hover(selector)
    @driver.action.move_to(find_deep(selector)).perform
  end

  def press_key(key)
    @driver.action.send_keys(key).perform
  end

  def scroll_page(direction, amount = 600)
    case direction.to_s
    when "top" then @driver.execute_script("window.scrollTo(0, 0)")
    when "bottom" then @driver.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    when "up" then @driver.execute_script("window.scrollBy(0, -#{amount.to_i})")
    else @driver.execute_script("window.scrollBy(0, #{amount.to_i})")
    end
  end

  def go_back
    @driver.navigate.back
    wait_ready
  end

  def go_forward
    @driver.navigate.forward
    wait_ready
  end

  def reload_page
    @driver.navigate.refresh
    wait_ready
  end

  def main_frame
    @driver.switch_to.default_content
    wait_ready
  end

  def enter_frame(selector)
    @driver.switch_to.frame(find_deep(selector, visible: false))
    wait_ready
  end

  def enter_frame_by_index(index)
    @driver.switch_to.frame(@driver.find_elements(:tag_name, "iframe")[index.to_i])
    wait_ready
  end

  def switch_tab(url_part)
    wait_until do
      @driver.window_handles.any? do |handle|
        @driver.switch_to.window(handle)
        @driver.current_url.include?(url_part)
      end
    end
    wait_ready
  end

  def accept_js_alert
    wait_until { @driver.switch_to.alert }
    @driver.switch_to.alert.accept
  end

  def dismiss_js_alert
    wait_until { @driver.switch_to.alert }
    @driver.switch_to.alert.dismiss
  end

  def wait_for_selector(selector, timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) { find_deep(selector) }
  end

  def wait_for_url(part, timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) { @driver.current_url.include?(part) }
  end

  def wait_for_gone(selector, timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) do
      @driver.find_elements(:css, selector).none?(&:displayed?)
    end
  end

  def wait_for_count(selector, count, timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) do
      @driver.find_elements(:css, selector).count(&:displayed?) >= count.to_i
    end
  end

  def wait_until_text(text, timeout: WAIT_TIMEOUT)
    wait_until(timeout: timeout) do
      @driver.execute_script(
        "var b = document.body; return !!(b && b.innerText && b.innerText.indexOf(arguments[0]) >= 0);",
        text
      )
    end
  end

  # İndirme tamamlanmasını dosya sistemi üzerinden explicit bekle.
  # Chrome'un indirme klasörü BROWSER_MCP_DOWNLOAD_DIR ile verilebilir.
  def wait_for_download(pattern = "", timeout: 30)
    port = ENV["BROWSER_MCP_PORT"] || "19418"
    dir = ENV["BROWSER_MCP_DOWNLOAD_DIR"] ||
          File.expand_path("../../artifacts/downloads-#{port}", __dir__)
    started = Time.now
    wait_until(timeout: timeout) do
      Dir[File.join(dir, "*")].any? do |f|
        !f.end_with?(".crdownload", ".tmp") && File.file?(f) &&
          File.basename(f).include?(pattern.to_s) && File.size(f).positive? &&
          File.mtime(f) >= (started - 1)
      end
    end
    Dir[File.join(dir, "*")].find { |f| File.basename(f).include?(pattern.to_s) }
  end

  def page_text
    @driver.find_element(:tag_name, "body").text
  end

  # AJAX/gecikmeli assertion için Zhan'ın try_for deseni.
  def try_for(seconds = 5)
    deadline = Time.now + seconds
    begin
      yield
    rescue RSpec::Expectations::ExpectationNotMetError, Selenium::WebDriver::Error::WebDriverError
      raise if Time.now > deadline

      sleep 0.2
      retry
    end
  end
end
