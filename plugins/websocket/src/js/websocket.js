// The page half of myzig's WebSocket plugin, served as /plugins/websocket.js
// (`websocket.asset`): a `WebSocket` with the browser's API whose
// connections Zig makes (the bound `WebSocket` service), with any header
// on the opening handshake and outside the page's Content Security Policy.
//
//   import { WebSocket } from "/plugins/websocket.js";
//   const ws = new WebSocket("wss://example.com/live", ["v1"], { headers: { authorization: `Bearer ${t}` } });
//   ws.onmessage = (e) => console.log(e.data);

const sockets = new Map();
let listening = false;
// Parts come batched; a browser fires each event of a socket in a task of
// its own, so what awaits one (`open`) runs before the next (`close`).
const queue = [];
let draining = false;
const drain = () => {
  const part = queue.shift();
  if (queue.length > 0) setTimeout(drain, 0);
  else draining = false;
  sockets.get(part.id)?._part(part);
};
const listen = () => {
  if (listening) return;
  listening = true;
  window.myzig.on("myzig-websocket", (part) => {
    queue.push(part);
    if (draining) return;
    draining = true;
    setTimeout(drain, 0);
  });
};

const call = (method, ...args) => window.myzig.call("WebSocket." + method, ...args);

const toBase64 = (bytes) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
};
const fromBase64 = (s) => {
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
};
const utf8 = new TextEncoder();

const headerPairs = (h) => (h ? [...new Headers(h)] : []);

export class WebSocket extends EventTarget {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  CONNECTING = 0;
  OPEN = 1;
  CLOSING = 2;
  CLOSED = 3;

  #id = crypto.randomUUID();
  #state = 0;
  #binaryType = "blob";
  #buffered = 0;
  #protocol = "";
  #url;
  #sending = Promise.resolve();
  #closeAfterOpen = null;
  onopen = null;
  onmessage = null;
  onerror = null;
  onclose = null;

  constructor(url, protocols = [], options = {}) {
    super();
    const u = new URL(String(url), location.href);
    if (u.protocol === "http:") u.protocol = "ws:";
    if (u.protocol === "https:") u.protocol = "wss:";
    if (u.protocol !== "ws:" && u.protocol !== "wss:") throw new SyntaxError(`WebSocket: unsupported URL scheme ${u.protocol}`);
    if (u.hash) throw new SyntaxError("WebSocket: URLs may not have a fragment");
    this.#url = u.href;
    const list = typeof protocols === "string" ? [protocols] : [...protocols];
    if (new Set(list).size !== list.length) throw new SyntaxError("WebSocket: duplicate subprotocols");
    if (!window.myzig) throw new Error("WebSocket plugin: not in a myzig page");
    listen();
    sockets.set(this.#id, this);
    call("connect", { id: this.#id, url: this.#url, protocols: list, headers: headerPairs(options.headers) }).catch((e) => {
      if (String(e).includes("UnknownService")) console.error("WebSocket plugin: bind its service (app.bind(&ws_service)) and register websocket.PartEvent");
      this._part({ kind: "close", code: 1006, reason: "", clean: false, message: String(e.message ?? e) });
    });
  }

  get url() {
    return this.#url;
  }
  get readyState() {
    return this.#state;
  }
  get protocol() {
    return this.#protocol;
  }
  get extensions() {
    return "";
  }
  get bufferedAmount() {
    return this.#buffered;
  }
  get binaryType() {
    return this.#binaryType;
  }
  set binaryType(t) {
    if (t === "blob" || t === "arraybuffer") this.#binaryType = t;
  }

  send(data) {
    if (this.#state === 0) throw new DOMException("WebSocket is still connecting", "InvalidStateError");
    if (this.#state !== 1) return;
    let size;
    let message;
    if (typeof data === "string") {
      size = utf8.encode(data).length;
      message = Promise.resolve(["text", data]);
    } else if (data instanceof Blob) {
      size = data.size;
      message = data.arrayBuffer().then((b) => ["binary", toBase64(new Uint8Array(b))]);
    } else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      size = bytes.length;
      message = Promise.resolve(["binary", toBase64(bytes)]);
    } else {
      size = utf8.encode(String(data)).length;
      message = Promise.resolve(["text", String(data)]);
    }
    this.#buffered += size;
    // In the order sent, Blobs too.
    this.#sending = this.#sending.then(async () => {
      const [kind, payload] = await message;
      await call("send", this.#id, kind, payload).catch(() => {});
    });
  }

  close(code, reason = "") {
    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
      throw new DOMException(`WebSocket: close code ${code} is not 1000 or between 3000 and 4999`, "InvalidAccessError");
    }
    if (utf8.encode(reason).length > 123) throw new DOMException("WebSocket: close reason over 123 bytes", "SyntaxError");
    if (this.#state >= 2) return;
    const c = code ?? 1005;
    if (this.#state === 0) {
      this.#closeAfterOpen = [c, reason];
      this.#state = 2;
      return;
    }
    this.#state = 2;
    this.#sending = this.#sending.then(() => call("close", this.#id, c, reason).catch(() => {}));
  }

  #fire(type, init, Ctor = Event) {
    const e = new Ctor(type, init);
    this.dispatchEvent(e);
    const handler = this["on" + type];
    if (typeof handler === "function") handler.call(this, e);
  }

  _part(p) {
    switch (p.kind) {
      case "open":
        this.#protocol = p.protocol;
        if (this.#closeAfterOpen) {
          const [c, r] = this.#closeAfterOpen;
          call("close", this.#id, c, r).catch(() => {});
          return;
        }
        this.#state = 1;
        this.#fire("open");
        break;
      case "text":
      case "binary": {
        if (this.#state !== 1 && this.#state !== 2) return;
        let data = p.data;
        let size = utf8.encode(p.data).length;
        if (p.kind === "binary") {
          const bytes = fromBase64(p.data);
          size = bytes.length;
          data = this.#binaryType === "arraybuffer" ? bytes.buffer : new Blob([bytes]);
        }
        this.#fire("message", { data, origin: new URL(this.#url).origin }, MessageEvent);
        call("ack", this.#id, size).catch(() => {});
        break;
      }
      case "sent":
        this.#buffered = Math.max(0, this.#buffered - p.bytes);
        break;
      case "close":
        sockets.delete(this.#id);
        this.#state = 3;
        if (!p.clean) {
          if (p.message) console.warn(`WebSocket ${this.#url}: ${p.message}`);
          this.#fire("error");
        }
        this.#fire("close", { code: p.code, reason: p.reason, wasClean: p.clean }, CloseEvent);
        break;
    }
  }
}

export default WebSocket;
