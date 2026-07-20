#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = new Set(process.argv.slice(2));
const root = dirname(fileURLToPath(import.meta.url));
const brokerScript = join(root, "server", "broker.mjs");
const turnScript = join(root, "turn", "turn-server.mjs");
const productionHost = "198.12.95.48";

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

sendPanelMessage({ kind: "remoteCoOpRunnerStarted" });
startChild("turn", [turnScript]);
startChild("broker", [brokerScript], { ipc: true });

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => stopAll(signal, 0));
}

function buildConfig() {
  const publicHost = stringEnv("MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST", "") || productionHost;
  const generatedSecret = !stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET", "");
  const sharedSecret = generatedSecret ? randomBytes(32).toString("base64url") : stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET", "");
  const turnPort = integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_PORT", 32189);
  const turnTLSPort = integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_TLS_PORT", 32443);
  const turnCertificatePath = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_CERT", "");
  const turnKeyPath = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_KEY", "");
  const tlsEnabled = Boolean(turnCertificatePath && turnKeyPath);
  const brokerCertificatePath = stringEnv("MACFORCE_NOW_REMOTE_COOP_BROKER_CERT", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TLS_CERT", "") || turnCertificatePath;
  const brokerKeyPath = stringEnv("MACFORCE_NOW_REMOTE_COOP_BROKER_KEY", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TLS_KEY", "") || turnKeyPath;
  const brokerTLSEnabled = Boolean(brokerCertificatePath && brokerKeyPath);
  const brokerPort = integerEnv("MACFORCE_NOW_REMOTE_COOP_PORT", 32188);
  const brokerPortCandidates = portCandidates(brokerPort, process.env.MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES);
  const brokerBindHost = stringEnv("MACFORCE_NOW_REMOTE_COOP_BIND_HOST", publicHost);
  const turnListeningIP = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP", publicHost);
  const turnURLs = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_URLS", buildTurnURLs(publicHost, turnPort, turnTLSPort, tlsEnabled));
  const env = {
    ...process.env,
    MACFORCE_NOW_REMOTE_COOP_BIND_HOST: brokerBindHost,
    MACFORCE_NOW_REMOTE_COOP_PORT: String(brokerPort),
    MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES: brokerPortCandidates.filter(candidate => candidate !== brokerPort).join(","),
    MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP: turnListeningIP,
    MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST", publicHost),
    MACFORCE_NOW_REMOTE_COOP_TURN_REALM: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_REALM", publicHost),
    MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET: sharedSecret,
    MACFORCE_NOW_REMOTE_COOP_TURN_URLS: turnURLs,
    MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS", "3600"),
    MACFORCE_NOW_REMOTE_COOP_BROKER_CERT: brokerCertificatePath,
    MACFORCE_NOW_REMOTE_COOP_BROKER_KEY: brokerKeyPath
  };
  if (isLoopbackHost(env.MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST) && !process.env.MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK) {
    env.MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK = "1";
  }
  return { publicHost, generatedSecret, sharedSecret, turnURLs, brokerBindHost, brokerPort, brokerPortCandidates, brokerTLSEnabled, turnListeningIP, env };
}

function startChild(label, scriptArgs, options = {}) {
  const child = spawn(process.execPath, scriptArgs, { env: config.env, stdio: options.ipc ? ["ignore", "pipe", "pipe", "ipc"] : ["ignore", "pipe", "pipe"] });
  children.set(label, child);
  sendPanelMessage({ kind: "remoteCoOpChildStarted", label, pid: child.pid });
  if (options.ipc) {
    child.on("message", message => {
      if (label === "broker" && message?.kind === "remoteCoOpBrokerListening") {
        printBrokerEndpoints(config, message.port, message.secure === true);
        sendPanelMessage(brokerListeningMessage(config, message));
      } else if (label === "broker" && message?.kind === "remoteCoOpBrokerStats") {
        sendPanelMessage(message);
      }
    });
  }
  prefixStream(label, child.stdout, process.stdout);
  prefixStream(label, child.stderr, process.stderr);
  child.on("exit", (code, signal) => {
    children.delete(label);
    if (!stopping) {
      const exitCode = code ?? (signal ? 1 : 0);
      console.error(`${label} exited${signal ? ` from ${signal}` : ""} with code ${exitCode}.`);
      sendPanelMessage({ kind: "remoteCoOpChildExited", label, code, signal });
      stopAll(`child:${label}`, exitCode === 0 ? 1 : exitCode);
    } else if (children.size === 0) {
      sendPanelMessage({ kind: "remoteCoOpRunnerExited", code: process.exitCode ?? 0 });
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
  sendPanelMessage({ kind: "remoteCoOpRunnerStopping", reason, exitCode });
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

function sendPanelMessage(message) {
  if (typeof process.send === "function") process.send(message);
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
  console.log("MacForce Now Remote Co-Op all-server runner");
  console.log(`  broker bind: ${config.brokerBindHost}:${config.brokerPort}${alternatePortSummary(config.brokerPortCandidates)}`);
  console.log(`  broker TLS: ${config.brokerTLSEnabled ? "enabled" : "disabled"}`);
  console.log(`  turn listen: ${config.turnListeningIP}`);
  console.log(`  public host: ${config.publicHost}`);
  console.log(`  TURN URLs: ${config.turnURLs}`);
  console.log(`  TURN shared secret: ${config.generatedSecret ? "generated for this run" : "provided by environment"}`);
  console.log("  production: defaults use HTTP/WS on the public IP. Configure broker HTTPS/WSS only when explicitly needed.");
}

function printBrokerEndpoints(config, brokerPort, secure) {
  console.log(`  browser URL: ${secure ? "https" : "http"}://${config.publicHost}:${brokerPort}/`);
  console.log(`  websocket URL: ${secure ? "wss" : "ws"}://${config.publicHost}:${brokerPort}/remote-coop`);
}

function brokerListeningMessage(config, message) {
  const secure = message.secure === true;
  return {
    ...message,
    publicHost: config.publicHost,
    browserURL: `${secure ? "https" : "http"}://${config.publicHost}:${message.port}/`,
    websocketURL: `${secure ? "wss" : "ws"}://${config.publicHost}:${message.port}/remote-coop`
  };
}

function alternatePortSummary(candidates) {
  const alternates = candidates.slice(1);
  return alternates.length > 0 ? ` (alternates: ${alternates.join(", ")})` : "";
}

function buildTurnURLs(host, port, tlsPort, tlsEnabled) {
  const urls = [`turn:${host}:${port}?transport=udp`, `turn:${host}:${port}?transport=tcp`];
  if (tlsEnabled) urls.push(`turns:${host}:${tlsPort}?transport=tcp`);
  return urls.join(",");
}

function stringEnv(name, fallback) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function portCandidates(preferredPort, alternateValue) {
  const parsedAlternates = typeof alternateValue === "string" && alternateValue.trim()
    ? alternateValue.split(",").map(value => Number.parseInt(value.trim(), 10))
    : [preferredPort + 1, preferredPort + 2];
  const candidates = Array.from(new Set([preferredPort, ...parsedAlternates].filter(isUsablePort)));
  return candidates.length > 0 ? candidates : [32188, 32190, 32191];
}

function isUsablePort(value) {
  return Number.isInteger(value) && value > 0 && value <= 65_535;
}

function isLoopbackHost(host) {
  return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(host.toLowerCase());
}

function printHelp() {
  console.log(`Usage: node RemoteCoOp/run-servers.mjs [--dry-run]

Starts all Remote Co-Op server-side Node processes and binds them to the
production public IP by default:
  - broker: MACFORCE_NOW_REMOTE_COOP_BIND_HOST=198.12.95.48
  - TURN:   MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48

The runner defaults to 198.12.95.48 for production URLs. Override it with
MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST for LAN deployments, or set the lower level
MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST and MACFORCE_NOW_REMOTE_COOP_TURN_URLS variables
directly.

Useful environment:
  MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST          Public DNS/IP to print and use for TURN URLs, default 198.12.95.48
  MACFORCE_NOW_REMOTE_COOP_PORT                 Broker HTTP/WebSocket port, default 32188
  MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES      Comma-separated fallback broker ports, default next two ports
  MACFORCE_NOW_REMOTE_COOP_BROKER_CERT          HTTPS certificate for broker; defaults to TURN cert
  MACFORCE_NOW_REMOTE_COOP_BROKER_KEY           HTTPS private key for broker; defaults to TURN key
  MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET   Shared TURN REST secret; generated if omitted
  MACFORCE_NOW_REMOTE_COOP_TURN_CERT            Enables turns: URL and broker HTTPS fallback when paired with key
  MACFORCE_NOW_REMOTE_COOP_TURN_KEY             Enables turns: URL and broker HTTPS fallback when paired with cert
  MACFORCE_NOW_REMOTE_COOP_TURNSERVER_BIN       Path/name of coturn turnserver binary

Examples:
  node RemoteCoOp/run-servers.mjs --dry-run
  MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST=192.168.1.25 node RemoteCoOp/run-servers.mjs
  MACFORCE_NOW_REMOTE_COOP_PUBLIC_HOST=198.12.95.48 \
  MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=replace-with-long-random-secret \
  node RemoteCoOp/run-servers.mjs`);
}
