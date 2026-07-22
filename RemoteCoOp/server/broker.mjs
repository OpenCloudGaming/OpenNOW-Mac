import { createServer as createHTTPServer } from "node:http";
import { createServer as createHTTPSServer } from "node:https";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const productionHost = "198.12.95.48";
const port = integerEnv("MACFORCE_NOW_REMOTE_COOP_PORT", 32188);
const portAlternates = portCandidates(port, process.env.MACFORCE_NOW_REMOTE_COOP_PORT_ALTERNATES);
const bindHost = process.env.MACFORCE_NOW_REMOTE_COOP_BIND_HOST ?? productionHost;
const MAX_FRAME_SIZE = 1024 * 1024;
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;
const MAX_DISPLAY_NAME_LENGTH = 64;
const root = normalize(join(fileURLToPath(new URL(".", import.meta.url)), "../browser"));
const brokerCertificatePath = stringEnv("MACFORCE_NOW_REMOTE_COOP_BROKER_CERT", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TLS_CERT", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_CERT", "");
const brokerKeyPath = stringEnv("MACFORCE_NOW_REMOTE_COOP_BROKER_KEY", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TLS_KEY", "") || stringEnv("MACFORCE_NOW_REMOTE_COOP_TURN_KEY", "");
const brokerTLSEnabled = Boolean(brokerCertificatePath && brokerKeyPath);
const brokerHTTPProtocol = brokerTLSEnabled ? "https" : "http";
const brokerWebSocketProtocol = brokerTLSEnabled ? "wss" : "ws";
const stunURLs = splitEnv("MACFORCE_NOW_REMOTE_COOP_STUN_URLS", "stun:stun.l.google.com:19302");
const turnURLs = splitEnv("MACFORCE_NOW_REMOTE_COOP_TURN_URLS", `turn:${productionHost}:32189?transport=udp,turn:${productionHost}:32189?transport=tcp`);
const turnUsername = process.env.MACFORCE_NOW_REMOTE_COOP_TURN_USERNAME ?? "";
const turnCredential = process.env.MACFORCE_NOW_REMOTE_COOP_TURN_CREDENTIAL ?? "";
const turnSharedSecret = process.env.MACFORCE_NOW_REMOTE_COOP_TURN_SHARED_SECRET ?? "";
const turnCredentialTTLSeconds = Number.parseInt(process.env.MACFORCE_NOW_REMOTE_COOP_TURN_TTL_SECONDS ?? "600", 10);
const inviteSharedSecret = process.env.MACFORCE_NOW_REMOTE_COOP_INVITE_SECRET ?? "";
const networkLoggingEnabled = booleanEnv("MACFORCE_NOW_REMOTE_COOP_LOG_NETWORK", true);
const messageFlowLoggingEnabled = booleanEnv("MACFORCE_NOW_REMOTE_COOP_LOG_MESSAGES", false);
const rooms = new Map();
const sockets = new Set();
const sessionStats = { totalStarted: 0, totalEnded: 0, recent: [] };
let nextSocketID = 1;

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"]
]);

if (Boolean(brokerCertificatePath) !== Boolean(brokerKeyPath)) {
  console.error("MacForce Now Remote Co-Op broker HTTPS requires both MACFORCE_NOW_REMOTE_COOP_BROKER_CERT and MACFORCE_NOW_REMOTE_COOP_BROKER_KEY, or matching TLS/TURN cert and key environment variables.");
  process.exit(1);
}

