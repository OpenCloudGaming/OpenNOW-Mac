#!/usr/bin/env node
import { createServer } from "node:https";
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authenticateSystemUser, authConfiguration, normalizeUsername, userIsAllowed } from "./auth/system-auth.mjs";
import { applyGitUpdate, updateStatus } from "./update/git-updater.mjs";

const panelRoot = dirname(fileURLToPath(import.meta.url));
const remoteCoOpRoot = dirname(panelRoot);
const repoRoot = dirname(remoteCoOpRoot);
const stateRoot = join(panelRoot, "state");
const runServersScript = join(remoteCoOpRoot, "run-servers.mjs");
const productionHost = "198.12.95.48";
const bindHost = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_BIND_HOST", "0.0.0.0");
const port = integerEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_PORT", 32187);
const sessionTimeoutMs = integerEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_SESSION_TIMEOUT_SECONDS", 3_600) * 1_000;
const loginWindowMs = 5 * 60_000;
const maxLoginFailures = 8;
const childAutostart = booleanEnv("MACFORCE_NOW_REMOTE_COOP_AUTOSTART", true);
const childAutoRestart = booleanEnv("MACFORCE_NOW_REMOTE_COOP_CHILD_AUTORESTART", false);
const automaticUpdates = booleanEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_UPDATE_AUTOMATIC", true);
const updateIntervalMs = Math.max(60, integerEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_UPDATE_INTERVAL_SECONDS", 300)) * 1_000;
const updateBranch = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_UPDATE_BRANCH", "");
const updateValidationCommand = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_UPDATE_VALIDATE", "node RemoteCoOp/run-servers.mjs --dry-run");
const updateAutoRestart = booleanEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_UPDATE_AUTO_RESTART", true);
const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"]
]);

mkdirSync(stateRoot, { recursive: true, mode: 0o700 });

const sessionSecret = readOrCreateSecret("session-secret");
const generatedTurnSecret = readOrCreateSecret("turn-shared-secret");
const generatedInviteSecret = readOrCreateSecret("invite-secret");
const tls = readOrCreateTLSMaterial();
const sessions = new Map();
const loginFailures = new Map();
const events = new Set();
const logs = [];
const maxLogs = integerEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_LOG_LINES", 1_000);
let manager;
let updaterRunning = false;
let lastUpdateResult = readJSONState("last-update.json", null);

const server = createServer({ cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) }, async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    appendLog("panel", `request failed: ${error.message}`);
    sendJSON(response, 500, { error: "internal_error" });
  }
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, async () => {
    appendLog("panel", `received ${signal}; stopping child and panel`);
    await manager.stop("panel_shutdown");
    process.exit(0);
  });
}

