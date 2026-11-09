import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startDashboard } from "./server.mjs";

test("read-only loopback evidence server and pushed updates", async () => {
  const directory = await mkdtemp(join(tmpdir(), "arc-dashboard-"));
  const file = join(directory, "test.build-status.json");
  const payload = { version: 1, lab: { resourceGroup: "test-infra" }, stages: { "30": { status: "running" } }, events: [] };
  await writeFile(file, JSON.stringify(payload));
  const dashboard = await startDashboard({ stateFile: file });
  try {
    assert.match(dashboard.url, /^http:\/\/127\.0\.0\.1:\d+\/[a-f0-9]{48}\/$/);
    const page = await fetch(dashboard.url);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /Build ledger/);
    assert.match(page.headers.get("content-security-policy"), /script-src 'self'/);
    assert.deepEqual((await (await fetch(dashboard.url + "state")).json()).state, payload);
    assert.equal((await fetch(dashboard.url, { method: "POST" })).status, 403);
    assert.equal((await fetch(new URL("/", dashboard.url))).status, 403);
    assert.equal((await fetch(dashboard.url + "lab.env")).status, 404);
    const abort = new AbortController();
    const feed = await fetch(dashboard.url + "events", { signal: abort.signal });
    const reader = feed.body.getReader();
    assert.match(new TextDecoder().decode((await reader.read()).value), /"running"/);
    payload.stages["30"].status = "completed";
    await writeFile(file, JSON.stringify(payload));
    const next = await Promise.race([
      reader.read(), new Promise((_, reject) => setTimeout(() => reject(new Error("No evidence update pushed.")), 3000).unref()),
    ]);
    assert.match(new TextDecoder().decode(next.value), /"completed"/);
    abort.abort();
    await writeFile(file, "private-invalid-data");
    const invalid = await fetch(dashboard.url + "state");
    assert.equal(invalid.status, 503);
    assert.doesNotMatch(await invalid.text(), /private-invalid-data/);
    await assert.rejects(startDashboard({ stateFile: join(directory, "private.env") }), /never an environment file/);
  } finally { await dashboard.close(); await rm(directory, { recursive: true }); }
});
