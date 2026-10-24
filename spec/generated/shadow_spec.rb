# Otomatik üretildi — benchmark.rb + scenarios/shadow.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:04:47+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageShadow
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def enter_msg(value)
    type_into("shadow::html:nth-of-type(1) > body:nth-of-type(1) > my-widget:nth-of-type(1)||#msg", value)
  end

  def click_ok
    click("shadow::html:nth-of-type(1) > body:nth-of-type(1) > my-widget:nth-of-type(1)||#ok")
  end
end

RSpec.describe "shadow — shadow DOM içindeki alana yaz" do
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
    page = PageShadow.new(@driver)
    page.open("http://127.0.0.1:8765/shadow")
    page.enter_msg("merhaba")
    page.click_ok
    try_for(5) do
      expect(@driver.execute_script("var t=((document.getElementById('result')||{}).textContent||'').toLowerCase(); return String(t.indexOf('shadow sonuç')>=0 && t.indexOf('merhaba')>=0)").to_s.strip).to eq("true")
    end
  end
end
