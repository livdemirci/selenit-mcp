# Otomatik üretildi — benchmark.rb + scenarios/frame.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:03:53+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageFrame
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def go_into_frame
    enter_frame("#frm")
  end

  def enter_ad(value)
    type_into("#ad", value)
  end

  def click_f
    click("#f > button:nth-of-type(1)")
  end

  def go_main_frame
    main_frame
  end
end

RSpec.describe "frame — iframe içindeki formu doldur" do
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
    page = PageFrame.new(@driver)
    page.open("http://127.0.0.1:8765/frame")
    page.go_into_frame
    page.enter_ad("Ada")
    page.click_f
    page.go_main_frame
    try_for(5) do
      expect(@driver.execute_script("return String(((document.getElementById('result')||{}).textContent||'').indexOf('Sonuç: Ada') >= 0)").to_s.strip).to eq("true")
    end
  end
end
