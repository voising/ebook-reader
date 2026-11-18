import Foundation

enum ReaderScripts {
    static let css = #"""
    html {
      background: var(--folio-bg) !important;
      -webkit-text-size-adjust: none;
    }
    body {
      background: var(--folio-bg) !important;
      color: var(--folio-fg) !important;
      font-family: var(--folio-font) !important;
      font-size: var(--folio-size) !important;
      line-height: var(--folio-lh) !important;
      max-width: var(--folio-width) !important;
      margin: 0 auto !important;
      padding: 72px 56px 64px !important;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
      font-kerning: normal;
      font-variant-ligatures: common-ligatures;
      -webkit-hyphens: auto;
      hyphens: auto;
      word-wrap: break-word;
      transition: background-color .25s ease, color .25s ease;
    }
    body * { color: inherit !important; background-color: transparent !important; border-color: color-mix(in srgb, var(--folio-fg) 18%, transparent) !important; }
    p, div, span, li, blockquote, td, th, dd, dt, em, i, b, strong, a, cite, small, sup, sub { font-family: inherit !important; }
    p, li, blockquote, dd { line-height: inherit !important; }
    p { margin-top: 0; margin-bottom: 0.9em; }
    h1, h2, h3, h4, h5, h6 { font-family: inherit !important; font-weight: 650; line-height: 1.25 !important; letter-spacing: -0.012em; margin: 1.6em 0 0.7em; text-wrap: balance; }
    h1 { font-size: 1.85em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
    blockquote { margin: 1.2em 0; padding-left: 1.1em; border-left: 3px solid color-mix(in srgb, var(--folio-fg) 20%, transparent) !important; font-style: italic; }
    pre, code, kbd, samp, tt { font-family: ui-monospace, "SF Mono", Menlo, monospace !important; font-size: 0.86em; }
    pre { white-space: pre-wrap; padding: 0.9em 1em; border-radius: 8px; background: color-mix(in srgb, var(--folio-fg) 6%, transparent) !important; }
    img, svg, video, image { max-width: 100% !important; height: auto !important; }
    img { border-radius: 2px; max-height: 88vh !important; width: auto !important; object-fit: contain; }
    a, a * { color: var(--folio-link) !important; text-decoration: none; }
    a:hover { text-decoration: underline; }
    hr { border: 0; border-top: 1px solid color-mix(in srgb, var(--folio-fg) 15%, transparent) !important; margin: 2.2em auto; width: 30%; }
    table { border-collapse: collapse; max-width: 100%; }
    ::selection { background: rgb(255 196 0 / 0.32); }

    mark.folio-hl { color: inherit !important; border-radius: 3px; padding: 0.04em 0; cursor: pointer; transition: background-color .2s ease, box-shadow .2s ease; -webkit-box-decoration-break: clone; }
    mark.folio-hl[data-color="yellow"] { background-color: rgb(255 204 41 / var(--folio-hl-a)) !important; }
    mark.folio-hl[data-color="green"]  { background-color: rgb(92 199 115 / var(--folio-hl-a)) !important; }
    mark.folio-hl[data-color="blue"]   { background-color: rgb(77 153 255 / var(--folio-hl-a)) !important; }
    mark.folio-hl[data-color="pink"]   { background-color: rgb(255 107 148 / var(--folio-hl-a)) !important; }
    mark.folio-hl[data-color="purple"] { background-color: rgb(179 122 245 / var(--folio-hl-a)) !important; }
    mark.folio-hl.flash { animation: folio-flash 1.4s ease; }
    ::highlight(folio-find) { background-color: rgb(255 204 41 / 0.35); }
    ::highlight(folio-find-current) { background-color: rgb(255 149 0 / 0.7); }
    @keyframes folio-flash { 0%, 100% { box-shadow: 0 0 0 0 transparent; } 30% { box-shadow: 0 0 0 4px rgb(255 204 41 / 0.55); } }

    #folio-bar {
      position: fixed; z-index: 2147483647; display: none; align-items: center; gap: 7px;
      padding: 7px 9px; border-radius: 14px;
      background: rgba(28, 28, 30, 0.88);
      -webkit-backdrop-filter: blur(20px) saturate(180%);
      box-shadow: 0 10px 30px rgba(0,0,0,.25), 0 0 0 0.5px rgba(255,255,255,.12) inset;
      font: 500 12.5px -apple-system, "SF Pro Text", sans-serif;
      opacity: 0; transform: translateY(4px) scale(.98);
      transition: opacity .14s ease, transform .14s ease;
      -webkit-user-select: none; user-select: none;
    }
    #folio-bar.show { opacity: 1; transform: none; }
    #folio-bar button { all: unset; cursor: pointer; }
    #folio-bar .sw { width: 18px; height: 18px; border-radius: 50%; box-shadow: 0 0 0 1px rgba(255,255,255,.18) inset; transition: transform .12s ease; }
    #folio-bar .sw:hover { transform: scale(1.15); }
    #folio-bar .sw.on { box-shadow: 0 0 0 2px rgba(28,28,30,1), 0 0 0 3.5px #fff; }
    #folio-bar .sw[data-color="yellow"] { background: #FFCC29; }
    #folio-bar .sw[data-color="green"]  { background: #5CC773; }
    #folio-bar .sw[data-color="blue"]   { background: #4D99FF; }
    #folio-bar .sw[data-color="pink"]   { background: #FF6B94; }
    #folio-bar .sw[data-color="purple"] { background: #B37AF5; }
    #folio-bar .sep { width: 1px; height: 16px; background: rgba(255,255,255,.18); margin: 0 2px; }
    #folio-bar .act { color: rgba(255,255,255,.92); padding: 3px 7px; border-radius: 7px; }
    #folio-bar .act:hover { background: rgba(255,255,255,.12); }
    #folio-bar .act.danger { color: #FF8A80; }

