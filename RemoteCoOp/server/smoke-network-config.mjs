#!/usr/bin/env node
import { createHmac, randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);

if (args.includes("--help") || args.includes("-h")) {
  printHelp();
  process.exit(0);
}

const brokerURLArg = argValue("--broker-url");
const verbose = envFlag("OPENNOW_REMOTE_COOP_SMOKE_VERBOSE", false);
const smokeSecret = process.env.OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET || "opennow-remote-coop-smoke-secret";
const smokeTurnURLs = process.env.OPENNOW_REMOTE_COOP_TURN_URLS || "turn:127.0.0.1:3478?transport=udp,turn:127.0.0.1:3478?transport=tcp";
const smokeStunURLs = process.env.OPENNOW_REMOTE_COOP_STUN_URLS || "stun:stun.l.google.com:19302";
const smokeTTLSeconds = process.env.OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS || "3600";

let brokerProcess = null;
let brokerStopping = false;

try {
  const brokerURL = brokerURLArg ? new URL(brokerURLArg) : await startBroker();
  await runSmokeChecks(brokerURL);
  console.log("Remote Co-Op network-config smoke passed.");
} catch (error) {
  console.error(`Remote Co-Op network-config smoke failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  await stopBroker();
}

async function startBroker() {
  const port = 18_780 + Math.floor(Math.random() * 1_000);
  const brokerURL = new URL(`http://127.0.0.1:${port}`);
  const brokerScript = fileURLToPath(new URL("./broker.mjs", import.meta.url));
  brokerProcess = spawn(process.execPath, [brokerScript], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      OPENNOW_REMOTE_COOP_PORT: String(port),
      OPENNOW_REMOTE_COOP_BIND_HOST: "127.0.0.1",
      OPENNOW_REMOTE_COOP_STUN_URLS: smokeStunURLs,
      OPENNOW_REMOTE_COOP_TURN_URLS: smokeTurnURLs,
      OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET: smokeSecret,
      OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS: smokeTTLSeconds
    }
  });
  if (verbose) {
    brokerProcess.stdout.on("data", data => process.stdout.write(`[broker] ${data}`));
    brokerProcess.stderr.on("data", data => process.stderr.write(`[broker] ${data}`));
  }
  brokerProcess.on("exit", code => {
    if (!brokerStopping && code !== 0 && process.exitCode === undefined) process.exitCode = code ?? 1;
  });
  await waitForBroker(brokerURL);
  return brokerURL;
}

async function runSmokeChecks(brokerURL) {
  await assertRelayOnly(brokerURL);
  await assertAutomatic(brokerURL);
  await assertDirectOnly(brokerURL);
}

async function assertRelayOnly(brokerURL) {
  const roomID = randomUUID();
  const config = await fetchNetworkConfiguration(brokerURL, inviteToken({ inviteID: roomID, transportMode: "relayOnly" }));
  assert(config.transportMode === "relayOnly", "relayOnly transportMode was not preserved");
  assert(config.iceTransportPolicy === "relay", "relayOnly did not force relay ICE policy");
  assert(Array.isArray(config.iceServers) && config.iceServers.length === 1, "relayOnly should emit exactly one TURN server group");
  const turnServer = config.iceServers[0];
  assert(turnServer.urls.every(url => url.startsWith("turn:") || url.startsWith("turns:")), "relayOnly emitted a non-TURN ICE URL");
  assert(typeof turnServer.username === "string" && turnServer.username.endsWith(`:${roomID}`), "TURN username does not include the room ID");
  assert(typeof turnServer.credential === "string" && turnServer.credential.length > 0, "TURN credential is missing");
  if (!brokerURLArg || process.env.OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET) {
    const expected = createHmac("sha1", smokeSecret).update(turnServer.username).digest("base64");
    assert(turnServer.credential === expected, "TURN credential HMAC does not match the shared secret");
  }
  const expiry = Number.parseInt(turnServer.username.split(":")[0], 10);
  assert(Number.isFinite(expiry) && expiry > Math.floor(Date.now() / 1_000), "TURN username expiry is not in the future");
}

