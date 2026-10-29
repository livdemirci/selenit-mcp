// Kompakt sayfa dökümü: görünür/etkileşimli öğeler; shadow DOM dahil.
// Küçük modeller (Gemma E4B) için kısa tutulur; her öğeye data-sl-ref="eN" yazılır.
// - Açık modal varsa yalnızca modal içeriği listelenir (arka plan gürültüsü gitmez).
//   Modal tespiti artık role=dialog/aria-modal dışında class sinyalleriyle de yapılır
//   (ör. e-ticaret'un .modal-container'ı role taşımaz); aday, görünüp ekran merkezini
//   kapatıyorsa modal sayılır.
// - role arzı olmayan engelleyici öğeler (çerez bandı, bildirim kutusu gibi
//   position:fixed + yüksek z-index overlay'ler) ilk MAX'e sweep öncelikle girer.
// - Özel açılır menülerin tıklanabilir seçenekleri (div/li, class'ında option
//   veya menu-item geçen) de döküme girer; role küçük sitelerde yok.
// - Tablo satırlarındaki düğmelere satır bağlamı eklenir: "Düzenle | 3 Ada Lovelace Londra".
return (function (maxElements) {
  var MAX = maxElements || 40;
  var q = 'a[href],button,input,textarea,select,summary,iframe,' +
          '[role=button],[role=link],[role=textbox],[role=checkbox],[role=tab],' +
          '[role=option],[role=menuitem],' +
          // WEB COMPONENT'LER (custom element). Kurumsal tasarım sistemleri
          // arama kutusunu <fss-search-input>, <my-search>, <x-search> gibi
          // tire içeren özel etiketlerle render eder. Bu etiketler yukarıdaki
          // selector'lerin HİÇBİRİNE uymaz, dolayısıyla arama kutusu dump'a
          // hiç girmez ve görev ilk adımda ölür. Ölçüm: bir kurumsal sitede
          // sayfada hiç <input> yoktu; arama <fss-search-input> içindeydi.
          // Genel kural: adında aria/role/search sinyali taşıyan custom
          // element'leri de tara (tire = custom element göstergesi).
          '*[class*="search" i],*[class*="arama" i],' +
          // Tag adında search/arama geçen custom element'ler. CSS selector
          // tag adına göre joker kabul etmez; bu yüzden yaygın adları
          // açıkça listeliyoruz ve walk() ayrıca tire içeren etiketleri tarar.
          'fss-search-input,search-input,x-search,my-search,site-search,' +
          'header-search,search-box,search-bar,' +
          // Toast'lar (başarı/hata bildirimleri) model için önemlidir: "Ürün sepete
          // eklendi", "ürün temin edilemiyor" gibi dönütleri görünür kılar.
          '[role=alert],[role=status],' +
          // liste sitesi vb. siteler toast'lara role vermez (hb-toast-notifier-*).
          '[class*="toast" i],' +
          // Sepete ekleme ikonu metinsiz SVG'dir (HBI spinnerIcon); kart
          // bağlamıyla vermek modelin hedef bulmasını sağlar.
          'svg[class*="spinnerIcon" i],svg[class*="addToCart" i],' +
          'div[class*="option" i],li[class*="option" i],' +
          'div[class*="menu-item" i],li[class*="menu-item" i],' +
          // Özel açılır menüler (combobox/dropdown) çoğu sitede role taşır:
          // sıralama, beden/varyant seçimi gibi tetikleyiciler görünür olsun.
          '[aria-haspopup],[aria-expanded],[role=combobox],[role=menu],' +
          '[role=listbox] li,[role=listbox] [role=option],' +
          // Tasarım sistemi seçenekleri (b-select-option, select-option ...).
          '[class*="select-option" i],[class*="select__option" i],' +
          '[onclick],[contenteditable="true"]';

  // Görünürlük: yalnızca öğenin kendi stiline bakmak YETMEZ. Öğe 0x0
  // olabilir ya da atası opacity:0 / display:none ile gizlenmiş olabilir
  // (hover/focus ile açılan arama kutuları böyle çalışır).
  // Ölçüm: bir kurumsal sitede arama kutusu <fss-search-input> 0x0 boyutta
  // ve atası opacity:0 idi; kullanıcı fareyi üzerine getirince mercek ikonu
  // beliriyor. Bu durumda öğe "görünmez" sayılıp dump'tan atılıyor ve model
  // arama kutusunun varlığını hiç öğrenemiyordu.
  // Çözüm: gizli olsa da ARAMA/GİRİŞ sinyali taşıyan öğeler "kapalı" olarak
  // işaretlenip yine de dump'a alınır; model önce tetikleyiciye dokunur.
  function gorunurluk(el) {
    var rect = el.getBoundingClientRect();
    var boyut = rect.width > 0 && rect.height > 0;
    var style = window.getComputedStyle(el);
    var kendiGizli = style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0';
    // Atalarda gizlilik var mı (en fazla 6 seviye)
    var ataGizli = false;
    var p = el.parentElement;
    for (var d = 0; d < 6 && p && p !== document.body; d++, p = p.parentElement) {
      var ps = window.getComputedStyle(p);
      if (ps.display === 'none' || ps.visibility === 'hidden' || ps.opacity === '0') { ataGizli = true; break; }
    }
    return { boyut: boyut, gizli: kendiGizli || ataGizli, disabled: !!el.disabled };
  }

  // Ölçüldü (2026-10-29): bir ilan sitesinde "Fiyat" filtresi açıldıktan sonra
  // iki metin alanı (placeholder Min/Max) hiçbir dump'a girmiyordu; alanlar
  // görünür, boyutlu ve disabled DEĞİLDİ. Neden: alanın ATALARINDAN biri
  // role=dialog/aria-modal taşıyordu ve "açık modal varsa yalnızca modalı tara"
  // kuralı tarama kökünü o kutuya daraltıyordu. Oysa metin alanı form
  // denetimidir: her zaman listelenmeli. Bu yüzden giriş alanları için
  // görünürlük kuralı ayrı: yalnızca boyut + disabled bakılır, atalardaki
  // gizlilik sinyali yok sayılır (Selenium zaten görünür olmayan alana
  // yazmayı reddedip net hata verir; yanlış eleme ise görevi sessizce öldürür).
  function giris_gorunur(el) {
    if (el.disabled) return false;
    var r = el.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) return false;
    var st = window.getComputedStyle(el);
    return !(st.display === 'none' || st.visibility === 'hidden');
  }

  function visible(el) {
    var t = (el.tagName || '').toLowerCase();
    if (t === 'input' || t === 'textarea' || t === 'select') {
      if (giris_gorunur(el)) return true;
    }
    var v = gorunurluk(el);
    if (v.disabled) return false;
    if (v.boyut && !v.gizli) return true;
    // Görünmez ama ARAMA sinyali taşıyorsa yine de listele (kapalı işaretli).
    return !!(el.tagName && el.tagName.indexOf('-') > 0 && /search|such|arama/i.test(el.tagName));
  }

  function clearRefs(root) {
    root.querySelectorAll('[data-sl-ref]').forEach(function (el) {
      el.removeAttribute('data-sl-ref');
    });
    root.querySelectorAll('*').forEach(function (el) {
      if (el.shadowRoot) clearRefs(el.shadowRoot);
    });
  }
  clearRefs(document);

  var items = [];
  var total = 0;
  var ziyaret = [];

  function goruldu(el) {
    var i = ziyaret.indexOf(el);
    if (i !== -1) return true;
    ziyaret.push(el);
    return false;
  }

  // Fiyat deseni: ürün kartı bağlamını sınıf adına bağlı kalmadan bulmak için.
  // Tek ve esnek fiyat deseni — iki ayrı tanım çakışıyordu (biri yalnızca
  // kuruşlu "57,97 TL", öteki yalnızca "399 TL" yakalıyordu). Hem "166,84 TL"
  // hem "172 TL" hem "1.299,00 ₺" eşleşmeli.
  var FIYAT_RE = /\d[\d.,]*\s*(?:TL|₺|\$|€|£|USD|EUR)\b|(?:₺|\$|€|£)\s*\d/i;

  function describe(el) {
    var name = (el.getAttribute('aria-label') ||
                el.innerText ||
                el.value ||
                el.getAttribute('placeholder') ||
                el.getAttribute('alt') ||
                el.getAttribute('title') ||
                el.getAttribute('src') || '')
               .replace(/\s+/g, ' ').trim();

    // Metinsiz custom element: <fss-search-input> gibi öğelerin içi kapalı
    // olduğu için metni boş gelir. Model için anlamlı bir etiket üret.
    if (!name) {
      var ct = (el.tagName || '').toLowerCase();
      // Yalnızca CUSTOM ELEMENT'ler için tag adından etiket üret.
      // Sıradan etiketler (svg/div/span) için isim BOŞ kalsın; aksi halde
      // aşağıdaki "metinsiz sepete ekleme ikonu" kuralı ezilir (regresyon).
      if (ct.indexOf('-') > 0) {
        name = /search|arama|sorgu|query/.test(ct) ? 'Arama kutusu' : ct;
      }
    }

    // Metinsiz sepete ekleme ikonuna okunur ad ver (HBI spinnerIcon katmanı).
    if (!name && /^svg$/i.test(el.tagName || '') &&
        /spinnerIcon|addToCart/i.test(el.getAttribute('class') || '')) {
      name = 'Sepete ekle ikonu';
    }

    // Satır bağlamı: aynı etiketli düğmeleri ayırt etmek için (tablo/liste)
    var row = el.closest ? el.closest('tr,li,[role=row]') : null;
    if (row) {
      var cells = row.querySelectorAll('td,th');
      var parts = [];
      for (var i = 0; i < cells.length; i++) {
        var t = (cells[i].innerText || '').replace(/\s+/g, ' ').trim();
        if (t && t !== name) parts.push(t);
      }
      var ctx = parts.join(' · ');
      if (ctx) name = name + ' | ' + ctx.slice(0, 50);
    }

    // Ürün kartı bağlamı: kart/tablo dışında aynı etiketle tekrar eden
    // düğmeleri (ör. "Sepete Ekle") ayırt etmek için kart başlığı + fiyat
    // eklenir: "Sepete Ekle | CEPFİT ... · 57,97 TL".
    // ------------------------------------------------------------------
    // KART BAĞLAMI — ALGORİTMİK
    // ------------------------------------------------------------------
    // Eski yaklaşım `closest('[class*=productCard]')` ile en yakın sınıf
    // eşleşmesini alıyordu. liste-sayfası ölçümü: bu, fiyatı TAŞIMAYAN
    // `a.productCardLink` öğesine denk geliyor, fiyat kardeş <div>'de
    // kalıyordu → dump'ta hiç fiyat görünmüyordu.
    //
    // Artık sıra: (1) yukarı yürü, fiyat sinyali taşıyan İLK ATA kart;
    //              (2) kart havuzu üyesi ilk ata (yapısal tekrar);
    //              (3) hiçbiri yoksa kart bağlamı yok.
    // Böylece sınıf adına değil, sayfada ölçülen iki sinyale dayanır.
    var kart = null;
    var p1 = el;
    for (var dp = 0; dp < 8 && p1 && p1 !== document.body; dp++, p1 = p1.parentElement) {
      if (dp === 0 && el === row) continue;              // satır kendisi sayılmaz
      var t1 = p1.innerText || '';
      if (t1.length >= 8 && t1.length <= 420 && FIYAT_RE.test(t1)) {
        // Kart içinde makul sayıda denetim olmalı (tüm sayfa değil).
        var k1 = p1.querySelectorAll ? p1.querySelectorAll('a,button,input,select,textarea').length : 0;
        if (k1 <= 6) { kart = p1; break; }
      }
    }
    if (!kart) {
      var p2 = el.parentElement;
      for (var dq = 0; dq < 6 && p2 && p2 !== document.body; dq++, p2 = p2.parentElement) {
        var c2 = (typeof p2.className === 'string' ? p2.className : '').trim().split(/\s+/)[0];
        if (c2 && kartHavuzu[c2]) { kart = p2; break; }
      }
    }
    // Kart kendisi de olabilir; fiyat her durumda eklensin.
    // NOT: eski `kart !== row` koşulu liste sitesi'da bloğu tümüyle atlıyordu
    // (kart <li> ile aynı öğeydi ve row'a eşit çıkıyordu) → fiyat hiç
    // görünmüyordu. Satır bağlamı zaten üstte ayrıca işlendi.
    if (kart) {
      var satirlar = (kart.innerText || '').split('\n').map(function (s) {
        return s.replace(/\s+/g, ' ').trim();
      }).filter(Boolean);
      var fiyat = '';
      for (var f = 0; f < satirlar.length; f++) {
        // "57,97 TL" gibi kısa fiyat satırları; üstü çizili ve Plus fiyatını geç.
        if (FIYAT_RE.test(satirlar[f]) && satirlar[f].length <= 24) { fiyat = satirlar[f]; break; }
      }
      var baslik = '';
      for (var b = 0; b < satirlar.length; b++) {
        var s = satirlar[b];
        if (s === fiyat || s === name) continue;
        if (/^(var|yok|sepete ekle|sepete ekleme)$/i.test(s)) continue;
        if (s.length <= 8) continue;
        if (!baslik || s.length > baslik.length) baslik = s;
      }
      // Fiyat sona yakınsa kaybolmasın: başlık kırpılır, fiyat korunur.
      // Fiyat HER ZAMAN eklenir (model fiyatı görmeli). Başlık yalnızca
      // elementin kendi adı kısa/genel olduğunda eklenir — ürün adını taşıyan
      // uzun isimlere başlık tekrarı yazılmaz.
      var baslikEkle = (kart !== el) && name.length < 24 && baslik && name.indexOf(baslik) === -1;
      var kctx = baslikEkle ? baslik.slice(0, 42) : '';
      if (fiyat) kctx = (kctx ? kctx + ' · ' : '') + fiyat;
      kctx = kctx.slice(0, 60);
      if (kctx) name = name + ' | ' + kctx;
    }

    if (name.length > 90) name = name.slice(0, 90) + '…';
    return {
      tag: el.tagName.toLowerCase(),
      type: (el.getAttribute('type') || '').toLowerCase(),
      name: (function () {
        var kapali = false;
        try { var v = gorunurluk(el); kapali = (v.gizli || !v.boyut); } catch (e) { kapali = false; }
        var etiket = name;
        if (aramaIsareti(el)) etiket = 'ARAMA KUTUSU: ' + etiket;
        // Kapalı ama etkileşimli öğe: model önce üzerine gelmeli/tıklamalı.
        // Kapalı öğe için modeli DOĞRU eyleme yönlendir.
        // Ölçüm: bir kurumsal sitede arama kutusu <fss-search-input> içinde
        // closed-shadow DOM kullanıyor; programatik tıklama (Selenium click)
        // bile açmıyor, yalnızca gerçek fare ile açılıyor. Model bunu bilmezse
        // aynı ref'e 3 kez tıklayıp döngüye giriyor ve görev ölüyor.
        if (kapali && etiket) {
          var kilitli = false;
          try {
            var sr = el.shadowRoot;
            var ct2 = (el.tagName || '').toLowerCase();
            // Custom element + shadowRoot yok → büyük olasılıkla closed shadow.
            // AMA: shadowRoot VARSA erişilebilir demektir; kapalı etiketi koyma.
            kilitli = ct2.indexOf('-') > 0 && !sr;
            // Kapalı etiketi yalnızca GERÇEKTEN erişilemezse anlamlı:
            // boyut sıfırsa ve shadow yoksa.
            if (kilitli) {
              var rr = el.getBoundingClientRect();
              if (rr.width > 0 && rr.height > 0) {
                // Görünür boyutu var: kapalı olabilir ama erişilebilir olma
                // ihtimali yüksek → "önce tıkla" demek daha doğru.
                kilitli = false;
              }
            }
          } catch (e) { kilitli = false; }
          etiket = etiket + (kilitli
            ? ' [KAPALI/ERİŞİLEMEZ — tıklama çalışmayabilir, alternatif yol kullan]'
            : ' [KAPALI — önce tıkla/hover]');
        }
        return etiket;
      })(),
      href: el.getAttribute('href') || el.getAttribute('src') || ''
    };
  }

  // Arama kutusu işareti: model bir <input>'un placeholder'ı dinamik ürün
  // önerisi taşıdığında (ör. "Philips Hue GO , 3851 TL") onu arama kutusu
  // olarak tanıyamıyor ve görev ilk adımda ölüyor. Dump'a açık işaret koy.
  // Ölçüt site-nötr: type=search, form içindeki ilk metin alanı, etikette
  // ara|search|sorgu geçmesi, ya da sayfadaki TEK görünür metin alanı olması.
  // Modern siteler aramayı <button>/<div role=combobox> olarak render edip
  // tıklanınca input açıyor; bu durumda da işaret konur (model önce tıklar).
  function aramaIsareti(el) {
    var tag = (el.tagName || '').toUpperCase();

    if (tag !== 'INPUT' && tag !== 'TEXTAREA') {
      // Input olmayan arama tetikleyicisi: görünen etiketi/erişilebilirlik
      // adı arama anlamı taşıyan düğme/div. DİKKAT: yalnızca buton/div —
      // <a> elenir, çünkü href'i "/arama?..." olan kampanya/kategori
      // linkleri arama kutusu sanılıyordu.
      if (tag !== 'BUTTON' && tag !== 'DIV') return false;
      var metin = (el.innerText || '').trim().replace(/\s+/g, ' ');
      if (metin.length === 0 || metin.length > 40) return false;
      var adt = ((el.getAttribute('aria-label') || '') + ' ' +
                 (el.getAttribute('placeholder') || '') + ' ' +
                 (el.getAttribute('title') || '') + ' ' +
                 metin + ' ' +
                 (typeof el.className === 'string' ? el.className : '')).toLowerCase();
      // Arama ANLAMI taşımalı; href'e BAKILMAZ.
      return /(^|[^a-z])(ara|arama|search|sorgu|query)([^a-z]|$)/.test(adt);
    }

    var METIN = { text: 1, search: 1, email: 1, tel: 1, url: 1, number: 1, password: 1, '': 1 };
    var tip = (el.getAttribute('type') || '').toLowerCase();
    if (el.tagName === 'INPUT' && !METIN[tip]) return false;
    var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
    if (!r || r.width <= 0 || r.height <= 0) return false;

    if (tip === 'search') return true;
    if (el.form) {
      var ilk = el.form.querySelector('input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit])');
      if (ilk === el) return true;
    }
    var ad = ((el.getAttribute('placeholder') || '') + ' ' +
              (el.getAttribute('aria-label') || '') + ' ' +
              (el.getAttribute('name') || '') + ' ' +
              (el.getAttribute('id') || '')).toLowerCase();
    if (/(^|[^a-z])(ara|arama|search|sorgu|query)([^a-z]|$)/.test(ad)) return true;

    // Sayfadaki tek görünür metin alanı → kesinlikle arama/giriş kutusu.
    var hepsi = document.querySelectorAll('input,textarea');
    var sayi = 0;
    for (var i = 0; i < hepsi.length; i++) {
      var t2 = (hepsi[i].getAttribute('type') || '').toLowerCase();
      if (hepsi[i].tagName === 'INPUT' && !METIN[t2]) continue;
      var r2 = hepsi[i].getBoundingClientRect();
      if (r2.width > 0 && r2.height > 0) sayi++;
    }
    return sayi === 1;
  }

  // Eşleşen tüm öğeleri topla; döküm sırası işaretlemenin SONUNDA belirlenir
  // (overlay öncelik sırasını değiştirmez).
  var toplanan = [];

  function topla(el, inShadow) {
    if (goruldu(el)) return;
    if (!visible(el)) return;
    // Sepete ekleme spinnerIcon/addToCart SVG'leri yalnızca KART içinde
    // anlamlıdır; header başarım/spinner'ları dökümü doldurmasın.
    if (/^svg$/i.test(el.tagName || '') &&
        /spinnerIcon|addToCart/i.test(el.getAttribute('class') || '')) {
      var kartArt = el.closest ? el.closest('article,li,[class*="card"]') : null;
      if (!kartArt) return;
    }
    total++;
    toplanan.push({ el: el, shadow: !!inShadow });
  }

  // Kart havuzundaki sınıf imzaları için selector'ü genişlet: ürün kartları
  // çoğu sitede etkileşimli etiket DEĞİL, sadece <div>. liste-sayfası ölçümü:
  // productCard-module_productInfoRoot div olduğu için q selector'üne hiç
  // uymuyordu → 2797 etkileşimli öğeli sayfada 11 item toplanıyordu.
  function kartSelectorleri() {
    var ks = Object.keys(kartHavuzu);
    var sec = [];
    for (var i = 0; i < ks.length; i++) {
      sec.push('[class~="' + ks[i].replace(/"/g, '\\"') + '"]');
    }
    return sec.join(',');
  }

  // Tag adında tire geçen (custom element) ve adı arama/giriş sinyali taşıyan
  // öğeler: CSS selector bunları joker ile yakalayamaz. Tüm custom
  // element'leri gezip TAG ADI üzerinden süzüyoruz.
  var CUSTOM_ARAMA = /search|arama|sorgu|query|inputbox/i;

  function walk(root, inShadow) {
    var els = root.querySelectorAll(q);
    for (var k = 0; k < els.length; k++) toplama_hedef(els[k], inShadow);

    // Custom element taraması (tag adı bazlı)
    var tum = root.querySelectorAll('*');
    for (var ce = 0; ce < tum.length; ce++) {
      var t = tum[ce].tagName || '';
      if (t.indexOf('-') > 0 && CUSTOM_ARAMA.test(t)) toplama_hedef(tum[ce], inShadow);
    }
    // Kart havuzu üyeleri ayrıca taranır (etkileşimli olmasalar da).
    var ks = kartSelectorleri();
    if (ks) {
      var kartlar = root.querySelectorAll(ks);
      for (var m = 0; m < kartlar.length; m++) toplama_hedef(kartlar[m], inShadow);
    }
    root.querySelectorAll('*').forEach(function (host) {
      if (host.shadowRoot) walk(host.shadowRoot, true);
    });
  }

  function toplama_hedef(el, inShadow) { topla(el, inShadow); }

  // --- Açık modal varsa yalnızca onu tara -------------------------------
  // role=dialog/aria-modal ek yok: class'ı modal/dialog içeren sabit üst
  // katmanlar da aday; görünüp görünür ekran merkezini kapsıyorsa modaldır.
  var modal = null;
  (function () {
    var cands = document.querySelectorAll(
      '[aria-modal="true"],[role="dialog"],dialog[open],' +
      '[class*="modal" i],[class*="dialog" i],[class*="popup" i]');
    var cx = window.innerWidth / 2;
    var cy = window.innerHeight / 2;
    var hit = null;
    try { hit = document.elementFromPoint(cx, cy); } catch (e) { hit = null; }
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i];
      if (!visible(c)) continue;
      if (hit && (hit === c || c.contains(hit))) {
        // En dış kapsayıcıyı seç: içteki adaylar dıştakini ezmeme.
        if (!modal || modal.contains(c)) modal = c;
      }
    }
    // Sağlama: modal içinde tıklanabilir bir şey yoksa poz tutması yanlış;
    // boşsa role/aria dayalı klasik taramaya dön.
    if (modal) {
      var q2 = 'a[href],button,input,textarea,select,[role=button],[role=link],[role=textbox]';
      var icinde = modal.querySelectorAll(q2);
      var gorunen = 0;
      for (var j = 0; j < icinde.length; j++) {
        if (visible(icinde[j]) && icinde[j].getBoundingClientRect().width > 0) gorunen++;
      }
      if (gorunen === 0) modal = null;
    }
  })();

  // --- Engelleme tam katmanlar (overlay önceliği) ------------------------
  // role taşmayan çerez bandı / bildirim kutusu gibi sabit öğeler döküm
  // dışında kalmıştı; bunlar ekranın üst katmanında olduğu için önce listelenir.
  var overlays = [];
  if (!modal) {
    document.querySelectorAll('div,section,aside,header,footer,nav,ul').forEach(function (el) {
      var st = window.getComputedStyle(el);
      if (st.position !== 'fixed' && st.position !== 'absolute') return;
      var zi = parseInt(st.zIndex, 10) || 0;
      if (zi < 400) return;
      if (!visible(el)) return;
      var r = el.getBoundingClientRect();
      if (r.width >= 0.4 * window.innerWidth || r.height >= 0.2 * window.innerHeight) {
        overlays.push(el);
      }
    });
  }

  function overlay_index(el) {
    for (var i = 0; i < overlays.length; i++) {
      if (overlays[i].contains(el)) return i;
    }
    return -1;
  }

  // Ürün kartı önceliği: büyük arama sayfalarında MAX bütçesi header/nav'e
  // gidiyordu (HBI 173 öğe → ilk 40 ALL menü; model ürünleri asla göremiyordu).
  // Ürün kartı içindeki öğeler (sepete ekle ikonu, fiyatlı kart linkleri)
  // menü linklerinden ÖNCE listelenir.
  //
  // KARŞI DENGE (SPA.com ölçümü): ürün kartı önceliği bu kez ters yönde
  // bozuluyordu — 485 etkileşimli öğeli ana sayfada ilk 40 slotu tamamen ürün
  // kartları dolduruyor, header'daki ARAMA KUTUSU hiç sıra alamıyordu.
  // Arama kutusu bir sitenin en kritik kontrolüdür; model onu göremezse görev
  // ilk adımda ölür. Bu yüzden form alanları (input/textarea/select) her zaman
  // ürün kartlarından ÖNCE gelir.
  // Metin girişi alanı mı? (Arama kutusu, form alanı — görevin başlaması için şart.)
  // liste-sayfası ölçümü: buradaki tanım <input> etiketinin TAMAMINI kapsıyordu,
  // dolayısıyla sol filtrenin marka checkbox'ları (rotring, fabercastell, …)
  // "giriş alanı" sayılıp ilk sıraları alıyor ve ürünler döküme hiç girmiyordu.
  // Artık yalnızca metin benzeri alanlar giriş sayılır.
  var METIN_TIPLERI = { text: 1, search: 1, email: 1, tel: 1, url: 1, number: 1, password: 1, '': 1 };

  function giris_alani(el) {
    var t = (el.tagName || '').toLowerCase();
    if (t === 'textarea') return true;
    if (t === 'select') return true;
    if (t !== 'input') return false;
    var tip = (el.getAttribute('type') || '').toLowerCase();
    return !!METIN_TIPLERI[tip];
  }

  // Birincil eylem düğmeleri: "Sepete Ekle", "Satın Al", "Kaydet", "Gönder".
  // SPA ürün sayfası ölçümü: ürün öneri kartları MAX bütçesini doldurup asıl
  // "Sepete Ekle" (BUTTON.add-to-cart-btn) dump'a hiç giremiyordu. Sayfanın
  // ana eylemi, öneri kartlarından her zaman daha önemlidir.
  // e-ticaret ölçümü: arama kutusu <input> DEĞİL — metinsiz bir ikon düğmesi
  // (button[data-testid=suggestion-placeholder]); tıklanınca arama overlay'i
  // açılıyor. Bu yüzden arama-benzeri düğmeler de birincil sayılır.
  function birincil_eylem(el) {
    if ((el.tagName || '').toLowerCase() !== 'button') {
      if (el.getAttribute && el.getAttribute('role') !== 'button') return false;
    }
    var t = (el.innerText || el.value || '').trim();
    var c = (el.getAttribute && el.getAttribute('class') || '').toLowerCase();
    var tid = (el.getAttribute && el.getAttribute('data-testid') || '').toLowerCase();
    var aria = (el.getAttribute && el.getAttribute('aria-label') || '').toLowerCase();
    // Metinsiz arama düğmeleri: data-testid/aria-label/class arama sinyali taşır.
    if (/search|suggestion-placeholder|search-icon|searchbtn/.test(tid + ' ' + aria + ' ' + c)) return true;
    if (!t || t.length > 30) return false;
    if (/sepete ekle|satın al|satin al|hemen al|kaydet|gönder|gonder|onayla|öde|ode|ekle/i.test(t)) return true;
    return /add-to-cart|addtocart|buy-now|buynow|checkout|primary/.test(c);
  }

  // Sıralama/filtre kontrolleri: büyük listelerde MAX bütçesi ürün kartlarına
  // gidince "Önerilen Sıralama" gibi düğmeler dökümde hiç görünmüyordu.
  // Combobox/dropdown ve metninde sırala/filtre geçen denetimler öne alınır.
  //
  // AMA: bu sezgisel çok geniş olursa liste sayfasının TAMAMI kontrol sayılır.
  // yoğun filtreli bir liste sitesi ölçümü: 229 öğenin 69'u "kontrol" sınıfına düşüyordu
  // (marka/kategori linkleri de eşleşiyor), ilk 40 slotu onlar doldurup
  // ürünler hiç sıra alamıyordu (ilk 40'ta 0 ürün kartı). Bu yüzden:
  //   - yalnızca GERÇEK form denetimleri (<select>, role=combobox, [aria-haspopup])
  //     ya da kısa metinli (< 40 karakter) sırala/filtre düğmeleri sayılır;
  //   - <a href> bağlantıları asla kontrol sayılmaz (onlar navigasyondur).
  // =====================================================================
  // ÜRÜN KARTI + DENETİM TESPİTİ — ALGORİTMİK (site adı yok)
  // =====================================================================
  // Ölçülebilir üç yapısal sinyal; sabit site kuralları yerine sayfa
  // başına hesaplanan eşikler kullanılır.
  //
  //  (A) YAPISAL TEKRAR — liste sayfalarında ürün kartları AYNI class'ı
  //      paylaşan kardeş öğelerdir. Tüm DOM'da 3..200 kez tekrar eden sınıf
  //      imzaları çıkarılır ("kart havuzu").
  //      Ölçüm: SPA product-item=20, e-ticaret product-card=36,
  //      liste sitesi productCardLink=72.
  //
  //  (B) FİYAT SİNYALİ — kart metninde para birimi taşıyan sayı.
  //      Para birimi evrenseldir (TL/₺/$/€/£). Filtreleri ayırmak için
  //      form denetimleri ve ARALIK+AÇIKLAMA kalıbı elenir.
  //
  //  (C) BAĞLANTI YOĞUNLUĞU — kartta <a href> olmalı; ama her çocuk link ise
  //      bu bir menüdür (sol filtre/footer), kart değil.
  var PARA_RE = /\d[\d.,]*\s*(?:TL|₺|\$|€|£|USD|EUR)\b|(?:₺|\$|€|£)\s*\d/i;
  var ARALIK_RE = /^\s*\d[\d.,]*\s*[-–]\s*\d[\d.,]*\s*(?:TL|₺|\$|€|£)?\s*(?:\(\s*\d+\s*\))?\s*$/i;

  function sinifImza(el) {
    return (typeof el.className === 'string' ? el.className : '').trim().split(/\s+/)[0] || '';
  }

  var kartHavuzu = (function () {
    var sayac = {}, ornek = {};
    var tum = document.querySelectorAll('li,article,div,section');
    for (var i = 0; i < tum.length; i++) {
      var e = tum[i];
      var c = sinifImza(e);
      if (c.length < 3) continue;
      var p = e.parentElement;
      if (!p || p.children.length < 3) continue;   // kardeş grubu değil
      sayac[c] = (sayac[c] || 0) + 1;
      if (!ornek[c]) ornek[c] = e;
    }
    var havuz = {};
    var ks = Object.keys(sayac);
    for (var k = 0; k < ks.length; k++) {
      var c2 = ks[k], n = sayac[c2];
      if (n < 3 || n > 200) continue;              // tek öğe ya da menü yığını
      var o = ornek[c2];
      var mt = (o.innerText || '').trim();
      if (mt.length > 0 && mt.length < 400 && PARA_RE.test(mt)) havuz[c2] = n;
    }
    return havuz;
  })();

  // Sayfa başına ölçülen eşikler (sabit sayı yok).
  var TIPIK_KART_METIN = (function () {
    var n = 0, toplam = 0;
    var ks = Object.keys(kartHavuzu);
    for (var i = 0; i < ks.length; i++) {
      var o = document.querySelector('[class~="' + ks[i].replace(/"/g, '\\"') + '"]');
      if (!o) continue;
      var t = (o.innerText || '').trim();
      if (t.length > 0) { toplam += t.length; n++; }
    }
    return n > 0 ? Math.round(toplam / n) : 0;
  })();

  function kart_icerik(el) {
    var tag = (el.tagName || '').toLowerCase();

    // (B-i) Form denetimleri asla ürün kartı değildir.
    if (tag === 'input' || tag === 'select' || tag === 'textarea') return false;
    if (el.getAttribute && (el.getAttribute('role') === 'checkbox' ||
                            el.getAttribute('role') === 'radio')) return false;
    var lab = el.closest ? el.closest('label') : null;
    if (lab && lab.querySelector('input[type=checkbox],input[type=radio]')) return false;

    // (B-ii) Fiyat ARALIĞI filtresi.
    var kendi = (el.innerText || '').trim();
    if (kendi && ARALIK_RE.test(kendi)) return false;

    // (A) Kart kapsayıcısını bul: kendisi havuzdaysa kendisi, değilse
    // en yakın havuz-üyesi ata (en fazla 4 seviye).
    var kapsayici = null;
    if (kartHavuzu[sinifImza(el)]) {
      kapsayici = el;
    } else if (el.closest) {
      // Önce en yakın HAVUZ-ÜYESİ atayı ara (ikon/buton gibi havuz dışı
      // çocuklar kartın içinde olabilir: metinsiz sepete-ekle SVG'si).
      var ph = el.parentElement;
      for (var dh = 0; dh < 6 && ph; dh++, ph = ph.parentElement) {
        if (kartHavuzu[sinifImza(ph)]) { kapsayici = ph; break; }
      }
    }
    // (A-yedek) Havuz boşsa (tek kartlı sayfa) veya havuz isabeti yoksa:
    // fiyat sinyali taşıyan EN YAKIN ata kart kabul edilir. Böylece yapısal
    // tekrar gerektirmeyen tek ürünlü sayfalar da doğru çalışır.
    if (!kapsayici && el.closest) {
      var pf = el.parentElement;
      for (var df = 0; df < 6 && pf && pf !== document.body; df++, pf = pf.parentElement) {
        var tf = pf.innerText || '';
        var kf = pf.querySelectorAll ? pf.querySelectorAll('a,button,input,select,textarea').length : 0;
        if (tf.length >= 8 && tf.length <= 420 && kf <= 6 && PARA_RE.test(tf)) {
          kapsayici = pf;
          break;
        }
      }
    }
    if (!kapsayici) {
      var p = el.parentElement;
      for (var d = 0; d < 4 && p; d++, p = p.parentElement) {
        if (kartHavuzu[sinifImza(p)]) { kapsayici = p; break; }
      }
      if (!kapsayici && el.closest) {
        var li = el.closest('li,article');
        if (li && kartHavuzu[sinifImza(li)]) kapsayici = li;
      }
    }
    if (!kapsayici) return false;

    var metin = (kapsayici.innerText || '').trim();
    // (B-iii) Fiyat taşımalı, etiket uzunluğunda olmamalı.
    if (!metin || metin.length < 8 || metin.length > 400) return false;
    if (!PARA_RE.test(metin)) return false;

    // (C) Link yoğunluğu: link yoksa kart değil; her çocuk link ise menü.
    var linkSayi = kapsayici.querySelectorAll ? kapsayici.querySelectorAll('a[href]').length : 0;
    if (linkSayi === 0) return false;
    var cocukSayi = kapsayici.children ? kapsayici.children.length : 0;
    if (cocukSayi >= 3 && linkSayi >= cocukSayi) return false;

    return true;
  }

  // Sıralama/filtre denetimi — ALGORİTMİK
  // Denetim = kendi başına işlev gören, LİSTE ÖĞESİ OLMAYAN form kontrolü.
  //   (1) gerçek form denetimi (select / combobox / aria-haspopup / button)
  //       — <a href> navigasyondur, denetim değil
  //   (2) kart havuzu içinde olmamalı (ürün kartındaki düğme denetim değil)
  //   (3) metni kart metninin yarısından kısa olmalı (eşik sayfa başına)
  function kontrol_oncelik(el) {
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'a') return false;

    var rol = el.getAttribute('role') || '';
    var popup = el.getAttribute('aria-haspopup');
    var tip = (el.getAttribute('type') || '').toLowerCase();
    var formDenetimi = (tag === 'select') || rol === 'combobox' || popup ||
                       (tag === 'button' && tip === 'button') ||
                       rol === 'listbox' || rol === 'menu';
    if (!formDenetimi) return false;

    var ata = el.parentElement;
    for (var d = 0; d < 4 && ata; d++, ata = ata.parentElement) {
      if (kartHavuzu[sinifImza(ata)]) return false;   // kart içi düğme
    }

    var metin = (el.innerText || '').trim();
    // Metinsiz buton (yalnızca ikon) denetim DEĞİLDİR: model onu tanımlayamaz,
    // slotu boşa harcar. liste-sayfası ölçümü: e3..e8 metinsiz <button> idi ve
    // ürün kartlarının önüne geçiyordu.
    if (metin.length === 0) {
      // Erişilebilirlik adı varsa (aria-label/title) hâlâ anlamlıdır.
      var etiket = (el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
      if (etiket.length === 0) return false;
    }
    if (TIPIK_KART_METIN > 0 && metin.length > TIPIK_KART_METIN / 2) return false;

    return true;
  }

  if (modal) {
    walk(modal, false);
  } else {
    walk(document, false);
  }

  // Sıralama + işaretleme (öncelik sırası):
  //   1. form alanları  2. sıralama/filtre denetimleri  3. birincil eylemler
  //   4. overlay  5. ürün kartı içerikleri  6. normal öğeler
  // (Arama kutusu/select olmadan görev başlayamaz; "Sepete Ekle" olmadan
  //  satın alma tamamlanamaz; sıralama/filtre olmadan liste yönetilemez.
  //  Üçü de öneri kartlarından önce gelir.)
  //
  // İSTİSNA (liste-sayfası ölçümü): liste sayfalarında çok sayıda FİLTRE alanı
  // ("Filtrele", "En az", "En çok" × onlarca) bulunur; hepsi "form alanı"
  // olunca 40 slotu doldurup ürünleri dışarıda bırakıyordu. Bu yüzden form
  // alanlarından yalnızca ilk EN FAZLA 3 tanesi öne alınır (site başına arama
  // kutusu + sıralama genelde 1-3 tanedir), gerisi ürün kartlarından SONRA
  // listelenir.
  // Sabit sayı yerine sayfa başına ölçüm:
  //   - ÜRÜN KARTI VARSA (liste sayfası): metin alanlarından en fazla 2'si
  //     öne alınır (arama + sıralama); kalan onlarca filtre alanı ürün
  //     kartlarından SONRA listelenir.
  //   - ÜRÜN KARTI YOKSA (form/detay sayfası): tüm giriş alanları öne alınır.
  var kartVar = false;
  for (var ci = 0; ci < toplanan.length; ci++) {
    if (kart_icerik(toplanan[ci].el)) { kartVar = true; break; }
  }
  var girisler = toplanan.filter(function (p) { return giris_alani(p.el); });

  // Arama kutusu HER ZAMAN ilk sırada olmalı: model onu görmezse görevin ilk
  // adımı ölür. e-ticaret anasayfası ölçümü: 40 slotu ürün kartları doldurup
  // arama kutusu dump'a hiç girmiyordu. Sinyal: type=search ya da
  // placeholder/aria-label/name'de ara|search|sorgu geçmesi.
  function aramaKutusu(el) {
    var tg = (el.tagName || '').toLowerCase();
    if (tg.indexOf('-') > 0 && /search|arama|sorgu|query/i.test(tg)) return true;
    var tip = (el.getAttribute('type') || '').toLowerCase();
    if (tip === 'search') return true;
    var ad = ((el.getAttribute('placeholder') || '') + ' ' +
              (el.getAttribute('aria-label') || '') + ' ' +
              (el.getAttribute('name') || '') + ' ' +
              (el.getAttribute('id') || '') + ' ' +
              (el.getAttribute('role') || '')).toLowerCase();
    return /(^|[^a-z])(ara|arama|search|sorgu|query)([^a-z]|$)/.test(ad);
  }
  // Arama kutusu bir <input> olmak zorunda değil: modern siteler aramayı
  // <button>/<div role=combobox> olarak render edip tıklanınca input açıyor.
  // e-ticaret anasayfası ölçümü: görünür input YOK; arama
  // button.suggestion-placeholder ("Ürün, kategori veya marka ara") idi ve
  // 40 slotu ürün kartları doldurduğu için dump'a hiç girmiyordu.
  // Bu yüzden arama sinyali taşıyan TÜM öğeler (input olmayanlar dahil)
  // öncelikli gruba alınır.
  function aramaSinyali(el) {
    if (aramaKutusu(el)) return true;
    var tag = (el.tagName || '').toLowerCase();
    // Custom element ve TAG ADINDA arama anlamı taşıyan öğe: <fss-search-input>
    // gibi öğelerin metni/aria-label'ı BOŞ olur (içi shadow/closed component).
    // Bu durumda tek sinyal tag adıdır.
    if (tag.indexOf('-') > 0 && /search|arama|sorgu|query/i.test(tag)) return true;
    // Custom element (tag adında tire) de olabilir: arama kutusu
    // <fss-search-input>, <x-search> gibi özel etiketlerle render edilir.
    var customElement = tag.indexOf('-') > 0;
    if (!customElement && tag !== 'button' && tag !== 'div' && tag !== 'a' && tag !== 'span' && tag !== 'input') return false;
    // Sinyal kaynakları DİKKATLİ seçilir: href'e BAKILMAZ.
    // SPA anasayfası ölçümü: kampanya banner linkleri "/arama?promotions=..."
    // href'i taşıdığı için arama kutusu sanılıyor, ilk 6 slotu doldurup asıl
    // arama kutusunu dump'tan itiyordu. Arama kutusu, href'inden değil
    // GÖRÜNEN ETİKETİNDEN / erişilebilirlik adından tanınır.
    var metin = (el.innerText || '').trim().replace(/\s+/g, ' ');
    var ad = ((el.getAttribute('aria-label') || '') + ' ' +
              (el.getAttribute('placeholder') || '') + ' ' +
              (el.getAttribute('title') || '') + ' ' +
              (el.getAttribute('role') || '') + ' ' +
              metin + ' ' +
              (typeof el.className === 'string' ? el.className : '')).toLowerCase();
    // Yapısal sinyal: sayfada TEK metin alanı varsa o kesinlikle arama/giriş
    // kutusudur — etiketi ne olursa olsun. SPA ölçümü: tek görünür input,
    // placeholder'ı dinamik ürün önerisi ("Philips Hue GO , 3851 TL"),
    // sınıf/id/form yok; hiçbir metin sinyali vermiyordu.
    if (el.tagName === 'INPUT' && TEK_METIN_ALANI === el) return true;
    // Yapısal sinyal: bir <form> içindeki ilk metin alanı, etiketi ne olursa
    // olsun arama/giriş kutusudur. SPA ölçümü: arama kutusunun placeholder'ı
    // dinamik ürün önerisi taşıyordu ("Philips Hue GO , 3851 TL") ve hiçbir
    // metin sinyali vermiyordu; kategori linkleri ilk 10 slotu dolduruyordu.
    if (el.form && el.tagName === 'INPUT') {
      var ilkFormAlani = el.form.querySelector('input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit])');
      if (ilkFormAlani === el) return true;
    }
    if (!/(ara|arama|search|sorgu|query)/.test(ad)) return false;
    // "Ürün ara" gibi KISA bir etiket olmalı; kampanya sloganı değil.
    if (metin.length > 40) return false;
    // Link metni tamamen rakam/boş ise (ör. "/arama?promotions=") arama değil.
    if (!/[a-zçğıöşü]{3,}/i.test(metin) && !/ara|search/i.test(
          (el.getAttribute('aria-label') || '') + (el.getAttribute('placeholder') || ''))) return false;
    return true;
  }
  // Sayfadaki görünür metin alanları (tek ise arama kutusu odur).
  var metinAlanlari = toplanan.filter(function (p) {
    return (p.el.tagName || '').toUpperCase() === 'INPUT' && giris_alani(p.el);
  });
  var TEK_METIN_ALANI = metinAlanlari.length === 1 ? metinAlanlari[0].el : null;

  var aramaOgeleri = toplanan.filter(function (p) { return aramaSinyali(p.el); });
  var aramalar = girisler.filter(function (p) { return aramaKutusu(p.el); });
  var digerGirisler = girisler.filter(function (p) { return !aramaKutusu(p.el); });

  var oncelikli_giris, kalan_giris;
  if (kartVar) {
    // Arama kutusu(ları) + en fazla 1 sıralama alanı öne; kalan filtreler sonra.
    oncelikli_giris = aramalar.slice(0, 2).concat(digerGirisler.slice(0, 1));
    kalan_giris = digerGirisler.slice(1);
  } else {
    oncelikli_giris = girisler;
    kalan_giris = [];
  }
  // Arama sinyali taşıyan öğeler listenin EN BAŞINA (input olsun olmasın).
  var secilen = [];
  aramaOgeleri.forEach(function (p) { if (secilen.indexOf(p) < 0) secilen.push(p); });
  oncelikli_giris.forEach(function (p) { if (secilen.indexOf(p) < 0) secilen.push(p); });
  var kalan = toplanan.filter(function (p) { return !giris_alani(p.el); });
  var kontroller = kalan.filter(function (p) { return kontrol_oncelik(p.el); });
  var kalan2 = kalan.filter(function (p) { return !kontrol_oncelik(p.el); });
  var birincil = kalan2.filter(function (p) { return birincil_eylem(p.el); });
  var digerleri = kalan2.filter(function (p) { return !birincil_eylem(p.el); });
  secilen = secilen.concat(
    kontroller,
    birincil,
    digerleri.filter(function (p) { return overlay_index(p.el) !== -1; }),
    digerleri.filter(function (p) { return overlay_index(p.el) === -1 && kart_icerik(p.el); }),
    digerleri.filter(function (p) { return overlay_index(p.el) === -1 && !kart_icerik(p.el); }),
    kalan_giris
  );

  // -------------------------------------------------------------------------
  // BENZERSİZLİK SÜZGECİ — site bağımsız
  // -------------------------------------------------------------------------
  // Kurumsal/landing sayfalarında aynı bağlantı onlarca kez tekrarlanır
  // (aynı "Aracını Tasarla" linki mobil+masaüstü menüsünde 9 kez). Ölçüm:
  // 275 etkileşimli öğeli bir sayfada 186 benzersiz öğe vardı ve 40 slotu
  // 2 linkin tekrarı doldurup arama kutusu/navigasyon dump'a hiç girmiyordu.
  //
  // Kural: aynı (görünen ad + href) imzasından en fazla TEKRAR_SINIRI kez
  // gösterilir. Sınır sayfadaki gerçek çeşitliliğe göre ölçülür:
  //   - çok benzersiz öğe varsa sınır 1 (her şey bir kez)
  //   - az benzersiz öğe varsa sınır 2 (meşru tekrarlar korunur)
  // Böylece hem menü çorbası hem de aşırı kırpma önlenir.
  function imza(p) {
    var e = p.el;
    var ad = (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '')
             .replace(/\s+/g, ' ').trim().slice(0, 60);
    var href = e.getAttribute ? (e.getAttribute('href') || '') : '';
    return e.tagName + '|' + ad + '|' + href;
  }

  var benzersizSayi = {};
  for (var bi = 0; bi < secilen.length; bi++) {
    var si = imza(secilen[bi]);
    benzersizSayi[si] = (benzersizSayi[si] || 0) + 1;
  }
  var benzersizToplam = Object.keys(benzersizSayi).length;
  var TEKRAR_SINIRI = benzersizToplam >= MAX ? 1 : 2;

  var gorulen = {};
  var suzulmus = [];
  for (var gi = 0; gi < secilen.length; gi++) {
    var sig = imza(secilen[gi]);
    var kac = gorulen[sig] || 0;
    if (kac >= TEKRAR_SINIRI) continue;
    gorulen[sig] = kac + 1;
    suzulmus.push(secilen[gi]);
  }

  for (var n = 0; n < MAX && n < suzulmus.length; n++) {
    var ref = 'e' + (n + 1);
    var el = suzulmus[n].el;
    el.setAttribute('data-sl-ref', ref);
    var d = describe(el);
    d.ref = ref;
    d.shadow = !!suzulmus[n].shadow;
    items.push(d);
  }

  return {
    url: location.href,
    title: document.title,
    total: total,
    modal: modal ? true : false,
    items: items
  };
})(arguments[0]);