const server = await makeBrokerServer(async (request, response) => {
  const startedAt = Date.now();
  const remote = socketAddress(request.socket);
  try {
    const url = new URL(request.url ?? "/", `${brokerHTTPProtocol}://${request.headers.host ?? "localhost"}`);
    response.on("finish", () => logNetwork("http.request", {
      method: request.method ?? "GET",
      path: url.pathname,
      status: response.statusCode,
      durationMs: Date.now() - startedAt,
      remote,
      forwardedFor: request.headers["x-forwarded-for"]
    }));
    if (url.pathname === "/remote-coop/network-config") {
      const inviteParameter = url.searchParams.get("invite") ?? "";
      const payload = verifyInviteToken(inviteParameter);
      const roomID = stringValue(payload?.inviteID) ?? roomIDForInviteCode(inviteParameter);
      const room = roomID ? rooms.get(roomID) : null;
      if (!payload && !room) {
        logNetwork("network-config.rejected", { remote, reason: "invalid_invite" });
        response.writeHead(403, { "content-type": "application/json; charset=utf-8" }).end(JSON.stringify({ error: "invalid_invite" }));
        return;
      }
      const networkConfiguration = room?.networkConfiguration ?? networkConfigurationFor(payload, roomID ?? "");
      logNetwork("network-config.served", { remote, roomID: roomID ?? "none", transportMode: networkConfiguration.transportMode, latencyMode: networkConfiguration.latencyMode });
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" }).end(JSON.stringify(networkConfiguration));
      return;
    }
    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = normalize(join(root, pathname));
    if (file !== root && !file.startsWith(root + sep)) {
      response.writeHead(403).end("Forbidden");
      return;
    }
    const data = await readFile(file);
    response.writeHead(200, {
      "cache-control": "no-store",
      "content-type": contentTypes.get(extname(file)) ?? "application/octet-stream"
    }).end(data);
  } catch (error) {
    logNetwork("http.error", { remote, error: error.message || "not_found" });
    response.writeHead(404).end("Not found");
  }
});

server.on("upgrade", (request, socket) => {
  const url = new URL(request.url ?? "/", `${brokerHTTPProtocol}://${request.headers.host ?? "localhost"}`);
  if (url.pathname !== "/remote-coop") {
    logNetwork("ws.upgrade.rejected", { remote: socketAddress(socket), path: url.pathname, reason: "invalid_path" });
    socket.destroy();
    return;
  }
  const key = request.headers["sec-websocket-key"];
  if (typeof key !== "string") {
    logNetwork("ws.upgrade.rejected", { remote: socketAddress(socket), path: url.pathname, reason: "missing_key" });
    socket.destroy();
    return;
  }
  const accept = createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "",
    ""
  ].join("\r\n"));
  logNetwork("ws.upgrade.accepted", { remote: socketAddress(socket), path: url.pathname, forwardedFor: request.headers["x-forwarded-for"] });
  attachSocket(socket);
});

listenOnAvailablePort(0);

function listenOnAvailablePort(index) {
  const candidate = portAlternates[index];
  const onError = error => {
    server.off("listening", onListening);
    if (error.code === "EADDRINUSE" && index + 1 < portAlternates.length) {
      console.warn(`MacForce Now Remote Co-Op broker port ${candidate} is in use; trying ${portAlternates[index + 1]}.`);
      listenOnAvailablePort(index + 1);
      return;
    }
    console.error(`MacForce Now Remote Co-Op broker failed to listen on ${bindHost}:${candidate}: ${error.message}`);
    process.exit(1);
  };
  const onListening = () => {
    server.off("error", onError);
    const address = server.address();
    const actualPort = typeof address === "object" && address ? address.port : candidate;
    console.log(`MacForce Now Remote Co-Op broker listening on ${brokerHTTPProtocol}://${bindHost}:${actualPort}`);
    if (typeof process.send === "function") process.send({ kind: "remoteCoOpBrokerListening", bindHost, port: actualPort, requestedPort: port, secure: brokerTLSEnabled });
  };
  server.once("error", onError);
  server.once("listening", onListening);
  server.listen(candidate, bindHost);
}

server.on("listening", () => {
  console.log(`Remote Co-Op ICE: stun=${stunURLs.length} turn=${turnURLs.length} turnAuth=${turnAuthSummary()} brokerWebSocket=${brokerWebSocketProtocol}`);
  console.log(`Remote Co-Op logging: network=${networkLoggingEnabled ? "enabled" : "disabled"} messageFlow=${messageFlowLoggingEnabled ? "enabled" : "disabled"}`);
  sendBrokerStats();
});

