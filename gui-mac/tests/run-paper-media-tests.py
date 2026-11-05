#!/usr/bin/env python3
"""Standalone, offline real-WKWebView DOM tests for conversation Markdown/media.

Compiles only a small WebKit test host, never F. All generated files are temporary.
HTTPS requests are blocked by a content rule: this tests DOM/CSP and user gating,
not availability, decoding, or playback of third-party videos.
"""
import base64
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TESTS = r"""
(function () {
  var checks = [];
  function ok(value, name) { if (!value) throw new Error(name); checks.push(name); }
  function show(text) { F.setMessages([{role: 'assistant', text: text}]); return document.querySelector('.content'); }
  function q(selector) { return document.querySelector('#messages ' + selector); }
  function count(selector) { return document.querySelectorAll('#messages ' + selector).length; }
  function safeAttrs() {
    return Array.from(document.querySelectorAll('#messages *')).every(function (node) {
      return Array.from(node.attributes).every(function (a) {
        return !/^on/i.test(a.name) && !['style','srcdoc','srcset','formaction','xlink:href','id'].includes(a.name);
      });
    });
  }
  ok(F.ready, 'production scripts loaded under CSP');
  show('# Title\n\n**bold** and *emphasis* and ~~deleted~~ `inline`\n\n> quote\n\n3. three\n4. four\n\n- [x] done\n- [ ] todo\n\n| A | B |\n| :--- | ---: |\n| a | b |\n\n```js\nconst x = "<script>";\n```\n\n[paper](https://arxiv.org/abs/2601.00001)');
  ok(q('h1').textContent === 'Title' && q('strong') && q('em') && q('del'), 'Markdown headings/emphasis preserved');
  ok(q('blockquote') && q('ol').start === 3 && count('li') === 4, 'Markdown quote and list numbering preserved');
  ok(count('input:disabled') === 2 && q('input').checked, 'GFM task checkboxes remain inert');
  ok(q('table') && q('th[align="right"]') && q('pre code.language-js').textContent.includes('<script>'), 'table alignment and fenced code preserved');
  ok(q('a').href === 'https://arxiv.org/abs/2601.00001' && q('a').rel.includes('noreferrer'), 'normal HTTPS Markdown links preserved');
  var payloads = ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'javascript&#58;alert(1)', 'jav&#x09;ascript:alert(1)', 'file:///etc/passwd', 'data:text/html,bad', 'blob:https://arxiv.org/bad', 'http://arxiv.org/x', '//arxiv.org/x', '/relative', 'https://127.0.0.1/x', 'https://2130706433/x', 'https://[::1]/x', 'https://localhost/x', 'https://host.local/x', 'https://arxiv.org:8443/x', 'https://user:pass@arxiv.org/x', 'https://arxiv.org\\@evil.test/x'];
  payloads.forEach(function (url) {
    show('[bad](<' + url + '>)\n\n![bad](<' + url + '>)');
    ok(!q('a[href]') && !q('img[src]') && !q('video'), 'reject unsafe URL ' + url);
  });
  show('<script>window.__pwn = true</script>\n\n<img src="https://arxiv.org/a.png" onerror="window.__pwn=true">\n\n<video src="https://arxiv.org/a.mp4" autoplay></video>\n\n<iframe src="https://evil.test"></iframe>\n\n<svg onload="window.__pwn=true"></svg>');
  ok(!q('script, img, iframe, video, svg') && !window.__pwn, 'raw HTML/script/media never admitted');
  // Exercise the DOM whitelist independently from marked's raw-HTML rejection.
  var injected = null;
  marked.use({hooks:{postprocess:function(html) { return injected === null ? html : injected; }}});
  try {
    injected = '<p id="clobber" style="background:url(https://evil.test)" onclick="window.__pwn=true">safe <a href="javascript:alert(1)" onmouseover="window.__pwn=true">bad</a><a href="https://arxiv.org/a" ping="https://evil.test" download="x" target="evil">good</a><img src="https://arxiv.org/f.png" srcset="https://evil.test/x 2x" width="999999" height="999999" onerror="window.__pwn=true"><iframe srcdoc="bad"></iframe><math><mtext>bad</mtext></math><object data="file:///etc/passwd"></object><video src="https://arxiv.org/a.mp4" autoplay></video><input type="text" autofocus><form><input></form></p>';
    show('ignored');
    ok(safeAttrs() && !q('iframe, math, object, video, form, input') && !window.__pwn, 'DOM whitelist strips executable tags and all attacker attributes');
    ok(count('a[href]') === 2 && !q('a[ping], a[download], a[target]'), 'DOM whitelist validates link destinations');
    ok(q('img').alt === '论文图片' && !q('img[width], img[height], img[srcset]'), 'image metadata rebuilt, hostile dimensions removed');
  } finally { injected = null; }
  var images = ['https://arxiv.org/f.png', 'https://export.arxiv.org/f.png', 'https://alphaxiv.org/f.png', 'https://assets.alphaxiv.org/f.png', 'https://paper-assets.alphaxiv.org/f.png', 'https://thumbnails.assets.alphaxiv.org/f.png', 'https://author.github.io/f.png', 'https://raw.githubusercontent.com/user/repo/main/f.png', 'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg', 'https://img.youtube.com/vi/abcdefghijk/0.jpg'];
  images.forEach(function (url) {
    show('![Figure 1: method](' + url + ' "caption")');
    var image = q('img'), style = getComputedStyle(image);
    ok(image && image.src === url && image.alt === 'Figure 1: method' && image.referrerPolicy === 'no-referrer', 'trusted Markdown image ' + url);
    ok(style.maxWidth === '100%' && style.maxHeight === '460px' && style.objectFit === 'contain' && image.loading === 'lazy', 'bounded lazy image layout ' + url);
    ok(q('.media-caption').textContent.includes('Figure 1') && q('.media-source').href === url, 'image caption and source ' + url);
  });
  ['https://evil.test/a.png', 'https://arxiv.org.evil.test/a.png', 'https://evilarxiv.org/a.png', 'https://assets.alphaxiv.org.evil.test/a.png', 'https://anything.alphaxiv.org/a.png', 'https://github.io.evil.test/a.png', 'https://192.168.1.1/a.png', 'https://10.0.0.1/a.png', 'https://169.254.169.254/a.png'].forEach(function (url) {
    show('![Blocked](' + url + ')');
    ok(!q('img') && q('.media-blocked').textContent.includes('Blocked'), 'untrusted/private image blocked ' + url);
  });
  show('[![linked image](https://arxiv.org/f.png)](https://arxiv.org/abs/2601.00001)');
  ok(!q('a a') && q('.media-caption').textContent.includes('来源：arxiv.org'), 'linked images keep source without nested anchors');
  ['mp4', 'webm'].forEach(function (extension) {
    var url = 'https://author.github.io/demo.' + extension;
    show('[Demo](' + url + ')');
    ok(q('.media-load') && !q('video, source, iframe, img'), 'video has no remote media element before explicit click ' + extension);
    q('.media-load').click();
    var video = q('video');
    ok(video && video.src === url && video.controls && video.preload === 'none' && video.playsInline, 'click creates native controlled video ' + extension);
    ok(!video.autoplay && !video.hasAttribute('autoplay') && video.paused && !q('iframe'), 'video never autoplays or embeds HTML ' + extension);
    ok(q('.media-source').href === url && !q('.media-load'), 'video source retained and load button consumed ' + extension);
  });
  show('[Author video](https://tweet-media.assets.alphaxiv.org/demo.mp4)');
  ok(q('.media-load') && !q('video'), 'actual alphaXiv author video domain is click-gated');
  q('.media-load').click();
  ok(q('video').src === 'https://tweet-media.assets.alphaxiv.org/demo.mp4', 'alphaXiv author video retains its actual source');
  show('[YouTube](https://www.youtube.com/watch?v=abcdefghijk)');
  ok(q('.media-load') && !q('img, video, iframe'), 'YouTube thumbnail not requested before click');
  q('.media-load').click();
  ok(q('img').src === 'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg' && !q('video, iframe') && q('.media-source').href.includes('youtube.com/watch'), 'YouTube click loads only trusted thumbnail with source link');
  show('[Vimeo](https://vimeo.com/123456789)');
  ok(!q('video, img, iframe, button') && q('.paper-video').textContent.includes('来源网站观看'), 'Vimeo honestly offers external viewing only');
  show('[No embed](https://evil.test/demo.mp4)\n\n[Project](https://author.github.io/project/)');
  ok(!q('video, img, iframe, button') && count('a') === 2, 'unknown video hosts and project pages remain explicit normal links');
  F.setMessages([{role:'user',text:'<img src=x onerror=alert(1)>'}]);
  ok(!q('img') && q('.bubble').textContent.includes('<img'), 'user text is never HTML');
  F.setTheme('dark'); ok(document.documentElement.classList.contains('theme-dark'), 'theme API retained');
  F.showError('<script>bad</script>'); F.showCapacityReached('detail');
  ok(q('.error').textContent.includes('<script>') && q('.notice-detail'), 'existing error and capacity APIs retained');
  var csp = document.querySelector('meta[http-equiv="Content-Security-Policy"]').content;
  ok(csp.includes("frame-src 'none'") && csp.includes("connect-src 'none'") && !csp.includes('img-src *'), 'CSP denies frames/connect and limits image hosts');
  return JSON.stringify({passed:checks.length, checks:checks, network:'blocked by test host; remote availability/playback not tested'});
})();
"""

