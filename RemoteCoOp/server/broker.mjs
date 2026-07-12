import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const port = Number.parseInt(process.env.OPENNOW_REMOTE_COOP_PORT ?? "8787", 10);
const root = normalize(join(fileURLToPath(new URL(".", import.meta.url)), "../browser"));
const rooms = new Map();
const sockets = new Set();

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"]
]);

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = normalize(join(root, pathname));
    if (!file.startsWith(root)) {
      response.writeHead(403).end("Forbidden");
      return;
    }
    const data = await readFile(file);
    response.writeHead(200, { "content-type": contentTypes.get(extname(file)) ?? "application/octet-stream" }).end(data);
  } catch {
    response.writeHead(404).end("Not found");
  }
});

server.on("upgrade", (request, socket) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  if (url.pathname !== "/remote-coop") {
    socket.destroy();
    return;
  }
  const key = request.headers["sec-websocket-key"];
  if (typeof key !== "string") {
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
  attachSocket(socket);
});

server.listen(port, "127.0.0.1", () => {
  console.log(`OpenNOW Remote Co-Op broker listening on http://127.0.0.1:${port}`);
});

setInterval(() => {
  const now = Date.now();
  for (const [roomID, room] of rooms) {
    if (room.expiresAtMs > 0 && room.expiresAtMs <= now) {
      broadcast(room, { kind: "inviteEnded", roomID, reason: "Invite expired" });
      closeRoom(roomID);
    }
  }
  for (const state of sockets) {
    if (now - state.lastSeenAt > 45_000) {
      state.socket.destroy();
    } else {
      send(state, { kind: "heartbeat", roomID: state.roomID });
    }
  }
}, 10_000).unref();

function attachSocket(socket) {
  const state = { socket, buffer: Buffer.alloc(0), role: "unknown", roomID: null, participantID: null, lastSeenAt: Date.now(), messageTimes: [] };
  sockets.add(state);
  socket.on("data", chunk => {
    state.buffer = Buffer.concat([state.buffer, chunk]);
    parseFrames(state);
  });
  socket.on("close", () => detachSocket(state));
  socket.on("error", () => detachSocket(state));
}

function detachSocket(state) {
  sockets.delete(state);
  if (!state.roomID) return;
  const room = rooms.get(state.roomID);
  if (!room) return;
  if (state.role === "host" && room.host === state) {
    broadcast(room, { kind: "inviteEnded", roomID: state.roomID, reason: "Host disconnected" }, state);
    closeRoom(state.roomID);
    return;
  }
  if (state.role === "guest" && state.participantID) {
    room.guests.delete(state.participantID);
    if (room.host) send(room.host, { kind: "guestDisconnected", roomID: state.roomID, participantID: state.participantID });
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
    const maskOffset = offset;
    if (masked) offset += 4;
    if (state.buffer.length < offset + length) return;
    let payload = state.buffer.subarray(offset, offset + length);
    if (masked) {
      const mask = state.buffer.subarray(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));
    }
    state.buffer = state.buffer.subarray(offset + length);
    handleFrame(state, opcode, payload);
  }
}

function handleFrame(state, opcode, payload) {
  state.lastSeenAt = Date.now();
  if (opcode === 0x8) {
    state.socket.end();
    return;
  }
  if (opcode === 0x9) {
    sendFrame(state.socket, 0xA, payload);
    return;
  }
  if (opcode !== 0x1) return;
  if (isRateLimited(state)) {
    send(state, { kind: "error", reason: "Rate limit exceeded" });
    state.socket.destroy();
    return;
  }
  try {
    handleMessage(state, JSON.parse(payload.toString("utf8")));
  } catch {
    send(state, { kind: "error", reason: "Invalid JSON message" });
  }
}

