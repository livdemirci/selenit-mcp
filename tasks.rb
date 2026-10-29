# Görev tanımları: hem benchmark.rb (LLM keşfi) hem replay.rb (modelsiz tekrar) kullanır.

APP = ENV["BENCH_APP_URL"] || "http://127.0.0.1:8765"
MAX_STEPS = (ENV["BENCH_MAX_STEPS"] || 10).to_i

# Sayfa durumunu JS ile doğrula: "true" dönerse geçti.
def js_check(js)
  lambda do |mcp, _answer|
    mcp.call("browser_evaluate", { "script" => js }).to_s.strip == "true"
  end
end

SYSTEM_PROMPT = <<~S
  Sen bir tarayıcı otomasyon ajanısın. Kurallar:
  - Her adımda TEK araç çağır, sonucu bekle.
  - Sayfayı anlamak için browser_snapshot kullan; öğeleri e1, e2 gibi ref ile seç.
  - Ref geçersizse yeniden browser_snapshot çağır.
  - Modal açıksa yalnızca modal içindeki öğeleri kullan.
  - iframe içine girmek için browser_frame, dosya için browser_upload kullan.
  - Dinamik içerik, URL değişimi veya indirme için browser_wait_for kullan
    (type: text/selector/url/count/download). Sabit bekleme yapma.
  - Görev bitince araç çağırmayı bırak ve en fazla 2 cümlelik kısa Türkçe cevap ver.
S

