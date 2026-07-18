let csrfToken = "";

const elements = {
  serviceState: document.querySelector("#service-state"),
  serviceDetail: document.querySelector("#service-detail"),
  childPid: document.querySelector("#child-pid"),
  childUptime: document.querySelector("#child-uptime"),
  brokerEndpoint: document.querySelector("#broker-endpoint"),
  lastExit: document.querySelector("#last-exit"),
  panelUser: document.querySelector("#panel-user"),
  panelPid: document.querySelector("#panel-pid"),
  panelUptime: document.querySelector("#panel-uptime"),
  autoUpdate: document.querySelector("#auto-update"),
  updateState: document.querySelector("#update-state"),
  updateDetail: document.querySelector("#update-detail"),
  pendingCommits: document.querySelector("#pending-commits"),
  logs: document.querySelector("#logs")
};

document.querySelector("#start").addEventListener("click", () => action("/admin/api/start"));
document.querySelector("#stop").addEventListener("click", () => action("/admin/api/stop"));
document.querySelector("#restart").addEventListener("click", () => action("/admin/api/restart"));
document.querySelector("#logout").addEventListener("click", () => action("/admin/api/logout", true));
document.querySelector("#refresh-logs").addEventListener("click", refreshLogs);
document.querySelector("#check-update").addEventListener("click", refreshUpdateStatus);
document.querySelector("#apply-update").addEventListener("click", applyUpdate);

start();

function start() {
  refreshStatus().catch(showStatusError);
  refreshLogs().catch(() => {});
  refreshUpdateStatus().catch(() => {});
  setInterval(refreshStatus, 5000);
  setInterval(refreshLogs, 5000);

  const events = new EventSource("/admin/api/events");
  events.addEventListener("message", () => {
    refreshStatus();
    refreshLogs();
  });
}

function showStatusError(error) {
  elements.serviceState.textContent = "Status Unavailable";
  elements.serviceDetail.textContent = `Could not load panel status: ${error.message}`;
}

async function action(path, redirectOnSuccess = false) {
  setBusy(true);
  try {
    const response = await fetch(path, { method: "POST", headers: { "x-csrf-token": csrfToken } });
    if (response.status === 401) location.href = "/admin/login";
    if (!response.ok) throw new Error(await response.text());
    if (redirectOnSuccess) location.href = "/admin/login";
    await refreshStatus();
    await refreshLogs();
  } catch (error) {
    alert(`Action failed: ${error.message}`);
  } finally {
    setBusy(false);
  }
}

async function applyUpdate() {
  setBusy(true);
  elements.updateState.textContent = "Updating";
  elements.updateDetail.textContent = "Stopping child process, pulling Git updates, and validating.";
  try {
    const response = await fetch("/admin/api/update/apply", { method: "POST", headers: { "x-csrf-token": csrfToken } });
    const payload = await response.json();
    if (!response.ok && !payload.result) throw new Error(JSON.stringify(payload));
    renderUpdateResult(payload.result);
    if (payload.restartingPanel) {
      elements.updateDetail.textContent = "Panel files changed. The service manager is restarting the panel.";
      setTimeout(() => location.reload(), 2500);
    }
  } catch (error) {
    alert(`Update failed: ${error.message}`);
  } finally {
    setBusy(false);
  }
}

async function refreshStatus() {
  const response = await fetch("/admin/api/status");
  if (response.status === 401) {
    location.href = "/admin/login";
    return;
  }
  const status = await response.json();
  csrfToken = status.csrfToken;
  renderStatus(status);
}

async function refreshLogs() {
  const response = await fetch("/admin/api/logs");
  if (!response.ok) return;
  const payload = await response.json();
  elements.logs.textContent = payload.logs.map(entry => `${entry.at} [${entry.label}] ${entry.message}`).join("\n");
  elements.logs.scrollTop = elements.logs.scrollHeight;
}

async function refreshUpdateStatus() {
  const response = await fetch("/admin/api/update/status");
  if (!response.ok) return;
  const payload = await response.json();
  renderUpdateStatus(payload.status, payload.lastUpdateResult);
}

function renderStatus(status) {
  const child = status.child;
  elements.serviceState.textContent = title(child.state);
  elements.serviceDetail.textContent = child.pid ? `Running as process ${child.pid}.` : "Remote Co-Op child process is not running.";
  elements.childPid.textContent = child.pid ?? "-";
  elements.childUptime.textContent = duration(child.uptimeSeconds);
  elements.brokerEndpoint.textContent = brokerEndpoint(child.broker);
  elements.lastExit.textContent = child.lastExit ? `${child.lastExit.at} code=${child.lastExit.code ?? "none"} signal=${child.lastExit.signal ?? "none"}` : "-";
  elements.panelUser.textContent = status.user;
  elements.panelPid.textContent = status.panel.pid;
  elements.panelUptime.textContent = duration(status.panel.uptimeSeconds);
  elements.autoUpdate.textContent = status.panel.automaticUpdates ? `Enabled (${status.panel.updateIntervalSeconds}s)` : "Disabled";
}

function renderUpdateStatus(status, lastResult) {
  if (status.blockedReason) {
    elements.updateState.textContent = "Blocked";
    elements.updateDetail.textContent = status.blockedReason;
  } else if (status.updateAvailable) {
    elements.updateState.textContent = "Update Available";
    elements.updateDetail.textContent = `${status.pendingCommits.length} pending commit(s) from ${status.upstream}.`;
  } else {
    elements.updateState.textContent = "Up To Date";
    elements.updateDetail.textContent = lastResult?.at ? `Last update result: ${lastResult.blockedReason || "applied"} at ${lastResult.at}.` : "No pending commits.";
  }
  elements.pendingCommits.style.display = status.pendingCommits?.length ? "block" : "none";
  elements.pendingCommits.textContent = status.pendingCommits?.join("\n") ?? "";
}

function renderUpdateResult(result) {
  elements.updateState.textContent = result.applied ? "Updated" : "Not Updated";
  elements.updateDetail.textContent = result.blockedReason || "Update applied and validation passed.";
  elements.pendingCommits.style.display = result.beforeStatus?.pendingCommits?.length ? "block" : "none";
  elements.pendingCommits.textContent = result.beforeStatus?.pendingCommits?.join("\n") ?? "";
}

function brokerEndpoint(broker) {
  if (!broker) return "-";
  const scheme = broker.secure ? "wss" : "ws";
  return `${scheme}://${broker.bindHost}:${broker.port}/remote-coop`;
}

function duration(seconds) {
  if (!seconds) return "-";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = seconds % 60;
  return [hours && `${hours}h`, minutes && `${minutes}m`, `${rest}s`].filter(Boolean).join(" ");
}

function title(value) {
  return String(value || "unknown").replace(/_/g, " ").replace(/^./, character => character.toUpperCase());
}

function setBusy(busy) {
  for (const button of document.querySelectorAll("button")) button.disabled = busy;
}
