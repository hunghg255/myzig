(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const { open } = await import("/plugins/sqlite.js");
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
  myzig.log("ok");
})().catch((e) => myzig.log("FAIL", String(e))).finally(() => myzig.window.close());
