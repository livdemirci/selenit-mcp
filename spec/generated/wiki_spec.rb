# Otomatik üretildi — benchmark.rb + scenarios/wiki.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:16:26+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageWiki
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def enter_searchinput(value)
    type_into("#searchInput", value)
    @driver.action.send_keys(:enter).perform
  end
end

RSpec.describe "wiki — Vikipedi'de arama yap" do
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
    page = PageWiki.new(@driver)
    page.open("https://tr.wikipedia.org")
    page.enter_searchinput("Alan Turing")
    try_for(5) { expect(@driver.current_url).to eq("https://tr.wikipedia.org/wiki/Alan_Turing") }
  end
end
