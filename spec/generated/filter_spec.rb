# Otomatik üretildi — benchmark.rb + scenarios/filter.json
# Kaynak model: google/gemma-4-e4b | 2026-10-23T08:02:36+0300
# selenit: "Run Selected Scripts Against Current Browser" (F11) veya: rspec bu_dosya.rb
require_relative "../support/sl_helper"

# Page Object: seçiciler ve işlemler tek yerde (Zhan: Maintainable Test Design).
class PageFilter
  include TwHelper

  def initialize(driver)
    @driver = driver
  end

  def enter_search(value)
    type_into("#search", value)
  end

  def click_tbody
    click("#tbody tr[data-id=\"10\"] button")
  end

  def select_status(label)
    select_option("#status", label)
  end

  def click_save
    click("#save")
  end
end

RSpec.describe "filter — tabloda ara, satırı düzenle, kaydet" do
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
    page = PageFilter.new(@driver)
    page.open("http://127.0.0.1:8765/dashboard")
    page.enter_search("Ada")
    page.click_tbody
    page.select_status("Aktif")
    page.click_save
    try_for(5) do
      expect(@driver.execute_script("var rows = Array.from(document.querySelectorAll('#tbody tr'));\nvar ok = rows.some(function (r) {\n  var st = r.querySelector('.st');\n  return r.innerText.indexOf('Ada') >= 0 && st && st.textContent.trim() === 'Aktif';\n});\nvar m = document.getElementById('modal');\nreturn String(ok && m && !m.classList.contains('open'));\n").to_s.strip).to eq("true")
    end
  end
end