async function makeBrokerServer(handler) {
  if (!brokerTLSEnabled) return createHTTPServer(handler);
  try {
    return createHTTPSServer({ cert: await readFile(brokerCertificatePath), key: await readFile(brokerKeyPath) }, handler);
  } catch (error) {
    console.error(`MacForce Now Remote Co-Op broker failed to load HTTPS certificate/key: ${error.message}`);
    process.exit(1);
  }
}

setInterval(() => {
  const now = Date.now();
  for (const [roomID, room] of rooms) {
    if (room.expiresAtMs > 0 && room.expiresAtMs <= now) {
      logNetwork("room.expired", { roomID, guests: room.guests.size, hostConnected: Boolean(room.host) });
      broadcast(room, { kind: "inviteEnded", roomID, reason: "Invite expired" });
      closeRoom(roomID, "expired");
    }
  }
  for (const state of sockets) {
    if (now - state.lastSeenAt > 45_000) {
      logNetwork("socket.timeout", socketLogFields(state));
      state.socket.destroy();
    } else {
      send(state, { kind: "heartbeat", roomID: state.roomID });
    }
  }
}, 10_000).unref();

function attachSocket(socket) {
  const state = { id: nextSocketID++, socket, buffer: Buffer.alloc(0), role: "unknown", roomID: null, participantID: null, inviteToken: null, displayName: null, connectedAt: Date.now(), lastSeenAt: Date.now(), messageTimes: [], bytesIn: 0, framesIn: 0, framesOut: 0, detached: false };
  sockets.add(state);
  logNetwork("socket.open", socketLogFields(state));
  socket.on("data", chunk => {
    state.bytesIn += chunk.length;
    if (state.buffer.length + chunk.length > MAX_BUFFERED_BYTES) {
      logNetwork("socket.buffer_overflow", { ...socketLogFields(state), bufferedBytes: state.buffer.length + chunk.length });
      state.socket.destroy();
      return;
    }
    state.buffer = Buffer.concat([state.buffer, chunk]);
    parseFrames(state);
  });
  socket.on("close", () => detachSocket(state, "close"));
  socket.on("error", error => detachSocket(state, "error", error));
}

function detachSocket(state, reason = "close", error = null) {
  if (state.detached) return;
  state.detached = true;
  sockets.delete(state);
  logNetwork("socket.close", { ...socketLogFields(state), reason, error: error?.message, durationMs: Date.now() - state.connectedAt, bytesIn: state.bytesIn, framesIn: state.framesIn, framesOut: state.framesOut });
  if (!state.roomID) return;
  const room = rooms.get(state.roomID);
  if (!room) return;
  if (state.role === "host" && room.host === state) {
    logNetwork("host.disconnected", { ...socketLogFields(state), guests: room.guests.size });
    broadcast(room, { kind: "inviteEnded", roomID: state.roomID, reason: "Host disconnected" }, state);
    closeRoom(state.roomID, "host_disconnected");
    return;
  }
  if (state.role === "guest" && state.participantID) {
    room.guests.delete(participantKey(state.participantID));
    logNetwork("guest.disconnected", { ...socketLogFields(state), hostConnected: Boolean(room.host) });
    if (room.host) send(room.host, { kind: "guestDisconnected", roomID: state.roomID, participantID: state.participantID });
    sendBrokerStats();
  }
}

