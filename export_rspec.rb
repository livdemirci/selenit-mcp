#!/usr/bin/env ruby
# scenarios/<görev>.json -> spec/generated/<görev>_spec.rb
#
# Zhimin Zhan'ın "Maintainable Automated Test Design" yaklaşımı:
#   - ham Selenium WebDriver sözdizimi (framework yok)
#   - explicit wait (Selenium::WebDriver::Wait); sabit sleep yok
#   - sayfa işlemleri Page Object içinde; test gövdesi okunabilir
#   - try_for ile AJAX/gecikmeli assertion tekrarı
#   - paylaşılan test helper (DRY)
#
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya:
#   rspec spec/generated/filter_spec.rb

require "json"
require "fileutils"

HELPER = <<~'RUBY'
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
RUBY

def ruby_str(value)
  value.to_s.inspect
end

def suffix_for(selector, fallback, text = nil)
  s = selector.to_s
  raw =
    if (m = s.match(/\A#([A-Za-z][\w-]*)\z/))
      m[1]
    elsif (m = s.match(/\[name=["']([^"']+)["']\]/))
      m[1]
    elsif (m = s.match(/\[data-testid=["']([^"']+)["']\]/))
      m[1]
    elsif text && !text.to_s.strip.empty?
      text.to_s.strip
    elsif (m = s.match(/#([A-Za-z][\w-]*)/))
      m[1]
    else
      "step_#{fallback}"
    end
  raw.tr("üğışöçÜĞİŞÖÇ", "ugisocUGISOC").gsub(/[^A-Za-z0-9_]/, "_").downcase
end

def unique_name(base, used)
  name = base
  i = 2
  while used[name]
    name = "#{base}_#{i}"
    i += 1
  end
  used[name] = true
  name
end

def method_for(step, index, used)
  args = step["args"] || {}
  sel = step["selector"].to_s
  tool = step["tool"].to_s

  case tool
  when "browser_click"
    return [nil, nil, nil, nil] if sel.empty?
    name = unique_name("click_#{suffix_for(sel, index, args['text'])}", used)
    [name, "", "    click(#{ruby_str(sel)})", nil]
  when "browser_type"
    return [nil, nil, nil, nil] if sel.empty?
    name = unique_name("enter_#{suffix_for(sel, index)}", used)
    body = "    type_into(#{ruby_str(sel)}, value)"
    body += "\n    @driver.action.send_keys(:enter).perform" if args["submit"]
    [name, "value", body, args["text"].to_s]
  when "browser_select"
    return [nil, nil, nil, nil] if sel.empty?
    name = unique_name("select_#{suffix_for(sel, index)}", used)
    label = args["label"] || args["value"] || ""
    [name, "label", "    select_option(#{ruby_str(sel)}, label)", label.to_s]
  when "browser_upload"
    return [nil, nil, nil, nil] if sel.empty?
    name = unique_name("upload_#{suffix_for(sel, index)}", used)
    [name, "path", "    attach_file(#{ruby_str(sel)}, path)", args["path"].to_s]
  when "browser_hover"
    return [nil, nil, nil, nil] if sel.empty?
    name = unique_name("hover_#{suffix_for(sel, index)}", used)
    [name, "", "    hover(#{ruby_str(sel)})", nil]
  when "browser_press_key"
    key = { "enter" => ":enter", "tab" => ":tab", "escape" => ":escape",
            "arrowdown" => ":arrow_down", "arrowup" => ":arrow_up" }[args["key"].to_s] || ":enter"
    name = unique_name("press_#{args['key'].to_s.gsub(/[^A-Za-z0-9]/, '_')}", used)
    [name, "", "    press_key(#{key})", nil]
  when "browser_frame"
    if args["action"].to_s == "enter"
      if sel.empty?
        name = unique_name("go_frame_index", used)
        [name, "", "    enter_frame_by_index(#{(args['index'] || 0).to_i})", nil]
      else
        name = unique_name("go_into_frame", used)
        [name, "", "    enter_frame(#{ruby_str(sel)})", nil]
      end
    else
      name = unique_name("go_main_frame", used)
      [name, "", "    main_frame", nil]
    end
  when "browser_scroll"
    dir = args["direction"].to_s.empty? ? "down" : args["direction"].to_s
    px = args["amount"].to_i.zero? ? 600 : args["amount"].to_i
    name = unique_name("scroll_#{dir}", used)
    [name, "", "    scroll_page(#{ruby_str(dir)}, #{px})", nil]
  when "browser_history"
    dir = args["direction"].to_s
    name, body =
      case dir
      when "forward" then ["history_forward", "    go_forward"]
      when "reload" then ["history_reload", "    reload_page"]
      else ["history_back", "    go_back"]
      end
    [unique_name(name, used), "", body, nil]
  when "browser_tabs"
    if step["tab_url"] && !step["tab_url"].to_s.empty?
      name = unique_name("go_tab", used)
      [name, "", "    switch_tab(#{ruby_str(step['tab_url'])})", nil]
    elsif args["action"].to_s == "switch"
      name = unique_name("go_tab", used)
      [name, "", "    @driver.switch_to.window(@driver.window_handles[#{(args['index'] || 0).to_i}])", nil]
    else
      [nil, nil, nil, nil]
    end
  when "browser_alert"
    if args["action"].to_s == "dismiss"
      name = unique_name("dismiss_alert", used)
      [name, "", "    dismiss_js_alert", nil]
    else
      name = unique_name("accept_alert", used)
      [name, "", "    accept_js_alert", nil]
    end
  when "browser_wait_for"
    case args["type"].to_s
    when "download"
      name = unique_name("wait_download", used)
      [name, "", "    wait_for_download(#{ruby_str(args['text'] || '')})", nil]
    when "selector"
      name = unique_name("wait_selector", used)
      [name, "", "    wait_for_selector(#{ruby_str(args['selector'])})", nil]
    when "url"
      name = unique_name("wait_url", used)
      [name, "", "    wait_for_url(#{ruby_str(args['value'] || args['text'])})", nil]
    when "gone"
      name = unique_name("wait_gone", used)
      [name, "", "    wait_for_gone(#{ruby_str(args['selector'])})", nil]
    when "count"
      name = unique_name("wait_count", used)
      [name, "", "    wait_for_count(#{ruby_str(args['selector'])}, #{args['value'].to_i})", nil]
    else
      text = args["text"] || args["value"]
      if text && !text.to_s.empty?
        name = unique_name("wait_text", used)
        [name, "", "    wait_until_text(#{ruby_str(text)})", nil]
      else
        [nil, nil, nil, nil]
      end
    end
  else
    [nil, nil, nil, nil]
  end
end

def render_page(scenario, used)
  lines = []
  calls = []
  steps = scenario["steps"] || []

  steps.each_with_index do |step, i|
    index = i + 1
    if step["tool"] == "browser_navigate"
      calls << "    page.open(#{ruby_str(step.dig('args', 'url'))})"
      next
    end

    name, arg, body, call_value = method_for(step, index, used)
    next if name.nil?

    call_args = call_value.nil? ? "" : ruby_str(call_value)
    invocation = call_args.empty? ? name : "#{name}(#{call_args})"
    calls << "    page.#{invocation}"
    signature = arg.to_s.empty? ? name : "#{name}(#{arg})"
    lines << "  def #{signature}"
    lines << body
    lines << "  end"
    lines << ""
  end

  [lines, calls]
end

def render(scenario)
  used = {}
  page_lines, calls = render_page(scenario, used)
  task = scenario["task"].to_s
  class_name = task.split(/[^A-Za-z0-9]/).map(&:capitalize).join
  class_name = "Task" if class_name.empty?
  class_name = "Page#{class_name}" unless class_name.end_with?("Page")

  assertion =
    if scenario["assert_js"] && !scenario["assert_js"].to_s.empty?
      "    try_for(5) do\n" \
        "      expect(@driver.execute_script(#{ruby_str(scenario['assert_js'])}).to_s.strip).to eq(#{ruby_str(scenario['assert_value'])})\n" \
        "    end"
    elsif scenario["final_url"]
      "    try_for(5) { expect(@driver.current_url).to eq(#{ruby_str(scenario['final_url'])}) }"
    else
      "    # TODO: iş kuralı doğrulaması ekle"
    end

  <<~RUBY
    # Otomatik üretildi — benchmark.rb + scenarios/#{task}.json
    # Kaynak model: #{scenario['model']} | #{scenario['recorded_at']}
    # selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
    require_relative "../support/sl_helper"

    # Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
    class #{class_name}
      include TwHelper

      def initialize(driver)
        @driver = driver
      end

    #{page_lines.join("\n")}end

    RSpec.describe #{ruby_str("#{task} — #{scenario['desc']}")} do
      include TwHelper

      before(:all) { @driver = attach_browser }

      # Test bağımsızlığı: frame/alert sızıntısını temizle; her senaryo kendi
      # navigasyonunu adımlarında yapar.
      before(:each) do
        @driver.switch_to.default_content rescue nil
        @driver.switch_to.alert.accept rescue nil
      end

      # selenit F11 semantiği: tarayıcı açık bırakılır. CI'da QUIT_BROWSER=1 verin.
      after(:all) { @driver.quit if ENV["QUIT_BROWSER"] == "1" }

      it "kaydedilmiş adımları explicit wait ile oynatır" do
        page = #{class_name}.new(@driver)
    #{calls.join("\n")}
    #{assertion}
      end
    end
  RUBY
end

keys = ARGV.empty? ? Dir[File.expand_path("scenarios/*.json", __dir__)].map { |p| File.basename(p, ".json") }.sort : ARGV
abort "senaryo yok (önce benchmark.rb çalıştır)" if keys.empty?

out_dir = File.expand_path("spec/generated", __dir__)
support_dir = File.expand_path("spec/support", __dir__)
FileUtils.mkdir_p(out_dir)
FileUtils.mkdir_p(support_dir)

helper_path = File.join(support_dir, "sl_helper.rb")
File.write(helper_path, HELPER)
puts "yazıldı: #{helper_path}"

keys.each do |key|
  path = File.expand_path("scenarios/#{key}.json", __dir__)
  unless File.exist?(path)
    warn "atlandı (senaryo yok): #{key}"
    next
  end
  scenario = JSON.parse(File.read(path))
  out = File.join(out_dir, "#{key}_spec.rb")
  File.write(out, render(scenario))
  puts "yazıldı: #{out}"
end
