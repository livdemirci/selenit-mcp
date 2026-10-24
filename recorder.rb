# Ref -> kalıcı CSS seçici üretimi (kayıt/replay için).
# Shadow DOM içindeki öğeler "shadow::<hostSeçici>||<içSeçici>" biçiminde döner.
#
# ÖNEMLİ: Selenium `execute_script` betiği bir fonksiyon gövdesi olarak çalıştırır;
# bu yüzden IIFE DEĞİL, açık `return` kullanan düz bir betik olmalıdır.
SELECTOR_JS = <<~'JS'
  function __sl_find(root, ref) {
    var el = root.querySelector('[data-sl-ref="' + ref + '"]');
    if (el) return el;
    var hosts = root.querySelectorAll('*');
    for (var i = 0; i < hosts.length; i++) {
      if (hosts[i].shadowRoot) {
        var r = __sl_find(hosts[i].shadowRoot, ref);
        if (r) return r;
      }
    }
    return null;
  }
  function __sl_path(el) {
    // Bağlantılar için hedef URL, sıra numarasından daha okunur ve dayanıklıdır.
    if (el.tagName === 'A') {
      var __href = el.getAttribute('href');
      if (__href && __href !== '#' && __href.indexOf('javascript:') !== 0) {
        return 'a[href="' + __href.replace(/"/g, '\\"') + '"]';
      }
    }

    // Locator chaining: tablo satırı data-id taşıyorsa satırı sabitle,
    // satır içindeki hedefi ona göre seç (Zhan: Case Study — Locator Chaining).
    var __row = el.closest ? el.closest('tr[data-id]') : null;
    if (__row) {
      var __holder = __row.parentElement;
      var __root = (__holder && __holder.id) ? '#' + __holder.id
                 : (__row.closest('table') && __row.closest('table').id ? '#' + __row.closest('table').id : 'table');
      var __inner = (el === __row) ? '' : (' ' + el.tagName.toLowerCase());
      return __root + ' tr[data-id="' + __row.getAttribute('data-id') + '"]' + __inner;
    }

    var parts = [];
    while (el && el.nodeType === 1) {
      if (el.id) { parts.unshift('#' + el.id); break; }
      var nm = el.getAttribute('name');
      if (nm) { parts.unshift(el.tagName.toLowerCase() + '[name="' + nm + '"]'); break; }
      var ti = el.getAttribute('data-testid');
      if (ti) { parts.unshift('[data-testid="' + ti + '"]'); break; }
      var al = el.getAttribute('aria-label');
      if (al) { parts.unshift(el.tagName.toLowerCase() + '[aria-label="' + al + '"]'); break; }
      var ph = el.getAttribute('placeholder');
      if (ph) { parts.unshift(el.tagName.toLowerCase() + '[placeholder="' + ph + '"]'); break; }
      var idx = 1, sib = el;
      while ((sib = sib.previousElementSibling)) { if (sib.tagName === el.tagName) idx++; }
      parts.unshift(el.tagName.toLowerCase() + ':nth-of-type(' + idx + ')');
      el = el.parentElement;
    }
    return parts.join(' > ');
  }
  var __sl_el = __sl_find(document, "%<ref>s");
  if (!__sl_el) return "";
  var __sl_root = __sl_el.getRootNode();
  if (__sl_root && __sl_root.host) return 'shadow::' + __sl_path(__sl_root.host) + '||' + __sl_path(__sl_el);
  return __sl_path(__sl_el);
JS

ACTION_TOOLS = %w[
  browser_navigate browser_click browser_type browser_select browser_press_key
  browser_scroll browser_frame browser_upload browser_hover browser_history
  browser_tabs browser_alert browser_wait_for
].freeze

def selector_for(mcp, ref)
  return nil if ref.nil? || ref.to_s.empty?
  return nil unless ref.to_s.match?(/\A[ef]\d+\z/)

  js = format(SELECTOR_JS, ref: ref)
  sel = mcp.call("browser_evaluate", { "script" => js }).to_s.strip
  return nil if sel.empty? || sel == "nil" || sel.start_with?("HATA")

  sel
rescue StandardError
  nil
end
