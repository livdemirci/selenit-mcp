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
    if (kart && kart !== el && kart !== row) {
      var satirlar = (kart.innerText || '').split('\n').map(function (s) {
        return s.replace(/\s+/g, ' ').trim();
      }).filter(Boolean);
      var fiyat = '';
      for (var f = 0; f < satirlar.length; f++) {
        // "57,97 TL" gibi kısa fiyat satırları; üstü çizili ve Plus fiyatını geç.
        if (/TL$/.test(satirlar[f]) && satirlar[f].length <= 16) { fiyat = satirlar[f]; break; }
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
  function giris_alani(el) {
    var t = (el.tagName || '').toLowerCase();
    return t === 'input' || t === 'textarea' || t === 'select';
  }

  // Birincil eylem düğmeleri: "Sepete Ekle", "Satın Al", "Kaydet", "Gönder".
  // n11 ürün sayfası ölçümü: ürün öneri kartları MAX bütçesini doldurup asıl
  // "Sepete Ekle" (BUTTON.add-to-cart-btn) dump'a hiç giremiyordu. Sayfanın
  // ana eylemi, öneri kartlarından her zaman daha önemlidir.
  function birincil_eylem(el) {
    if ((el.tagName || '').toLowerCase() !== 'button') {
      if (el.getAttribute && el.getAttribute('role') !== 'button') return false;
    }
    var t = (el.innerText || el.value || '').trim();
    if (!t || t.length > 30) return false;
    if (/sepete ekle|satın al|satin al|hemen al|kaydet|gönder|gonder|onayla|öde|ode|ekle/i.test(t)) return true;
    var c = (el.getAttribute && el.getAttribute('class') || '').toLowerCase();
    return /add-to-cart|addtocart|buy-now|buynow|checkout|primary/.test(c);
  }

  function kart_icerik(el) {
    if (el.closest('[class*="productList" i],[data-asin]')) return true;
    var c = el.closest('li,article,div');
    if (c && c.querySelector &&
        c.querySelector('a[href*="/urun/"],a[href*="/dp/"],a[href*="-p-"]')) {
      return true;
    }
    return false;
  }

  if (modal) {
    walk(modal, false);
  } else {
    walk(document, false);
  }

  // Sıralama + işaretleme (öncelik sırası):
  //   1. form alanları  2. birincil eylem düğmeleri  3. overlay
  //   4. ürün kartı içerikleri  5. normal öğeler
  // (Arama kutusu/select olmadan görev başlayamaz; "Sepete Ekle" olmadan
  //  satın alma tamamlanamaz. İkisi de öneri kartlarından önce gelir.)
  var secilen = toplanan.filter(function (p) { return giris_alani(p.el); });
  var kalan = toplanan.filter(function (p) { return !giris_alani(p.el); });
  var birincil = kalan.filter(function (p) { return birincil_eylem(p.el); });
  var digerleri = kalan.filter(function (p) { return !birincil_eylem(p.el); });
  secilen = secilen.concat(
    birincil,
    digerleri.filter(function (p) { return overlay_index(p.el) !== -1; }),
    digerleri.filter(function (p) { return overlay_index(p.el) === -1 && kart_icerik(p.el); }),
    digerleri.filter(function (p) { return overlay_index(p.el) === -1 && !kart_icerik(p.el); })
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
