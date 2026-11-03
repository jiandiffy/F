(() => {
  let term, fit, epoch = 0, snapshotPending = false, themeName = 'light';
  // 黑白两套配色都保持 F 的灰阶风格；白色模式与原来完全一致。
  const themes = {
    light:{background:'#fff',foreground:'#252525',cursor:'#777',cursorAccent:'#fff',selectionBackground:'#ddd',
      black:'#222',red:'#555',green:'#555',yellow:'#555',blue:'#555',magenta:'#555',cyan:'#555',white:'#888',
      brightBlack:'#666',brightRed:'#444',brightGreen:'#444',brightYellow:'#444',brightBlue:'#444',brightMagenta:'#444',brightCyan:'#444',brightWhite:'#aaa'},
    // 深色模式不留自己的底色，直接透出停靠区/应用背景，避免出现色块差异。
    dark:{background:'rgba(0,0,0,0)',foreground:'#e2e2e2',cursor:'#9a9a9a',cursorAccent:'#1c1c1e',selectionBackground:'rgba(120,120,120,0.35)',
      black:'#3a3a3a',red:'#b6b6b6',green:'#b6b6b6',yellow:'#b6b6b6',blue:'#b6b6b6',magenta:'#b6b6b6',cyan:'#b6b6b6',white:'#9c9c9c',
      brightBlack:'#6c6c6c',brightRed:'#d2d2d2',brightGreen:'#d2d2d2',brightYellow:'#d2d2d2',brightBlue:'#d2d2d2',brightMagenta:'#d2d2d2',brightCyan:'#d2d2d2',brightWhite:'#f0f0f0'},
  };
  const bridge = body => window.webkit.messageHandlers.fterm.postMessage({...body,epoch});
  /// 页面底色和终端配色一起换，切换主题不重建会话。
  function paintTheme() {
    document.documentElement.dataset.theme = themeName;
    if (term) term.options.theme = themes[themeName];
  }
  function snapshot() {
    if (snapshotPending) return;
    snapshotPending = true;
    setTimeout(() => {
      snapshotPending = false;
      const buffer = term.buffer.active, lines = [];
      for (let i = Math.max(0, buffer.length - 6000); i < buffer.length; i++) lines.push(buffer.getLine(i)?.translateToString(true) || '');
      while (lines.length && lines[lines.length-1] === '') lines.pop();
      bridge({type:'screen',text:lines.join('\n').slice(-240000),cursorX:buffer.cursorX,cursorY:buffer.cursorY,baseY:buffer.baseY,viewportY:buffer.viewportY});
    }, 25);
  }
  function resize() {
    if (document.documentElement.clientWidth < 30 || document.documentElement.clientHeight < 30) return;
    fit.fit();
  }
  function create(next) {
    term?.dispose();
    epoch = next;
    term = new Terminal({fontFamily:'Menlo, Monaco, monospace',fontSize:11.5,lineHeight:1.25,cursorBlink:true,
      screenReaderMode:true,scrollback:6000,macOptionIsMeta:true,allowProposedApi:true,allowTransparency:true,
      theme:themes[themeName]});
    fit = new FitAddon.FitAddon();term.loadAddon(fit);term.open(document.getElementById('terminal'));
    term.attachCustomKeyEventHandler(event => {
      if (event.metaKey && ['c','v','a'].includes(event.key.toLowerCase())) return false;
      return true;
    });
    term.onData(data => bridge({type:'input',data}));
    term.onBinary(data => bridge({type:'binary',data:btoa(data)}));
    term.onResize(({cols,rows}) => bridge({type:'resize',cols,rows}));
    term.onWriteParsed(snapshot);
    resize();snapshot();
  }
  window.FT = {
    reset(next){create(next)},
    write(data,next){if(next===epoch)term.write(Uint8Array.from(atob(data),c=>c.charCodeAt(0)))},
    focus(){resize();term.focus()}, fit:resize,
    input(data){term.input(data,true)}, paste(data){term.paste(data)},
    snapshot(){snapshot()},
    setTheme(name){themeName = name === 'dark' ? 'dark' : 'light'; paintTheme()},
  };
  new ResizeObserver(resize).observe(document.documentElement);
  document.addEventListener('keydown', event => {
    if (event.metaKey && event.key.toLowerCase()==='a') {event.preventDefault();term.selectAll()}
    if (event.metaKey && event.key.toLowerCase()==='c' && term.hasSelection()) {event.preventDefault();bridge({type:'copy',data:term.getSelection()})}
  },true);
  create(0);paintTheme();bridge({type:'ready'});
})();
