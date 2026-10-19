(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const states = [];
  const until = (kind) =>
    new Promise((resolve, reject) => {
      const off = myzig.on("myzig-updater", (s) => {
        states.push(s.kind);
        if (s.kind === kind) { off(); resolve(s); }
        if (s.kind === "failed") { off(); reject(new Error("failed: " + s.message)); }
      });
    });

  const available = until("available");
  await myzig.call("Updater.check");
  const a = await available;
  expect(a.version === "2.0.0" && a.notes.includes("better"), "available " + JSON.stringify(a));
  expect(states[0] === "checking", "checking first " + states.join());

  const ready = until("ready");
  await myzig.call("Updater.install");
  const r = await ready;
  expect(r.version === "2.0.0", "ready");
  expect(states.includes("downloading"), "progress " + states.join());
  expect((await myzig.call("Demo.installed")).startsWith("version 2.0.0"), "installed");

  await myzig.call("Updater.skip");
  expect((await myzig.call("Updater.preferences")).skippedVersion === "2.0.0", "skipped");
  await myzig.call("Updater.setAutomaticChecks", false);
  expect((await myzig.call("Updater.preferences")).automaticChecks === false, "preference");
  myzig.log("ok");
})().catch((e) => myzig.log("FAIL", String(e))).finally(() => myzig.window.close());
