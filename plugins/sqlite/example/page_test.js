(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const { open } = await import("/plugins/sqlite.js");

  // After the reload below: the last document's databases closed with it;
  // this one's own (index.html opens notes.db) may be open already.
  if (sessionStorage.getItem("reloaded")) {
    const after = await myzig.call("Demo.connections");
    expect(after <= 1, "databases left by the last document: " + after);
    return true;
  }
  const db = await open(":memory:");
  await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, data BLOB, big INTEGER)");
  const r = await db.execute("INSERT INTO t(name, data, big) VALUES (?, ?, ?)", ["Ada", new Uint8Array([0, 255]), 9007199254740993n]);
  expect(r.changes === 1 && r.lastInsertId === 1n, "insert " + JSON.stringify({ c: r.changes, id: String(r.lastInsertId) }));
  const q = await db.query("SELECT id, name, data, big FROM t WHERE name = :name", ["Ada"]);
  expect(q.columns.join() === "id,name,data,big", "columns " + q.columns);
  const [id, name, data, big] = q.rows[0];
  expect(id === 1 && name === "Ada", "row");
  expect(data instanceof Uint8Array && data[1] === 255, "blob");
  expect(big === 9007199254740993n, "bigint " + big);
  const tx = await db.transaction([
    { sql: "INSERT INTO t(name) VALUES (?)", params: ["b"] },
    { sql: "INSERT INTO t(name) VALUES (?)", params: ["c"] },
  ]);
  expect(tx.length === 2 && tx[1].lastInsertId === 3n, "transaction");
  let err = "";
  try {
    await db.transaction([
      { sql: "INSERT INTO t(name) VALUES ('d')" },
      { sql: "INSERT INTO nope VALUES (1)" },
    ]);
  } catch (e) { err = String(e); }
  expect(err.includes("Sqlite"), "failed transaction " + err);
  expect((await db.query("SELECT count(*) FROM t")).rows[0][0] === 3, "rolled back");
  err = "";
  try { await db.execute("BEGIN"); } catch (e) { err = String(e); }
  expect(err.includes("StatementNotAllowed"), "guard " + err);
  err = "";
  try { await open("../escape.db"); } catch (e) { err = String(e); }
  expect(err.includes("InvalidDatabaseName"), "name " + err);
  await db.close();
  err = "";
  try { await db.query("SELECT 1"); } catch (e) { err = String(e); }
  expect(err.includes("DatabaseClosed") || err === "", "closed " + err);

  // A database left open as the page reloads, with index.html's.
  await open(":memory:");
  const before = await myzig.call("Demo.connections");
  expect(before >= 2, "databases before the reload: " + before);
  sessionStorage.setItem("reloaded", "1");
  location.reload();
  return false;
})().then((done) => {
  if (!done) return;
  myzig.log("ok");
  myzig.window.close();
}, (e) => {
  myzig.log("FAIL", String(e));
  myzig.window.close();
});