async function route(request, response) {
  const url = new URL(request.url ?? "/", `https://${request.headers.host ?? "localhost"}`);
  if (request.method === "GET" && url.pathname === "/healthz") {
    sendJSON(response, 200, { ok: true });
    return;
  }
  if (request.method === "GET" && url.pathname === "/") {
    redirect(response, "/admin");
    return;
  }
  if (request.method === "GET" && url.pathname === "/admin/login") {
    await sendFile(response, join(panelRoot, "login.html"));
    return;
  }
  const publicAsset = panelAssetPath(url.pathname);
  if (request.method === "GET" && publicAsset) {
    await sendFile(response, publicAsset);
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/login") {
    await handleLogin(request, response);
    return;
  }

  const session = authenticatedSession(request);
  if (!session) {
    if (url.pathname.startsWith("/admin/api/")) sendJSON(response, 401, { error: "not_authenticated" });
    else redirect(response, "/admin/login");
    return;
  }

  if (request.method === "POST" && !validCSRF(request, session)) {
    sendJSON(response, 403, { error: "invalid_csrf" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/admin") {
    await sendFile(response, join(panelRoot, "admin.html"));
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/api/logout") {
    sessions.delete(session.id);
    setCookie(response, "macforce-now_coop_panel", "", { maxAge: 0 });
    sendJSON(response, 200, { ok: true });
    return;
  }
  if (request.method === "GET" && url.pathname === "/admin/api/status") {
    sendJSON(response, 200, panelStatus(session));
    return;
  }
  if (request.method === "GET" && url.pathname === "/admin/api/logs") {
    sendJSON(response, 200, { logs });
    return;
  }
  if (request.method === "GET" && url.pathname === "/admin/api/events") {
    streamEvents(response, session);
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/api/start") {
    await manager.start(`user:${session.username}`);
    audit(session.username, "start");
    sendJSON(response, 200, panelStatus(session));
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/api/stop") {
    await manager.stop(`user:${session.username}`);
    audit(session.username, "stop");
    sendJSON(response, 200, panelStatus(session));
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/api/restart") {
    await manager.restart(`user:${session.username}`);
    audit(session.username, "restart");
    sendJSON(response, 200, panelStatus(session));
    return;
  }
  if (request.method === "GET" && url.pathname === "/admin/api/update/status") {
    const status = await safeUpdateStatus();
    sendJSON(response, 200, { status, lastUpdateResult });
    return;
  }
  if (request.method === "POST" && url.pathname === "/admin/api/update/apply") {
    const result = await runGitUpdate(session.username, "manual");
    sendJSON(response, result.applied ? 200 : 409, { result, restartingPanel: shouldRestartPanel(result) });
    if (shouldRestartPanel(result)) setTimeout(() => process.exit(0), 750).unref();
    return;
  }

  sendJSON(response, 404, { error: "not_found" });
}

function panelAssetPath(pathname) {
  if (pathname === "/admin.css" || pathname === "/admin/admin.css") return join(panelRoot, "admin.css");
  if (pathname === "/admin.js" || pathname === "/admin/admin.js") return join(panelRoot, "admin.js");
  return "";
}

async function handleLogin(request, response) {
  const remote = request.socket.remoteAddress ?? "unknown";
  if (isRateLimited(remote)) {
    sendHTML(response, 429, loginPage("Too many failed attempts. Try again later."));
    return;
  }

  const body = await readBody(request, 16_384);
  const form = new URLSearchParams(body);
  const username = normalizeUsername(form.get("username") ?? "");
  const password = form.get("password") ?? "";
  let authenticated = false;
  try {
    authenticated = await authenticateSystemUser(username, password);
    if (authenticated) authenticated = await userIsAllowed(username);
  } catch (error) {
    appendLog("auth", `login backend failed: ${error.message}`);
  }

  if (!authenticated) {
    recordFailure(remote);
    audit(username || remote, "login_failed");
    sendHTML(response, 401, loginPage("Invalid username, password, or panel access group."));
    return;
  }

  loginFailures.delete(remote);
  const session = createSession(username);
  setCookie(response, "macforce-now_coop_panel", signSessionID(session.id), { maxAge: Math.floor(sessionTimeoutMs / 1_000) });
  audit(username, "login");
  redirect(response, "/admin");
}

function panelStatus(session) {
  return {
    csrfToken: session.csrfToken,
    user: "Authenticated",
    panel: {
      uptimeSeconds: Math.floor(process.uptime()),
      pid: process.pid,
      automaticUpdates,
      updateIntervalSeconds: Math.floor(updateIntervalMs / 1_000),
      tlsGenerated: tls.generated
    },
    child: manager.status(),
    update: { lastUpdateResult },
    auth: authConfiguration()
  };
}

class ChildManager {
  constructor() {
    this.child = null;
    this.state = "stopped";
    this.startedAt = 0;
    this.stopping = false;
    this.restartRequested = false;
    this.lastExit = null;
    this.broker = null;
    this.coopStats = defaultCoOpStats();
  }

  async start(reason) {
    if (this.child) return;
    this.state = "starting";
    this.stopping = false;
    this.broker = null;
    const env = childEnvironment();
    const child = spawn(process.execPath, [runServersScript], { cwd: repoRoot, env, stdio: ["ignore", "pipe", "pipe", "ipc"] });
    this.child = child;
    this.startedAt = Date.now();
    appendLog("panel", `starting Remote Co-Op servers (${reason})`);
    emitEvent();

    child.stdout.on("data", chunk => appendStream("remote-coop", chunk));
    child.stderr.on("data", chunk => appendStream("remote-coop", chunk));
    child.on("message", message => this.handleMessage(message));
    child.on("error", error => {
      appendLog("panel", `failed to start child: ${error.message}`);
      this.state = "failed";
      emitEvent();
    });
    child.on("exit", (code, signal) => {
      this.lastExit = { code, signal, at: new Date().toISOString() };
      this.child = null;
      const wasStopping = this.stopping;
      this.stopping = false;
      this.state = wasStopping ? "stopped" : "crashed";
      appendLog("panel", `Remote Co-Op child exited${signal ? ` from ${signal}` : ""} with code ${code ?? "none"}`);
      emitEvent();
      if (!wasStopping && childAutoRestart) {
        setTimeout(() => this.start("autorestart").catch(error => appendLog("panel", `autorestart failed: ${error.message}`)), 5_000).unref();
      }
    });
  }

  async stop(reason) {
    if (!this.child) {
      this.state = "stopped";
      return;
    }
    appendLog("panel", `stopping Remote Co-Op servers (${reason})`);
    this.stopping = true;
    this.state = "stopping";
    emitEvent();
    const child = this.child;
    child.kill("SIGTERM");
    await waitForExit(child, 7_500);
    if (this.child === child) child.kill("SIGKILL");
    await waitForExit(child, 2_500);
  }

  async restart(reason) {
    const wasRunning = Boolean(this.child);
    if (wasRunning) await this.stop(reason);
    await this.start(reason);
  }

  handleMessage(message) {
    if (!message || typeof message !== "object") return;
    if (message.kind === "remoteCoOpRunnerStarted") {
      this.state = "running";
    } else if (message.kind === "remoteCoOpBrokerListening") {
      this.broker = message;
      this.state = "running";
    } else if (message.kind === "remoteCoOpBrokerStats") {
      this.coopStats = coOpStatsFromMessage(message);
    } else if (message.kind === "remoteCoOpRunnerStopping") {
      this.state = "stopping";
    } else if (message.kind === "remoteCoOpChildExited") {
      appendLog("panel", `${message.label} process exited with code ${message.code ?? "none"}${message.signal ? ` from ${message.signal}` : ""}`);
    }
    emitEvent();
  }

  status() {
    return {
      state: this.state,
      pid: this.child?.pid ?? null,
      uptimeSeconds: this.child ? Math.floor((Date.now() - this.startedAt) / 1_000) : 0,
      broker: this.broker,
      coopStats: this.coopStats,
      lastExit: this.lastExit,
      autostart: childAutostart,
      autorestart: childAutoRestart
    };
  }
}

function defaultCoOpStats() {
  return { activeSessions: 0, activeGuests: 0, pendingSessions: 0, pendingGuests: 0, pastSessions: 0, totalStarted: 0, recentSessions: [], updatedAt: null };
}

function coOpStatsFromMessage(message) {
  return {
    activeSessions: finiteNumber(message.activeSessions),
    activeGuests: finiteNumber(message.activeGuests),
    pendingSessions: finiteNumber(message.pendingSessions),
    pendingGuests: finiteNumber(message.pendingGuests),
    pastSessions: finiteNumber(message.pastSessions),
    totalStarted: finiteNumber(message.totalStarted),
    recentSessions: Array.isArray(message.recentSessions) ? message.recentSessions.slice(0, 12).map(session => ({
      endedAt: typeof session.endedAt === "string" ? session.endedAt : "",
      durationSeconds: finiteNumber(session.durationSeconds),
      maxGuests: finiteNumber(session.maxGuests),
      reason: typeof session.reason === "string" ? session.reason : "closed"
    })) : [],
    updatedAt: typeof message.updatedAt === "string" ? message.updatedAt : null
  };
}

function finiteNumber(value) {
  return Number.isFinite(value) ? value : 0;
}

manager = new ChildManager();

server.listen(port, bindHost, () => {
  appendLog("panel", `MacForce Now Remote Co-Op panel listening on https://${bindHost}:${port}`);
  appendLog("panel", `auth helper: ${authConfiguration().helperPath}`);
  if (childAutostart) manager.start("autostart").catch(error => appendLog("panel", `autostart failed: ${error.message}`));
  if (automaticUpdates) scheduleAutomaticUpdates();
});

async function runGitUpdate(username, mode) {
  if (updaterRunning) return { applied: false, blockedReason: "update already running" };
  updaterRunning = true;
  const childWasRunning = Boolean(manager.child);
  try {
    audit(username, `update_${mode}_started`);
    if (childWasRunning) await manager.stop("git_update");
    const result = await applyGitUpdate(repoRoot, { branch: updateBranch, validationCommand: updateValidationCommand });
    lastUpdateResult = { ...result, at: new Date().toISOString(), mode };
    writeJSONState("last-update.json", lastUpdateResult);
    if (result.applied) audit(username, `update_${mode}_applied`);
    else audit(username, `update_${mode}_blocked:${result.blockedReason}`);
    if (childWasRunning && (!shouldRestartPanel(result) || !updateAutoRestart)) await manager.start("git_update");
    return result;
  } catch (error) {
    const result = { applied: false, blockedReason: error.message, at: new Date().toISOString(), mode };
    lastUpdateResult = result;
    writeJSONState("last-update.json", result);
    appendLog("update", `update failed: ${error.message}`);
    if (childWasRunning) await manager.start("git_update_failed");
    return result;
  } finally {
    updaterRunning = false;
    emitEvent();
  }
}

function shouldRestartPanel(result) {
  return updateAutoRestart && result?.applied && Array.isArray(result.changedPanelFiles) && result.changedPanelFiles.length > 0;
}

async function safeUpdateStatus() {
  try {
    return await updateStatus(repoRoot, { branch: updateBranch });
  } catch (error) {
    return { blockedReason: error.message, updateAvailable: false, pendingCommits: [] };
  }
}

function scheduleAutomaticUpdates() {
  setTimeout(async function tick() {
    const status = await safeUpdateStatus();
    if (status.updateAvailable && !status.blockedReason) {
      const result = await runGitUpdate("system", "automatic");
      if (shouldRestartPanel(result)) setTimeout(() => process.exit(0), 750).unref();
    }
    setTimeout(tick, updateIntervalMs).unref();
  }, 30_000).unref();
}

function childEnvironment() {
  const publicHost = stringEnv("MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST", productionHost);
  const env = {
    ...process.env,
    MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST: publicHost,
    MACFORCE_NOW_REMOTE_COOP_PORT: stringEnv("MACFORCE_NOW_REMOTE_COOP_PORT", "32188"),
    MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET", generatedTurnSecret),
    MACFORCE_NOW_REMOTE_COOP_INVITE_SECRET: stringEnv("MACFORCE_NOW_REMOTE_COOP_INVITE_SECRET", generatedInviteSecret)
  };
  return env;
}

function authenticatedSession(request) {
  const cookie = parseCookies(request.headers.cookie ?? "")["macforce-now_coop_panel"];
  const sessionID = verifySessionCookie(cookie);
  if (!sessionID) return null;
  const session = sessions.get(sessionID);
  if (!session) return null;
  if (Date.now() - session.lastSeenAt > sessionTimeoutMs) {
    sessions.delete(sessionID);
    return null;
  }
  session.lastSeenAt = Date.now();
  return session;
}

function createSession(username) {
  const session = { id: randomBytes(32).toString("base64url"), username, csrfToken: randomBytes(32).toString("base64url"), createdAt: Date.now(), lastSeenAt: Date.now() };
  sessions.set(session.id, session);
  return session;
}

function signSessionID(sessionID) {
  return `${sessionID}.${hmac(sessionID, sessionSecret)}`;
}

function verifySessionCookie(value) {
  if (typeof value !== "string") return "";
  const [sessionID, signature] = value.split(".");
  if (!sessionID || !signature) return "";
  const expected = hmac(sessionID, sessionSecret);
  const expectedBuffer = Buffer.from(expected, "utf8");
  const signatureBuffer = Buffer.from(signature, "utf8");
  if (expectedBuffer.length !== signatureBuffer.length) return "";
  return timingSafeEqual(expectedBuffer, signatureBuffer) ? sessionID : "";
}

function validCSRF(request, session) {
  const provided = request.headers["x-csrf-token"];
  if (typeof provided !== "string" || typeof session.csrfToken !== "string") return false;
  const providedBuffer = Buffer.from(provided, "utf8");
  const expectedBuffer = Buffer.from(session.csrfToken, "utf8");
  if (providedBuffer.length !== expectedBuffer.length) return false;
  return timingSafeEqual(providedBuffer, expectedBuffer);
}

function hmac(value, secret) {
  return createHmac("sha256", secret).update(value).digest("base64url");
}

function isRateLimited(remote) {
  const now = Date.now();
  const record = loginFailures.get(remote);
  if (!record) return false;
  record.failures = record.failures.filter(at => now - at < loginWindowMs);
  return record.failures.length >= maxLoginFailures;
}

function recordFailure(remote) {
  const now = Date.now();
  const record = loginFailures.get(remote) ?? { failures: [] };
  record.failures = record.failures.filter(at => now - at < loginWindowMs);
  record.failures.push(now);
  loginFailures.set(remote, record);
}

function readOrCreateSecret(name) {
  const path = join(stateRoot, name);
  if (existsSync(path)) return readFileSync(path, "utf8").trim();
  const secret = randomBytes(48).toString("base64url");
  writeFileSync(path, `${secret}\n`, { mode: 0o600 });
  return secret;
}

function readOrCreateTLSMaterial() {
  const certPath = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_CERT", join(stateRoot, "panel-cert.pem"));
  const keyPath = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_KEY", join(stateRoot, "panel-key.pem"));
  if (existsSync(certPath) && existsSync(keyPath)) return { certPath, keyPath, generated: false };

  const host = stringEnv("MACFORCE_NOW_REMOTE_COOP_PANEL_TLS_HOST", stringEnv("MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST", productionHost));
  const configPath = join(stateRoot, "openssl.cnf");
  const altName = /^\d+\.\d+\.\d+\.\d+$/.test(host) ? `IP.1 = ${host}` : `DNS.1 = ${host}`;
  writeFileSync(configPath, `[req]\ndefault_bits = 2048\nprompt = no\ndefault_md = sha256\ndistinguished_name = dn\nx509_extensions = v3_req\n[dn]\nCN = ${host}\n[v3_req]\nsubjectAltName = @alt_names\n[alt_names]\n${altName}\n`, { mode: 0o600 });
  const result = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "825", "-keyout", keyPath, "-out", certPath, "-config", configPath], { stdio: "pipe" });
  if (result.status !== 0) throw new Error(`failed to generate panel TLS certificate with openssl: ${result.stderr.toString("utf8")}`);
  return { certPath, keyPath, generated: true };
}

