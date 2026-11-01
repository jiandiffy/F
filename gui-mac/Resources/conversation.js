(function () {
  marked.use({ gfm: true, breaks: true });

  var root = document.getElementById('messages');
  var current = null;
  var renderTimer = null;
  var thinkTimer = null;

  function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
  }

  function scrollToBottom(force) {
    var doc = document.scrollingElement;
    var remain = doc.scrollHeight - window.scrollY - window.innerHeight;
    if (force || remain < 180) window.scrollTo(0, doc.scrollHeight);
  }

  function addUser(text) {
    var msg = el('div', 'msg user');
    var bubble = el('div', 'bubble');
    bubble.textContent = text;
    msg.appendChild(bubble);
    root.appendChild(msg);
    scrollToBottom(true);
  }

  function addAssistant(text) {
    var msg = el('div', 'msg assistant');
    var content = el('div', 'content');
    content.innerHTML = marked.parse(text || '');
    msg.appendChild(content);
    root.appendChild(msg);
  }

  function startAssistant() {
    var msg = el('div', 'msg assistant');
    var thinking = el('div', 'thinking');
    thinking.hidden = true;
    var content = el('div', 'content');
    msg.appendChild(thinking);
    msg.appendChild(content);
    root.appendChild(msg);
    current = {
      msg: msg,
      thinking: thinking,
      content: content,
      thinkBuf: '',
      textBuf: '',
      thinkDone: false
    };
    scrollToBottom(true);
  }

  function scheduleThink() {
    if (!current || current.thinkDone || thinkTimer) return;
    thinkTimer = setTimeout(function () {
      thinkTimer = null;
      if (!current) return;
      current.thinking.hidden = false;
      current.thinking.textContent = current.thinkBuf;
      current.thinking.scrollTop = current.thinking.scrollHeight;
      scrollToBottom(false);
    }, 40);
  }

  function scheduleRender() {
    if (!current || renderTimer) return;
    renderTimer = setTimeout(function () {
      renderTimer = null;
      if (!current) return;
      current.content.innerHTML = marked.parse(current.textBuf);
      scrollToBottom(false);
    }, 90);
  }

  window.F = {
    ready: true,

    setTheme: function (theme) {
      document.documentElement.classList.toggle("theme-dark", theme === "dark");
      document.documentElement.style.colorScheme = theme === "dark" ? "dark" : "light";
    },

    clear: function () {
      root.innerHTML = '';
      current = null;
    },

    setMessages: function (list) {
      root.innerHTML = '';
      current = null;
      (list || []).forEach(function (m) {
        if (m.role === 'user') addUser(m.text);
        else addAssistant(m.text);
      });
      requestAnimationFrame(function () { scrollToBottom(true); });
    },

    addUser: addUser,
    addUpdateNotice: function (text) { addAssistant(text); scrollToBottom(true); },

    startAssistant: startAssistant,

    appendThinking: function (delta) {
      if (!current) startAssistant();
      current.thinkBuf += delta;
      scheduleThink();
    },

    endThinking: function (text) {
      if (!current) return;
      if (typeof text === 'string') current.thinkBuf = text;
      current.thinking.hidden = !current.thinkBuf;
      current.thinking.textContent = current.thinkBuf;
      current.thinking.classList.add('done');
      current.thinking.scrollTop = current.thinking.scrollHeight;
      current.thinkDone = true;
      scrollToBottom(false);
    },

    appendText: function (delta) {
      if (!current) startAssistant();
      current.textBuf += delta;
      scheduleRender();
    },

    endAssistant: function (text) {
      if (!current) startAssistant();
      if (typeof text === 'string') current.textBuf = text;
      current.content.innerHTML = marked.parse(current.textBuf);
      current.thinking.classList.add('done');
      if (!current.thinkBuf) current.thinking.hidden = true;
      if (!current.textBuf && !current.thinkBuf) current.msg.remove();
      current = null;
      scrollToBottom(false);
    },

    settle: function () {
      if (!current) return;
      current.thinking.classList.add('done');
      current = null;
    },

    showError: function (text) {
      var d = el('div', 'error');
      d.textContent = text;
      root.appendChild(d);
      scrollToBottom(true);
    },

    // 额度用尽：淡灰色、居中换行显示在主对话框里，不打断对话流
    showCapacityReached: function (detail) {
      var n = el('div', 'notice');
      var title = el('div', 'notice-title');
      title.textContent = '! capacity reached';
      n.appendChild(title);
      if (detail) {
        var d = el('div', 'notice-detail');
        d.textContent = detail;
        n.appendChild(d);
      }
      root.appendChild(n);
      scrollToBottom(true);
    },

    scrollToBottom: scrollToBottom
  };
})();
