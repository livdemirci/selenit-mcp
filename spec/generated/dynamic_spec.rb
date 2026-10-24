# Otomatik üretildi — benchmark.rb + scenarios/dynamic.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:08:17+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageDynamic
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def scroll_down
    scroll_page("down", 600)
  end

  def scroll_down_2
    scroll_page("down", 600)
  end
end

RSpec.describe "dynamic — dinamik içeriği bekle, kaydır, say" do
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
    page = PageDynamic.new(@driver)
    page.open("http://127.0.0.1:8765/dynamic")
    page.scroll_down
    page.scroll_down_2
    try_for(5) do
      expect(@driver.execute_script("return String(document.querySelectorAll('#list li').length >= 10)").to_s.strip).to eq("true")
    end
  end
end
