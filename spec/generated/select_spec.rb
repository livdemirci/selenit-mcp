# Otomatik üretildi — benchmark.rb + scenarios/select.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T07:59:37+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageSelect
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def select_step_2(label)
    select_option("html:nth-of-type(1) > body:nth-of-type(1) > select:nth-of-type(1)", label)
  end
end

RSpec.describe "select — açılır listeden seçenek seç" do
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
    page = PageSelect.new(@driver)
    page.open("data:text/html,<title>Renk</title><select><option value=kirmizi>Kırmızı</option><option value=mavi>Mavi</option></select>")
    page.select_step_2("Mavi")
    try_for(5) { expect(@driver.current_url).to eq("data:text/html,<title>Renk</title><select><option value=kirmizi>K%C4%B1rm%C4%B1z%C4%B1</option><option value=mavi>Mavi</option></select>") }
  end
end
