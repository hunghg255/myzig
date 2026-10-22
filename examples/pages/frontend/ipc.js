// End-to-end IPC throughput, including batched replies and UTF-16 conversion.
export async function run() {
  const cases = [
    { name: "ascii-small", value: "x".repeat(64), count: 200 },
    { name: "unicode", value: "Tiếng Việt 🐯 ".repeat(64), count: 100 },
    { name: "large", value: "x".repeat(65536), count: 20 },
  ];
  const results = [];
  for (const item of cases) {
    const batch = async () => {
      const replies = await Promise.all(Array.from({ length: 8 },
        () => myzig.call("Test.echo", item.value)));
      if (!replies.every((v) => v === item.value)) throw new Error("echo mismatch " + item.name);
    };
    for (let i = 0; i < 5; i++) await batch();
    const samples = [];
    for (let round = 0; round < 5; round++) {
      const start = performance.now();
      for (let i = 0; i < item.count; i++) await batch();
      samples.push(performance.now() - start);
    }
    results.push({ name: item.name, calls: item.count * 8,
      payload_utf8_bytes: new TextEncoder().encode(item.value).length, elapsed_ms: samples });
  }
  myzig.log("ipc-result", JSON.stringify(results));
  myzig.log("ipc-probe: ok");
  myzig.window.close();
}
