#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { networkInterfaces } from "node:os";
import { spawn, spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = new Set(process.argv.slice(2));
const root = dirname(fileURLToPath(import.meta.url));
const brokerScript = join(root, "server", "broker.mjs");
const turnScript = join(root, "turn", "turn-server.mjs");

if (args.has("--help") || args.has("-h")) {
  printHelp();
  process.exit(0);
}

const config = buildConfig();
printSummary(config);

if (args.has("--dry-run")) {
  const result = spawnSync(process.execPath, [turnScript, "--dry-run"], { env: config.env, stdio: "inherit" });
  process.exit(result.status ?? 1);
}

const children = new Map();
let stopping = false;

startChild("turn", [turnScript]);
startChild("broker", [brokerScript]);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => stopAll(signal, 0));
}

function buildConfig() {
  const publicHost = stringEnv("OPENNOW_REMOTE_COOP_PUBLIC_HOST", "") || stringEnv("OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST", "") || firstLANIPv4() || "127.0.0.1";
  const generatedSecret = !stringEnv("OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET", "");
  const sharedSecret = generatedSecret ? randomBytes(32).toString("base64url") : stringEnv("OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET", "");
  const turnPort = integerEnv("OPENNOW_REMOTE_COOP_TURN_PORT", 3478);
  const turnTLSPort = integerEnv("OPENNOW_REMOTE_COOP_TURN_TLS_PORT", 443);
  const tlsEnabled = Boolean(stringEnv("OPENNOW_REMOTE_COOP_TURN_CERT", "") && stringEnv("OPENNOW_REMOTE_COOP_TURN_KEY", ""));
  const brokerPort = integerEnv("OPENNOW_REMOTE_COOP_PORT", 8787);
  const brokerBindHost = stringEnv("OPENNOW_REMOTE_COOP_BIND_HOST", "0.0.0.0");
  const turnListeningIP = stringEnv("OPENNOW_REMOTE_COOP_TURN_LISTENING_IP", "0.0.0.0");
  const turnURLs = stringEnv("OPENNOW_REMOTE_COOP_TURN_URLS", buildTurnURLs(publicHost, turnPort, turnTLSPort, tlsEnabled));
  const env = {
    ...process.env,
    OPENNOW_REMOTE_COOP_BIND_HOST: brokerBindHost,
    OPENNOW_REMOTE_COOP_PORT: String(brokerPort),
    OPENNOW_REMOTE_COOP_TURN_LISTENING_IP: turnListeningIP,
    OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST: stringEnv("OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST", publicHost),
    OPENNOW_REMOTE_COOP_TURN_REALM: stringEnv("OPENNOW_REMOTE_COOP_TURN_REALM", publicHost),
    OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET: sharedSecret,
    OPENNOW_REMOTE_COOP_TURN_URLS: turnURLs,
    OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS: stringEnv("OPENNOW_REMOTE_COOP_TURN_TTL_SECONDS", "3600")
  };
  if (isLoopbackHost(env.OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST) && !process.env.OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK) {
    env.OPENNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK = "1";
  }
  return { publicHost, generatedSecret, sharedSecret, turnURLs, brokerBindHost, brokerPort, turnListeningIP, env };
}

function startChild(label, scriptArgs) {
  const child = spawn(process.execPath, scriptArgs, { env: config.env, stdio: ["ignore", "pipe", "pipe"] });
  children.set(label, child);
  prefixStream(label, child.stdout, process.stdout);
  prefixStream(label, child.stderr, process.stderr);
  child.on("exit", (code, signal) => {
    children.delete(label);
    if (!stopping) {
      const exitCode = code ?? (signal ? 1 : 0);
      console.error(`${label} exited${signal ? ` from ${signal}` : ""} with code ${exitCode}.`);
      stopAll(`child:${label}`, exitCode === 0 ? 1 : exitCode);
    } else if (children.size === 0) {
      process.exit(process.exitCode ?? 0);
    }
  });
  child.on("error", error => {
    console.error(`${label} failed to start: ${error.message}`);
    stopAll(`child:${label}`, 1);
  });
}

