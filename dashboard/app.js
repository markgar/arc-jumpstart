const labels = { completed: "Verified", running: "Running", waiting: "Waiting", submitted: "Submitted", failed: "Failed", skipped: "Skipped", unknown: "Unknown", "not-started": "Not started", unverified: "Unverified" };
const stageOrder = ["00", "10", "sql-media", "20", "30", "40", "45", "50", "60", "ssms", "arc-launchers", "bastion"];
let state, selected, failuresOnly = false;
const el = id => document.getElementById(id);
function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}
function pill(status) { return node("span", labels[status] || "Unknown", `pill ${Object.hasOwn(labels, status) ? status : "unknown"}`); }
function time(value) {
  if (!value) return "Not recorded";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "Not recorded" : date.toLocaleString();
}
function age(value) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.valueOf())) return "not recorded";
  const seconds = Math.max(0, Math.floor((Date.now() - date) / 1000));
  return seconds < 60 ? `${seconds}s ago` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ago` : `${Math.floor(seconds / 3600)}h ago`;
}
function renderDetail() {
  const stage = state.stages[selected];
  el("detail-title").textContent = stage.title;
  el("detail-status").replaceChildren(pill(stage.status));
  el("detail-description").textContent = stage.detail || "No execution evidence has been recorded for this stage.";
  el("detail-times").replaceChildren();
  for (const [label, value] of [["Started", time(stage.startedAt)], ["Finished", time(stage.endedAt)], ["Last change", time(stage.progressAt)], ["Attempt", stage.attempt || "Not recorded"]]) {
    el("detail-times").append(node("dt", label), node("dd", value));
  }
  el("output").textContent = stage.output || "No host output has been recorded. Absence of output is not proof of failure.";
}
function renderGuests() {
  const rows = [
    ["JS-DC-01", "Domain controller", false, false],
    ["JS-SQL-01", "Standalone SQL", true, false],
    ["JS-SQL-AG-01", "AG replica", true, true],
    ["JS-SQL-AG-02", "AG replica", true, true],
    ["JS-RETAIL-01", "SQL + SSAS", true, false],
    ["JS-INSIGHT-01", "SSAS", true, false],
  ];
  if (state.lab.includeAppliance) rows.push(["JS-MIGRATE-01", "Reserved · unused appliance VM", false, false]);
  const passed = id => state.stages[id]?.status === "completed";
  el("guests").replaceChildren();
  for (const [name, role, sql, ag] of rows) {
    const row = node("tr");
    const heading = node("th", name); heading.scope = "row"; heading.append(node("small", role)); row.append(heading);
    const workload = name !== "JS-MIGRATE-01";
    for (const [applicable, verified, text] of [
      [true, passed("40"), "Verified"], [true, passed("40"), "Licensed"],
      [sql, passed("45"), "Verified"], [workload, passed("50"), "Verified"],
      [ag, passed("60"), "Verified"], [sql, passed("arc-launchers"), "Staged"],
    ]) row.append(node("td", !applicable ? "Not applicable" : verified ? text : "Unverified", verified && applicable ? "yes" : "unknown"));
    el("guests").append(row);
  }
}
function renderHistory() {
  el("events").replaceChildren();
  const events = state.events.filter(event => !failuresOnly || event.status === "failed").slice(-40).reverse();
  if (!events.length) { el("events").append(node("li", failuresOnly ? "No captured failure events." : "No event history captured yet.")); return; }
  for (const event of events) {
    const row = node("li");
    const stamp = node("time", time(event.at)); stamp.dateTime = event.at;
    const stage = node("div", state.stages[event.stage]?.title || event.stage);
    const detail = node("div"); detail.append(pill(event.status), node("p", event.detail));
    row.append(stamp, stage, detail); el("events").append(row);
  }
}
function render() {
  const focusedStage = document.activeElement?.dataset.stage;
  const stages = stageOrder.map(id => state.stages[id]).filter(Boolean);
  const active = stages.filter(s => s.status === "running" || s.status === "waiting");
  const failed = stages.filter(s => s.status === "failed" && s.id !== "bastion");
  const core = stages.filter(s => /^\d+$/.test(s.id));
  if (!selected || !state.stages[selected]) selected = (failed[0] || active[0] || stages.findLast(s => s.status === "completed") || stages[0]).id;
  el("lab").textContent = `${state.lab.resourceGroup} · ${state.lab.region || "Region not recorded"} · Windows Server ${state.lab.windowsVersion} · ${state.lab.includeLinux ? "Windows + Linux" : "Windows only"}`;
  el("headline").textContent = failed.length ? `Build stopped at ${failed[0].title.toLowerCase()}`
    : active.length === 1 && active[0].status === "waiting" ? `Waiting: ${active[0].title.toLowerCase()}`
    : active.length ? active.map(s => s.title).join(" + ") + " running"
    : core.length === 8 && core.every(s => s.status === "completed") ? "Core infrastructure gates passed"
    : "No active execution recorded";
  el("explanation").textContent = failed.length ? "Completed gates are retained. The next step is scoped diagnosis, not rebuilding the lab."
    : active.length ? "Only confirmed evidence advances a stage. A quiet step is not automatically a failure."
    : "Review unverified and not-started stages below. Arc connection remains a separate user action.";
  if (state.stages.bastion?.status === "failed") el("explanation").textContent += " Independent Bastion needs attention; it does not block the core build.";
  el("verified").textContent = `${core.filter(s => s.status === "completed").length} / ${core.length} core gates verified`;
  el("pipeline").replaceChildren();
  for (const stage of stages) {
    const button = node("button", undefined, "stage"); button.type = "button";
    button.dataset.stage = stage.id;
    button.setAttribute("aria-current", String(stage.id === selected));
    button.append(node("span", /^\d+$/.test(stage.id) ? stage.id : "—", "stage-code"));
    const title = node("span", stage.title, "stage-title");
    if (stage.id === "20" || stage.id === "30") title.append(node("small", "Parallel preparation"));
    if (stage.id === "bastion") title.append(node("small", "Independent · not a readiness gate"));
    button.append(title, pill(stage.status));
    button.onclick = () => { selected = stage.id; render(); };
    el("pipeline").append(button);
  }
  renderDetail(); renderGuests(); renderHistory(); freshness();
  if (focusedStage) [...el("pipeline").children].find(button => button.dataset.stage === focusedStage)?.focus();
}
function freshness() {
  if (!state) return;
  el("freshness").textContent = `Evidence observed ${age(state.updatedAt)}`;
}
el("history-filter").onclick = () => {
  failuresOnly = !failuresOnly;
  el("history-filter").setAttribute("aria-pressed", String(failuresOnly));
  el("history-filter").textContent = failuresOnly ? "Show all events" : "Show failures only";
  if (state) renderHistory();
};
const feed = new EventSource("events");
feed.onopen = () => { el("connection").textContent = "Watching local evidence"; };
feed.onerror = () => {
  el("connection").textContent = "Connection interrupted";
  el("error").hidden = false;
  el("error").textContent = "The local evidence connection is unavailable. Displayed data may be stale; no build status is being inferred.";
};
feed.onmessage = event => {
  try {
    const payload = JSON.parse(event.data);
    if (payload.error) throw new Error(payload.error);
    if (!payload.state?.stages || !payload.state?.lab || !Array.isArray(payload.state.events)) throw new Error("Invalid build evidence.");
    if (state && new Date(payload.state.updatedAt) < new Date(state.updatedAt)) return;
    state = payload.state;
    el("error").hidden = true; render();
  } catch (error) {
    el("error").hidden = false; el("error").textContent = error.message;
  }
};
setInterval(freshness, 1000);
