// The page half of myzig's watch plugin, served as /plugins/watch.js
// (`watch.asset`): watches of the roots the app names (the bound `Watch`
// service), as async iterables of batches of changes.
//
//   import { watch } from "/plugins/watch.js";
//   const watcher = await watch("project", { recursive: true });
//   for await (const events of watcher) for (const e of events) console.log(e.op, e.path, e.oldPath);

export class WatchError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "WatchError";
    /** denied, not-found, limit, unsupported, path-encoding or io. */
    this.code = code;
  }
}

const CODES = { Denied: "denied", NotFound: "not-found", Limit: "limit", Unsupported: "unsupported", PathEncoding: "path-encoding", Io: "io" };
const toError = (name) => {
  const key = Object.keys(CODES).find((k) => String(name).includes(k));
  return new WatchError(key ? CODES[key] : "io", `watch: ${name}`);
};

const watchers = new Map();
let listening = false;
const listen = () => {
  if (listening) return;
  listening = true;
  window.myzig.on("myzig-watch", (b) => watchers.get(b.id)?._batch(b));
};

const call = (method, ...args) => window.myzig.call("Watch." + method, ...args);

class Watcher {
  #id;
  #queue = [];
  #wake = null;
  #done = false;
  #settle;
  /** Settles once Zig stopped the watch; rejects with the error that stopped it. */
  closed;

  constructor(id) {
    this.#id = id;
    this.closed = new Promise((resolve, reject) => (this.#settle = { resolve, reject }));
    this.closed.catch(() => {});
  }

  _batch(b) {
    if (b.kind === "batch") {
      this.#queue.push(b.events.map((e) => ({ op: e.op, path: e.path, oldPath: e.oldPath ?? undefined, isDir: e.isDir })));
    } else {
      this.#finish(b.code ? toError(b.code) : null);
    }
    const wake = this.#wake;
    this.#wake = null;
    wake?.();
  }

  #finish(err) {
    if (this.#done) return;
    this.#done = true;
    watchers.delete(this.#id);
    if (err) this.#settle.reject(err);
    else this.#settle.resolve();
  }

  /** Stops the watch. */
  async close() {
    if (this.#done) return;
    this.#finish(null);
    const wake = this.#wake;
    this.#wake = null;
    wake?.();
    await call("stop", this.#id).catch(() => {});
  }

  async *[Symbol.asyncIterator]() {
    try {
      for (;;) {
        if (this.#queue.length) {
          const events = this.#queue.shift();
          // Zig looks again once the batch was taken.
          call("ack", this.#id).catch(() => {});
          yield events;
          continue;
        }
        if (this.#done) {
          await this.closed;
          return;
        }
        await new Promise((r) => (this.#wake = r));
      }
    } finally {
      if (!this.#done) await this.close();
    }
  }
}

/** Watches the root `name` (or `path` in it); resolves once everything is watched. */
export async function watch(name, options = {}) {
  if (!window.myzig) throw new Error("watch plugin: not in a myzig page");
  options.signal?.throwIfAborted();
  listen();
  const id = crypto.randomUUID();
  const w = new Watcher(id);
  watchers.set(id, w);
  try {
    await call("start", { id, name, path: options.path ?? "", recursive: !!options.recursive, debounceMs: options.debounceMs ?? 0 });
  } catch (e) {
    watchers.delete(id);
    if (String(e).includes("UnknownService")) throw new Error("watch plugin: bind its service (app.bind(&watch_service)) and register watch.BatchEvent");
    throw toError(e.message ?? e);
  }
  options.signal?.addEventListener("abort", () => w.close(), { once: true });
  return w;
}
