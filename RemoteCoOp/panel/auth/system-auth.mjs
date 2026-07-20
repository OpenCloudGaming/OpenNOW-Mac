import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const authRoot = dirname(fileURLToPath(import.meta.url));
const bundledHelper = join(authRoot, "pam-auth-helper");
const installedHelper = "/usr/local/libexec/macforce-now-remote-coop-pam-auth-helper";
const defaultExplicitGroup = "macforce-now-coop-admin";
const fallbackAdminGroups = process.platform === "darwin" ? ["admin"] : ["sudo", "wheel"];

export function authConfiguration() {
  return {
    helperPath: helperPath(),
    allowedGroups: allowedGroups(),
    fallbackAdminGroups
  };
}

export async function authenticateSystemUser(username, password) {
  const normalizedUsername = normalizeUsername(username);
  if (!normalizedUsername || typeof password !== "string" || password.length === 0) return false;

  const helper = helperPath();
  if (!helper || !existsSync(helper)) throw new Error(`system auth helper is not installed at ${helper ?? installedHelper}`);

  const result = await run(helper, [normalizedUsername], password, 15_000);
  return result.code === 0;
}

export async function userIsAllowed(username) {
  const normalizedUsername = normalizeUsername(username);
  if (!normalizedUsername) return false;

  const groups = await userGroups(normalizedUsername);
  if (groups.size === 0) return false;

  const explicitGroups = allowedGroups();
  const existingExplicitGroups = [];
  for (const group of explicitGroups) {
    if (await groupExists(group)) existingExplicitGroups.push(group);
  }

  const requiredGroups = existingExplicitGroups.length > 0 ? existingExplicitGroups : fallbackAdminGroups;
  return requiredGroups.some(group => groups.has(group));
}

export function normalizeUsername(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  return /^[A-Za-z0-9._@-]{1,128}$/.test(trimmed) ? trimmed : "";
}

function helperPath() {
  const configured = process.env.MACFORCE_NOW_REMOTE_COOP_PANEL_AUTH_HELPER;
  if (typeof configured === "string" && configured.trim()) return configured.trim();
  if (existsSync(installedHelper)) return installedHelper;
  return bundledHelper;
}

function allowedGroups() {
  const configured = process.env.MACFORCE_NOW_REMOTE_COOP_PANEL_ALLOWED_GROUPS;
  const groups = typeof configured === "string" && configured.trim()
    ? configured.split(",").map(group => group.trim()).filter(Boolean)
    : [defaultExplicitGroup];
  return groups.length > 0 ? groups : [defaultExplicitGroup];
}

async function userGroups(username) {
  const result = await run("id", ["-Gn", username], "", 5_000);
  if (result.code !== 0) return new Set();
  return new Set(result.stdout.trim().split(/\s+/).filter(Boolean));
}

async function groupExists(group) {
  if (process.platform === "darwin") {
    const result = await run("/usr/bin/dscl", [".", "-read", `/Groups/${group}`], "", 5_000);
    return result.code === 0;
  }

  const getent = await run("getent", ["group", group], "", 5_000);
  if (getent.code === 0) return true;
  const id = await run("id", ["-g", group], "", 5_000);
  return id.code === 0;
}

function run(command, args, stdin, timeoutMilliseconds) {
  return new Promise(resolve => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      child.kill("SIGKILL");
    }, timeoutMilliseconds);

    child.stdout.on("data", chunk => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", chunk => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: 127, stdout, stderr: error.message });
    });
    child.on("close", code => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: code ?? 1, stdout, stderr });
    });
    child.stdin.end(stdin);
  });
}
