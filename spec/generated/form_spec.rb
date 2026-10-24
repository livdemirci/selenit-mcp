# Otomatik üretildi — benchmark.rb + scenarios/form.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T07:56:56+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageForm
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def enter_ad(value)
    type_into("input[name=\"ad\"]", value)
  end

  def click_step_3
    click("html:nth-of-type(1) > body:nth-of-type(1) > button:nth-of-type(1)")
  end
end

RSpec.describe "form — test formunu doldur ve gönder" do
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
    page = PageForm.new(@driver)
    page.open("data:text/html,<title>Form</title><input name=ad placeholder='Ad'><button onclick=\"document.title=document.querySelector('input').value\">Gönder</button>")
    page.enter_ad("Gemma")
    page.click_step_3
    try_for(5) { expect(@driver.current_url).to eq("data:text/html,<title>Form</title><input name=ad placeholder='Ad'><button onclick=\"document.title=document.querySelector('input').value\">G%C3%B6nder</button>") }
  end
end
