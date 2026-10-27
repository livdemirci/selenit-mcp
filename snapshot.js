// Kompakt sayfa dökümü: görünür/etkileşimli öğeler; shadow DOM dahil.
// Küçük modeller (Gemma E4B) için kısa tutulur; her öğeye data-sl-ref="eN" yazılır.
// - Açık modal varsa yalnızca modal içeriği listelenir (arka plan gürültüsü gitmez).
//   Modal tespiti artık role=dialog/aria-modal dışında class sinyalleriyle de yapılır
//   (ör. Trendyol'un .modal-container'ı role taşımaz); aday, görünüp ekran merkezini
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
          // Toast'lar (başarı/hata bildirimleri) model için önemlidir: "Ürün sepete
          // eklendi", "ürün temin edilemiyor" gibi dönütleri görünür kılar.
          '[role=alert],[role=status],' +
          // Hepsiburada vb. siteler toast'lara role vermez (hb-toast-notifier-*).
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

  function visible(el) {
    var rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    var style = window.getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') return false;
    if (el.disabled) return false;
    return true;
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
  var FIYAT_RE = /(\d{1,3}(?:[.\s]\d{3})*|\d+)[.,]\d{2}\s*(TL|₺|\$|€|USD|EUR)/i;

  function describe(el) {
    var name = (el.getAttribute('aria-label') ||
                el.innerText ||
                el.value ||
                el.getAttribute('placeholder') ||
                el.getAttribute('alt') ||
                el.getAttribute('title') ||
                el.getAttribute('src') || '')
               .replace(/\s+/g, ' ').trim();

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
    var kart = el.closest
      ? el.closest('[data-testid*="card"],.product-card,[class*="product-card"],[class*="p-card"],[class*="productCard"]')
      : null;
    // Sınıf adı ürün kartı sinyali vermiyorsa fiyat deseninden bul: fiyat
    // gösteren EN YAKIN ata (her e-ticaret kartında fiyat vardır). Böylece
    // "kart", "verticalProduct", "productListContent" gibi siteye özgü
    // sınıf adlarına bağımlı kalmadan tekrar eden düğmeler ayırt edilir.
    if (!kart) {
      var aday = el.parentElement;
      var derinlik = 0;
      while (aday && derinlik < 6 && aday !== document.body) {
        var adayMetin = (aday.innerText || '');
        var adayKontroller = aday.querySelectorAll('a,button,input,select,textarea').length;
        if (adayMetin.length > 0 && adayMetin.length <= 420 &&
            adayKontroller <= 4 && FIYAT_RE.test(adayMetin)) {
          kart = aday;
          break;
        }
        aday = aday.parentElement;
        derinlik++;
      }
    }
    if (kart && kart !== el && kart !== row) {
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
      var kctx = baslik.slice(0, 42);
      if (fiyat) kctx = (kctx ? kctx + ' · ' : '') + fiyat;
      kctx = kctx.slice(0, 60);
      // Kendi adı zaten açıklayıcı olan öğelere (ör. başlık bağlantısı) bağlam ezme.
      if (kctx && name.length < 24 && name.indexOf(baslik) === -1) name = name + ' | ' + kctx;
    }

    if (name.length > 90) name = name.slice(0, 90) + '…';
    return {
      tag: el.tagName.toLowerCase(),
      type: (el.getAttribute('type') || '').toLowerCase(),
      name: name,
      href: el.getAttribute('href') || el.getAttribute('src') || ''
    };
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

  function walk(root, inShadow) {
    var els = root.querySelectorAll(q);
    for (var k = 0; k < els.length; k++) toplama_hedef(els[k], inShadow);
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
  // KARŞI DENGE (n11.com ölçümü): ürün kartı önceliği bu kez ters yönde
  // bozuluyordu — 485 etkileşimli öğeli ana sayfada ilk 40 slotu tamamen ürün
  // kartları dolduruyor, header'daki ARAMA KUTUSU hiç sıra alamıyordu.
  // Arama kutusu bir sitenin en kritik kontrolüdür; model onu göremezse görev
  // ilk adımda ölür. Bu yüzden form alanları (input/textarea/select) her zaman
  // ürün kartlarından ÖNCE gelir.
  // Metin girişi alanı mı? (Arama kutusu, form alanı — görevin başlaması için şart.)
  // Hepsiburada ölçümü: buradaki tanım <input> etiketinin TAMAMINI kapsıyordu,
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
  // n11 ürün sayfası ölçümü: ürün öneri kartları MAX bütçesini doldurup asıl
  // "Sepete Ekle" (BUTTON.add-to-cart-btn) dump'a hiç giremiyordu. Sayfanın
  // ana eylemi, öneri kartlarından her zaman daha önemlidir.
  // Trendyol ölçümü: arama kutusu <input> DEĞİL — metinsiz bir ikon düğmesi
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
  // Vatan Bilgisayar ölçümü: 229 öğenin 69'u "kontrol" sınıfına düşüyordu
  // (marka/kategori linkleri de eşleşiyor), ilk 40 slotu onlar doldurup
  // ürünler hiç sıra alamıyordu (ilk 40'ta 0 ürün kartı). Bu yüzden:
  //   - yalnızca GERÇEK form denetimleri (<select>, role=combobox, [aria-haspopup])
  //     ya da kısa metinli (< 40 karakter) sırala/filtre düğmeleri sayılır;
  //   - <a href> bağlantıları asla kontrol sayılmaz (onlar navigasyondur).
  function kontrol_oncelik(el) {
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'a') return false;

    var rol = el.getAttribute('role') || '';
    var popup = el.getAttribute('aria-haspopup');
    if (tag === 'select' || rol === 'combobox' || popup) return true;

    var metin = (el.innerText || '').trim();
    if (metin.length > 40) return false; // uzun metin = liste öğesi, kontrol değil
    var ad = ((el.getAttribute('aria-label') || '') + ' ' +
              (typeof el.className === 'string' ? el.className : '') + ' ' +
              metin).toLowerCase();
    return /s[ıi]rala|sort|filtre|filter/.test(ad);
  }

  // Ürün kartı mı? Siteye özgü sınıf adları güvenilmez; üç bağımsız sinyal:
  //   1) bilinen liste kapsayıcısı (productList/data-asin)
  //   2) ürün-benzeri href (/urun/, /dp/, -p-)
  //   3) FIYAT DESENİ — kart metninde fiyat VE ürün kartı işareti
  // Vatan Bilgisayar ölçümü: arama sayfasında 229 etkileşimli öğe var, ilk 40
  // slotu sol filtre paneli dolduruyordu. Salt fiyat deseni yetmedi: sol
  // paneldeki "200 - 499TL (15)" gibi FİYAT ARALIĞI FİLTRE linkleri de
  // eşleşiyordu. Bu yüzden fiyat + şu ek koşullar aranır:
  //   - element bir <a> ise metni fiyat aralığı/filtre kalıbı OLMAMALI
  //   - kart içinde fiyat ve ürün adı benzeri uzun metin bulunmalı
  var FIYAT_RE = /\d[\d.,]*\s*(?:TL|₺)\b|₺\s*\d/i;
  // "200 - 499TL (15)", "500 - 999 TL (58)" → filtre linki, ürün kartı değil
  var FILTRE_FIYAT_RE = /^\s*\d[\d.,]*\s*[-–]\s*\d[\d.,]*\s*(?:TL|₺)?\s*\(\d+\)\s*$/i;

  function kart_icerik(el) {
    // Form denetimleri (checkbox/radio/select/input) ürün kartı DEĞİLDİR.
    // Hepsiburada ölçümü: sol filtrenin fiyat aralığı checkbox'ları
    // ("0-2800", "2800-14000") fiyat desenine uyduğu için ürün kartı sayılıp
    // gerçek ürünleri dökümden itiyordu.
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'select' || tag === 'textarea') return false;
    if (el.getAttribute && el.getAttribute('role') === 'checkbox') return false;
    // Bir <label> içindeki checkbox'ı saran link de filtre sayılır.
    if (el.closest && el.closest('label') && el.closest('label').querySelector(':scope > input[type=checkbox],:scope > input[type=radio]')) return false;

    if (el.closest('[class*="productList" i],[data-asin]')) return true;
    var c = el.closest('li,article,div');
    if (!c || !c.querySelector) return false;
    if (c.querySelector('a[href*="/urun/"],a[href*="/dp/"],a[href*="-p-"]')) return true;

    var metin = (c.innerText || '').trim();
    if (metin.length === 0 || metin.length > 300) return false;
    if (!FIYAT_RE.test(metin)) return false;

    // Bağlantıysa: fiyat aralığı filtresi linklerini ele.
    if ((el.tagName || '').toLowerCase() === 'a') {
      var kendi = (el.innerText || '').trim();
      if (FILTRE_FIYAT_RE.test(kendi)) return false;
      // "(15)" gibi adet eki taşıyan linkler kategori/marka filtresidir.
      if (/\(\d+\)\s*$/.test(kendi) && !/TL|₺/i.test(kendi)) return false;
    }
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
  // İSTİSNA (Hepsiburada ölçümü): liste sayfalarında çok sayıda FİLTRE alanı
  // ("Filtrele", "En az", "En çok" × onlarca) bulunur; hepsi "form alanı"
  // olunca 40 slotu doldurup ürünleri dışarıda bırakıyordu. Bu yüzden form
  // alanlarından yalnızca ilk EN FAZLA 3 tanesi öne alınır (site başına arama
  // kutusu + sıralama genelde 1-3 tanedir), gerisi ürün kartlarından SONRA
  // listelenir.
  const ONCELIKLI_GIRIS = 3;
  var girisler = toplanan.filter(function (p) { return giris_alani(p.el); });
  var oncelikli_giris = girisler.slice(0, ONCELIKLI_GIRIS);
  var kalan_giris = girisler.slice(ONCELIKLI_GIRIS);
  var secilen = oncelikli_giris.slice();
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

  for (var n = 0; n < MAX && n < secilen.length; n++) {
    var ref = 'e' + (n + 1);
    var el = secilen[n].el;
    el.setAttribute('data-sl-ref', ref);
    var d = describe(el);
    d.ref = ref;
    d.shadow = !!secilen[n].shadow;
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
