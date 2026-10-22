// The page runtime, injected at document start into every page's main frame.
// It owns the wire protocol (see README and src/page_channel.zig): calls go
// out as JSON strings, replies, events and channel values come back batched
// through __myzig.receive([...]).
(() => {
  if (window.myzig) return;
  // WebKit's message handler (macOS, Linux) or WebView2's (Windows).
  const webview2 = window.chrome && window.chrome.webview;
  // WebKitGTK cannot tell which frame posted a message: there the main
  // frame's messages start with the page's token (src/linux/page.zig).
  const frame = "";
  const post = webview2
    ? (m) => webview2.postMessage(JSON.stringify(m))
    : (m) => window.webkit.messageHandlers.myzig.postMessage(frame + JSON.stringify(m));
  const platform = webview2 ? "windows" : navigator.platform.startsWith("Linux") ? "linux" : "macos";
  const pending = new Map();
  const listeners = new Map();
  let nextId = 1;
  const report = (e) => setTimeout(() => { throw e; });

  const call = (method, ...args) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      post({ t: "call", id, m: method, a: args });
    });

  const on = (name, fn) => {
    let set = listeners.get(name);
    if (!set) listeners.set(name, (set = new Set()));
    set.add(fn);
    return () => set.delete(fn);
  };
  const once = (name, fn) => {
    const off = on(name, (p) => {
      off();
      fn(p);
    });
    return off;
  };

  // Channels: values both ways, in order, until either side closes. Values
  // from Zig wait here until taken; taking them acknowledges what Zig asked.
  const WINDOW = 1 << 20;
  const channels = new Map();
  const kinds = new Map();
  const unclaimed = new Map();
  let nextChannel = 1;
  const makeChannel = (id, onmessage) => {
    let handler = null;
    let closed = false;
    let queue = [];
    const waiters = [];
    let seq = 0;
    let outSeq = 0, outSent = 0, outTaken = 0, outAsked = 0;
    const asks = [];
    const drains = [];
    const ack = (n) => post({ t: "chan-ack", c: id, n });
    const deliver = (v) => {
      try {
        handler(v);
      } catch (e) {
        report(e);
      }
    };
    const finish = () => {
      channels.delete(id);
      if (queue.length === 0) waiters.splice(0).forEach((w) => w({ value: undefined, done: true }));
      drains.splice(0).forEach((d) => d.reject(new Error("myzig: channel closed")));
      if (ch.onclose) {
        try {
          ch.onclose();
        } catch (e) {
          report(e);
        }
      }
    };
    const internal = {
      push(v, ask) {
        if (closed) return;
        const n = ++seq;
        if (handler) deliver(v);
        else if (waiters.length > 0) waiters.shift()({ value: v, done: false });
        else return void queue.push({ v, n, ask });
        if (ask) ack(n);
      },
      end() {
        if (closed) return;
        closed = true;
        finish();
      },
      acked(n) {
        while (asks.length > 0 && asks[0][0] <= n) outTaken = asks.shift()[1];
        while (outSent - outTaken < WINDOW && drains.length > 0) drains.shift().resolve();
      },
    };
    const ch = {
      get onmessage() {
        return handler;
      },
      set onmessage(fn) {
        handler = fn;
        while (handler && queue.length > 0) {
          const q = queue.shift();
          deliver(q.v);
          if (q.ask) ack(q.n);
        }
      },
      onclose: null,
      get closed() {
        return closed;
      },
      // Resolves once Zig has room for more.
      send(v) {
        if (closed) return Promise.reject(new Error("myzig: channel closed"));
        const s = JSON.stringify(v === undefined ? null : v);
        const n = ++outSeq;
        outSent += s.length + 48;
        const ask = outSent - outAsked >= WINDOW / 2;
        if (ask) {
          outAsked = outSent;
          asks.push([n, outSent]);
        }
        post(ask ? { t: "chan-msg", c: id, v: s, n, a: 1 } : { t: "chan-msg", c: id, v: s, n });
        if (outSent - outTaken < WINDOW) return Promise.resolve();
        return new Promise((resolve, reject) => drains.push({ resolve, reject }));
      },
      close() {
        if (closed) return;
        closed = true;
        queue = [];
        post({ t: "chan-close", c: id });
        finish();
      },
      [Symbol.asyncIterator]() {
        return {
          next() {
            const q = queue.shift();
            if (q) {
              if (q.ask) ack(q.n);
              return Promise.resolve({ value: q.v, done: false });
            }
            if (closed) return Promise.resolve({ value: undefined, done: true });
            return new Promise((r) => waiters.push(r));
          },
          return() {
            ch.close();
            return Promise.resolve({ value: undefined, done: true });
          },
        };
      },
      toJSON: () => id,
    };
    channels.set(id, internal);
    if (onmessage) ch.onmessage = onmessage;
    return ch;
  };
  // `new Channel(onmessage?)`: a channel to pass to a bound method.
  function Channel(onmessage) {
    return makeChannel(nextChannel++, onmessage);
  }
  // Channels Zig opens, by kind; those opened before a listener wait for one.
  const onChannel = (name, fn) => {
    let set = kinds.get(name);
    if (!set) kinds.set(name, (set = new Set()));
    set.add(fn);
    const waiting = unclaimed.get(name);
    if (waiting) {
      unclaimed.delete(name);
      waiting.forEach((ch) => fn(ch));
    }
    return () => set.delete(fn);
  };
  const opened = (id, name) => {
    const ch = makeChannel(id);
    const set = kinds.get(name);
    if (set && set.size > 0) {
      for (const fn of [...set]) {
        try {
          fn(ch);
        } catch (e) {
          report(e);
        }
      }
    } else {
      const list = unclaimed.get(name) || [];
      if (list.length < 1024) list.push(ch);
      unclaimed.set(name, list);
    }
  };

  const receive = (messages) => {
    for (const m of messages) {
      if (m.t === "reply") {
        const p = pending.get(m.id);
        if (!p) continue;
        pending.delete(m.id);
        if (m.ok) p.resolve(m.v);
        else p.reject(new Error(m.e));
      } else if (m.t === "event") {
        const set = listeners.get(m.n);
        if (!set) continue;
        for (const fn of [...set]) {
          try {
            fn(m.p);
          } catch (e) {
            console.error(e);
          }
        }
      } else if (m.t === "chan") {
        const c = channels.get(m.c);
        if (!c) continue;
        if (m.end) c.end();
        else c.push(m.p, m.a === 1);
      } else if (m.t === "chan-ack") {
        const c = channels.get(m.c);
        if (c) c.acked(m.n);
      } else if (m.t === "chan-open") {
        opened(m.c, m.n);
      }
    }
  };

  // A script Zig evaluates for its result (Page.evalResult).
  const settle = (id, k, fn) => {
    Promise.resolve()
      .then(fn)
      .then((v) => {
        const s = v === undefined ? "null" : JSON.stringify(v);
        post({ t: "eval", id, k, ok: true, v: s === undefined ? "null" : s });
      })
      .catch((e) => post({ t: "eval", id, k, ok: false, e: String((e && e.message) || e) }));
  };

  // Find in page (Page.findInPage): highlights with the CSS Custom
  // Highlight API where there is one, else the selection.
  let found = null;
  let sheet = null;
  const highlights = () => typeof CSS !== "undefined" && "highlights" in CSS && typeof Highlight !== "undefined";
  const ranges = (text, matchCase) => {
    const out = [];
    if (!text || !document.body) return out;
    const needle = matchCase ? text : text.toLowerCase();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const el = node.parentElement;
        if (!el || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TEXTAREA)$/.test(el.tagName)) return NodeFilter.FILTER_REJECT;
        return el.getClientRects().length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      },
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const hay = matchCase ? node.nodeValue : node.nodeValue.toLowerCase();
      for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length)) {
        const r = document.createRange();
        r.setStart(node, i);
        r.setEnd(node, i + needle.length);
        out.push(r);
      }
    }
    return out;
  };
  const stopFind = () => {
    if (found && !highlights()) getSelection()?.removeAllRanges();
    found = null;
    if (highlights()) {
      CSS.highlights.delete("myzig-find");
      CSS.highlights.delete("myzig-find-active");
    }
  };
  const find = (text, o = {}) => {
    const matchCase = !!o.matchCase;
    if (!o.next || !found || found.text !== text || found.matchCase !== matchCase)
      found = { text, matchCase, ranges: ranges(text, matchCase), active: -1 };
    const n = found.ranges.length;
    if (n === 0) {
      stopFind();
      return { matches: 0, active: 0 };
    }
    found.active = found.active < 0 ? (o.backward ? n - 1 : 0) : (found.active + (o.backward ? n - 1 : 1)) % n;
    const r = found.ranges[found.active];
    if (highlights()) {
      if (!sheet && "adoptedStyleSheets" in document) {
        sheet = new CSSStyleSheet();
        sheet.replaceSync("::highlight(myzig-find){background-color:#fdeb62;color:#000}::highlight(myzig-find-active){background-color:#ff9632;color:#000}");
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      }
      CSS.highlights.set("myzig-find", new Highlight(...found.ranges));
      CSS.highlights.set("myzig-find-active", new Highlight(r));
    } else {
      const sel = getSelection();
      sel?.removeAllRanges();
      sel?.addRange(r);
    }
    r.startContainer.parentElement?.scrollIntoView({ block: "center", inline: "nearest" });
    return { matches: n, active: found.active + 1 };
  };

  // Prints to the app's stderr: for tests run with --myzig-eval.
  const log = (...args) =>
    post({ t: "log", v: args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ") });

  const win = Object.freeze({
    close: () => post({ t: "win", op: "close" }),
    minimize: () => post({ t: "win", op: "minimize" }),
    toggleMaximize: () => post({ t: "win", op: "zoom" }),
    setTitle: (title) => post({ t: "win", op: "title", v: String(title) }),
  });

  Object.defineProperty(window, "__myzig", { value: Object.freeze({ receive, settle, find, stopFind }) });
  Object.defineProperty(window, "myzig", {
    value: Object.freeze({ call, on, once, log, Channel, onChannel, window: win, platform, version: "0.1.7" }),
  });

  const ready = () => post({ t: "dom-ready" });
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true });
  else ready();

  // Frameless windows: elements styled `--app-region: drag` move the window.
  document.addEventListener(
    "mousedown",
    (e) => {
      if (e.button !== 0) return;
      for (let el = e.target; el && el.nodeType === 1; el = el.parentElement) {
        const region = getComputedStyle(el).getPropertyValue("--app-region").trim();
        if (region === "no-drag") return;
        if (region === "drag") {
          post({ t: e.detail === 2 ? "dblclick" : "drag" });
          return;
        }
      }
    },
    true,
  );
})();