function handleMessage(state, message) {
  if (message.kind === "heartbeat") return;
  if (message.kind === "hostHello") {
    registerHost(state, message);
    return;
  }
  if (message.kind === "guestJoinRequested") {
    registerGuest(state, message);
    return;
  }
  if (message.kind === "guestInput" || message.kind === "guestDisconnected") {
    relayGuestEvent(state, message);
    return;
  }
  if (["participantUpdated", "participantRemoved", "guestRejected", "inputRejected", "inviteEnded", "peerSignal"].includes(message.kind)) {
    relayHostCommand(state, message);
  }
}

function registerHost(state, message) {
  const roomID = stringValue(message.roomID ?? message.invite?.id);
  if (!roomID) {
    send(state, { kind: "error", reason: "Missing room ID" });
    return;
  }
  const room = roomFor(roomID);
  room.host = state;
  room.invite = message.invite ?? null;
  room.expiresAtMs = inviteExpiryMilliseconds(message.invite?.token);
  state.role = "host";
  state.roomID = roomID;
  send(state, { kind: "heartbeat", roomID });
}

function registerGuest(state, message) {
  const roomID = stringValue(message.roomID);
  const participantID = stringValue(message.participantID);
  if (!roomID || !participantID) {
    send(state, { kind: "guestRejected", participantID, reason: "Missing room or participant ID" });
    return;
  }
  const room = rooms.get(roomID);
  if (!room?.host) {
    send(state, { kind: "guestRejected", roomID, participantID, reason: "Host is not connected" });
    return;
  }
  state.role = "guest";
  state.roomID = roomID;
  state.participantID = participantID;
  room.guests.set(participantID, state);
  send(room.host, sanitizeMessage({ ...message, roomID, participantID }));
}

function relayGuestEvent(state, message) {
  const room = state.roomID ? rooms.get(state.roomID) : null;
  if (state.role !== "guest" || !room?.host) {
    send(state, { kind: "guestRejected", roomID: state.roomID, participantID: state.participantID, reason: "Guest is not joined" });
    return;
  }
  send(room.host, sanitizeMessage({ ...message, roomID: state.roomID, participantID: state.participantID }));
}

function relayHostCommand(state, message) {
  const roomID = stringValue(message.roomID ?? state.roomID);
  const room = roomID ? rooms.get(roomID) : null;
  if (state.role !== "host" || !room || room.host !== state) {
    send(state, { kind: "error", reason: "Host is not registered" });
    return;
  }
  const outbound = sanitizeMessage({ ...message, roomID });
  if (message.kind === "inviteEnded") {
    broadcast(room, outbound, state);
    closeRoom(roomID);
    return;
  }
  const participantID = stringValue(message.participantID ?? message.participant?.id);
  if (participantID && room.guests.has(participantID)) {
    send(room.guests.get(participantID), outbound);
    if (message.kind === "participantRemoved" || message.kind === "guestRejected") room.guests.delete(participantID);
  } else {
    broadcast(room, outbound, state);
  }
}

function send(state, message) {
  if (!state || state.socket.destroyed) return;
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

function closeRoom(roomID) {
  const room = rooms.get(roomID);
  if (!room) return;
  if (room.host) room.host.roomID = null;
  for (const guest of room.guests.values()) guest.roomID = null;
  rooms.delete(roomID);
}

function roomFor(roomID) {
  const existing = rooms.get(roomID);
  if (existing) return existing;
  const room = { host: null, guests: new Map(), invite: null, expiresAtMs: 0 };
  rooms.set(roomID, room);
  return room;
}

function inviteExpiryMilliseconds(token) {
  const payload = decodeInvitePayload(token);
  const expiresAt = Number(payload?.expiresAtEpochSeconds ?? 0);
  return Number.isFinite(expiresAt) && expiresAt > 0 ? Math.round(expiresAt * 1_000) : 0;
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

function isRateLimited(state) {
  const now = Date.now();
  state.messageTimes = state.messageTimes.filter(time => now - time < 5_000);
  state.messageTimes.push(now);
  return state.messageTimes.length > 420;
}