TASKS = {
  "link" => {
    desc: "example.com'daki bağlantıya tıkla, açılan sayfanın başlığını söyle",
    prompt: "https://example.com adresine git, sayfadaki bağlantıya tıkla ve açılan sayfanın başlığını söyle.",
    check: lambda do |mcp, _answer|
      deadline = Time.now + 5
      url = ""
      while Time.now < deadline
        url = mcp.call("browser_evaluate", { "script" => "return location.href" })
        break if url.include?("iana.org")
        sleep 0.2
      end
      url.include?("iana.org")
    end
  },
  "form" => {
    desc: "test formunu doldur ve gönder",
    prompt: "Şu sayfaya git: data:text/html,<title>Form</title><input name=ad placeholder='Ad'><button onclick=\"document.title=document.querySelector('input').value\">Gönder</button> . " \
            "Ad alanına 'Gemma' yaz, Gönder düğmesine bas ve sayfa başlığını söyle.",
    check: lambda do |mcp, _answer|
      title = mcp.call("browser_evaluate", { "script" => "return document.title" })
      title.include?("Gemma")
    end
  },
  "wiki" => {
    desc: "Vikipedi'de arama yap",
    prompt: "https://tr.wikipedia.org adresine git, arama kutusuna 'Alan Turing' yaz, klavyeden Enter'a bas " \
            "(otomatik tamamlama önerisine tıklama) ve açılan sayfanın başlığını söyle.",
    check: lambda do |mcp, answer|
      title = mcp.call("browser_evaluate", { "script" => "return document.title" })
      title.include?("Alan Turing") || answer.to_s.include?("Alan Turing")
    end
  },
  "hn" => {
    desc: "Hacker News'te en üstteki 3 başlığı listele",
    prompt: "https://news.ycombinator.com adresine git ve en üstteki 3 haber başlığını numaralı listele.",
    check: lambda do |mcp, answer|
      text = mcp.call("browser_evaluate", { "script" => "return location.href" })
      text.include?("ycombinator") && answer.to_s.scan(/^\s*\d[\.\)]?\s+\S/).size >= 3
    end
  },
  "deep" => {
    desc: "uzun sayfada metne göre bağlantı bul ve tıkla",
    prompt: "https://en.wikipedia.org/wiki/Alan_Turing adresine git. Sayfada 'Turing machine' yazılı bağlantıyı bul ve tıkla; açılan sayfanın başlığını söyle.",
    check: lambda do |mcp, _answer|
      url = mcp.call("browser_evaluate", { "script" => "return location.href" })
      url.include?("Turing_machine")
    end
  },
  "read" => {
    desc: "sayfa metnini oku ve özetle",
    prompt: "https://example.com adresine git ve sayfadaki ana paragrafı Türkçeye çevirip tek cümleyle özetle.",
    check: lambda do |mcp, answer|
      url = mcp.call("browser_evaluate", { "script" => "return location.href" })
      url.include?("example.com") && answer.to_s.length > 25
    end
  },
  "select" => {
    desc: "açılır listeden seçenek seç",
    prompt: "Şu sayfaya git: data:text/html,<title>Renk</title><select><option value=kirmizi>Kırmızı</option><option value=mavi>Mavi</option></select> . " \
            "Açılır listeden 'Mavi' seçeneğini seç ve seçili değeri söyle.",
    check: lambda do |mcp, _answer|
      value = mcp.call("browser_evaluate", { "script" => "return document.querySelector('select').value" })
      value.include?("mavi")
    end
  },
  "alert" => {
    desc: "JS uyarı penceresini kapat",
    prompt: "Şu sayfaya git: data:text/html,<title>Uyari</title><button onclick=\"alert('merhaba')\">Uyar</button> . " \
            "'Uyar' düğmesine bas, açılan uyarıyı kapat ve uyarı metnini söyle.",
    check: lambda do |mcp, answer|
      url = mcp.call("browser_evaluate", { "script" => "return document.title" })
      url.include?("Uyari") && answer.to_s.downcase.include?("merhaba")
    end
  },
  "stale" => {
    desc: "sayfa değiştikten sonra eski ref kullanımı",
    prompt: "https://example.com adresine git, bağlantıya tıkla, sonra geri dön ve ana sayfadaki başlığı söyle.",
    check: lambda do |mcp, answer|
      url = mcp.call("browser_evaluate", { "script" => "return location.href" })
      url.include?("example.com") && answer.to_s.downcase.include?("example")
    end
  },

  # --- zor senaryolar (yerel testapp) -------------------------------------
  "login" => {
    desc: "kullanıcı adı/parola ile oturum aç",
    assert_js: "return String(location.pathname === '/dashboard' && localStorage.getItem('auth') === '1')",
    prompt: "#{APP}/login adresine git. Kullanıcı adı alanına 'demo', parola alanına 'demo123' yaz ve 'Giriş Yap' düğmesine bas. " \
            "Girişten sonra hangi sayfaya geldiğini söyle.",
    check: lambda do |mcp, _answer|
      state = mcp.call("browser_evaluate", {
        "script" => "return location.pathname + '|' + (localStorage.getItem('auth') || '')"
      })
      state.to_s.include?("dashboard|1")
    end
  },
  "filter" => {
    desc: "tabloda ara, satırı düzenle, kaydet",
    assert_js: <<~JS,
      var rows = Array.from(document.querySelectorAll('#tbody tr'));
      var ok = rows.some(function (r) {
        var st = r.querySelector('.st');
        return r.innerText.indexOf('Ada') >= 0 && st && st.textContent.trim() === 'Aktif';
      });
      var m = document.getElementById('modal');
      return String(ok && m && !m.classList.contains('open'));
    JS
    prompt: "#{APP}/dashboard adresine git (gerekirse demo/demo123 ile giriş yap). Arama kutusuna 'Ada' yaz. " \
            "Görünen ilk satırdaki 'Düzenle' düğmesine tıkla. Açılan pencerede durumu 'Aktif' yap ve 'Kaydet' düğmesine bas. Ne olduğunu söyle.",
    check: lambda do |mcp, _answer|
      state = mcp.call("browser_evaluate", {
        "script" => <<~JS
          var rows = Array.from(document.querySelectorAll('#tbody tr'));
          var ok = rows.some(function (r) {
            var st = r.querySelector('.st');
            return r.innerText.indexOf('Ada') >= 0 && st && st.textContent.trim() === 'Aktif';
          });
          var m = document.getElementById('modal');
          return ok && m && !m.classList.contains('open');
        JS
      })
      state.to_s.strip == "true"
    end
  },
  "frame" => {
    desc: "iframe içindeki formu doldur",
    assert_js: "return String(((document.getElementById('result')||{}).textContent||'').indexOf('Sonuç: Ada') >= 0)",
    prompt: "#{APP}/frame adresine git. Sayfadaki iframe içine gir, Ad alanına 'Ada' yaz ve 'Gönder' düğmesine bas. " \
            "Ana sayfaya dön ve sonucu söyle.",
    check: lambda do |mcp, _answer|
      mcp.call("browser_frame", { "action" => "main" }) rescue nil
      text = mcp.call("browser_evaluate", {
        "script" => "var r = document.getElementById('result'); return r ? r.textContent : ''"
      })
      text.to_s.include?("Sonuç: Ada")
    end
  },
  "shadow" => {
    desc: "shadow DOM içindeki alana yaz",
    assert_js: "var t=((document.getElementById('result')||{}).textContent||'').toLowerCase(); return String(t.indexOf('shadow sonuç')>=0 && t.indexOf('merhaba')>=0)",
    prompt: "#{APP}/shadow adresine git. Shadow DOM içindeki Mesaj alanına 'merhaba' yaz ve 'Onayla' düğmesine bas. Sonucu söyle.",
    check: lambda do |mcp, _answer|
      text = mcp.call("browser_evaluate", {
        "script" => "var r = document.getElementById('result'); return r ? r.textContent : ''"
      })
      text.to_s.downcase.include?("shadow sonuç") && text.to_s.include?("merhaba")
    end
  },
  "upload" => {
    desc: "dosya yükleme alanına dosya ver",
    assert_js: "return String(((document.getElementById('out')||{}).textContent||'').indexOf('agent_upload.txt') >= 0)",
    prompt: "#{APP}/upload adresine git. Dosya alanına /tmp/agent_upload.txt dosyasını yükle ve 'Yükle' düğmesine bas. " \
            "Ekranda dosya adı görünüyor mu söyle.",
    check: lambda do |mcp, _answer|
      text = mcp.call("browser_evaluate", {
        "script" => "var r = document.getElementById('out'); return r ? r.textContent : ''"
      })
      text.to_s.include?("agent_upload.txt")
    end
  },
  "newtab" => {
    desc: "yeni sekmede açılan sayfaya geç",
    prompt: "#{APP}/tabs adresine git. 'Yeni sekmede aç' bağlantısına tıkla, açılan yeni sekmeye geç ve sayfadaki gizli değeri söyle.",
    check: lambda do |mcp, _answer|
      tabs = mcp.call("browser_tabs", { "action" => "list" })
      text = mcp.call("browser_evaluate", { "script" => "return document.body.innerText" })
      tabs.to_s.include?("/tab2") && text.to_s.include?("42")
    end
  },
  "dynamic" => {
    desc: "dinamik içeriği bekle, kaydır, say",
    assert_js: "return String(document.querySelectorAll('#list li').length >= 10)",
    prompt: "#{APP}/dynamic adresine git. Liste dolduktan sonra sayfayı en alta kaydır, yeni kayıtların gelmesini bekle " \
            "ve toplam kaç kayıt olduğunu söyle.",
    check: lambda do |mcp, _answer|
      count = mcp.call("browser_evaluate", {
        "script" => "return String(document.querySelectorAll('#list li').length)"
      })
      count.to_i >= 10
    end
  },
  "download" => {
    desc: "PDF indirmeyi bekle ve dosya adını doğrula",
    assert_js: "return String(document.title)",
    prompt: "#{APP}/ adresine git. 'Rapor indir (PDF)' bağlantısına tıkla, indirmenin tamamlanmasını bekle " \
            "ve indirilen dosyanın adını söyle.",
    check: lambda do |mcp, answer|
      out = mcp.call("browser_wait_for", {
        "type" => "download", "text" => "agent_rapor.pdf", "timeout" => 20
      })
      dir = File.expand_path("artifacts/downloads-#{ENV['BENCH_MCP_PORT'] || 19_420}", __dir__)
      file = File.join(dir, "agent_rapor.pdf")
      out.include?("indirme tamamlandı") && File.exist?(file) && File.size(file).positive? &&
        answer.to_s.include?("agent_rapor.pdf")
    end
  },
  "magaza" => {
    desc: "Mağaza (yerel): sıralama menüsü → en ucuz ayakkabı → sepete 4 adet",
    prompt: "Şu sayfaya git: #{APP}/magaza .\n" \
            "1) 'Önerilen Sıralama' düğmesine tıkla, açılan menüden 'Fiyat - Düşükten Yükseğe' seçeneğini seç.\n" \
            "2) Listede en ucuz AYAKKABI ürününü seç (bakım süngeri gibi ürünleri atla) ve 'Sepete Ekle' düğmesine bas.\n" \
            "3) Sepette adet 4 olana kadar devam et (artı düğmesi, adet alanı veya 'Sepete Ekle').\n" \
            "4) Cevap vermeden önce snapshot al ve sepette '4 ürün' yazdığını doğrula.\n" \
            "Son durumu kısaca söyle: ürün, adet ve toplam tutar.",
    check: lambda do |mcp, _answer|
      state = mcp.call("browser_evaluate", {
        "script" => "return document.getElementById('sepet-adet').textContent + '|' + document.getElementById('sepet-detay').textContent"
      }).to_s
      parcalar = state.split("|", 2)
      parcalar[0].to_s.strip == "4" && parcalar[1].to_s.include?("Ayakkabı") && parcalar[1].to_s.include?("x 4")
    end
  },

  # ---------------------------------------------------------------------------
  # SITE-NÖTR GÖREV: hedef yalnızca ortam değişkeninden gelir.
  # Repoda site adı, alan adı veya siteye özgü CSS seçici YOKTUR. Amaç,
  # aracın herhangi bir arama/listeleme sayfasında aynı algoritmayla
  # çalıştığını ölçmek: arama kutusunu bul → ara → sonuç sayfasında fiyat
  # taşıyan ilk ürünü oku.
  #   SELENIT_TARGET_URL=https://... SELENIT_TARGET_TERM=... ruby benchmark.rb sitenotr
  # ---------------------------------------------------------------------------
  "sitenotr" => {
    desc: "Site-nötr: arama yap, sonuç sayfasındaki ilk ürünün adını ve fiyatını oku",
    prompt: lambda do
      hedef = ENV["SELENIT_TARGET_URL"].to_s
      terim = ENV["SELENIT_TARGET_TERM"].to_s
      raise "SELENIT_TARGET_URL ve SELENIT_TARGET_TERM tanımlı olmalı" if hedef.empty? || terim.empty?
      "Şu adrese git: #{hedef}\n" \
      "1) Sayfada arama/giriş alanı varsa içine '#{terim}' yaz ve gönder (submit).\n" \
      "   ÖNEMLİ: dump'ta ilk sırada bir 'Arama' BAĞLANTISI (a etiketi) varsa önce\n" \
      "   ona tıkla — asıl arama kutusu ondan sonra açılır. Doğrudan linke yazmaya\n" \
      "   çalışırsan 'öğe tıklanamıyor' hatası alırsın.\n" \
      "2) Arama kutusu doğrudan input değil de bir düğme/başlıksa önce ona tıkla, açılan alana yaz.\n" \
      "3) Arama kutusu HİÇ YOKSA veya açılmıyorsa (dump'ta [KAPALI] / [ERİŞİLEMEZ] yazıyorsa, " \
      "ya da tıklama 'öğe var ama tıklanamıyor' hatası veriyorsa): arama kutusunda ISRAR ETME. " \
      "Bunun yerine sayfadaki mevcut bağlantılarda '#{terim}' ile eşleşen bir hedef ara " \
      "(browser_find kullan) ve en yakın olana tıkla. Bulamazsan görevi 'arama kutusu yok, " \
      "şu bağlantılar var' diyerek cevapla.\n" \
      "4) Sonuç sayfası geldiğinde, SAYFANIN TÜRÜNE göre cevap ver:\n" \
      "   - Liste/ürün sayfasıysa (fiyat görünüyorsa): ilk sonucun adını ve fiyatını yaz.\n" \
      "   - Kurumsal/ürün-detay sayfasıysa (fiyat YOKSA): arama sonucunda çıkan ilk\n" \
      "     anlamlı başlığı ve ona giden bağlantının adresini yaz. Fiyat UYDURMA.\n" \
      "   - 404/hata sayfasına düştüysen: bunu açıkça söyle ve arama terimini tekrar\n" \
      "     denemek yerine elde ettiğin sonucu bildir.\n" \
      "5) Fiyat varsa 'ürün | fiyat', yoksa 'sonuç | adres' formatında ver."
    end,
    # Ölçüt CEVABA bakar, sayfa durumuna değil: model doğru ürün+fiyatı
    # söylediyse görev tamamdır. (Sayfa metnini de şart koşmak, arama sonrası
    # farklı bir görünüme geçen sitelerde yanlış negatif üretiyordu.)
    check: lambda do |_mcp, answer|
      a = answer.to_s
      # Fiyatlı sonuç VEYA (fiyatsız sitede) anlamlı bir sonuç + adres.
      # Fiyat deseni: "1.970,99 TL", "690,00 TL" ve kırpılmış "250+" gibi
      # biçimleri de kabul et (model cevabı 130 karakterde kesilebiliyor).
      # Fiyat deseni: "1.970,99 TL" (birim sonda) VE "₺ 4.873.000" /
      # "$19.99" (birim başta) biçimlerinin ikisini de kabul et.
      fiyatli = a.match?(/\d[\d.,]*\s*(?:TL|₺|\$|€|£)/) ||
                a.match?(/(?:₺|\$|€|£)\s*\d[\d.,]*/) ||
                a.match?(/\d[\d.,]{2,}\s*\+/)
      adresli = a.match?(/https?:\/\/\S+|\/\S+\.html|başlık|sonuç|link/i)
      return false unless fiyatli || adresli

      # Ürün adı kontrolü BİÇİM BAĞIMSIZ olmalı: model bazen "ürün | ad fiyat |
      # 99,90 TL" gibi fazladan ayraç/etiket ekliyor ve split("|",2) ile alınan
      # ilk parça "ürün " (5 karakter) kalıyordu → yanlış negatif.
      # Bu yüzden ayraçlara ve şablon etiketlerine bakılmaz: cevapta fiyat
      # deseninin DIŞINDA en az 10 karakterlik bir metin var mı diye bakılır.
      sade = a.gsub(/\d[\d.,]*\s*(?:TL|₺|\$|€|£)/, " ")
              .gsub(/\b(ürün|urun|fiyat|ad|isim|product|price)\b/i, " ")
              .gsub(/[|:·—\-]/, " ")
              .gsub(/\s+/, " ")
              .strip
      # Eşik 5: kısa ama anlamlı ürün adları ("Kalem") elenmemeli.
      # Şablon cevabı ("ürün | fiyat") zaten fiyat dışı metin bırakmaz.
      sade.length >= 5
    end
  },

  # ---------------------------------------------------------------------------
  # AŞAMA-2 / S2 — SIRALAMA + FİYAT ARALIĞI + LİSTE→DETAY (ilan no + fiyat).
  # Ölçtüğü üç yetenek:
  #   1) Özel açılır menü (button + role=option): "Ucuzdan Pahalıya" seçimi.
  #   2) Aralık filtresi: iki metin alanı (min/max) + uygula düğmesi.
  #   3) Liste → detay geçişi: detay sayfasında ilan no + fiyatı AYNI yerden okuma
  #      ve cevabın gerçekten o ilana ait olması (uydurma no yakalanır).
  # Site-nötr: hedef ve filtre değerleri ENV'den; repoda site adı/seçici yok.
  #   SELENIT_TARGET_URL=... SELENIT_FILTER_MIN=... SELENIT_FILTER_MAX=... \
  #   SELENIT_SORT_LABEL="Ucuzdan Pahalıya" ruby benchmark.rb filtre2
  # ---------------------------------------------------------------------------
  "filtre2" => {
    desc: "Site-nötr: sırala + fiyat aralığı filtrele, ilk ilanın no ve fiyatını getir",
    prompt: lambda do
      hedef = ENV["SELENIT_TARGET_URL"].to_s
      raise "SELENIT_TARGET_URL tanımlı olmalı" if hedef.empty?

      siralama = ENV["SELENIT_SORT_LABEL"].to_s
      min = ENV["SELENIT_FILTER_MIN"].to_s
      max = ENV["SELENIT_FILTER_MAX"].to_s
      aralik = (min.empty? && max.empty?) ? "" : "#{min} - #{max}"

      adimlar = []
      # Her adım tek cümle: model adım adım ilerlesin, atlamasın.
      adimlar << "1) Sıralama kutusunu aç (üstünde 'Sıralama' veya 'Önerilen' yazar) " \
                 "ve açılan listeden '#{siralama}' seçeneğini seç." unless siralama.empty?
      adimlar << "#{adimlar.size + 1}) Fiyat filtresini aç (üstünde 'Fiyat' yazar). " \
                 "Açılan panelde iki metin alanı olur: en az #{min}, en çok #{max}. " \
                 "Bu alanlara değerleri yaz, sonra 'Filtrele' düğmesine bas." unless aralik.empty?
      adimlar << "#{adimlar.size + 1}) Sonuç listesinde SPONSORLU/REKLAM kartlarını atla " \
                 "(kart üstünde 'Sponsorlu'/'Reklam' yazar ya da filtreye uymaz). " \
                 "ORGANİK ilk ilanın başlığına tıkla ve detay sayfasını aç."
      adimlar << "#{adimlar.size + 1}) Detay sayfası açılınca DOM tamamen değişir; eski ref'ler " \
                 "geçersizdir. Yeniden browser_snapshot al. İlan numarasını ve fiyatı AYNI " \
                 "ilanın içinden oku; iki değeri farklı yerlerden toplama."
      adimlar << "#{adimlar.size + 1}) Fiyatı göremiyorsan 'fiyat yok' yaz, UYDURMA. " \
                 "İlan numarasını göremiyorsan 'ilan no yok' yaz."

      "Şu adrese git: #{hedef}\n" \
      "#{adimlar.join("\n")}\n" \
      "Son olarak cevabını TEK satırda tam olarak şu biçimde ver: " \
      "'ilan | <ilan no veya ilan no yok> | <fiyat veya fiyat yok>'"
    end,
    # Ölçüt İKİ bağımsız sinyale bakar; ikisi de sayfadan gelir, cevaba güvenmez:
    #   A) Filtre gerçekten uygulandı mı? (detay sayfasında min/max hâlâ taşınıyorsa)
    #   B) Cevaptaki ilan no bu detay sayfasının no'su mu? (uydurma no kapatılır)
    # Sayfa hiç no göstermiyorsa (bazı siteler no'yu yalnızca API'de tutar) B
    # atlanır ve yalnızca biçim + fiyatın sayfada geçmesi aranır.
    check: lambda do |mcp, answer|
      a = answer.to_s
      deger = lambda do |js|
        begin
          mcp.call("browser_evaluate", { "script" => js }).to_s.lines.first.to_s.strip
        rescue StandardError
          ""
        end
      end

      fiyatli = a.match?(/\d[\d.,]*\s*(?:TL|₺|\$|€|£)/i) || a.match?(/(?:₺|\$|€|£)\s*\d[\d.,]*/)
      no = a.scan(/\d{6,12}/).first

      sayfa_no = deger.call(<<~JS)
        var o = [];
        o.push(location.href);
        var t = document.body ? document.body.innerText : '';
        var m = t.match(/\\b\\d{6,12}\\b/g) || [];
        return o.concat(m).join(',');
      JS
      sayfa_url = deger.call("return location.href")

      # A) Filtre URL'de ya da detay sayfasında taşınıyor mu? (değerler ENV'den)
      min = ENV["SELENIT_FILTER_MIN"].to_s
      max = ENV["SELENIT_FILTER_MAX"].to_s
      filtre_var = [min, max].reject(&:empty?).all? { |v| sayfa_no.include?(v) || sayfa_url.include?(v) }
      # Detay sayfasına geçildiyse filtre querystring'de kalır; cevap biçimi +
      # ilan no pinlemesi asıl kanıt. Filtre hiç uygulanmadıysa FAIL.
      next false unless filtre_var
      next false unless fiyatli

      # B) Pinleme: cevaptaki no bu sayfanın no'su mu?
      adaylar = sayfa_no.scan(/\d{6,12}/)
      next true if adaylar.empty? # sayfa no vermiyor: biçim + filtre yeterli
      next false if no.nil?

      # C) Cevaptaki fiyat da sayfada geçmeli: model başka bir ilanın fiyatını
      # yazarsa (ya da uydurursa) burada yakalanır.
      cevap_fiyat = a.scan(/\d[\d.,]*/).max_by(&:length).to_s
      sayfa_metni = deger.call("return document.body ? document.body.innerText : ''")
      fiyat_dogru = !cevap_fiyat.empty? && sayfa_metni.delete(" ").include?(cevap_fiyat.gsub(/\.(?=\d{3}\b)/, "")) ||
                    sayfa_metni.include?(cevap_fiyat)
      next false unless fiyat_dogru

      adaylar.include?(no)
    end
  }
}.freeze