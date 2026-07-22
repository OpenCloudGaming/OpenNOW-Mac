#!/usr/bin/env node
import { accessSync, constants } from "node:fs";
import { delimiter, isAbsolute, join } from "node:path";
import { spawn } from "node:child_process";

const args = new Set(process.argv.slice(2));
const productionHost = "198.12.95.48";

if (args.has("--help") || args.has("-h")) {
  printHelp();
  process.exit(0);
}

const config = readConfig();
const validation = validateConfig(config);

for (const warning of validation.warnings) console.warn(`warning: ${warning}`);

if (validation.errors.length > 0) {
  for (const error of validation.errors) console.error(`error: ${error}`);
  process.exit(1);
}

const turnserverPath = findTurnserver(config.turnserverBin);
const turnserverArgs = buildTurnserverArgs(config);

printSummary(config, turnserverPath, turnserverArgs);

if (args.has("--dry-run")) {
  if (!turnserverPath) console.warn("warning: turnserver was not found. Install coturn before running without --dry-run.");
  process.exit(0);
}

if (!turnserverPath) {
  console.error("error: turnserver was not found. Install coturn, or set MACFORCE_NOW_REMOTE_COOP_TURNSERVER_BIN.");
  console.error("macOS: brew install coturn");
  console.error("Debian/Ubuntu: sudo apt-get install coturn");
  process.exit(1);
}

const child = spawn(turnserverPath, turnserverArgs, { stdio: "inherit" });
let stopping = false;

child.on("exit", (code, signal) => {
  if (signal && !stopping) console.error(`turnserver exited from signal ${signal}`);
  process.exitCode = code ?? (stopping ? 0 : signal ? 1 : 0);
});

child.on("error", error => {
  console.error(`error: failed to start turnserver: ${error.message}`);
  process.exitCode = 1;
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => stopChild(signal));
}

function stopChild(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`Received ${signal}; stopping turnserver.`);
  if (child.exitCode !== null) return;
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
  }, 5_000).unref();
}

function readConfig() {
  const devAllowLoopback = booleanEnv("MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK", false);
  const publicHost = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST", devAllowLoopback ? "127.0.0.1" : productionHost);
  const tlsCert = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_CERT", "");
  const tlsKey = stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_KEY", "");
  return {
    turnserverBin: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURNSERVER_BIN", "turnserver"),
    publicHost,
    realm: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_REALM", publicHost || "macforce-now-remote-coop"),
    sharedSecret: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET", ""),
    listeningIP: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP", publicHost),
    externalIP: stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_EXTERNAL_IP", ""),
    port: integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_PORT", 32189),
    tlsPort: integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_TLS_PORT", 32443),
    minPort: integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_MIN_PORT", 42160),
    maxPort: integerEnv("MACFORCE_NOW_REMOTE_COOP_TURN_MAX_PORT", 42200),
    tlsCert,
    tlsKey,
    tlsEnabled: Boolean(tlsCert && tlsKey),
    devAllowLoopback,
    verbose: booleanEnv("MACFORCE_NOW_REMOTE_COOP_TURN_VERBOSE", false)
  };
}

function validateConfig(config) {
  const errors = [];
  const warnings = [];
  const portFields = [
    ["MACFORCE_NOW_REMOTE_COOP_TURN_PORT", config.port],
    ["MACFORCE_NOW_REMOTE_COOP_TURN_TLS_PORT", config.tlsPort],
    ["MACFORCE_NOW_REMOTE_COOP_TURN_MIN_PORT", config.minPort],
    ["MACFORCE_NOW_REMOTE_COOP_TURN_MAX_PORT", config.maxPort]
  ];

  if (!config.publicHost) errors.push("MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST is required unless MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1.");
  if (!config.sharedSecret) errors.push("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET is required and must match the broker secret.");
  if (config.sharedSecret && config.sharedSecret.length < 16) warnings.push("MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET should be at least 16 characters in production.");
  if (!config.realm) errors.push("MACFORCE_NOW_REMOTE_COOP_TURN_REALM is required.");

  for (const [name, value] of portFields) {
    if (!Number.isInteger(value) || value < 1 || value > 65_535) errors.push(`${name} must be an integer from 1 to 65535.`);
  }
  if (config.minPort > config.maxPort) errors.push("MACFORCE_NOW_REMOTE_COOP_TURN_MIN_PORT must be less than or equal to MACFORCE_NOW_REMOTE_COOP_TURN_MAX_PORT.");

  if (Boolean(config.tlsCert) !== Boolean(config.tlsKey)) errors.push("MACFORCE_NOW_REMOTE_COOP_TURN_CERT and MACFORCE_NOW_REMOTE_COOP_TURN_KEY must be provided together.");
  if (!config.devAllowLoopback && isLoopbackHost(config.publicHost)) errors.push("Loopback TURN hosts require MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1.");
  if (!config.devAllowLoopback && !config.tlsEnabled) warnings.push("No TLS certificate/key configured. TURN UDP/TCP can still work, but TURNS over TCP 443 will not be advertised.");
  if (!config.devAllowLoopback && !config.externalIP) warnings.push("MACFORCE_NOW_REMOTE_COOP_TURN_EXTERNAL_IP is recommended when coturn runs behind NAT.");

  return { errors, warnings };
}

