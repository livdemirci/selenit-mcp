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
  "sepet" => {
    desc: "Trendyol: arama → en düşük fiyat → sepete ekle → sepette fiyat doğrulama",
    prompt: "Gerçek Trendyol sitesinde alışveriş akışını sırayla yap, her adımı beklediği gibi yapmadan diğerine geçme:\n" \
            "1) https://www.trendyol.com adresine git.\n" \
            "2) Açılışta engelleyici pencere/bant varsa kapat (X düğmesi veya 'Tümünü Reddet').\n" \
            "3) Arama kutusuna 'kulaklık' yaz ve Enter'a bas.\n" \
            "4) Sonuç sayfasında sıralama seçeneğini 'En Düşük Fiyat' yap. URL'de sst=PRICE_BY_ASC olmalı.\n" \
            "5) Sonuç listesindeki ilk ürün kartının adını ve fiyatını söyle.\n" \
            "6) Bu ürünün 'Sepete Ekle' düğmesine bas ve eklenmesini bekle.\n" \
            "7) 'Sepetim' bağlantısıyla sepet sayfasına git.\n" \
            "8) Sepet sayfasında aynı ürünün fiyatını oku; kart fiyatıyla AYNI mı söyle.\n" \
            "Cevapta şu formatta ver: ürün | kart fiyatı | sepet fiyatı | eşleşme: evet/hayır | sst var mı.",
    check: lambda do |mcp, answer|
      url = mcp.call("browser_evaluate", { "script" => "return location.href" })
      # Sepete ulaşıldı mı? Ürün/cevap en azından bir fiyat bilgisi taşımalı.
      url.to_s.include?("sepetim") && answer.to_s =~ /\d+[\.,]\d{2}\s*TL/
    end
  },
  "hepsi" => {
    desc: "Hepsiburada: arama → en düşük fiyat → ilk satılabilir ürünü sepete ekle → sepette fiyat doğrulama",
    prompt: "Gerçek Hepsiburada sitesinde alışveriş akışını sırayla yap:\n" \
            "1) https://www.hepsiburada.com adresine git.\n" \
            "2) Ara çubuğuna 'kulaklık' yaz ve Enter'a bas.\n" \
            "   ÖNEMLİ: yazmadan önce arama inputunu TIKLA (input[aria-label='Site içinde ara']) —\n" \
            "   sanal/sahte input farklı bir eleman olabilir.\n" \
            "3) Sonuç sayfasında sıralama denetimini aç (div[class*='dropdown-cf']) ve\n" \
            "   'En düşük fiyat' seçeneğine bas. URL'de siralama=artanfiyat olmalı.\n" \
            "4) Sonuç listesindeki İLK organik ürünün adını ve fiyatını söyle.\n" \
            "   DİKKAT: listeye reklam kartları karışır; başında 'Reklam' olmayan kartı seç.\n" \
            "5) O kartın sepete ekleme ikonunu bas — düğme metni YOK:\n" \
            "   [class*='productListContent-'] li article svg[class*='spinnerIcon']\n" \
            "6) Toast oku: 'Ürün sepete eklendi' çıkmadıysa ve 'geçici olarak temin edilemiyor'\n" \
            "   hatası varsa stoksuzdur → bir SONRAKİ satılabilir ürüne geç ve yazıya yaz.\n" \
            "   Toast hiç GELMEDİYSE de ürün tepki vermemiş sayılır: taze snapshot al,\n" \
            "   SIRADAKİ 'Sepete ekle ikonu' ref'ine geç (aynı ref'e 3 kez tıklamak döngü hatasıdır).\n" \
            "7) 'Sepetim' ile sepette gel; sepetteki ürün adı ve fiyatını oku.\n" \
            "Cevapta şu formatta ver: ürün | kart fiyatı | sepet fiyatı | eşleşme: evet/hayır | toast: okuma",
    check: lambda do |mcp, answer|
      url = mcp.call("browser_evaluate", { "script" => "return location.href" })
      url.to_s.include?("sepet") && answer.to_s =~ /\d+[\.,]\d{2}\s*TL/
    end
  }
}.freeze
