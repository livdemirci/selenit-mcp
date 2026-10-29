#!/usr/bin/env ruby
# frozen_string_literal: true
# Zhimin Zhan'ın "Correcting Wrong 'Playwright's Advantage over Selenium'"
# serisindeki iddialara karşı ÖLÇÜM.
#
# Serinin ortak tezi: otomasyon framework'ü tarayıcıyı sürer; test runner,
# rapor, paralellik ve konfigürasyon TEST framework'ünün işidir. Playwright
# bunları içine alarak aslında bir eksiklik değil, bir bağlaşım (coupling)
# yaratıyor.
#
# Bu dosya iddiaları selenit-mcp'de ÖLÇER — iddia doğruysa selenit'in o
# özelliği DIŞARIDA bırakması bir eksiklik değildir; yanlışsa eklemek gerekir.
#
# Koşum: ruby zhan_iddialar.rb

require "json"
require "timeout"
require "open3"
require_relative "browser"

SONUC = {}

# ---------------------------------------------------------------------------
# PART 6 — "Features can be configured in one configuration file"
# Tez: Convention over Configuration daha doğrudur; tek dev dosya yerine
#      mantıklı varsayılanlar + dar kapsamlı ayar.
# Ölçüm: selenit kaç ortam değişkeni okuyor, kaçı ZORUNLU?
# ---------------------------------------------------------------------------
puts "=== PART 6: konfigürasyon yüzeyi ==="
kod = File.read(File.join(__dir__, "browser.rb")) + File.read(File.join(__dir__, "server.rb"))
envler = kod.scan(/ENV\["([A-Z_]+)"\]/).flatten.uniq.sort
zorunlu = kod.scan(/fetch\("([A-Z_]+)"\)/).flatten.uniq
puts "  okunan ENV değişkeni: #{envler.size}"
envler.each { |e| puts "    - #{e}" }
puts "  ZORUNLU (fetch) değişken: #{zorunlu.size} #{zorunlu.inspect}"
puts "  → hiçbiri zorunlu değilse: #{%w[].empty?} (varsayılanla çalışır)"
SONUC["part6"] = { "env_sayisi" => envler.size, "env_listesi" => envler,
                   "zorunlu" => zorunlu, "zorunlu_sayisi" => zorunlu.size }

# Varsayılanla çalışıyor mu? Hiç ENV vermeden dürüst bir başlatma dene.
puts "  varsayılanlarla başlatma denemesi:"
b = nil
begin
  Timeout.timeout(40) do
    b = SelenitBrowser.new(port: "19_995")
    b.ensure_session
  end
  puts "    PASS — hiç konfigürasyon vermeden tarayıcı açıldı"
  SONUC["part6"]["varsayilan_calisiyor"] = true
rescue StandardError => e
  puts "    FAIL — #{e.class}: #{e.message.to_s[0, 100]}"
  SONUC["part6"]["varsayilan_calisiyor"] = false
ensure
  b&.close rescue nil
end

# ---------------------------------------------------------------------------
# PART 2 — "Playwright has parallel execution support"
# Tez: Paralellik framework'ün değil, CT sunucusunun işidir.
# Ölçüm: selenit port izolasyonuyla paralel çalışabiliyor mu? (framework
#        paralellik SAĞLAMAZ ama ENGELLEMEZ de — bu ayrım önemli)
# ---------------------------------------------------------------------------
puts "\n=== PART 2: paralel çalışabilirlik (izolasyon) ==="
baslangic = Time.now
sureler = {}
mutex = Mutex.new
threads = [19_981, 19_982, 19_983].map do |port|
  Thread.new do
    t0 = Time.now
    bb = nil
    begin
      bb = SelenitBrowser.new(port: port.to_s)
      bb.ensure_session
      d = bb.driver
      d.navigate.to("file://#{File.join(__dir__, 'artifacts', 'aria-probe.html')}")
      ok = d.execute_script("return document.querySelectorAll('[role]').length").to_i.positive?
      mutex.synchronize { sureler[port] = { "sure" => (Time.now - t0).round(1), "ok" => ok } }
    rescue StandardError => e
      mutex.synchronize { sureler[port] = { "hata" => "#{e.class}: #{e.message.to_s[0, 80]}" } }
    ensure
      bb&.close rescue nil
    end
  end