function parseFrames(state) {
  while (state.buffer.length >= 2) {
    const first = state.buffer[0];
    const second = state.buffer[1];
    const opcode = first & 0x0f;
    const masked = (second & 0x80) === 0x80;
    let length = second & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (state.buffer.length < offset + 2) return;
      length = state.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (state.buffer.length < offset + 8) return;
      const high = state.buffer.readUInt32BE(offset);
      const low = state.buffer.readUInt32BE(offset + 4);
      length = high * 2 ** 32 + low;
      offset += 8;
    }
    if (length > MAX_FRAME_SIZE) {
      logNetwork("socket.frame_too_large", { ...socketLogFields(state), frameSize: length, maxSize: MAX_FRAME_SIZE });
      state.socket.destroy();
      return;
    }
    const maskOffset = offset;
    if (masked) offset += 4;
    if (state.buffer.length < offset + length) return;
    let payload = state.buffer.subarray(offset, offset + length);
    if (masked) {
      const mask = state.buffer.subarray(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));
    }
    state.buffer = state.buffer.subarray(offset + length);
    state.framesIn += 1;
    handleFrame(state, opcode, payload);
  }
}

function handleFrame(state, opcode, payload) {
  state.lastSeenAt = Date.now();
  if (opcode === 0x8) {
    logNetwork("socket.close-frame", socketLogFields(state));
    state.socket.end();
    return;
  }
  if (opcode === 0x9) {
    logNetwork("socket.ping", socketLogFields(state));
    sendFrame(state.socket, 0xA, payload);
    return;
  }
  if (opcode !== 0x1) {
    logNetwork("socket.frame.ignored", { ...socketLogFields(state), opcode });
    return;
  }
  if (isRateLimited(state)) {
    logNetwork("socket.rate_limited", socketLogFields(state));
    send(state, { kind: "error", reason: "Rate limit exceeded" });
    state.socket.destroy();
    return;
  }
  try {
    handleMessage(state, JSON.parse(payload.toString("utf8")));
  } catch (error) {
    logNetwork("message.invalid_json", { ...socketLogFields(state), error: error.message });
    send(state, { kind: "error", reason: "Invalid JSON message" });
  }
}

function handleMessage(state, message) {
  logMessageFlow("in", state, message);
  if (message.kind === "heartbeat") return;
  if (message.kind === "hostHello") {
    registerHost(state, message);
    return;
  }
  if (message.kind === "guestJoinRequested") {
    registerGuest(state, message);
    return;
  }
  if (message.kind === "peerSignal") {
    if (state.role === "host") {
      relayHostCommand(state, message);
    } else {
      relayGuestEvent(state, message);
    }
    return;
  }
  if (["participantUpdated", "participantRemoved", "guestRejected", "inputRejected", "inviteEnded"].includes(message.kind)) {
    relayHostCommand(state, message);
    return;
  }
  if (message.kind === "guestInput" || message.kind === "guestDisconnected") {
    relayGuestEvent(state, message);
  }
}

function registerHost(state, message) {
  const roomID = stringValue(message.roomID ?? message.invite?.id);
  if (!roomID) {
    logNetwork("host.rejected", { ...socketLogFields(state), reason: "missing_room" });
    send(state, { kind: "error", reason: "Missing room ID" });
    return;
  }
  const payload = verifyInviteToken(message.invite?.token);
  if (!payload) {
    logNetwork("host.rejected", { ...socketLogFields(state), reason: "invalid_invite_signature" });
    send(state, { kind: "error", reason: "Invalid or expired invite token" });
    return;
  }
  const room = roomFor(roomID);
  if (room.host && !room.host.detached) {
    logNetwork("host.rejected", { ...socketLogFields(state), reason: "host_already_registered" });
    send(state, { kind: "error", reason: "Host already registered for this room" });
    return;
  }
  room.host = state;
  if (room.hostRegisteredAtMs <= 0) {
    room.hostRegisteredAtMs = Date.now();
    sessionStats.totalStarted += 1;
  }
  room.invite = message.invite ?? null;
  room.networkConfiguration = networkConfigurationFor(payload, roomID);
  room.expiresAtMs = inviteExpiryMilliseconds(message.invite?.token);
  state.role = "host";
  state.roomID = roomID;
  logNetwork("host.registered", { ...socketLogFields(state), pendingGuests: room.guests.size, transportMode: room.networkConfiguration.transportMode, latencyMode: room.networkConfiguration.latencyMode });
  send(state, { kind: "heartbeat", roomID });
  send(state, { kind: "networkConfiguration", roomID, networkConfiguration: room.networkConfiguration });
  for (const guest of room.guests.values()) {
    logNetwork("guest.forwarded_to_host", { socketID: guest.id, roomID, participantID: guest.participantID });
    send(state, sanitizeMessage({
      kind: "guestJoinRequested",
      roomID,
      participantID: guest.participantID,
      inviteToken: guest.inviteToken,
      displayName: guest.displayName || "Guest"
    }));
  }
  sendBrokerStats();
}

