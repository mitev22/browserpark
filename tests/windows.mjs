// Helper for the tests. usage: node windows.mjs <port> fully-onscreen | count | new-window | shared-tab
const [port, cmd] = process.argv.slice(2);
const { webSocketDebuggerUrl: url } = await (await fetch(`http://localhost:${port}/json/version`)).json();
const targets = await (await fetch(`http://localhost:${port}/json/list`)).json();
const ws = new WebSocket(url);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const send = (method, params = {}, sessionId) =>
  new Promise((res, rej) => {
    const me = ++id;
    const h = (e) => {
      const m = JSON.parse(e.data);
      if (m.id !== me) return;
      ws.removeEventListener("message", h);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: me, method, params, ...(sessionId ? { sessionId } : {}) }));
  });

const windows = new Map();
for (const t of targets.filter((t) => t.type === "page")) {
  const { windowId, bounds } = await send("Browser.getWindowForTarget", { targetId: t.id });
  windows.set(windowId, bounds);
}

if (cmd === "count") console.log(windows.size);
if (cmd === "fully-onscreen") console.log([...windows.values()].every((b) => b.left >= 0 && b.top >= 0) ? "yes" : "no");
if (cmd === "new-window") await send("Target.createTarget", { url: "about:blank", newWindow: true });
if (cmd === "shared-tab") {
  // A background tab beside the first page, opened on Chrome's own port so the proxy can't change it.
  const { targetId } = await send("Target.createTarget", { url: "https://example.edu", background: true });
  await new Promise((r) => setTimeout(r, 1500));
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const reply = await send("Runtime.evaluate", { expression: "document.visibilityState" }, sessionId);
  console.log(reply.result.value);
}
ws.close();