SWIFT = r'''
import AppKit
import WebKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
final class Host: NSObject, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    func start() {
        WKContentRuleListStore(url: directory.deletingLastPathComponent().appendingPathComponent("content-rules")).compileContentRuleList(forIdentifier: UUID().uuidString,
            encodedContentRuleList: """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
            """) { rule, error in
            guard let rule = rule else { self.fail("network rule: \(String(describing:error))"); return }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(rule)
            self.web = WKWebView(frame: NSRect(x:0,y:0,width:780,height:900), configuration:config)
            self.web.navigationDelegate = self
            self.window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:900), styleMask:[.borderless], backing:.buffered, defer:false)
            self.window.contentView = self.web
            self.web.loadFileURL(self.directory.appendingPathComponent("conversation.html"), allowingReadAccessTo:self.directory)
        }
    }
    func fail(_ message: String) { fputs("FAIL: \(message)\n", stderr); exit(1) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("navigation: \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("provisional: \(error)") }
    // Mirrors the native host's local-page-only policy. Video subresources must
    // not require any new page/frame navigation permission or embedded HTML.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.standardizedFileURL == directory.appendingPathComponent("conversation.html").standardizedFileURL,
           action.targetFrame?.isMainFrame == true { decisionHandler(.allow) }
        else { decisionHandler(.cancel); fail("unexpected navigation from media preview") }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = String(data:Data(base64Encoded:"__TESTS__")!, encoding:.utf8)!
        webView.evaluateJavaScript(script) { value, error in
            if let error = error { self.fail("DOM assertions: \(error)"); return }
            guard let result = value as? String else { self.fail("no result"); return }
            print(result)
            // A real CSP violation event, independent of the content blocker.
            webView.evaluateJavaScript("""
            window.__cspBlocked = false;
            document.addEventListener('securitypolicyviolation', function(e) { if (e.blockedURI.includes('127.0.0.1')) window.__cspBlocked = true; });
            var img = document.createElement('img'); img.src='https://127.0.0.1/blocked.png'; document.body.appendChild(img); true;
            """) { _, error in
                if let error = error { self.fail("CSP setup: \(error)"); return }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                    webView.evaluateJavaScript("window.__cspBlocked") { value, error in
                        guard error == nil, value as? Bool == true else { self.fail("WebKit CSP did not block private-host image"); return }
                        print("PASS: real WebKit CSP private-host request rejection")
                        exit(0)
                    }
                }
            }
        }
    }
}
let host = Host(URL(fileURLWithPath:CommandLine.arguments[1], isDirectory:true))
host.start()
DispatchQueue.main.asyncAfter(deadline:.now()+25) { host.fail("WebKit timeout") }
app.run()
'''


def main():
    with tempfile.TemporaryDirectory(prefix='f-paper-media-') as temporary:
        work = Path(temporary)
        resources = work / 'Resources'
        resources.mkdir()
        for name in ('conversation.html', 'conversation.js', 'marked.umd.js'):
            shutil.copy2(ROOT / 'Resources' / name, resources / name)
        source = work / 'main.swift'
        source.write_text(SWIFT.replace('__TESTS__', base64.b64encode(TESTS.encode()).decode()))
        binary = work / 'paper-media-tests'
        subprocess.run(['swiftc', '-module-cache-path', str(work / 'module-cache'), str(source), '-o', str(binary)], check=True, timeout=90)
        result = subprocess.run([str(binary), str(resources)], timeout=35, capture_output=True, text=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        result.check_returncode()


if __name__ == '__main__':
    main()
