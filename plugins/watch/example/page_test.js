(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const { watch, WatchError } = await import("/plugins/watch.js");

  const watcher = await watch("sandbox", { recursive: true, debounceMs: -1 });
  const it = watcher[Symbol.asyncIterator]();
  // Takes batches until one has the event.
  const until = async (op, path) => {
    for (;;) {
      const { value, done } = await it.next();
      if (done) throw new Error("ended before " + op + " " + path);
      if (value.some((e) => e.op === op && e.path === path)) return;
    }
  };
  await myzig.call("Sandbox.write", "a.txt", "one");
  await until("create", "a.txt");
  await myzig.call("Sandbox.write", "a.txt", "one more");
  await until("write", "a.txt");
  await myzig.call("Sandbox.mkdir", "docs");
  await until("create", "docs");
  await myzig.call("Sandbox.write", "docs/b.md", "#");
  await until("create", "docs/b.md");
  await myzig.call("Sandbox.remove", "a.txt");
  await until("remove", "a.txt");
  await watcher.close();
  await watcher.closed;

  // A file in the root, watched by its path.
  await myzig.call("Sandbox.write", "settings.json", "{}");
  const file = await watch("sandbox", { path: "settings.json", debounceMs: -1 });
  const fit = file[Symbol.asyncIterator]();
  await myzig.call("Sandbox.write", "settings.json", "{\"a\":1}");
  const batch = (await fit.next()).value;
  expect(batch.some((e) => e.op === "write" && e.path === "."), "file write " + JSON.stringify(batch));
  await file.close();

  const code = async (name, opts) => {
    try { await watch(name, opts); return "none"; } catch (e) { return e instanceof WatchError ? e.code : String(e); }
  };
  expect((await code("nope")) === "denied", "unknown root");
  expect((await code("sandbox", { path: "../x" })) === "denied", "escape");
  expect((await code("sandbox", { path: "missing" })) === "not-found", "missing");
  myzig.log("ok");
})().catch((e) => myzig.log("FAIL", String(e))).finally(() => myzig.window.close());