    #folio-next {
      display: block; box-sizing: border-box; max-width: var(--folio-width); margin: 0 auto; padding: 32px 56px 120px;
      font: 500 14px -apple-system, "SF Pro Text", sans-serif; color: var(--folio-fg); cursor: pointer;
      -webkit-user-select: none; user-select: none;
    }
    #folio-next .card { display: flex; justify-content: space-between; align-items: center; padding: 18px 22px; border-radius: 14px;
      background: color-mix(in srgb, var(--folio-fg) 5%, transparent); transition: background .15s ease; }
    #folio-next:hover .card { background: color-mix(in srgb, var(--folio-fg) 9%, transparent); }
    #folio-next .k { opacity: .55; font-size: 11px; letter-spacing: .08em; text-transform: uppercase; display: block; margin-bottom: 3px; }
    #folio-next .t { font-family: var(--folio-font); font-size: 17px; font-weight: 600; }
    #folio-next .arrow { opacity: .5; font-size: 20px; }
    """#

    static let js = #"""
    (function () {
      if (window.folio) return;
      const post = (m) => { try { window.webkit.messageHandlers.folio.postMessage(m); } catch (e) {} };
      const COLORS = ['yellow', 'green', 'blue', 'pink', 'purple'];

      function textNodes() {
        const out = [];
        if (!document.body) return out;
        const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let n; while ((n = w.nextNode())) out.push(n);
        return out;
      }
      function offsetOf(node, offset) {
        const r = document.createRange();
        r.setStart(document.body, 0);
        try { r.setEnd(node, offset); } catch (e) { return 0; }
        return r.toString().length;
      }
      function skip(n) {
        const p = n.parentNode;
        return !p || (p.closest && p.closest('script,style'));
      }
      function wrap(h) {
        const nodes = textNodes();
        let acc = 0;
        for (const n of nodes) {
          const len = n.data.length;
          const s = Math.max(h.start - acc, 0), e = Math.min(h.end - acc, len);
          acc += len;
          if (e > s && /\S/.test(n.data.slice(s, e)) && !skip(n)) {
            let t = n;
            if (s > 0) t = t.splitText(s);
            if (e - s < t.data.length) t.splitText(e - s);
            const m = document.createElement('mark');
            m.className = 'folio-hl';
            m.setAttribute('data-id', h.id);
            m.setAttribute('data-color', h.color);
            t.parentNode.insertBefore(m, t);
            m.appendChild(t);
          }
          if (acc >= h.end) break;
        }
      }
      function marks(id) { return Array.from(document.querySelectorAll('mark.folio-hl[data-id="' + id + '"]')); }
      function unwrap(id) {
        marks(id).forEach((m) => {
          const p = m.parentNode;
          while (m.firstChild) p.insertBefore(m.firstChild, m);
          p.removeChild(m);
          p.normalize();
        });
      }
      function flash(id) {
        marks(id).forEach((m) => { m.classList.remove('flash'); void m.offsetWidth; m.classList.add('flash'); });
      }
      function unionRect(els) {
        let r = null;
        els.forEach((el) => {
          const b = el.getBoundingClientRect();
          r = r ? { top: Math.min(r.top, b.top), bottom: Math.max(r.bottom, b.bottom), left: Math.min(r.left, b.left), right: Math.max(r.right, b.right) } : { top: b.top, bottom: b.bottom, left: b.left, right: b.right };
        });
        if (r) { r.width = r.right - r.left; }
        return r;
      }

      // Search: same pattern as BookSearch.pattern(for:) — words joined by any whitespace, case-insensitive.
      const canMark = !!(window.CSS && CSS.highlights && window.Highlight);
      function findRanges(q) {
        const words = q.trim().split(/\s+/).filter(Boolean).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
        if (!words.length) return [];
        const re = new RegExp(words.join('\\s+'), 'gi');
        const nodes = textNodes().filter((n) => !skip(n));
        if (!nodes.length) return [];
        const starts = []; let text = '';
        nodes.forEach((n) => { starts.push(text.length); text += n.data; });
        function at(pos, isEnd) {
          let lo = 0, hi = nodes.length - 1;
          while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (isEnd ? starts[mid] < pos : starts[mid] <= pos) lo = mid; else hi = mid - 1;
          }
          return [nodes[lo], pos - starts[lo]];
        }
        const out = []; let m;
        while ((m = re.exec(text))) {
          const [sn, so] = at(m.index, false), [en, eo] = at(m.index + m[0].length, true);
          const r = document.createRange();
          try { r.setStart(sn, so); r.setEnd(en, eo); out.push(r); } catch (e) {}
        }
        return out;
      }

      // Floating toolbar
      let bar = null, mode = null, pending = null, target = null;
      function ensureBar() {
        if (bar) return bar;
        bar = document.createElement('div');
        bar.id = 'folio-bar';
        document.documentElement.appendChild(bar);
        bar.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
        bar.addEventListener('mouseup', (e) => { e.stopPropagation(); });
        return bar;
      }
      function btn(cls, label, title, fn) {
        const b = document.createElement('button');
        b.className = cls; b.textContent = label; b.title = title;
        b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); fn(); });
        return b;
      }
      function sep() { const s = document.createElement('span'); s.className = 'sep'; return s; }
      function showBar(rect, active) {
        const b = ensureBar();
        b.textContent = '';
        COLORS.forEach((c) => {
          const s = btn('sw' + (c === active ? ' on' : ''), '', 'Highlight ' + c, () => onColor(c));
          s.setAttribute('data-color', c);
          b.appendChild(s);
        });
        b.appendChild(sep());
        b.appendChild(btn('act', '✦ Ask Claude', 'Ask Claude about this passage', onAsk));
        if (mode === 'select') b.appendChild(btn('act', 'Copy', 'Copy', onCopy));
        else b.appendChild(btn('act danger', 'Remove', 'Remove highlight', onRemove));
        b.style.display = 'flex';
        const bw = b.offsetWidth, bh = b.offsetHeight;
        let top = rect.top - bh - 10;
        if (top < 8) top = rect.bottom + 10;
        let left = rect.left + rect.width / 2 - bw / 2;
        left = Math.max(8, Math.min(left, window.innerWidth - bw - 8));
        b.style.top = top + 'px';
        b.style.left = left + 'px';
        requestAnimationFrame(() => b.classList.add('show'));
      }
      function hideBar() {
        if (!bar) return;
        bar.classList.remove('show');
        bar.style.display = 'none';
        mode = null; pending = null; target = null;
      }
      function captureSelection() {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount || !document.body) return null;
        const r = sel.getRangeAt(0).cloneRange();
        const body = document.body;
        if (bar && (bar.contains(r.startContainer) || bar.contains(r.endContainer))) return null;
        if (!body.contains(r.startContainer)) r.setStart(body, 0);
        if (!body.contains(r.endContainer)) r.setEnd(body, body.childNodes.length);
        const start = offsetOf(r.startContainer, r.startOffset);
        const end = offsetOf(r.endContainer, r.endOffset);
        const text = r.toString().trim();
        if (!text || end <= start) return null;
        return { start, end, text, rect: r.getBoundingClientRect() };
      }
      function onColor(c) {
        if (mode === 'select' && pending) {
          post({ type: 'highlight', start: pending.start, end: pending.end, text: pending.text, color: c });
          window.getSelection().removeAllRanges();
        } else if (mode === 'mark' && target) {
          post({ type: 'recolor', id: target, color: c });
        }
        hideBar();
      }
      function onAsk() {
        const text = mode === 'select' && pending ? pending.text : marks(target).map((m) => m.textContent).join('');
        post({ type: 'ask', text });
        hideBar();
      }
      function onCopy() { if (pending) post({ type: 'copy', text: pending.text }); hideBar(); }
      function onRemove() { if (target) post({ type: 'remove', id: target }); hideBar(); }

      document.addEventListener('mousedown', (e) => { if (bar && !bar.contains(e.target)) hideBar(); });
      document.addEventListener('mouseup', (e) => {
        if (bar && bar.contains(e.target)) return;
        setTimeout(() => {
          const p = captureSelection();
          if (p) { mode = 'select'; pending = p; showBar(p.rect, null); return; }
          const m = e.target && e.target.closest ? e.target.closest('mark.folio-hl') : null;
          if (m) {
            mode = 'mark'; target = m.getAttribute('data-id');
            showBar(unionRect(marks(target)), m.getAttribute('data-color'));
          }
        }, 0);
      });

      let scrollTimer = null;
      window.addEventListener('scroll', () => {
        if (mode) hideBar();
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => {
          const max = document.documentElement.scrollHeight - window.innerHeight;
          post({ type: 'scroll', fraction: max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 1 });
        }, 250);
      }, { passive: true });

      document.addEventListener('keydown', (e) => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === 'ArrowRight') { post({ type: 'nav', dir: 1 }); e.preventDefault(); }
        else if (e.key === 'ArrowLeft') { post({ type: 'nav', dir: -1 }); e.preventDefault(); }
        else if (e.key === 'Escape') hideBar();
      });

      window.folio = {
        load(list) { list.forEach(wrap); },
        apply(h) { wrap(h); flash(h.id); },
        remove(id) { unwrap(id); },
        recolor(id, c) { marks(id).forEach((m) => m.setAttribute('data-color', c)); },
        scrollToHighlight(id, smooth) {
          const m = marks(id)[0];
          if (m) { m.scrollIntoView({ block: 'center', behavior: smooth ? 'smooth' : 'auto' }); flash(id); }
        },
        scrollToFragment(f, smooth) {
          const el = document.getElementById(f) || document.getElementsByName(f)[0];
          if (el) el.scrollIntoView({ block: 'start', behavior: smooth ? 'smooth' : 'auto' });
        },
        scrollToFraction(f) {
          const max = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo(0, Math.max(0, max * f));
        },
        highlightSelection(c) {
          const p = captureSelection();
          if (!p) return;
          post({ type: 'highlight', start: p.start, end: p.end, text: p.text, color: c });
          window.getSelection().removeAllRanges();
          hideBar();
        },
        askSelection() {
          const p = captureSelection();
          if (p) post({ type: 'ask', text: p.text });
          hideBar();
        },
        find(q, n, smooth) {
          const ranges = findRanges(q);
          const cur = n >= 0 && ranges.length ? ranges[Math.min(n, ranges.length - 1)] : null;
          if (canMark) {
            CSS.highlights.set('folio-find', new Highlight(...ranges));
            if (cur) CSS.highlights.set('folio-find-current', new Highlight(cur));
            else CSS.highlights.delete('folio-find-current');
          }
          if (!cur) return;
          if (!canMark) { const s = window.getSelection(); s.removeAllRanges(); s.addRange(cur); }
          const b = cur.getBoundingClientRect();
          window.scrollTo({ top: Math.max(0, window.scrollY + b.top - window.innerHeight * 0.4), behavior: smooth ? 'smooth' : 'auto' });
        },
        clearFind() {
          if (canMark) { CSS.highlights.delete('folio-find'); CSS.highlights.delete('folio-find-current'); }
        },
        setTheme(vars) {
          for (const k in vars) document.documentElement.style.setProperty(k, vars[k]);
        },
        setNext(title) {
          let f = document.getElementById('folio-next');
          if (!title) { if (f) f.remove(); return; }
          if (!f) {
            f = document.createElement('div');
            f.id = 'folio-next';
            f.addEventListener('click', () => post({ type: 'nav', dir: 1 }));
            document.documentElement.appendChild(f);
          }
          f.textContent = '';
          const card = document.createElement('div'); card.className = 'card';
          const left = document.createElement('div');
          const k = document.createElement('span'); k.className = 'k'; k.textContent = 'Next';
          const t = document.createElement('span'); t.className = 't'; t.textContent = title;
          left.appendChild(k); left.appendChild(t);
          const a = document.createElement('span'); a.className = 'arrow'; a.textContent = '→';
          card.appendChild(left); card.appendChild(a); f.appendChild(card);
        },
      };
    })();
    """#

    /// Runs at document start: installs the stylesheet and theme variables before first paint.
    static func bootstrap(theme: ThemeSnapshot) -> String {
        let cssJSON = jsonString(css)
        let varsJSON = (try? String(data: JSONSerialization.data(withJSONObject: theme.vars), encoding: .utf8)) ?? "{}"
        return """
        (function () {
          var vars = \(varsJSON);
          for (var k in vars) document.documentElement.style.setProperty(k, vars[k]);
          var s = document.createElement('style');
          s.id = 'folio-style';
          s.textContent = \(cssJSON);
          document.documentElement.appendChild(s);
        })();
        """
    }

    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(str.dropFirst().dropLast())
    }
}
