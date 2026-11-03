#!/usr/bin/env python3
"""Native browser/session and Node↔CryptoKit IPC tests on isolated fixture data."""
from pathlib import Path
import subprocess, tempfile, os, threading, uuid, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(tempfile.mkdtemp(prefix='f-browser-native-'))
SOURCE=r'''
import AppKit
import WebKit
enum BoardStore { static let appSupport = URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_BROWSER_TEST_ROOT"]!) }
func check(_ value: Bool,_ name:String) { guard value else { fatalError("FAIL: "+name) };print("PASS: "+name);fflush(stdout) }
@main struct Tests {
 @MainActor static func call(_ p:BrowserPlugin,_ input:[String:Any]) async -> [String:Any] { await withCheckedContinuation { c in p.command(input) { c.resume(returning:$0) } } }
 @MainActor static func readReady(_ p:BrowserPlugin) async throws -> [String:Any] {
  for _ in 0..<200 {
   let state=await call(p,["action":"read"])
   if state["ok"] as? Bool==true, let value=state["value"] as? [String:Any], value["snapshot"] != nil { return value }
   try await Task.sleep(nanoseconds:50_000_000)
  }
  let state=await call(p,["action":"state"])
  fatalError("Browser did not finish navigation: \(state)")
 }
 @MainActor static func wait(_ web:WKWebView,_ script:String) async throws {
  for _ in 0..<200 { if (try? await web.evaluateJavaScript(script)) as? Bool == true { return };try await Task.sleep(nanoseconds:50_000_000) }
  print("THEME DIAGNOSTIC:", (try? await web.evaluateJavaScript("JSON.stringify({url:location.href,style:!!document.querySelector('#f-browser-theme'),body:document.body?.outerHTML.slice(0,7000),panel:document.querySelector('#panel')?getComputedStyle(document.querySelector('#panel')).backgroundColor:null})")) ?? "unavailable");fflush(stdout)
  fatalError("Timed out: "+script)
 }
 @MainActor static func capture(_ web:WKWebView,_ name:String) async throws {
  let image:NSImage = try await withCheckedThrowingContinuation { c in web.takeSnapshot(with:nil) { image,error in if let image { c.resume(returning:image) } else { c.resume(throwing:error!) } } }
  let composed=NSImage(size:image.size);composed.lockFocus()
  (ThemeColors.isDark(web.effectiveAppearance) ? NSColor.black : NSColor.white).setFill()
  NSRect(origin:.zero,size:image.size).fill();image.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1);composed.unlockFocus()
  let bitmap=NSBitmapImageRep(data:composed.tiffRepresentation!)!
  try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_BROWSER_SCREENSHOTS"]!).appendingPathComponent(name+".png"))
 }
 @available(macOS 14.0, *) @MainActor static func persistent(_ mode:String) async throws {
  let store=WKWebsiteDataStore(forIdentifier:UUID(uuidString:ProcessInfo.processInfo.environment["F_BROWSER_TEST_PROFILE"]!)!)
  let plugin=BrowserPlugin(directory:BoardStore.appSupport,session:FBrowserSession(store:store))
  plugin.setEnabled(true);plugin.activate()
  let base=ProcessInfo.processInfo.environment["F_BROWSER_TEST_ARTICLE_URL"]!.replacingOccurrences(of:"/article",with:"")
  plugin.open(URL(string:base+"/account")!)
  try await wait(plugin.web!,"document.readyState==='complete' && document.querySelector('#account')!==null")
  if mode == "write" {
   try await plugin.web!.evaluateJavaScript("localStorage.setItem('f-persistent-fixture','saved');document.cookie='f_persist=fixture; Max-Age=3600; Path=/'")
   let cookies=await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning:$0) } }
   check(cookies.contains{$0.name=="f_persist"},"isolated persistent profile accepts browser cookie")
   try await Task.sleep(nanoseconds:1_000_000_000)
  } else {
   check((try await plugin.web!.evaluateJavaScript("localStorage.getItem('f-persistent-fixture')==='saved' && document.cookie.includes('f_persist=fixture')")) as? Bool == true,"cookie and localStorage survive a fresh browser process without Chrome")
   await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast) { c.resume() } }
  }
  plugin.shutdown()
 }
 @MainActor static func main() async throws {
  _=NSApplication.shared;NSApplication.shared.setActivationPolicy(.accessory)
  if let mode=ProcessInfo.processInfo.environment["F_BROWSER_PROFILE_MODE"], #available(macOS 14.0, *) { try await persistent(mode);return }
  check(try FBrowserSession.address("alphaxiv.org/abs/2401.12345").absoluteString == "https://alphaxiv.org/abs/2401.12345","bare domains become HTTPS URLs")
  check(try FBrowserSession.address("中文 paper attention").host == "www.google.com","free text uses Google search")
  check(FBrowserSession.displayAddress(URL(string:"https://www.google.com.hk/search?q=%E9%80%8F%E6%98%8E+glass%2B")!) == "透明 glass+", "regional Google URLs display the decoded search query")
  check(FBrowserSession.displayAddress(URL(string:"https://google.com.evil.test/search?q=secret")!).hasPrefix("https://"), "lookalike hosts retain their actual URL")
  for text in ["javascript:alert(1)","file:///tmp/private","https://user:secret@example.org"] { do { _=try FBrowserSession.address(text);fatalError("unsafe URL") } catch { print("PASS: unsafe URL rejected") } }
  let store=WKWebsiteDataStore.nonPersistent(),session=FBrowserSession(store:store),root=BoardStore.appSupport
  let plugin=BrowserPlugin(directory:root.appendingPathComponent("browser"),session:session)
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=plugin.view
  plugin.setEnabled(true);plugin.activate();window.orderFront(nil);window.display()
  let web=plugin.web!;check(web.configuration.websiteDataStore === store,"browser uses the shared website profile")
  plugin.view.layout()
  let field=plugin.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
  check(field.placeholderString?.isEmpty != false,"search field has no placeholder text")
  check(field.frame.width < 480 && abs(field.frame.midY - (plugin.view.bounds.height - 25)) < 1,"compact search field aligns with the host button row")
  check(web.frame.maxY == plugin.view.bounds.height - FChrome.toolbarHeight - 36,"web content starts below the address and navigation rows")
  web.loadHTMLString("<html><body><h1>Browser fixture</h1><button onclick=\"document.querySelector('h1').textContent='CLICKED'\">Press</button><input name='normal'><input type='password' value='SECRET_FIXTURE'><input type='hidden' value='HIDDEN_FIXTURE'></body></html>",baseURL:URL(string:"https://app.example.test"))
  for _ in 0..<200 { if !web.isLoading, (try? await web.evaluateJavaScript("document.body?.innerText.includes('Browser fixture')")) as? Bool == true { break };try await Task.sleep(nanoseconds:50_000_000) }
  let state=await call(plugin,["action":"read"]),value=state["value"] as! [String:Any]
  check(state["ok"] as? Bool == true && !(String(describing:value).contains("SECRET_FIXTURE")),"page snapshots do not expose password values")
  let links=value["links"] as! [[String:Any]],target=links.first{ $0["label"] as? String == "Press" }!["id"] as! Int
  let stale=await call(plugin,["action":"click","target":target,"snapshot":"wrong"]);check(stale["ok"] as? Bool == false,"stale snapshot actions are rejected")
  let clicked=await call(plugin,["action":"click","target":target,"snapshot":value["snapshot"]!]);check(clicked["ok"] as? Bool == true,"Agent click targets the actual current page")
  check((try await web.evaluateJavaScript("document.querySelector('h1').textContent")) as? String == "CLICKED","click executes without a separate model or page bridge")
  let article=ProcessInfo.processInfo.environment["F_BROWSER_TEST_ARTICLE_URL"]!
  let searchHTML="""
  <html><head><style>body{background:white;color:#202124;font:16px Arial}#sfcnt{background:white;height:140px}#search h3{color:#1a0dab}#main{margin-left:180px;min-width:900px}.g{margin:0 0 32px;background:#fff}.VwiC3b{color:#202124}cite{color:#202124}.card{background:#fafafa}</style></head><body>
  <div id="sfcnt"><div id="logo">Google</div><form action="/search"><input name="q" value="F transparent browser"></form></div><div id="top_nav">全部 图片 视频 新闻</div>
  <div id="main"><div id="search"><div id="rso"><div class="g"><cite>example.test · 界面设计</cite><a id="result" href="\(article)"><h3>透明玻璃，让内容自然呈现</h3></a><div class="VwiC3b">搜索框延续 F 的玻璃质感。标题清晰，简介使用更明亮的灰色，阅读轻松自然。</div></div>
  <div class="g"><cite>design.example · 阅读体验</cite><a href="\(article)"><h3>简洁的黑白主题与网页阅读</h3></a><div class="VwiC3b">搜索结果与内容页面随主题切换，保留图片、交互与网页原有布局。</div></div></div></div></div></body></html>
  """
  plugin.applyAppearance(dark:true)
  web.loadHTMLString(searchHTML,baseURL:URL(string:"https://www.google.com.hk/search?q=F%20transparent%20browser"))
  try await wait(web,"document.querySelector('#result') !== null && document.querySelector('#f-browser-theme') !== null")
  for dark in [true,false,true] {
   plugin.applyAppearance(dark:dark)
   let title=dark ? "rgb(245, 245, 247)" : "rgb(24, 25, 28)",text=dark ? "rgb(199, 201, 206)" : "rgb(69, 71, 76)"
   try await wait(web,"getComputedStyle(document.querySelector('h3')).color === '\(title)'")
   check((try await web.evaluateJavaScript("getComputedStyle(document.querySelector('#sfcnt')).display === 'none' && getComputedStyle(document.querySelector('#top_nav')).display === 'none'")) as? Bool == true,"Google search chrome and category row hidden in \(dark ? "dark" : "light") theme")
   check((try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.VwiC3b')).color === '\(text)'")) as? Bool == true,"readable search snippets in \(dark ? "dark" : "light") theme")
   check((try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth && getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)'")) as? Bool == true,"transparent search results fit the window")
   try await capture(web,"search-\(dark ? "dark" : "light")")
  }
  // Follow an actual search result, retaining the same page/profile and theme.
  try await web.evaluateJavaScript("document.querySelector('#result').click()")
  try await wait(web,"document.querySelector('#article') !== null && !document.querySelector('#sfcnt')")
  try await wait(web,"document.querySelector('#panel').hasAttribute('data-f-surface')")
  for dark in [true,false] {
   plugin.applyAppearance(dark:dark)
   let title=dark ? "rgb(245, 245, 247)" : "rgb(24, 25, 28)"
   try await wait(web,"getComputedStyle(document.querySelector('h1')).color === '\(title)'")
   check((try await web.evaluateJavaScript("getComputedStyle(document.querySelector('#panel')).backgroundColor !== 'rgb(255, 255, 255)' && getComputedStyle(document.querySelector('#brand')).backgroundColor === 'rgb(210, 50, 50)' && getComputedStyle(document.querySelector('img')).filter === 'none'")) as? Bool == true,"destination surfaces adapt while image and brand colours survive")
   try await web.evaluateJavaScript("document.querySelector('input').value='保留输入';document.querySelector('button').click()")
   check((try await web.evaluateJavaScript("document.querySelector('#action').textContent === '已展开' && document.querySelector('input').value === '保留输入'")) as? Bool == true,"destination forms and buttons work after theme changes")
   try await web.evaluateJavaScript("(()=>{document.querySelector('#late')?.remove();const p=document.createElement('p');p.id='late';p.style='background:white;color:black';p.textContent='动态加载的内容同样适配主题';document.querySelector('article').append(p)})()")
   try await wait(web,"document.querySelector('#late').hasAttribute('data-f-surface') && getComputedStyle(document.querySelector('#late')).color !== 'rgb(0, 0, 0)'")
   try await capture(web,"article-\(dark ? "dark" : "light")")
  }
  window.setContentSize(NSSize(width:390,height:650));window.display()
  web.loadHTMLString(searchHTML,baseURL:URL(string:"https://www.google.com/search?q=F"))
  try await wait(web,"document.querySelector('#result') !== null")
  check((try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth")) as? Bool == true,"search results fit narrow windows")
  try await capture(web,"search-narrow")
  window.setContentSize(NSSize(width:900,height:650));window.display()
  let base=article.replacingOccurrences(of:"/article",with:"")
  plugin.open(URL(string:base+"/login")!)
  try await wait(web,"document.querySelector('#signin')!==null")
  // Simulate the human entering fixture credentials directly into WebKit, not through the Agent tool.
  try await web.evaluateJavaScript("document.querySelector('[name=user]').value='fixture';document.querySelector('[name=password]').value='fixture-password';document.querySelector('#signin').submit()")
  try await wait(web,"document.querySelector('#account')?.textContent==='signed in'")
  let first=plugin.selectedTab!,second=plugin.newTab()
  plugin.open(URL(string:base+"/account")!)
  try await wait(second.web,"document.querySelector('#account')?.textContent==='signed in'")
  check(first.web !== second.web && second.web.configuration.websiteDataStore === store,"tabs own independent pages and share F login")
  try await second.web.evaluateJavaScript("document.querySelector('input').value='second tab draft'")
  plugin.selectTab(first);check(plugin.web === web,"switching tabs restores the original WebKit instance")
  let firstRead=await call(plugin,["action":"read"]),firstState=firstRead["value"] as! [String:Any]
  plugin.selectTab(second)
  let wrongTab=await call(plugin,["action":"click","target":0,"snapshot":firstState["snapshot"]!,"tabId":second.id])
  check(wrongTab["ok"] as? Bool == false,"snapshot from another tab cannot act on the selected page")
  check((try await second.web.evaluateJavaScript("document.querySelector('input').value")) as? String == "second tab draft","tab switches preserve form drafts")
  plugin.open(URL(string:base+"/two")!);try await wait(second.web,"document.querySelector('#two')!==null")
  _=await call(plugin,["action":"back","tabId":second.id]);try await wait(second.web,"document.querySelector('#account')!==null")
  _=await call(plugin,["action":"forward","tabId":second.id]);try await wait(second.web,"document.querySelector('#two')!==null")
  check(second.web.canGoBack,"real back and forward navigation preserve per-tab history")
  let extra=plugin.newWindow();extra.open(URL(string:base+"/account")!)
  try await wait(extra.web!,"document.querySelector('#account')?.textContent==='signed in'")
  check(extra.web !== web && extra.web!.window !== window,"new browser window has its own page, window and shared login")
  extra.applyAppearance(dark:false)
  check(extra.view.window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua,"independent window follows the browser appearance")
  plugin.windows.first!.close();check(plugin.windows.isEmpty && plugin.tabs.count==2,"closing a browser window leaves workspace tabs intact")
  plugin.selectTab(first)
  try await web.evaluateJavaScript("void window.open('/popup','f-login-fixture')")
  for _ in 0..<200 { if let popup=plugin.windows.first?.browser.web, (try? await popup.evaluateJavaScript("document.querySelector('#popup')!==null")) as? Bool == true { break };try await Task.sleep(nanoseconds:50_000_000) }
  check(plugin.windows.count==1,"window.open creates a real WebKit popup")
  let popup=plugin.windows.first!.browser.web!
  try await popup.evaluateJavaScript("window.opener.document.body.setAttribute('data-popup-result','returned');window.close()")
  try await wait(web,"document.body.getAttribute('data-popup-result')==='returned'")
  for _ in 0..<100 { if plugin.windows.isEmpty { break };try await Task.sleep(nanoseconds:20_000_000) }
  check(plugin.windows.isEmpty,"popup preserves opener and closes after login-style handoff")
  try await web.evaluateJavaScript("(()=>{const a=document.createElement('a');a.href='/two';a.target='_blank';document.body.append(a);a.click()})()")
  for _ in 0..<200 { if let target=plugin.windows.first?.browser.web, (try? await target.evaluateJavaScript("document.querySelector('#two')!==null")) as? Bool == true { break };try await Task.sleep(nanoseconds:50_000_000) }
  check(plugin.windows.first?.browser.web?.url?.path=="/two","target=_blank opens without replacing the current page")
  plugin.windows.first!.close()
  for _ in 0..<6 {
   plugin.open(URL(string:base+"/offline")!)
   var failed=false
   for _ in 0..<100 { let state=await call(plugin,["action":"state"]);if state["ok"] as? Bool==false { failed=true;break };try await Task.sleep(nanoseconds:20_000_000) }
   check(failed,"abrupt offline connection reports failure without hanging")
   plugin.open(URL(string:base+"/account")!);try await wait(web,"document.querySelector('#account')?.textContent==='signed in' && document.readyState==='complete'")
  }
  check((await call(plugin,["action":"read"]))["ok"] as? Bool==true,"browser recovers after repeated connection loss and keeps login")
  plugin.webViewWebContentProcessDidTerminate(web)
  check((await call(plugin,["action":"read"]))["ok"] as? Bool==false,"terminated web process is reported without replaying navigation")
  _=await call(plugin,["action":"reload"]);try await wait(web,"document.querySelector('#account')?.textContent==='signed in'")
  for _ in 0..<10 { _=plugin.newTab() }
  for i in 0..<240 { plugin.selectTab(plugin.tabs[i % plugin.tabs.count]);plugin.applyAppearance(dark:i%2==0) }
  for tab in Array(plugin.tabs) where tab !== first { plugin.closeTab(tab) }
  plugin.selectTab(first)
  check(plugin.tabs.count==1 && plugin.web===web,"240 switches and background tab closes preserve the selected page")
  let currentState=try await readReady(plugin)
  let linksNow=currentState["links"] as! [[String:Any]]
  if let input=linksNow.first(where:{$0["tag"] as? String=="INPUT"}) {
   check((await call(plugin,["action":"fill","tabId":first.id,"snapshot":currentState["snapshot"]!,"target":input["id"]!,"text":"same tab works"]))["ok"] as? Bool==true,"explicit tabId retains a valid snapshot on the same tab")
  }
  let listed=await call(plugin,["action":"tabs"]);check(((listed["value"] as! [String:Any])["tabs"] as! [[String:Any]]).count==1,"Agent tab list reflects live tabs")
  let temporary=await call(plugin,["action":"newTab"]),temporaryID=(temporary["value"] as! [String:Any])["tabId"]!
  _=await call(plugin,["action":"closeTab","tabId":temporaryID])
  check((await call(plugin,["action":"selectTab","tabId":temporaryID]))["ok"] as? Bool==false,"closed tab IDs cannot select a replacement page")
  window.setContentSize(NSSize(width:390,height:650));window.display();plugin.view.layoutSubtreeIfNeeded()
  let toolbarButtons=plugin.view.subviews.compactMap{$0 as? NSButton}
  check(toolbarButtons.allSatisfy{plugin.view.bounds.contains($0.frame)},"browser controls stay inside a narrow window")
  let tabScroll=plugin.view.subviews.compactMap{$0 as? NSScrollView}.first!
  check(tabScroll.documentView!.frame.width >= 140 && tabScroll.documentView!.subviews.first!.frame.width==140,"tab label and close control have visible frames")
  for key in ["t","w"] {
   let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:0)!
   check(plugin.view.performKeyEquivalent(with:event),"Cmd+\(key) is handled by browser workspace")
  }
  check(plugin.tabs.count==1,"keyboard new/close tab preserves the original page")
  plugin.applyAppearance(dark:false)
  window.appearance=NSAppearance(named:.aqua);window.backgroundColor = .white
  window.makeKeyAndOrderFront(nil);window.display()
  try await Task.sleep(nanoseconds:300_000_000)
  if ProcessInfo.processInfo.environment["F_BROWSER_CAPTURE_UI"]=="1" {
   let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
   capture.arguments=["-x","-l",String(window.windowNumber),URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_BROWSER_SCREENSHOTS"]!).appendingPathComponent("browser-window.png").path]
   try capture.run();capture.waitUntilExit()
  }
  window.setContentSize(NSSize(width:900,height:650));window.display()
  if ProcessInfo.processInfo.environment["F_BROWSER_LIVE_SEARCH"] == "1" {
   plugin.open(URL(string:"https://www.google.com.hk/search?q=transparent%20glass%20design")!)
   try await wait(web,"new URLSearchParams(location.search).get('q') === 'transparent glass design' && !document.querySelector('#result') && document.querySelector('h3') !== null && document.readyState === 'complete'")
   check((try await web.evaluateJavaScript("Array.from(document.querySelectorAll('input[name=q], textarea[name=q]')).every(e=>e.getClientRects().length===0)")) as? Bool == true,"live Google never shows a second search box")
   check((try await web.evaluateJavaScript("Array.from(document.querySelectorAll('#top_nav, #hdtb, #appbar, .KP7LCb, .kBeHyf')).every(e=>e.getClientRects().length===0)")) as? Bool == true,"live Google category row is hidden")
   let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as! String
   try html.write(to:URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_BROWSER_SCREENSHOTS"]!).appendingPathComponent("live-google.html"),atomically:true,encoding:.utf8)
   for dark in [true,false] {
    plugin.applyAppearance(dark:dark)
    let title=dark ? "rgb(245, 245, 247)" : "rgb(24, 25, 28)"
    try await wait(web,"getComputedStyle(document.querySelector('h3')).color === '\(title)'")
    try await capture(web,"live-google-\(dark ? "dark" : "light")")
   }
   print("PASS: live Google results rendered in both themes")
  }
  let cookies:[[String:Any]]=[["domain":".example.test","path":"/","name":"f_fixture_session","value":"SECRET_COOKIE_FIXTURE","secure":true,"httpOnly":true,"sameSite":"lax"]]
  let payload:[String:Any]=["action":"importSession","origin":"https://app.example.test","cookies":cookies,"storage":["authToken":"FIXTURE_TOKEN"]]
  let imported=await call(plugin,payload);check(imported["ok"] as? Bool == true && !String(describing:imported).contains("SECRET_COOKIE_FIXTURE"),"session import returns counts rather than credentials")
  let all:[HTTPCookie]=await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning:$0) } }
  let cookie=all.first{$0.name=="f_fixture_session"};check(cookie?.isSecure == true && cookie?.isHTTPOnly == true,"secure and HttpOnly session-cookie flags are preserved")
  for i in 0..<30 { var next=payload;next["storage"]=["authToken":"FIXTURE_\(i)"];let result=await call(plugin,next);check(result["ok"] as? Bool == true,"session refresh \(i)") }
  check(web.configuration.userContentController.userScripts.count <= 2,"repeated session refresh replaces scripts with bounded memory")
  for origin in ["https://accounts.google.com","https://www.google.cn"] { let result=await call(plugin,["action":"importSession","origin":origin,"cookies":cookies]);check(result["ok"] as? Bool == false,"Google credentials are not imported") }
  var bad=payload;bad["cookies"]=[["domain":"evil.test","path":"/","name":"bad","value":"x"]];check((await call(plugin,bad))["ok"] as? Bool == false,"foreign-domain cookies are rejected before mutation")
  let ipc=root.appendingPathComponent("ipc"),bridge=BrowserBridge(directory:ipc);try bridge.start { input,reply in reply(["ok":true,"value":["action":input["action"] ?? ""]]) }
  let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["F_BROWSER_TEST_NODE"]!);process.arguments=["--input-type=module","-e","import {browserRequest} from '"+ProcessInfo.processInfo.environment["F_BROWSER_TRANSPORT"]!+"';console.log(JSON.stringify(await browserRequest({action:'state',secret:'NEVER_PLAINTEXT'})));" ];process.environment=ProcessInfo.processInfo.environment.merging(["F_BROWSER_DIRECTORY":ipc.path]){_,v in v};process.standardOutput=output;process.standardError=output;try process.run()
  for _ in 0..<300 { if !process.isRunning {break};try await Task.sleep(nanoseconds:20_000_000) }
  check(!process.isRunning && process.terminationStatus==0,"real Node encrypted transport interoperates with Swift CryptoKit")
  let reply=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)!;check(reply.contains("state"),"native IPC responds through the per-user endpoint")
  bridge.stop();check(!FileManager.default.fileExists(atPath:ipc.appendingPathComponent("endpoint.json").path),"plugin shutdown unregisters native control endpoint")
  _=plugin.newWindow();_=plugin.newTab()
  plugin.setEnabled(false);check(plugin.web == nil && plugin.tabs.isEmpty && plugin.windows.isEmpty,"disabling browser releases every tab and popup")
  plugin.setEnabled(true);plugin.activate();check(plugin.tabs.count==1,"re-enabling creates one fresh page without stale observers")
  plugin.shutdown()
  window.close();print("ALL BROWSER TESTS PASSED; no real Chrome credentials accessed")
 }
}
'''
(OUT/'Tests.swift').write_text(SOURCE)
command=['swiftc','-parse-as-library','-target','arm64-apple-macos11.0','-module-cache-path',str(OUT/'cache'),'-o',str(OUT/'tests'),str(ROOT/'Core/Plugins.swift'),str(ROOT/'Core/Kernel.swift'),str(ROOT/'Core/UI/Chrome.swift'),*map(str,sorted((ROOT/'Plugins/Browser').glob('*.swift'))),str(OUT/'Tests.swift')]
print('OUTPUT:',OUT,flush=True)
compiled=subprocess.run(command,capture_output=True,text=True,timeout=180);(OUT/'compile.log').write_text(compiled.stdout+compiled.stderr);print(compiled.stdout+compiled.stderr,flush=True)
if compiled.returncode:raise SystemExit(compiled.returncode)
class ArticleFixture(BaseHTTPRequestHandler):
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  if self.path=='/login' and b'user=fixture' in body and b'password=fixture-password' in body:
   self.send_response(303);self.send_header('Set-Cookie','f_login=fixture; HttpOnly; Path=/');self.send_header('Location','/account');self.end_headers()
  else: self.send_error(401)
 def do_GET(self):
  if self.path=='/offline':
   self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
  pages={'/login':'<form id="signin" method="post" action="/login"><input name="user"><input name="password" type="password"><button>Sign in</button></form>',
         '/account':'<div id="account">'+('signed in' if 'f_login=fixture' in self.headers.get('Cookie','') else 'signed out')+'</div><input name="draft"><a href="/two">next</a>',
         '/two':'<h1 id="two">Second page</h1>', '/popup':'<h1 id="popup">Login handoff</h1>'}
  if self.path in pages:
   self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(('<!doctype html><title>F browser fixture</title>'+pages[self.path]).encode());return
  page='''<!doctype html><html><head><meta charset="utf-8"><style>body{margin:32px;font:16px -apple-system;background:#fff;color:#111}article{max-width:720px;margin:auto}#panel{padding:24px;background:#fff;border:1px solid #ddd;border-radius:16px}h1{color:#111;font-size:28px}p{line-height:1.8}img{width:100%;height:120px;object-fit:cover;border-radius:12px}input,button{padding:10px;border:1px solid #ddd;border-radius:8px}#brand{background:rgb(210,50,50);width:24px;height:8px}</style></head><body><article id="article"><small>DESIGN · 阅读</small><h1>透明玻璃，让内容自然呈现</h1><p>保持轻盈的页面层次，让文字、图片与交互融入 F 的黑白主题。</p><div id="panel"><h2>简洁，也要清晰易读</h2><p>这是从搜索结果点击打开的内容页。页面原有布局与图片保留，深浅背景和文字随主题同步。</p><img alt="原始图片" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='720' height='120'%3E%3Crect width='720' height='120' fill='%237d9aa5'/%3E%3Ccircle cx='540' cy='60' r='38' fill='%23eed9af'/%3E%3C/svg%3E"><p><input placeholder="输入内容"><button onclick="document.querySelector('#action').textContent='已展开'">展开内容</button></p><span id="action"></span><div id="brand"></div></div></article></body></html>'''
  body=page.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(body)
 def log_message(self,*args): pass
