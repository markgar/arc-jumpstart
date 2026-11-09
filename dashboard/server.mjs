import { createServer } from "node:http";
import { watch } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, basename, resolve } from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

export async function startDashboard({ stateFile, port = 0 }) {
  const file = resolve(stateFile);
  if (!file.endsWith(".build-status.json")) throw new Error("Select a .build-status.json evidence file, never an environment file.");
  const root = dirname(fileURLToPath(import.meta.url));
  const prefix = `/${randomBytes(24).toString("hex")}/`;
  const clients = new Set();
  async function snapshot() {
    try {
      const state = JSON.parse(await readFile(file, "utf8"));
      if (state.version !== 1 || !state.lab || !state.stages || !Array.isArray(state.events)) {
        throw new Error("schema");
      }
      return { state };
    } catch (error) {
      return { error: error.code === "ENOENT"
        ? "No evidence file exists yet. Start the deployment runner or capture a snapshot."
        : "Build evidence could not be read. Regenerate the snapshot; no status is being assumed." };
    }
  }
  const server = createServer(async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'");
    const expectedHost = `127.0.0.1:${server.address().port}`;
    if (req.headers.host !== expectedHost || req.method !== "GET" || !req.url?.startsWith(prefix)) {
      res.writeHead(403); res.end("Read-only local dashboard."); return;
    }
    const route = req.url.slice(prefix.length);
    if (route === "state") {
      const data = await snapshot();
      res.writeHead(data.error ? 503 : 200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(data)); return;
    }
    if (route === "events") {
      res.writeHead(200, { "Content-Type": "text/event-stream", Connection: "keep-alive" });
      clients.add(res);
      res.write(`data: ${JSON.stringify(await snapshot())}\n\n`);
      req.on("close", () => clients.delete(res));
      return;
    }
    const assets = { "": ["index.html", "text/html"], "app.js": ["app.js", "text/javascript"], "style.css": ["style.css", "text/css"] };
    const asset = Object.hasOwn(assets, route) ? assets[route] : null;
    if (!asset) { res.writeHead(404); res.end("Not found."); return; }
    try {
      const body = await readFile(resolve(root, asset[0]));
      res.writeHead(200, { "Content-Type": `${asset[1]}; charset=utf-8` });
      res.end(body);
    } catch {
      res.writeHead(500); res.end("Dashboard assets unavailable.");
    }
  });
  const watcher = watch(dirname(file), async (_event, name) => {
    if (name && String(name) !== basename(file)) return;
    const data = `data: ${JSON.stringify(await snapshot())}\n\n`;
    for (const client of clients) client.write(data);
  });
  watcher.on("error", () => {
    const data = 'data: {"error":"Local evidence watcher stopped. Restart the dashboard; no Azure polling is performed."}\n\n';
    for (const client of clients) client.write(data);
  });
  const heartbeat = setInterval(() => {
    for (const client of clients) client.write(": local connection heartbeat\n\n");
  }, 20000);
  heartbeat.unref();
  try {
    await new Promise((ok, fail) => {
      server.once("error", fail);
      server.listen(port, "127.0.0.1", ok);
    });
  } catch (error) { watcher.close(); clearInterval(heartbeat); throw error; }
  return {
    url: `http://127.0.0.1:${server.address().port}${prefix}`,
    close: async () => {
      watcher.close(); clearInterval(heartbeat);
      for (const client of clients) client.end();
      await new Promise((ok, fail) => server.close(error => error ? fail(error) : ok()));
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const value = name => args[args.indexOf(name) + 1];
  if (!args.includes("--state")) throw new Error("Use --state <lab.build-status.json>.");
  const port = args.includes("--port") ? Number(value("--port")) : 0;
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("Invalid port.");
  const dashboard = await startDashboard({ stateFile: value("--state"), port });
  process.stdout.write(`${dashboard.url}\n`);
  const stop = async () => { await dashboard.close(); process.exit(0); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
}
