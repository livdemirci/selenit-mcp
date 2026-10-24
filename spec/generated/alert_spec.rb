# Otomatik üretildi — benchmark.rb + scenarios/alert.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:00:10+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageAlert
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def click_step_2
    click("html:nth-of-type(1) > body:nth-of-type(1) > button:nth-of-type(1)")
  end

  def accept_alert
    accept_js_alert
  end
end

RSpec.describe "alert — JS uyarı penceresini kapat" do
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
    page = PageAlert.new(@driver)
    page.open("data:text/html,<title>Uyari</title><button onclick=\"alert('merhaba')\">Uyar</button>")
    page.click_step_2
    page.accept_alert
    try_for(5) { expect(@driver.current_url).to eq("data:text/html,<title>Uyari</title><button onclick=\"alert('merhaba')\">Uyar</button>") }
  end
end