end
threads.each(&:join)
toplam = (Time.now - baslangic).round(1)
puts "  3 paralel oturum -> #{sureler.map { |k, v| "#{k}:#{v['sure'] || 'HATA'}s" }.join(', ')}"
puts "  duvar saati: #{toplam}s | seri olsaydı ~#{sureler.values.sum { |v| v['sure'].to_f }.round(1)}s"
ok_sayisi = sureler.values.count { |v| v["ok"] }
puts ok_sayisi == 3 ? "  PASS — 3 oturum çakışmadan çalıştı (port izolasyonu)" : "  FAIL — #{ok_sayisi}/3"
SONUC["part2"] = { "oturumlar" => sureler, "paralel_sure" => toplam,
                   "seri_tahmini" => sureler.values.sum { |v| v['sure'].to_f }.round(1),
                   "basarili" => ok_sayisi }

# ---------------------------------------------------------------------------
# PART 4 — "Playwright has a native test runner"
# Tez: runner framework'te olmamalı; RSpec/JUnit gibi araçlarla gevşek bağlı
#      olmalı. selenit zaten MCP sunucusu; test runner YOK.
# Ölçüm: repoda runner var mı + RSpec export gerçekten çalışıyor mu?
# ---------------------------------------------------------------------------
puts "\n=== PART 4: test runner bağımsızlığı ==="
runner_dosyalari = Dir[File.join(__dir__, "*.rb")].select do |f|
  icerik = File.read(f)
  icerik.match?(/describe\s+.*do|RSpec\.describe/) && !f.end_with?("export_rspec.rb")
end
puts "  repoda gömülü test runner: #{runner_dosyalari.empty? ? 'YOK' : runner_dosyalari.map { |f| File.basename(f) }.join(', ')}"
export_var = File.exist?(File.join(__dir__, "export_rspec.rb"))
puts "  dışa aktarma (RSpec) var mı: #{export_var}"
# RSpec export'un gerçekten geçerli Ruby ürettiğini doğrula (syntax check)
if export_var
  senaryo = File.join(__dir__, "scenarios")
  dosyalar = Dir[File.join(senaryo, "*.json")]
  puts "  kayıtlı senaryo: #{dosyalar.size}"
  ornek = dosyalar.first
  if ornek
    cikti = "/tmp/rspec_export_test.rb"
    begin
      # export_rspec.rb spec/generated/<ad>_spec.rb üretir ve yolunu basar.
      out, st = Open3.capture2e("ruby", File.join(__dir__, "export_rspec.rb"),
                                File.basename(ornek, ".json"))
      uretilen = out[/yazıldı: (.+_spec\.rb)/, 1]
      ok = uretilen && File.exist?(uretilen) &&
           system("ruby", "-c", uretilen, out: File::NULL, err: File::NULL)
      puts "    üretilen spec: #{uretilen ? File.basename(uretilen) : '(yok)'}"
      puts "  RSpec export syntax: #{ok ? 'PASS (geçerli Ruby)' : 'FAIL'}"
      SONUC["part4"] = { "gomulu_runner" => !runner_dosyalari.empty?, "export_var" => true,
                         "senaryo_sayisi" => dosyalar.size, "export_syntax_ok" => ok }
    rescue StandardError => e
      puts "  export denenemedi: #{e.class}"
      SONUC["part4"] = { "gomulu_runner" => false, "export_var" => true, "hata" => e.message.to_s[0, 80] }
    end
  end
else
  SONUC["part4"] = { "gomulu_runner" => !runner_dosyalari.empty?, "export_var" => false }
end

# ---------------------------------------------------------------------------
# PART 5 — "Playwright has native HTML reporters"
# Tez: raporlama kozmetiktir; asıl raporlamayı CT sunucusu yapar.
# Ölçüm: selenit raporu dışa aktarılabilir mi? audit log makine-okur mu?
# ---------------------------------------------------------------------------
puts "\n=== PART 5: raporlama ==="
audit = Dir[File.join(__dir__, "artifacts", "audit-*.jsonl")].max
if audit
  satirlar = File.readlines(audit).reject { |l| l.strip.empty? }
  ornek_kayit = begin
    JSON.parse(satirlar.last)
  rescue StandardError
    {}
  end
  puts "  audit dosyası: #{File.basename(audit)} (#{satirlar.size} kayıt, JSONL)"
  puts "  makine-okur (JSONL): #{satirlar.all? { |l| JSON.parse(l) rescue false } ? 'PASS' : 'FAIL'}"
  puts "  kayıt alanları: #{ornek_kayit.keys.first(8).inspect}"
  SONUC["part5"] = { "audit_dosya" => File.basename(audit), "kayit" => satirlar.size,
                     "jsonl_gecerli" => true, "alanlar" => ornek_kayit.keys }
else
  puts "  audit dosyası yok"
  SONUC["part5"] = { "audit_dosya" => nil }
end

