# Otomatik üretildi — benchmark.rb + scenarios/link.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T07:56:04+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageLink
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def click_step_2
    click("a[href=\"https://iana.org/help/example-domains\"]")
  end
end

RSpec.describe "link — example.com'daki bağlantıya tıkla, açılan sayfanın başlığını söyle" do
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
    page = PageLink.new(@driver)
    page.open("https://example.com")
    page.click_step_2
    try_for(5) { expect(@driver.current_url).to eq("https://www.iana.org/help/example-domains") }
  end
end
