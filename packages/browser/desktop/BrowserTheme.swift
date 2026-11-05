import WebKit

/// Shared by search results and destination pages, including dynamically loaded content.
/// CSS follows the WKWebView's inherited F appearance without reloading the page.
enum FBrowserTheme {
    static let script = #"""
    (() => {
      const style = document.createElement('style');
      style.id = 'f-browser-theme';
      style.textContent = `
        :root {
          color-scheme: light !important;
          --f-text: #45474c; --f-title: #18191c; --f-muted: #62656c;
          --f-line: rgba(0,0,0,.13); --f-surface: rgba(255,255,255,.38);
          --f-panel: #f4f4f5; --f-focus: #575b65;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            color-scheme: dark !important;
            --f-text: #c7c9ce; --f-title: #f5f5f7; --f-muted: #a7abb3;
            --f-line: rgba(255,255,255,.15); --f-surface: rgba(255,255,255,.045);
            --f-panel: #252629; --f-focus: #c7c9ce;
          }
        }
        :root, :root:not(#f-browser-theme-override) body, :root:not(#f-browser-theme-override) body :is(#root, #__next, main, [role=main]) {
          background: transparent !important;
        }
        :root:not(#f-browser-theme-override) body { color: var(--f-text) !important; }
        :root:not(#f-browser-theme-override) body *:not(svg, svg *, img, video, canvas, iframe) {
          color: var(--f-text) !important;
          -webkit-text-fill-color: currentColor !important;
          border-color: var(--f-line) !important;
          text-shadow: none !important;
        }
        :root:not(#f-browser-theme-override) body :is(a, h1, h2, h3, h4, h5, h6, strong, b, button, summary, label),
        :root:not(#f-browser-theme-override) body :is(a, h1, h2, h3, h4, h5, h6, button) * {
          color: var(--f-title) !important;
        }
        :root:not(#f-browser-theme-override) body :is(small, cite, figcaption, time),
        :root:not(#f-browser-theme-override) body :is(small, cite, figcaption, time) * { color: var(--f-muted) !important; }
        :root:not(#f-browser-theme-override) body [data-f-surface] { background-color: var(--f-surface) !important; box-shadow: none !important; }
        :root:not(#f-browser-theme-override) body [data-f-gradient] { background-image: none !important; }
        :root:not(#f-browser-theme-override) body :is(input:not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]), textarea, select, button) {
          background-color: var(--f-surface) !important;
          color: var(--f-title) !important; border-color: var(--f-line) !important;
        }
        :root:not(#f-browser-theme-override) body :is(input, textarea)::placeholder { color: var(--f-muted) !important; opacity: 1 !important; }
        :root:not(#f-browser-theme-override) body :is(dialog, [role=dialog], [role=menu], [role=listbox], [popover]) {
          background-color: var(--f-panel) !important;
        }
        :root:not(#f-browser-theme-override) body :focus-visible { outline: 2px solid var(--f-focus) !important; outline-offset: 3px; }
        :root:not(#f-browser-theme-override) body a:hover { text-decoration: underline !important; text-underline-offset: 3px; }
        :root:not(#f-browser-theme-override) body mark, :root:not(#f-browser-theme-override) body ::selection { background-color: var(--f-line) !important; color: var(--f-title) !important; }
      `;
      const isSearch = () => /(^|\.)google\.(com|[a-z]{2}|com\.[a-z]{2}|co\.[a-z]{2})$/.test(location.hostname) && location.pathname === '/search';
      const searchStyle = document.createElement('style');
      searchStyle.textContent = `
        :root:not(#f-browser-theme-override) body :is(#hdr, #searchform, #sfcnt, #sf, #gb, #gbw, #gbar, #logo, #logocont, #top_nav, #appbar, #hdtb, .KP7LCb, .kBeHyf, [role=navigation]:has(a[href*='tbm=isch']), [role=navigation]:has(a[href*='udm=2']), img[alt='Google'], form[action='/search'], form:has([name=q]), [role=search]) { display: none !important; }
        :root:not(#f-browser-theme-override) body { margin: 0 !important; min-width: 0 !important; font-family: -apple-system, BlinkMacSystemFont, sans-serif !important; }
        :root:not(#f-browser-theme-override) body :is(div, section, header, footer, nav, article, table, tr, td, th, ul, li, span) { background-color: transparent !important; box-shadow: none !important; }
        :root:not(#f-browser-theme-override) body :is(#hdr, #header, #top_nav, #appbar, #hdtb) {
          background: transparent !important; box-shadow: none !important; border: 0 !important;
          min-height: 0 !important; height: auto !important; position: static !important;
          box-sizing: border-box !important; max-width: 960px !important; margin: 0 auto 12px !important; padding: 0 28px !important;
        }
        :root:not(#f-browser-theme-override) body :is(#main, #rcnt, #search, #center_col, #rso, #res, #bres) {
          background: transparent !important; box-shadow: none !important; border: 0 !important;
          margin: 0 !important; padding: 0 !important; width: auto !important; min-width: 0 !important; max-width: none !important;
        }
        :root:not(#f-browser-theme-override) body #main { box-sizing: border-box !important; max-width: 960px !important; margin: 0 auto !important; padding: 10px 28px 40px !important; }
        :root:not(#f-browser-theme-override) body :is(.g, .MjjYud) { background: transparent !important; box-shadow: none !important; }
        :root:not(#f-browser-theme-override) body h3 { font-size: 20px !important; line-height: 1.4 !important; font-weight: 500 !important; margin-bottom: 8px !important; }
        :root:not(#f-browser-theme-override) body #search a { text-decoration: none; }
        :root:not(#f-browser-theme-override) body :is(.VwiC3b, .IsZvec, .st, [data-sncf]),
        :root:not(#f-browser-theme-override) body :is(.VwiC3b, .IsZvec, .st, [data-sncf]) * { color: var(--f-text) !important; line-height: 1.65 !important; }
        :root:not(#f-browser-theme-override) body :is(cite, .byrV5b, .VuuXrf) { font-size: 12px !important; font-style: normal !important; }
        @media (max-width: 540px) { :root:not(#f-browser-theme-override) body #main { padding: 8px 20px 28px !important; } }
      `;
      const mount = () => {
        const root = document.head || document.documentElement;
        if (!root) return;
        if (!style.isConnected) root.appendChild(style);
        if (isSearch()) { if (!searchStyle.isConnected) root.appendChild(searchStyle); }
        else searchStyle.remove();
      };
      // Only neutral painted surfaces are adapted; photos, SVGs, canvas and brand
      // colours retain their pixels. Inspect incremental DOM work in bounded batches.
      const pending = new Set();
      let scheduled = false;
      const inspect = e => {
        if (!(e instanceof HTMLElement) || /^(STYLE|SCRIPT|LINK|META|IMG|VIDEO|CANVAS|IFRAME)$/.test(e.tagName)) return;
        e.removeAttribute('data-f-surface'); e.removeAttribute('data-f-gradient');
        const c = getComputedStyle(e);
        const rgb = c.backgroundColor.match(/[\d.]+/g)?.map(Number);
        if (rgb && (rgb.length < 4 || rgb[3] > .02) && Math.max(...rgb.slice(0,3)) - Math.min(...rgb.slice(0,3)) < 32)
          e.setAttribute('data-f-surface', '');
        if (/gradient\(/.test(c.backgroundImage) && !/url\(/.test(c.backgroundImage)) e.setAttribute('data-f-gradient', '');
      };
      let walker = null;
      const flush = () => {
        mount();
        let budget = 250;
        while (budget-- > 0) {
          if (!walker) {
            const e = pending.values().next().value;
            if (!e) break;
            pending.delete(e);
            if (!e.isConnected) continue;
            inspect(e); walker = document.createTreeWalker(e, NodeFilter.SHOW_ELEMENT);
          }
          const e = walker.nextNode();
          if (e) inspect(e); else walker = null;
        }
        scheduled = !!walker || pending.size > 0;
        if (scheduled) setTimeout(flush, 0);
      };
      const enqueue = e => {
        if (!(e instanceof HTMLElement)) return;
        // A subtree replaces its descendants in the queue, keeping large SPA
        // updates from accumulating one traversal per inserted element.
        for (const old of pending) { if (old.contains(e)) return; if (e.contains(old)) pending.delete(old); }
        pending.add(e);
        if (!scheduled) { scheduled = true; setTimeout(flush, 0); }
      };
      mount();
      const observer = new MutationObserver(records => {
        for (const r of records) {
          if (r.type === 'attributes') enqueue(r.target);
          else for (const e of r.addedNodes) enqueue(e);
        }
      });
      observer.observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style']});
      document.addEventListener('DOMContentLoaded', () => { mount(); enqueue(document.body); }, {once: true});
      window.addEventListener('popstate', () => { mount(); enqueue(document.body); });
      enqueue(document.body);
    })()
    """#
}
