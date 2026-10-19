// The page half of myzig's fetch plugin, served as /plugins/fetch.js
// (`fetch.asset`): a standard `fetch` whose requests Zig makes (the bound
// `Fetch` service), free of CORS and of the webview's rules on headers.
// The response's body streams as Zig reads it; aborting the signal
// cancels the request in Zig.
//
//   import { fetch } from "/plugins/fetch.js";
//   const res = await fetch("https://api.example.com/items", { headers: { authorization: `Bearer ${t}` } });
//
// URLs that are not http or https (the app's own pages, data:, blob:) go
// to the webview's fetch.

const NULL_BODY = new Set([101, 103, 204, 205, 304]);
const NORMALIZED = new Set(["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"]);

/** Requests in flight by id: each a queue of parts and a waiter. */
const flights = new Map();
let listening = false;
const listen = () => {
  if (listening) return;
  listening = true;
  window.myzig.on("myzig-fetch", (part) => {
    const f = flights.get(part.id);
    if (!f) return;
    f.parts.push(part);
    const wake = f.wake;
    f.wake = null;
    wake?.();
  });
};

const nextPart = (f) =>
  f.parts.length
    ? Promise.resolve(f.parts.shift())
    : new Promise((resolve, reject) => {
        f.wake = () => resolve(f.parts.shift());
        f.fail = reject;
      });

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

const failure = (message) => {
  if (String(message).includes("UnknownService")) {
    return new Error("fetch plugin: bind its service (app.bind(&fetch_service)) and register fetch.PartEvent");
  }
  return new TypeError(`fetch failed: ${message}`);
};

/** Makes an HTTP request from Zig, with the options and result of the standard fetch. */
export async function fetch(input, init = {}) {
  const req = typeof Request !== "undefined" && input instanceof Request ? input : null;
  const url = new URL(req ? req.url : input instanceof URL ? input.href : String(input), location.href);
  if (url.protocol !== "http:" && url.protocol !== "https:") return globalThis.fetch(input, init);
  if (!window.myzig) throw new Error("fetch plugin: not in a myzig page");
  listen();

  const signal = init.signal ?? req?.signal ?? null;
  signal?.throwIfAborted();
  let method = init.method ?? req?.method ?? "GET";
  if (NORMALIZED.has(method.toUpperCase())) method = method.toUpperCase();
  const headers = new Headers(init.headers ?? req?.headers);
  let body = null;
  if (init.body != null) {
    const r = new Response(init.body);
    const type = r.headers.get("content-type");
    if (type && !headers.has("content-type")) headers.set("content-type", type);
    body = new Uint8Array(await r.arrayBuffer());
  } else if (init.body === undefined && req?.body) {
    body = new Uint8Array(await req.arrayBuffer());
  }
  if (body && (method === "GET" || method === "HEAD")) throw new TypeError(`fetch: a ${method} request cannot have a body`);

  const id = crypto.randomUUID();
  const f = { parts: [], wake: null, fail: null };
  flights.set(id, f);
  let stream;
  let finished = false;
  const finish = () => {
    finished = true;
    flights.delete(id);
    signal?.removeEventListener("abort", onAbort);
  };
  const onAbort = () => {
    if (finished) return;
    finish();
    window.myzig.call("Fetch.abort", id).catch(() => {});
    try {
      stream?.error(signal.reason);
    } catch {}
    f.fail?.(signal.reason);
  };
  signal?.addEventListener("abort", onAbort, { once: true });

  try {
    await window.myzig.call("Fetch.start", {
      id,
      url: url.href,
      method,
      headers: [...headers],
      body: body && toBase64(body),
      redirect: init.redirect ?? req?.redirect ?? "follow",
    });
  } catch (e) {
    finish();
    throw failure(e.message ?? e);
  }

  const head = await nextPart(f);
  if (head.kind === "failed") {
    finish();
    throw failure(head.message);
  }
  const status = head.status;
  const nullBody = NULL_BODY.has(status) || method === "HEAD";
  const readable = nullBody
    ? null
    : new ReadableStream(
        {
          start(controller) {
            stream = controller;
          },
          async pull(controller) {
            const part = await nextPart(f);
            if (part.kind === "chunk") {
              const bytes = fromBase64(part.chunk);
              controller.enqueue(bytes);
              window.myzig.call("Fetch.ack", id, bytes.length).catch(() => {});
            } else if (part.kind === "end") {
              finish();
              controller.close();
            } else {
              finish();
              controller.error(failure(part.message));
            }
          },
          cancel() {
            if (finished) return;
            finish();
            window.myzig.call("Fetch.abort", id).catch(() => {});
          },
        },
        { highWaterMark: 0 },
      );
  if (nullBody) {
    finish();
    window.myzig.call("Fetch.abort", id).catch(() => {});
  }
  // Response takes statuses from 200 to 599 only.
  const valid = status >= 200 && status <= 599;
  const res = new Response(readable, { status: valid ? status : 200, statusText: head.statusText, headers: head.headers });
  const own = (name, value) => Object.defineProperty(res, name, { value, enumerable: true });
  own("url", head.url || url.href);
  own("redirected", head.redirected);
  if (!valid) own("status", status);
  return res;
}

export default fetch;