function stopAll(reason, exitCode) {
  if (stopping) return;
  stopping = true;
  process.exitCode = exitCode;
  console.log(`Stopping Remote Co-Op server nodes (${reason}).`);
  for (const child of children.values()) {
    if (child.exitCode === null) child.kill("SIGTERM");
  }
  setTimeout(() => {
    for (const child of children.values()) {
      if (child.exitCode === null) child.kill("SIGKILL");
    }
    process.exit(process.exitCode ?? 0);
  }, 5_000).unref();
}

function prefixStream(label, stream, output) {
  let buffer = "";
  stream.on("data", chunk => {
    buffer += chunk.toString("utf8");
    let newlineIndex = buffer.indexOf("\n");
    while (newlineIndex >= 0) {
      const line = buffer.slice(0, newlineIndex).replace(/\r$/, "");
      output.write(`[${label}] ${line}\n`);
      buffer = buffer.slice(newlineIndex + 1);
      newlineIndex = buffer.indexOf("\n");
    }
  });
  stream.on("end", () => {
    if (buffer.length > 0) output.write(`[${label}] ${buffer.replace(/\r$/, "")}\n`);
  });
}

function printSummary(config) {
  console.log("OpenNOW Remote Co-Op all-server runner");
  console.log(`  broker bind: ${config.brokerBindHost}:${config.brokerPort}`);
  console.log(`  turn listen: ${config.turnListeningIP}`);
  console.log(`  public host: ${config.publicHost}`);
  console.log(`  browser URL: http://${config.publicHost}:${config.brokerPort}/`);
  console.log(`  websocket URL: ws://${config.publicHost}:${config.brokerPort}/remote-coop`);
  console.log(`  TURN URLs: ${config.turnURLs}`);
  console.log(`  TURN shared secret: ${config.generatedSecret ? "generated for this run" : "provided by environment"}`);
  console.log("  production: put the broker behind HTTPS/WSS and use a public TURN host with certificates.");
}

function buildTurnURLs(host, port, tlsPort, tlsEnabled) {
  const urls = [`turn:${host}:${port}?transport=udp`, `turn:${host}:${port}?transport=tcp`];
  if (tlsEnabled) urls.push(`turns:${host}:${tlsPort}?transport=tcp`);
  return urls.join(",");
}

function firstLANIPv4() {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal) return address.address;
    }
  }
  return "";
}

function stringEnv(name, fallback) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function isLoopbackHost(host) {
  return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(host.toLowerCase());
}

function printHelp() {
  console.log(`Usage: node RemoteCoOp/run-servers.mjs [--dry-run]

Starts all Remote Co-Op server-side Node processes and binds them to all local
interfaces by default:
  - broker: OPENNOW_REMOTE_COOP_BIND_HOST=0.0.0.0
  - TURN:   OPENNOW_REMOTE_COOP_TURN_LISTENING_IP=0.0.0.0

The runner derives a LAN IPv4 address for invite URLs when possible. Override it
with OPENNOW_REMOTE_COOP_PUBLIC_HOST for LAN/WAN deployments, or set the lower
level OPENNOW_REMOTE_COOP_TURN_PUBLIC_HOST and OPENNOW_REMOTE_COOP_TURN_URLS
variables directly.

Useful environment:
  OPENNOW_REMOTE_COOP_PUBLIC_HOST          Public DNS/IP to print and use for TURN URLs
  OPENNOW_REMOTE_COOP_PORT                 Broker HTTP/WebSocket port, default 8787
  OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET   Shared TURN REST secret; generated if omitted
  OPENNOW_REMOTE_COOP_TURN_CERT            Enables turns: URL when paired with key
  OPENNOW_REMOTE_COOP_TURN_KEY             Enables turns: URL when paired with cert
  OPENNOW_REMOTE_COOP_TURNSERVER_BIN       Path/name of coturn turnserver binary

Examples:
  node RemoteCoOp/run-servers.mjs --dry-run
  OPENNOW_REMOTE_COOP_PUBLIC_HOST=192.168.1.25 node RemoteCoOp/run-servers.mjs
  OPENNOW_REMOTE_COOP_PUBLIC_HOST=turn.example.com \
  OPENNOW_REMOTE_COOP_TURN_SHARED_SECRET=replace-with-long-random-secret \
  OPENNOW_REMOTE_COOP_TURN_CERT=/etc/letsencrypt/live/turn.example.com/fullchain.pem \
  OPENNOW_REMOTE_COOP_TURN_KEY=/etc/letsencrypt/live/turn.example.com/privkey.pem \
  node RemoteCoOp/run-servers.mjs`);
}