function registerGuest(state, message) {
  const participantID = stringValue(message.participantID);
  const inviteToken = stringValue(message.inviteToken);
  if (!participantID) {
    logNetwork("guest.rejected", { ...socketLogFields(state), participantID: "none", reason: "missing_participant" });
    send(state, { kind: "guestRejected", reason: "Missing participant ID" });
    return;
  }
  if (!inviteToken) {
    logNetwork("guest.rejected", { ...socketLogFields(state), participantID, reason: "missing_invite_token" });
    send(state, { kind: "guestRejected", participantID, reason: "Missing invite token" });
    return;
  }
  const payload = verifyInviteToken(inviteToken);
  if (!payload) {
    logNetwork("guest.rejected", { ...socketLogFields(state), participantID, reason: "invalid_invite_signature" });
    send(state, { kind: "guestRejected", participantID, reason: "Invalid or expired invite token" });
    return;
  }
  const roomID = stringValue(message.roomID) ?? stringValue(payload?.inviteID) ?? roomIDForInviteCode(inviteToken);
  if (!roomID) {
    logNetwork("guest.rejected", { ...socketLogFields(state), participantID, reason: "room_not_found" });
    send(state, { kind: "guestRejected", participantID, reason: "Host room not found" });
    return;
  }
  const room = roomFor(roomID);
  state.role = "guest";
  state.roomID = roomID;
  state.participantID = participantID;
  state.inviteToken = inviteToken;
  const rawDisplayName = stringValue(message.displayName) || "Guest";
  state.displayName = rawDisplayName.length > MAX_DISPLAY_NAME_LENGTH ? rawDisplayName.slice(0, MAX_DISPLAY_NAME_LENGTH) : rawDisplayName;
  room.guests.set(participantKey(participantID), state);
  room.maxGuests = Math.max(room.maxGuests, room.guests.size);
  if (!room.invite && payload) room.networkConfiguration = networkConfigurationFor(payload, roomID);
  if (room.expiresAtMs <= 0) room.expiresAtMs = inviteExpiryMilliseconds(state.inviteToken);
  logNetwork(room.host ? "guest.joined" : "guest.pending", { ...socketLogFields(state), hostConnected: Boolean(room.host), guests: room.guests.size, transportMode: room.networkConfiguration.transportMode, latencyMode: room.networkConfiguration.latencyMode });
  send(state, { kind: "networkConfiguration", roomID, participantID, networkConfiguration: room.networkConfiguration });
  if (room.host) send(room.host, sanitizeMessage({ ...message, roomID, participantID }));
  sendBrokerStats();
}

function relayGuestEvent(state, message) {
  const room = state.roomID ? rooms.get(state.roomID) : null;
  if (state.role !== "guest" || !room?.host) {
    logNetwork("guest.event.rejected", { ...socketLogFields(state), kind: message.kind ?? "unknown", reason: "not_joined_or_host_missing" });
    send(state, { kind: "guestRejected", roomID: state.roomID, participantID: state.participantID, reason: "Guest is not joined" });
    return;
  }
  const allowedGuestKinds = ["guestInput", "guestDisconnected", "peerSignal"];
  if (!allowedGuestKinds.includes(message.kind)) {
    logNetwork("guest.event.rejected", { ...socketLogFields(state), kind: message.kind ?? "unknown", reason: "disallowed_message_kind" });
    return;
  }
  logNetwork("guest.event.relayed", { ...socketLogFields(state), kind: message.kind ?? "unknown" });
  send(room.host, sanitizeMessage({ ...message, roomID: state.roomID, participantID: state.participantID }));
}

