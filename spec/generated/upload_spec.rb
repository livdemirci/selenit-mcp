# Otomatik üretildi — benchmark.rb + scenarios/upload.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:05:51+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageUpload
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def upload_file(path)
    attach_file("#file", path)
  end

  def click_up
    click("#up")
  end
end

RSpec.describe "upload — dosya yükleme alanına dosya ver" do
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
    page = PageUpload.new(@driver)
    page.open("http://127.0.0.1:8765/upload")
    page.upload_file("/tmp/agent_upload.txt")
    page.click_up
    try_for(5) do
      expect(@driver.execute_script("return String(((document.getElementById('out')||{}).textContent||'').indexOf('agent_upload.txt') >= 0)").to_s.strip).to eq("true")
    end
  end
end
