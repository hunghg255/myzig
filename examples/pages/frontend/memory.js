// A hidden-window IPC recovery probe, not a visible presentation benchmark.
export async function run(mode) {
  const check = (ok, message) => { if (!ok) throw new Error(message); };
  check(mode === "normal" || mode === "restore", "unknown probe mode");
  const target = async (normal) => {
    const actual = await myzig.call("Test.memoryTarget", normal);
    check(actual === (normal ? 0 : 1), "runtime memory target " + actual);
  };
  const ping = async () => {
    const start = performance.now();
    check(await myzig.call("Test.ping") === "pong", "ping reply");
    return performance.now() - start;
  };
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  if (await myzig.call("Test.memoryTarget", true) === null) {
    myzig.log("memory-probe: skipped (unsupported runtime)");
    myzig.log("memory-probe: ok");
    myzig.window.close();
    return;
  }
  if (!sessionStorage.getItem("memory-probe-reloaded")) {
    sessionStorage.setItem("memory-probe-reloaded", "yes");
    location.reload();
    return;
  }
  // Keep touched JS memory and a DOM object across every transition.
  const bytes = new Uint8Array(8 * 1024 * 1024);
  for (let i = 0; i < bytes.length; i += 4096) bytes[i] = (i / 4096) % 251;
  const node = document.createElement("p");
  node.textContent = "memory-state-survives";
  document.body.append(node);
  const origin = performance.timeOrigin;
  const samples = [];
  await target(true);
  for (let i = 0; i < 20; i++) await ping(); // Warm IPC/JIT before timing.
  for (let cycle = 0; cycle < 10; cycle++) {
    await target(mode === "normal");
    // Low must keep timers, requests and IPC alive without losing state.
    const body = await (await fetch("/embedded%20name.txt", { cache: "no-store" })).text();
    check(body === "embedded space", "fetch during dwell");
    await ping();
    myzig.log("memory-phase", mode, cycle, "dwell");
    // No fetch or IPC after this idle period until the timed restore request.
    await sleep(2000);
    const start = performance.now();
    await target(true);
    const transition = performance.now() - start;
    const first = await ping();
    const warm = [];
    for (let i = 0; i < 20; i++) warm.push(await ping());
    check(document.body.contains(node) && node.textContent === "memory-state-survives", "DOM lost");
    check(performance.timeOrigin === origin, "document reloaded");
    for (let i = 0; i < bytes.length; i += 4096) {
      check(bytes[i] === (i / 4096) % 251, "JS memory lost");
    }
    samples.push({ cycle, transition_ms: transition, first_ping_ms: first, warm_ping_ms: warm });
    myzig.log("memory-phase", mode, cycle, "normal");
    await sleep(1000);
  }
  await target(false);
  myzig.log("memory-result", JSON.stringify({ mode, cycles: samples.length,
    user_agent: navigator.userAgent, reloaded: true, samples }));
  myzig.log("memory-probe: ok");
  myzig.window.close();
}