function relayHostCommand(state, message) {
  const roomID = stringValue(message.roomID ?? state.roomID);
  const room = roomID ? rooms.get(roomID) : null;
  if (state.role !== "host" || !room || room.host !== state) {
    logNetwork("host.command.rejected", { ...socketLogFields(state), kind: message.kind ?? "unknown", roomID: roomID ?? "none", reason: "host_not_registered" });
    send(state, { kind: "error", reason: "Host is not registered" });
    return;
  }
  const allowedHostKinds = ["participantUpdated", "participantRemoved", "guestRejected", "inputRejected", "inviteEnded", "peerSignal"];
  if (!allowedHostKinds.includes(message.kind)) {
    logNetwork("host.command.rejected", { ...socketLogFields(state), kind: message.kind ?? "unknown", reason: "disallowed_message_kind" });
    return;
  }
  const outbound = sanitizeMessage({ ...message, roomID });
  if (message.kind === "inviteEnded") {
    logNetwork("room.ended", { ...socketLogFields(state), guests: room.guests.size });
    broadcast(room, outbound, state);
    closeRoom(roomID, "host_ended");
    return;
  }
  const participantID = stringValue(message.participantID ?? message.participant?.id);
  const key = participantKey(participantID);
  if (key && room.guests.has(key)) {
    logNetwork("host.command.relayed", { ...socketLogFields(state), kind: message.kind ?? "unknown", participantID });
    send(room.guests.get(key), outbound);
    if (message.kind === "participantRemoved" || message.kind === "guestRejected") {
      room.guests.delete(key);
      sendBrokerStats();
    }
  } else {
    logNetwork("host.command.broadcast", { ...socketLogFields(state), kind: message.kind ?? "unknown", guests: room.guests.size });
    broadcast(room, outbound, state);
  }
}

function send(state, message) {
  if (!state || state.socket.destroyed) return;
  logMessageFlow("out", state, message);
  state.framesOut += 1;
  sendFrame(state.socket, 0x1, Buffer.from(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }), "utf8"));
}

function sendFrame(socket, opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(length, 6);
  }
  socket.write(Buffer.concat([header, payload]));
}

function broadcast(room, message, except = null) {
  if (room.host && room.host !== except) send(room.host, message);
  for (const guest of room.guests.values()) {
    if (guest !== except) send(guest, message);
  }
}

function closeRoom(roomID, reason = "closed") {
  const room = rooms.get(roomID);
  if (!room) return;
  logNetwork("room.closed", { roomID, hostConnected: Boolean(room.host), guests: room.guests.size });
  recordClosedSession(room, reason);
  if (room.host) room.host.roomID = null;
  for (const guest of room.guests.values()) guest.roomID = null;
  rooms.delete(roomID);
  sendBrokerStats();
}

function roomFor(roomID) {
  const existing = rooms.get(roomID);
  if (existing) return existing;
  const room = { host: null, guests: new Map(), invite: null, networkConfiguration: networkConfigurationFor(null, roomID), expiresAtMs: 0, createdAtMs: Date.now(), hostRegisteredAtMs: 0, maxGuests: 0 };
  rooms.set(roomID, room);
  return room;
}

function recordClosedSession(room, reason) {
  if (room.hostRegisteredAtMs <= 0) return;
  sessionStats.totalEnded += 1;
  sessionStats.recent.unshift({
    endedAt: new Date().toISOString(),
    durationSeconds: Math.max(0, Math.round((Date.now() - room.hostRegisteredAtMs) / 1_000)),
    maxGuests: room.maxGuests,
    reason: sanitizedEndReason(reason)
  });
  sessionStats.recent.length = Math.min(sessionStats.recent.length, 12);
}