function appendStream(label, chunk) {
  for (const line of chunk.toString("utf8").split(/\r?\n/)) {
    if (line) appendLog(label, line);
  }
}

function appendLog(label, message) {
  const entry = { at: new Date().toISOString(), label, message: redact(message) };
  logs.push(entry);
  while (logs.length > maxLogs) logs.shift();
  console.log(`[${label}] ${entry.message}`);
  emitEvent();
}

function audit(username, action) {
  appendLog("audit", `panel action=${action}`);
}

function redact(value) {
  return String(value)
    .replace(/((?:SECRET|TOKEN|PASSWORD|CREDENTIAL|KEY|CERT)[A-Z0-9_]*=)([^\s]+)/gi, "$1<redacted>")
    .replace(/(--static-auth-secret=)([^\s]+)/gi, "$1<redacted>")
    .replace(/\b(roomID|participantID|inviteToken|displayName|remote|forwardedFor)=((?:"[^"]*")|[^\s]+)/gi, "$1=<redacted>")
    .replace(/\b(room|participant)=([^\s]+)/gi, "$1=<redacted>");
}

function emitEvent() {
  const payload = `data: ${JSON.stringify({ at: new Date().toISOString() })}\n\n`;
  for (const response of events) response.write(payload);
}

function streamEvents(response) {
  response.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-store",
    connection: "keep-alive"
  });
  response.write("retry: 2000\n\n");
  events.add(response);
  response.on("close", () => events.delete(response));
}

