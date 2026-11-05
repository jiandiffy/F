(function () {
  // Raw HTML is never a media/API escape hatch. Markdown is rendered below
  // through an inert template and a second, attribute-by-attribute DOM allowlist.
  marked.use({ gfm: true, breaks: true, renderer: { html: function () { return ''; } } });

  // Keep selection/copy native, but secondary clicks must have no menu or
  // selection side effect. Do not intercept keyboard editing shortcuts.
  document.addEventListener('contextmenu', function (event) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
  ['pointerdown', 'mousedown', 'mouseup'].forEach(function (type) {
    document.addEventListener(type, function (event) {
      if (event.button === 2 || (event.button === 0 && event.ctrlKey)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
  });

  var root = document.getElementById('messages');

  function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
  }

  function httpsURL(value) {
    if (!value || /[\u0000-\u0020\u007f\\]/.test(value)) return null;
    try {
      var url = new URL(value);
      var host = url.hostname.toLowerCase();
      if (url.protocol !== 'https:' || url.username || url.password ||
          (url.port && url.port !== '443') || !host.includes('.') ||
          /[:\[\]]/.test(host) || /^[\d.]+$/.test(host) ||
          /\.(localhost|local|internal|lan|home)$/.test(host)) return null;
      return url;
    } catch (_) { return null; }
  }

  function paperMediaHost(host) {
    return host === 'arxiv.org' || host.endsWith('.arxiv.org') ||
      host === 'alphaxiv.org' || host === 'assets.alphaxiv.org' ||
      host === 'paper-assets.alphaxiv.org' || host.endsWith('.assets.alphaxiv.org') ||
      host.endsWith('.github.io') || host === 'raw.githubusercontent.com';
  }

  function imageURL(value) {
    var url = httpsURL(value);
    return url && (paperMediaHost(url.hostname) || url.hostname === 'i.ytimg.com' ||
      url.hostname === 'img.youtube.com') ? url : null;
  }

  function sourceLink(url) {
    var link = el('a', 'media-source');
    link.href = url.href;
    link.rel = 'noopener noreferrer';
    link.referrerPolicy = 'no-referrer';
    link.textContent = '来源：' + url.hostname + url.pathname;
    link.title = url.href;
    return link;
  }

  function imagePreview(node, insideLink) {
    var url = imageURL(node.getAttribute('src'));
    var label = node.getAttribute('alt') || '论文图片';
    if (!url) {
      var blocked = el('span', 'media-blocked');
      blocked.textContent = '[图片未加载：' + label + '（仅允许可信 HTTPS 来源）]';
      return blocked;
    }
    var wrapper = el('span', 'paper-media');
    var image = el('img', 'paper-image');
    image.alt = label;
    image.loading = 'lazy';
    image.decoding = 'async';
    image.referrerPolicy = 'no-referrer';
    image.src = url.href;
    wrapper.appendChild(image);
    var caption = el('span', 'media-caption');
    caption.textContent = label + ' · ';
    if (insideLink) caption.appendChild(document.createTextNode('来源：' + url.hostname + url.pathname));
    else caption.appendChild(sourceLink(url));
    wrapper.appendChild(caption);
    return wrapper;
  }

  function videoInfo(url) {
    if (paperMediaHost(url.hostname) && /\.(mp4|webm)$/i.test(url.pathname)) return { kind: 'file' };
    if (['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'].includes(url.hostname)) {
      var id = url.hostname === 'youtu.be' ? url.pathname.slice(1) :
        (url.pathname === '/watch' ? url.searchParams.get('v') :
          (/^\/(shorts|embed)\/([^/]+)$/.exec(url.pathname) || [])[2]);
      if (/^[A-Za-z0-9_-]{11}$/.test(id || '')) return { kind: 'youtube', id: id };
    }
    if (['vimeo.com', 'www.vimeo.com'].includes(url.hostname) && /^\/\d+\/?$/.test(url.pathname)) {
      return { kind: 'external' };
    }
    return null;
  }

  function videoPreview(url, info, label) {
    var wrapper = el('span', 'paper-media paper-video');
    var title = el('span', 'media-caption');
    title.textContent = label || '论文演示视频';
    wrapper.appendChild(title);
    if (info.kind !== 'external') {
      var button = el('button', 'media-load');
      button.type = 'button';
      button.textContent = info.kind === 'file' ? '加载视频（不自动播放）' : '加载 YouTube 缩略图（在来源网站观看）';
      button.addEventListener('click', function () {
        // No src, poster, iframe, or remote request exists before this click.
        var media;
        if (info.kind === 'file') {
          media = el('video', 'paper-player');
          media.controls = true;
          media.preload = 'none';
          media.playsInline = true;
          media.autoplay = false;
          media.setAttribute('referrerpolicy', 'no-referrer');
          media.src = url.href;
        } else {
          media = el('img', 'paper-image');
          media.alt = 'YouTube 视频缩略图；请在来源网站观看';
          media.referrerPolicy = 'no-referrer';
          media.src = 'https://i.ytimg.com/vi/' + info.id + '/hqdefault.jpg';
        }
        button.replaceWith(media);
      }, { once: true });
      wrapper.appendChild(button);
    } else {
      var notice = el('span', 'media-caption');
      notice.textContent = '外部视频：请在来源网站观看（不嵌入网页）';
      wrapper.appendChild(notice);
    }
    wrapper.appendChild(sourceLink(url));
    return wrapper;
  }

  var markdownTags = new Set(('p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code strong em del ' +
    'table thead tbody tfoot tr th td a img input').split(' '));
  var dropTags = new Set('script style iframe object embed svg math template form meta link base video audio source track'.split(' '));

  function cleanNode(node, insideLink) {
    if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE) return document.createDocumentFragment();
    var tag = node.localName.toLowerCase();
    if (dropTags.has(tag) || node.namespaceURI !== 'http://www.w3.org/1999/xhtml') return document.createDocumentFragment();
    if (tag === 'img') return imagePreview(node, insideLink);
    var url = tag === 'a' ? httpsURL(node.getAttribute('href')) : null;
    var info = url && !insideLink ? videoInfo(url) : null;
    if (info) return videoPreview(url, info, node.textContent);
    var result = markdownTags.has(tag) && (tag !== 'a' || (url && !insideLink)) ? el(tag) : document.createDocumentFragment();
    if (tag === 'input') {
      if (node.getAttribute('type') !== 'checkbox') return document.createDocumentFragment();
      result.type = 'checkbox';
      result.disabled = true;
      result.checked = node.hasAttribute('checked');
      return result;
    }
    if (tag === 'a' && url && !insideLink) {
      result.href = url.href;
      result.rel = 'noopener noreferrer';
      result.referrerPolicy = 'no-referrer';
    }
    if (result.nodeType === Node.ELEMENT_NODE) {
      if (node.hasAttribute('title')) result.title = node.getAttribute('title');
      if (tag === 'ol' && /^\d{1,8}$/.test(node.getAttribute('start') || '')) result.setAttribute('start', node.getAttribute('start'));
      if ((tag === 'td' || tag === 'th') && /^(left|center|right)$/.test(node.getAttribute('align') || '')) result.setAttribute('align', node.getAttribute('align'));
      if (tag === 'code' && /^language-[a-z0-9_+-]{1,40}$/i.test(node.className)) result.className = node.className;
    }
    Array.from(node.childNodes).forEach(function (child) { result.appendChild(cleanNode(child, insideLink || tag === 'a')); });
    return result;
  }

  function renderMarkdown(content, text) {
    // A template is inert (unlike inserting marked output into the live page).
    // Never move untrusted nodes/attributes into the document, even if marked
    // changes its HTML escaping or a future renderer emits unexpected markup.
    var template = document.createElement('template');
    template.innerHTML = marked.parse(text || '');
    Array.from(template.content.childNodes).forEach(function (node) { content.appendChild(cleanNode(node, false)); });
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
    renderMarkdown(content, text);
    msg.appendChild(content);
    root.appendChild(msg);
  }

  window.F = {
    ready: true,

    setTheme: function (theme) {
      document.documentElement.classList.toggle("theme-dark", theme === "dark");
      document.documentElement.style.colorScheme = theme === "dark" ? "dark" : "light";
    },

    setMessages: function (list) {
      root.innerHTML = '';
      (list || []).forEach(function (m) {
        if (m.role === 'user') addUser(m.text);
        else if (m.role === 'assistant') addAssistant(m.text);
      });
      requestAnimationFrame(function () { scrollToBottom(true); });
    },

    addUser: addUser,
    addUpdateNotice: function (text) { addAssistant(text); scrollToBottom(true); },

    // Native code publishes one completed answer after agent_settled.
    endAssistant: function (text) {
      addAssistant(text);
      scrollToBottom(false);
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
    }
  };
})();