function brokerStats() {
  const allRooms = Array.from(rooms.values());
  const activeRooms = allRooms.filter(room => room.hostRegisteredAtMs > 0);
  const pendingRooms = allRooms.filter(room => room.hostRegisteredAtMs <= 0 && room.guests.size > 0);
  return {
    kind: "remoteCoOpBrokerStats",
    activeSessions: activeRooms.length,
    activeGuests: activeRooms.reduce((total, room) => total + room.guests.size, 0),
    pendingSessions: pendingRooms.length,
    pendingGuests: pendingRooms.reduce((total, room) => total + room.guests.size, 0),
    pastSessions: sessionStats.totalEnded,
    totalStarted: sessionStats.totalStarted,
    recentSessions: sessionStats.recent,
    updatedAt: new Date().toISOString()
  };
}

function sendBrokerStats() {
  if (typeof process.send === "function") process.send(brokerStats());
}

function sanitizedEndReason(reason) {
  return ["closed", "expired", "host_disconnected", "host_ended"].includes(reason) ? reason : "closed";
}

function roomIDForInviteCode(value) {
  const code = inviteCodeValue(value);
  if (!code) return null;
  for (const [roomID, room] of rooms) {
    if (inviteCodeValue(room.invite?.code) === code) return roomID;
  }
  return null;
}

function networkConfigurationFor(payload, roomID) {
  const transportMode = ["automatic", "directOnly", "relayOnly"].includes(payload?.transportMode) ? payload.transportMode : "automatic";
  const latencyMode = ["quality", "lowLatency"].includes(payload?.latencyMode) ? payload.latencyMode : "quality";
  const iceTransportPolicy = transportMode === "relayOnly" ? "relay" : "all";
  const iceServers = iceServersFor(transportMode, roomID);
  return {
    transportMode,
    iceTransportPolicy,
    latencyMode,
    iceServers,
    dataChannelInputEnabled: true,
    websocketInputFallbackEnabled: latencyMode !== "lowLatency",
    directPeerCandidateWarning: warningFor(transportMode, iceServers)
  };
}

function iceServersFor(transportMode, roomID) {
  const servers = [];
  if (transportMode !== "relayOnly" && stunURLs.length > 0) servers.push({ urls: stunURLs });
  if (transportMode !== "directOnly" && turnURLs.length > 0) {
    const credentials = turnCredentials(roomID);
    if (credentials.username && credentials.credential) servers.push({ urls: turnURLs, ...credentials });
  }
  return servers;
}

function turnCredentials(roomID) {
  if (turnSharedSecret) {
    const expiry = Math.floor(Date.now() / 1000) + Math.max(60, turnCredentialTTLSeconds);
    const username = `${expiry}:${roomID}`;
    const credential = createHmac("sha1", turnSharedSecret).update(username).digest("base64");
    return { username, credential };
  }
  if (turnUsername && turnCredential) return { username: turnUsername, credential: turnCredential };
  return {};
}

function warningFor(transportMode, iceServers) {
  if (transportMode === "relayOnly" && iceServers.length === 0) return "Relay Only requires TURN credentials, but this broker has no TURN server configured.";
  if (transportMode === "relayOnly") return "Relay Only uses TURN relay candidates to avoid exposing direct peer IP candidates.";
  if (transportMode === "directOnly") return "Direct Only can expose direct peer IP candidates and may fail behind strict routers or firewalls.";
  return "Automatic may use direct peer candidates before falling back to TURN relay. Use Relay Only to hide direct IP candidates.";
}

function turnAuthSummary() {
  if (turnSharedSecret) return `shared-secret ttl=${Math.max(60, turnCredentialTTLSeconds)}s`;
  if (turnUsername && turnCredential) return "static-credentials";
  return "none";
}

function inviteExpiryMilliseconds(token) {
  const payload = verifyInviteToken(token);
  const expiresAt = Number(payload?.expiresAtEpochSeconds ?? 0);
  return Number.isFinite(expiresAt) && expiresAt > 0 ? Math.round(expiresAt * 1_000) : 0;
}