function readJSONState(name, fallback) {
  try {
    return JSON.parse(readFileSync(join(stateRoot, name), "utf8"));
  } catch {
    return fallback;
  }
}

function writeJSONState(name, value) {
  writeFileSync(join(stateRoot, name), `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

async function sendFile(response, path) {
  try {
    const stat = statSync(path);
    response.writeHead(200, {
      "cache-control": "no-store",
      "content-type": contentTypes.get(extname(path)) ?? "application/octet-stream",
      "content-length": stat.size
    });
    createReadStream(path).pipe(response);
  } catch {
    sendJSON(response, 404, { error: "not_found" });
  }
}

function sendJSON(response, status, payload) {
  const body = `${JSON.stringify(payload)}\n`;
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body)
  });
  response.end(body);
}

function sendHTML(response, status, html) {
  response.writeHead(status, { "cache-control": "no-store", "content-type": "text/html; charset=utf-8" });
  response.end(html);
}

function redirect(response, location) {
  response.writeHead(303, { location, "cache-control": "no-store" });
  response.end();
}

function setCookie(response, name, value, options) {
  const parts = [`${name}=${value}`, "Path=/admin", "HttpOnly", "Secure", "SameSite=Strict"];
  if (Number.isInteger(options.maxAge)) parts.push(`Max-Age=${options.maxAge}`);
  response.setHeader("set-cookie", parts.join("; "));
}

function parseCookies(header) {
  const cookies = {};
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index < 0) continue;
    cookies[part.slice(0, index).trim()] = part.slice(index + 1).trim();
  }
  return cookies;
}

function readBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", chunk => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function waitForExit(child, timeoutMilliseconds) {
  return new Promise(resolve => {
    if (child.exitCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, timeoutMilliseconds);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function loginPage(error) {
  return readFileSync(join(panelRoot, "login.html"), "utf8").replace("<!--ERROR-->", error ? `<p class=\"error\">${escapeHTML(error)}</p>` : "");
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"]/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[character]));
}

function stringEnv(name, fallback) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function booleanEnv(name, fallback) {
  const value = process.env[name];
  if (typeof value !== "string") return fallback;
  return !["0", "false", "no", "off", ""].includes(value.trim().toLowerCase());
}