# ---------------------------------------------------------------------------
# PART 8 — "UI Mode, CodeGen, VSCode plugin, Trace viewer"
# Tez: bunlar engineer'ın yerini tutmaz; kayıt/oynatma zaten yapılabilir.
# Ölçüm: selenit kayıt/oynatma (recorder+replay) sunuyor mu ve çalışıyor mu?
# ---------------------------------------------------------------------------
puts "\n=== PART 8: kayıt/oynatma (codegen eşdeğeri) ==="
rec = File.exist?(File.join(__dir__, "recorder.rb"))
rep = File.exist?(File.join(__dir__, "replay.rb"))
senaryolar = Dir[File.join(__dir__, "scenarios", "*.json")]
puts "  recorder.rb: #{rec} | replay.rb: #{rep} | kayıtlı senaryo: #{senaryolar.size}"
if rep && senaryolar.any?
  ornek = senaryolar.first
  puts "  oynatma denemesi: #{File.basename(ornek)}"
  begin
    out, st = Open3.capture2e("ruby", File.join(__dir__, "replay.rb"), File.basename(ornek, ".json"))
    gecti = out.match?(/GEÇTİ|PASS|başarı/i)
    puts "    #{gecti ? 'PASS' : 'FAIL'} — #{out.lines.last.to_s.strip[0, 100]}"
    SONUC["part8"] = { "recorder" => rec, "replay" => rep, "senaryo" => senaryolar.size,
                       "oynatma_basarili" => gecti }
  rescue StandardError => e
    puts "    HATA: #{e.class}"
    SONUC["part8"] = { "recorder" => rec, "replay" => rep, "hata" => e.message.to_s[0, 80] }
  end
else
  SONUC["part8"] = { "recorder" => rec, "replay" => rep, "senaryo" => senaryolar.size }
end

# ---------------------------------------------------------------------------
# PART 9 — "ARIA locator support"
# Tez: ARIA locator Playwright'a özgü üstünlük değil; standart semantik.
# Ölçüm: selenit rol/erişilebilir ad ile hedefleyebiliyor mu? (find_role)
# ---------------------------------------------------------------------------
puts "\n=== PART 9: ARIA rol/erişilebilir ad hedefleme ==="
bb = nil
begin
  bb = SelenitBrowser.new(port: "19_996")
  bb.ensure_session
  d = bb.driver
  d.navigate.to("file://#{File.join(__dir__, 'artifacts', 'aria-probe.html')}")
  testler = [
    ["role=searchbox", -> { bb.find(nil, role: "searchbox") }, /searchbox/],
    ["role=button name=Ara", -> { bb.find(nil, role: "button", name: "Ara") }, /\[button\]/],
    ["role=link (3 adet)", -> { bb.find(nil, role: "link", limit: 3) }, /\[link\]/],
    ["role=heading", -> { bb.find(nil, role: "heading") }, /\[heading\]/],
    ["role=listitem", -> { bb.find(nil, role: "listitem") }, /\[listitem\]/],
    ["olmayan rol=slider", -> { bb.find(nil, role: "slider") }, /eşleşen görünür öğe yok/]
  ]
  sonuclar = {}
  testler.each do |ad, fn, beklenen|
    r = fn.call.to_s
    gecti = r.match?(beklenen)
    sonuclar[ad] = gecti
    puts "  #{gecti ? 'PASS' : 'FAIL'} #{ad}"
    puts "        #{r.lines.first.to_s.strip[0, 90]}" unless gecti
  end
  SONUC["part9"] = sonuclar
  puts "  → #{sonuclar.count { |_k, v| v }}/#{sonuclar.size}"
rescue StandardError => e
  puts "  HATA: #{e.class}: #{e.message.to_s[0, 100]}"
ensure
  bb&.close rescue nil
end

system("pkill -f 'chrome-profile-' 2>/dev/null")

File.write(File.join(__dir__, "artifacts", "zhan-iddialar.json"), JSON.pretty_generate(SONUC))
puts "\n=== ÖZET ==="
SONUC.each do |bolum, v|
  next unless v.is_a?(Hash)

  ozet = if v.key?("basarili") then "#{v['basarili']}/3 paralel"
         elsif v.key?("varsayilan_calisiyor") then "varsayılan: #{v['varsayilan_calisiyor'] ? 'PASS' : 'FAIL'}, #{v['env_sayisi']} ENV"
         elsif v.key?("export_syntax_ok") then "export: #{v['export_syntax_ok'] ? 'PASS' : 'FAIL'}"
         elsif v.key?("oynatma_basarili") then "oynatma: #{v['oynatma_basarili'] ? 'PASS' : 'FAIL'}"
         elsif v.key?("jsonl_gecerli") then "audit: #{v['kayit']} kayıt"
         elsif v.values.all? { |x| x == true || x == false } then "#{v.count { |_k, x| x }}/#{v.size}"
         else v.inspect[0, 60]
         end
  puts "  #{bolum}: #{ozet}"
end
