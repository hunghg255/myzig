// The page half of myzig's SQLite plugin, served as /plugins/sqlite.js
// (`sqlite.asset`). It calls the bound `Sqlite` service and turns its wire
// form back into JavaScript values: bigints for integers past 2^53 (and
// rowids), Uint8Arrays for blobs.
//
//   import { open } from "/plugins/sqlite.js";
//   const db = await open("app.db");
//   await db.execute("INSERT INTO notes(title) VALUES (?)", ["Hello"]);
//   const { columns, rows } = await db.query("SELECT id, title FROM notes");

const call = (method, ...args) => {
  if (!window.myzig) return Promise.reject(new Error("sqlite: not in a myzig page"));
  return window.myzig.call("Sqlite." + method, ...args).catch((e) => {
    if (String(e).includes("UnknownService")) throw new Error("sqlite: bind the plugin's service (app.bind(&sqlite_service))");
    throw e;
  });
};

const toBase64 = (bytes) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};
const fromBase64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

const param = (v) => {
  if (v === undefined) throw new TypeError("sqlite: undefined is not a parameter (use null)");
  if (typeof v === "bigint") return { $bigint: v.toString() };
  if (typeof v === "number" && !Number.isFinite(v)) throw new TypeError("sqlite: numbers must be finite");
  if (typeof v === "number" && Number.isInteger(v) && !Number.isSafeInteger(v)) throw new TypeError("sqlite: integer beyond 2^53: bind a bigint");
  if (v instanceof Uint8Array) return { $blob: toBase64(v) };
  if (v instanceof ArrayBuffer) return { $blob: toBase64(new Uint8Array(v)) };
  if (ArrayBuffer.isView(v)) return { $blob: toBase64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) };
  if (v === null || typeof v === "string" || typeof v === "number" || typeof v === "boolean") return v;
  throw new TypeError("sqlite: unsupported parameter " + Object.prototype.toString.call(v));
};
const params = (list = []) => list.map(param);

const result = (r) => ({ changes: r.changes, lastInsertId: BigInt(r.lastInsertId) });

const rows = (w) => {
  const out = w.rows.map((r) => r.slice());
  for (const s of w.special) {
    const v = out[s.row][s.col];
    out[s.row][s.col] = s.kind === "bigint" ? BigInt(v) : s.kind === "blob" ? fromBase64(v) : Number(v);
  }
  return { columns: w.columns, rows: out };
};

export class Database {
  #id;
  #closed = false;
  constructor(id) {
    this.#id = id;
  }
  /** Runs one statement: { changes, lastInsertId (a bigint) }. */
  async execute(sql, values) {
    return result(await call("execute", this.#id, sql, params(values)));
  }
  /** Runs one query: { columns, rows }, each row an array in column order. */
  async query(sql, values) {
    return rows(await call("query", this.#id, sql, params(values)));
  }
  /** Runs [{ sql, params }] in one transaction, all or nothing. */
  async transaction(statements) {
    const list = statements.map((s) => ({ sql: s.sql, params: params(s.params) }));
    return (await call("transaction", this.#id, list)).map(result);
  }
  async close() {
    if (this.#closed) return;
    this.#closed = true;
    await call("close", this.#id);
  }
}

/** Opens a database by file name in the app's data directory, or ":memory:". */
export async function open(name, options = {}) {
  return new Database(await call("open", name, { readOnly: !!options.readOnly }));
}