async function assertAutomatic(brokerURL) {
  const config = await fetchNetworkConfiguration(brokerURL, inviteToken({ inviteID: randomUUID(), transportMode: "automatic" }));
  assert(config.transportMode === "automatic", "automatic transportMode was not preserved");
  assert(config.iceTransportPolicy === "all", "automatic should use all ICE candidates");
  const urls = config.iceServers.flatMap(server => server.urls ?? []);
  if (!brokerURLArg || process.env.OPENNOW_REMOTE_COOP_STUN_URLS) assert(urls.some(url => url.startsWith("stun:")), "automatic should include STUN URLs");
  if (!brokerURLArg || process.env.OPENNOW_REMOTE_COOP_TURN_URLS) assert(urls.some(url => url.startsWith("turn:")), "automatic should include TURN URLs when configured");
}

async function assertDirectOnly(brokerURL) {
  const config = await fetchNetworkConfiguration(brokerURL, inviteToken({ inviteID: randomUUID(), transportMode: "directOnly" }));
  assert(config.transportMode === "directOnly", "directOnly transportMode was not preserved");
  assert(config.iceTransportPolicy === "all", "directOnly should not force relay policy");
  const urls = config.iceServers.flatMap(server => server.urls ?? []);
  assert(!urls.some(url => url.startsWith("turn:") || url.startsWith("turns:")), "directOnly should not include TURN URLs");
}

async function fetchNetworkConfiguration(brokerURL, invite) {
  const url = new URL("/remote-coop/network-config", brokerURL);
  url.searchParams.set("invite", invite);
  const response = await getJSON(url);
  assert(response.statusCode === 200, `network-config returned HTTP ${response.statusCode}`);
  return response.body;
}

function inviteToken(payload) {
  const encoded = Buffer.from(JSON.stringify({ expiresAtEpochSeconds: Math.floor(Date.now() / 1_000) + 600, ...payload }), "utf8").toString("base64url");
  return `${encoded}.smoke-signature`;
}

async function waitForBroker(brokerURL) {
  const deadline = Date.now() + 5_000;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await getJSON(new URL("/", brokerURL), 500);
      if (response.statusCode === 200 || response.statusCode === 404) return;
    } catch (error) {
      lastError = error;
    }
    await sleep(100);
  }
  throw new Error(`broker did not become ready: ${lastError?.message ?? "timeout"}`);
}

function getJSON(url, timeoutMilliseconds = 2_000) {
  return new Promise((resolve, reject) => {
    const request = (url.protocol === "https:" ? httpsRequest : httpRequest)(url, { timeout: timeoutMilliseconds }, response => {
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        try {
          resolve({ statusCode: response.statusCode ?? 0, body: text ? JSON.parse(text) : null });
        } catch {
          resolve({ statusCode: response.statusCode ?? 0, body: text });
        }
      });
    });
    request.on("timeout", () => request.destroy(new Error(`request timed out: ${url}`)));
    request.on("error", reject);
    request.end();
  });
}

async function stopBroker() {
  if (!brokerProcess || brokerProcess.exitCode !== null) return;
  brokerStopping = true;
  brokerProcess.kill("SIGTERM");
  const deadline = Date.now() + 2_000;
  while (brokerProcess.exitCode === null && Date.now() < deadline) await sleep(50);
  if (brokerProcess.exitCode === null) brokerProcess.kill("SIGKILL");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function argValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
}

function envFlag(name, fallback) {
  const value = process.env[name];
  if (typeof value !== "string") return fallback;
  return !["0", "false", "no", "off", ""].includes(value.trim().toLowerCase());
}

function printHelp() {
  console.log(`Usage: node RemoteCoOp/server/smoke-network-config.mjs [--broker-url URL]

By default this starts a temporary local broker with test STUN/TURN settings and
verifies Automatic, Relay Only, and Direct Only ICE network config responses.

Use --broker-url to target an already running broker. When targeting a running
broker, set OPENNOW_REMOTE_COOP_TURN_URLS and OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET
in this process if you want the smoke check to verify TURN HMAC credentials.`);
}