function verifyInviteToken(token) {
  if (typeof token !== "string" || !inviteSharedSecret) return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payloadSegment, signatureSegment] = parts;
  if (!payloadSegment || !signatureSegment) return null;
  const payloadBuffer = Buffer.from(base64URLToBase64(payloadSegment), "base64");
  if (payloadBuffer.length === 0) return null;
  const signatureBuffer = Buffer.from(base64URLToBase64(signatureSegment), "base64");
  if (signatureBuffer.length === 0) return null;
  const expectedSignature = createHmac("sha256", inviteSharedSecret).update(payloadBuffer).digest();
  if (expectedSignature.length !== signatureBuffer.length) return null;
  if (!timingSafeEqual(expectedSignature, signatureBuffer)) return null;
  try {
    const payload = JSON.parse(payloadBuffer.toString("utf8"));
    const expiresAt = Number(payload?.expiresAtEpochSeconds ?? 0);
    if (Number.isFinite(expiresAt) && expiresAt > 0 && expiresAt * 1_000 < Date.now()) return null;
    return payload;
  } catch {
    return null;
  }
}

function decodeInvitePayload(token) {
  if (typeof token !== "string") return null;
  const [payload] = token.split(".");
  if (!payload) return null;
  try {
    return JSON.parse(Buffer.from(base64URLToBase64(payload), "base64").toString("utf8"));
  } catch {
    return null;
  }
}

function base64URLToBase64(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  return base64.padEnd(base64.length + (4 - (base64.length % 4 || 4)), "=");
}

function sanitizeMessage(message) {
  return JSON.parse(JSON.stringify(message));
}

function stringValue(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function participantKey(value) {
  return typeof value === "string" && value.length > 0 ? value.toLowerCase() : null;
}

function inviteCodeValue(value) {
  if (typeof value !== "string") return null;
  const code = value.trim().toUpperCase();
  return /^[A-Z0-9]{6}$/.test(code) ? code : null;
}

function logMessageFlow(direction, state, message) {
  if (!messageFlowLoggingEnabled) return;
  const participantID = stringValue(message.participantID ?? message.participant?.id) ?? "none";
  const roomID = stringValue(message.roomID ?? state.roomID) ?? "none";
  const signalKind = message.peerSignal?.kind ? ` signal=${message.peerSignal.kind}` : "";
  console.log(`[flow] ${direction} role=${state.role} kind=${message.kind ?? "unknown"}${signalKind} room=${roomID} participant=${participantID}`);
}

function logNetwork(event, fields = {}) {
  if (!networkLoggingEnabled) return;
  const details = Object.entries(fields)
    .filter(([, value]) => value !== null && value !== undefined && value !== "")
    .map(([key, value]) => `${key}=${logValue(value)}`)
    .join(" ");
  console.log(`[network] ${new Date().toISOString()} event=${event}${details ? ` ${details}` : ""}`);
}

function socketLogFields(state) {
  return {
    socketID: state.id,
    remote: socketAddress(state.socket),
    role: state.role,
    roomID: state.roomID ?? "none",
    participantID: state.participantID ?? "none"
  };
}

function socketAddress(socket) {
  return `${socket.remoteAddress ?? "unknown"}:${socket.remotePort ?? "unknown"}`;
}

function logValue(value) {
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return JSON.stringify(value.map(String));
  return JSON.stringify(String(value));
}

function splitEnv(name, fallback) {
  return (process.env[name] ?? fallback)
    .split(",")
    .map(value => value.trim())
    .filter(Boolean);
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function stringEnv(name, fallback) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function booleanEnv(name, fallback) {
  const value = process.env[name];
  if (typeof value !== "string") return fallback;
  return !["0", "false", "no", "off", ""].includes(value.trim().toLowerCase());
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

function isRateLimited(state) {
  const now = Date.now();
  state.messageTimes = state.messageTimes.filter(time => now - time < 5_000);
  state.messageTimes.push(now);
  return state.messageTimes.length > 420;
}