function buildTurnserverArgs(config) {
  const result = [
    "--use-auth-secret",
    `--static-auth-secret=${config.sharedSecret}`,
    `--realm=${config.realm}`,
    "--fingerprint",
    "--lt-cred-mech",
    "--no-cli",
    "--no-multicast-peers",
    `--listening-ip=${config.listeningIP}`,
    `--listening-port=${config.port}`,
    `--min-port=${config.minPort}`,
    `--max-port=${config.maxPort}`,
    "--log-file=stdout",
    "--simple-log"
  ];
  if (config.externalIP) result.push(`--external-ip=${config.externalIP}`);
  if (config.tlsEnabled) {
    result.push(`--tls-listening-port=${config.tlsPort}`, `--cert=${config.tlsCert}`, `--pkey=${config.tlsKey}`, "--no-dtls");
  } else {
    result.push("--no-tls", "--no-dtls");
  }
  if (config.devAllowLoopback) result.push("--allow-loopback-peers");
  if (config.verbose) result.push("--verbose");
  return result;
}

function brokerEnvironment(config) {
  const urls = [`turn:${config.publicHost}:${config.port}?transport=udp`, `turn:${config.publicHost}:${config.port}?transport=tcp`];
  if (config.tlsEnabled) urls.push(`turns:${config.publicHost}:${config.tlsPort}?transport=tcp`);
  return {
    MACFORCE_NOW_REMOTE_COOP_TURN_URLS: urls.join(","),
    MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET: config.sharedSecret,
    MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS: "600"
  };
}

function printSummary(config, turnserverPath, turnserverArgs) {
  console.log("MacForce Now Remote Co-Op TURN server configuration");
  console.log(`  mode: ${config.devAllowLoopback ? "development" : "production"}`);
  console.log(`  public host: ${config.publicHost}`);
  console.log(`  listening: ${config.listeningIP}:${config.port}`);
  console.log(`  relay ports: ${config.minPort}-${config.maxPort}/udp`);
  console.log(`  TLS: ${config.tlsEnabled ? `${config.tlsPort}/tcp` : "disabled"}`);
  console.log(`  turnserver: ${turnserverPath ?? "not found"}`);
  console.log(`  command: ${(turnserverPath ?? config.turnserverBin)} ${turnserverArgs.map(redactArg).join(" ")}`);
  console.log("Broker environment:");
  for (const [key, value] of Object.entries(brokerEnvironment(config))) console.log(`  ${key}=${redactEnvValue(key, value)}`);
}

function findTurnserver(bin) {
  if (!bin) return null;
  if (isAbsolute(bin) || bin.includes("/")) return executable(bin) ? bin : null;
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    if (!directory) continue;
    const candidate = join(directory, bin);
    if (executable(candidate)) return candidate;
  }
  return null;
}

function executable(path) {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function redactArg(arg) {
  if (arg.startsWith("--static-auth-secret=")) return "--static-auth-secret=<redacted>";
  return arg;
}

function redactEnvValue(key, value) {
  return key.includes("SECRET") || key.includes("CREDENTIAL") ? "<redacted>" : value;
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

function isLoopbackHost(host) {
  return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(host.toLowerCase());
}

function printHelp() {
  console.log(`Usage: node RemoteCoOp/turn/turn-server.mjs [--dry-run]

Starts coturn for MacForce Now Remote Co-Op. This Node app manages the system
turnserver binary; it does not implement TURN itself.

Required environment:
  MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST       Public DNS name or IP for clients, default 198.12.95.48
  MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET    Shared REST auth secret, also used by broker

Common environment:
  MACFORCE_NOW_REMOTE_COOP_TURNSERVER_BIN         Path/name of turnserver binary
  MACFORCE_NOW_REMOTE_COOP_TURN_REALM            TURN auth realm, defaults to public host
  MACFORCE_NOW_REMOTE_COOP_TURN_PORT             UDP/TCP TURN port, default 32189
  MACFORCE_NOW_REMOTE_COOP_TURN_TLS_PORT         TLS/TCP TURNS port, default 32443
  MACFORCE_NOW_REMOTE_COOP_TURN_MIN_PORT         Relay min UDP port, default 42160
  MACFORCE_NOW_REMOTE_COOP_TURN_MAX_PORT         Relay max UDP port, default 42200
  MACFORCE_NOW_REMOTE_COOP_TURN_LISTENING_IP     Local listen IP, default public host
  MACFORCE_NOW_REMOTE_COOP_TURN_EXTERNAL_IP      Public relay IP when behind NAT
  MACFORCE_NOW_REMOTE_COOP_TURN_CERT             TLS certificate path
  MACFORCE_NOW_REMOTE_COOP_TURN_KEY              TLS private key path
  MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1  Enables local 127.0.0.1 testing

Examples:
  MACFORCE_NOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
  MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=local-development-secret \
  node RemoteCoOp/turn/turn-server.mjs --dry-run

  MACFORCE_NOW_REMOTE_COOP_TURN_PUBLIC_HOST=198.12.95.48 \
  MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET=replace-with-long-random-secret \
  node RemoteCoOp/turn/turn-server.mjs`);
}