server=ThreadingHTTPServer(('127.0.0.1',0),ArticleFixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
env=dict(os.environ,F_BROWSER_TEST_ROOT=str(OUT/'data'),F_BROWSER_TEST_NODE=str(ROOT.parent/'pi/runtime/node/bin/node'),F_BROWSER_TRANSPORT=(ROOT.parent/'harness/src/browser/transport.mjs').as_uri(),F_BROWSER_TEST_ARTICLE_URL=f'http://127.0.0.1:{server.server_port}/article',F_BROWSER_SCREENSHOTS=str(OUT))
try:
 result=subprocess.run([str(OUT/'tests')],env=env,capture_output=True,text=True,timeout=180);(OUT/'tests.log').write_text(result.stdout+result.stderr);print(result.stdout+result.stderr,flush=True)
 if result.returncode==0:
  profile=str(uuid.uuid4())
  for mode in ['write','read']:
   result=subprocess.run([str(OUT/'tests')],env=dict(env,F_BROWSER_TEST_PROFILE=profile,F_BROWSER_PROFILE_MODE=mode),capture_output=True,text=True,timeout=45)
   (OUT/('persistent-'+mode+'.log')).write_text(result.stdout+result.stderr);print(result.stdout+result.stderr,flush=True)
   if result.returncode:break
finally: server.shutdown()
raise SystemExit(result.returncode)
