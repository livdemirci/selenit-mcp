# Otomatik üretildi — benchmark.rb + scenarios/login.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:01:28+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageLogin
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def enter_user(value)
    type_into("#user", value)
  end

  def enter_pass(value)
    type_into("#pass", value)
  end

  def click_f
    click("#f > button:nth-of-type(1)")
  end
end

RSpec.describe "login — kullanıcı adı/parola ile oturum aç" do
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
    page = PageLogin.new(@driver)
    page.open("http://127.0.0.1:8765/login")
    page.enter_user("demo")
    page.enter_pass("demo123")
    page.click_f
    try_for(5) do
      expect(@driver.execute_script("return String(location.pathname === '/dashboard' && localStorage.getItem('auth') === '1')").to_s.strip).to eq("true")
    end
  end
end
