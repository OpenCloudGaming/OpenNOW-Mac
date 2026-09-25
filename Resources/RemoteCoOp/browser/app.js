// Browser Remote Co-Op guest.
//
// Connects straight to the host over WebTransport and decodes with WebCodecs. There is no WebRTC and
// no signaling library: the page pins the host's WebTransport certificate from the host's own origin,
// then joins on a bidirectional control stream. The host sends H.264 video and 48 kHz stereo PCM as
// datagrams - the browser cannot decode the seat's HEVC, so it is sent a per-guest transcode - and the
// guest sends gamepad input back on the same datagrams.
//
// Wire formats mirror the host exactly (see OPN/RemoteCoOp/RemoteCoOpBrowserProtocol.swift and the
// native packet framings): video fragments, audio chunks, and one 62-byte input frame. The byte
// layouts live in ./wire.mjs so they can be verified without a browser.

import {
  buttonsForGamepad,
  codecString,
  encodeInputFrame,
  readUint32,
  readUint64
} from "./wire.mjs";

const elements = {
  title: document.querySelector("#title"),
  joinCard: document.querySelector("#join-card"),
  sessionCard: document.querySelector("#session-card"),
  inviteCode: document.querySelector("#invite-code"),
  displayName: document.querySelector("#display-name"),
  joinButton: document.querySelector("#join-button"),
  joinStatus: document.querySelector("#join-status"),
  state: document.querySelector("#session-state"),
  detail: document.querySelector("#session-detail"),
  networkState: document.querySelector("#network-state"),
  networkDetail: document.querySelector("#network-detail"),
  gamepadName: document.querySelector("#gamepad-name"),
  gamepadDetail: document.querySelector("#gamepad-detail"),
  diagnosticsPanel: document.querySelector("#diagnostics-panel"),
  diagnosticsToggle: document.querySelector("#diagnostics-toggle"),
  diagnosticsList: document.querySelector("#diagnostics-list"),
  copyDiagnosticsButton: document.querySelector("#copy-diagnostics-button"),
  playerNumber: document.querySelector("#player-number"),
  controllerGate: document.querySelector("#controller-gate"),
  connectionNotice: document.querySelector("#connection-notice"),
  connectionNoticeTitle: document.querySelector("#connection-notice-title"),
  connectionNoticeBody: document.querySelector("#connection-notice-body"),
  connectionNoticeHint: document.querySelector("#connection-notice-hint"),
  videoCanvas: document.querySelector("#video-canvas"),
  videoPlaceholder: document.querySelector(".video-placeholder"),
  disconnectButton: document.querySelector("#disconnect-button")
};

const AUDIO_SAMPLE_RATE = 48000;
const AUDIO_CHANNELS = 2;
/// Bump when the page's behaviour changes so a diagnostics paste proves which build is running.
const PAGE_BUILD = "wt-webcodecs-2026-09-25g";

const connectionState = {
  transport: null,
  controlWriter: null,
  datagramWriter: null,
  datagramReader: null,
  participantID: null,
  reconnectToken: null,
  mediaConfig: null,
  decoder: null,
  reassembler: null,
  audioContext: null,
  audioWorklet: null,
  joinStreamReader: null,
  isConnected: false,
  isApproved: false,
  playerIndex: null,
  inputSequence: 0,
  pendingFrame: null,
  isDrawScheduled: false,
  shouldReconnect: true,
  reconnectAttempts: 0
};

const STORAGE_KEY = "opennow.remote-coop.browser.identity";

function loadIdentity() {
  try {
    const stored = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "null");
    if (stored && stored.participantID && stored.reconnectToken) {
      connectionState.participantID = stored.participantID;
      connectionState.reconnectToken = stored.reconnectToken;
    }
  } catch {}
}

function saveIdentity() {
  if (!connectionState.participantID || !connectionState.reconnectToken) return;
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
      participantID: connectionState.participantID,
      reconnectToken: connectionState.reconnectToken
    }));
  } catch {}
}

const diagnostics = {
  videoFragments: 0,
  videoUnits: 0,
  videoChunks: 0,
  videoKeyUnits: 0,
  videoRejected: 0,
  videoStarted: 0,
  videoFramesDecoded: 0,
  videoFramesDrawn: 0,
  videoFramesDropped: 0,
  audioChunks: 0,
  inputFrames: 0,
  videoConfig: "-",
  lastError: ""
};

const inviteFromURL = new URL(window.location.href).searchParams.get("invite") ?? "";
let inviteToken = inviteFromURL.trim();
/// A link carries the signed token, and the token encodes the short code the host reads aloud.
/// Manual entry, by contrast, expects the whole token: a bare code cannot be verified.
const hasTokenFromURL = inviteFromURL.trim().length > 0;

/// The short invite code from a signed token's payload, for display only.
function inviteCode(fromToken) {
  const payload = fromToken.split(".")[0];
  if (!payload) return "";
  try {
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
    const decoded = JSON.parse(new TextDecoder().decode(bytes));
    return typeof decoded.code === "string" ? decoded.code : "";
  } catch {
    return "";
  }
}

/// The code shown to the guest while the host decides. Read aloud to the host to identify the request.
const inviteCodeText = hasTokenFromURL ? inviteCode(inviteFromURL.trim()) : "";

// MARK: - Small helpers

function show(element, isVisible) {
  if (!element) return;
  element.classList.toggle("hidden", !isVisible);
}

function setStatus(text) {
  if (elements.joinStatus) elements.joinStatus.textContent = text;
}

function setSessionState(label, detail) {
  if (elements.state) elements.state.textContent = label;
  if (elements.detail) elements.detail.textContent = detail;
}

function setNetworkState(label) {
  if (elements.networkState) elements.networkState.textContent = label;
}

function showNotice(title, body, hint) {
  if (!elements.connectionNotice) return;
  if (elements.connectionNoticeTitle) elements.connectionNoticeTitle.textContent = title;
  if (elements.connectionNoticeBody) elements.connectionNoticeBody.textContent = body;
  if (elements.connectionNoticeHint) elements.connectionNoticeHint.textContent = hint ?? "";
  show(elements.connectionNotice, true);
}

function hideNotice() {
  show(elements.connectionNotice, false);
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function configureVideoDecoder(avcC, width, height) {
  if (connectionState.decoder) {
    try { connectionState.decoder.close(); } catch {}
    connectionState.decoder = null;
  }
  const codec = codecString(avcC);
  connectionState.decoderCodec = codec;
  const config = {
    codec,
    description: avcC,
    codedWidth: width,
    codedHeight: height,
    // No hardware preference: a hint of `prefer-hardware` makes configure() fail outright where no
    // hardware decoder is available (headless, remote/VM GPUs) instead of falling back to software.
    hardwareAcceleration: "no-preference",
    optimizeForLatency: true
  };
  const decoder = new VideoDecoder({
    output: (frame) => {
      presentFrame(frame);
    },
    error: (error) => {
      diagnostics.lastError = `video decoder: ${error.message} (codec=${codec})`;
      if (connectionState.reassembler) connectionState.reassembler.reset();
      connectionState.needsKeyFrame = true;
    }
  });
  VideoDecoder.isConfigSupported(config).then((support) => {
    diagnostics.videoConfig = `codec=${codec} supported=${support.supported}`;
    if (!support.supported) {
      diagnostics.lastError = `video config not supported (codec=${codec})`;
      return;
    }
    decoder.configure(config);
    connectionState.decoder = decoder;
    connectionState.needsKeyFrame = true;
  }).catch((error) => {
    diagnostics.lastError = `isConfigSupported: ${error.message} (codec=${codec})`;
  });
}

function drawFrame(frame) {
  const canvas = elements.videoCanvas;
  if (!canvas) return;
  const context = canvas.getContext("2d", { alpha: false, desynchronized: true });
  if (!context) return;
  if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
    canvas.width = frame.displayWidth;
    canvas.height = frame.displayHeight;
  }
  context.drawImage(frame, 0, 0, canvas.width, canvas.height);
  diagnostics.videoFramesDrawn += 1;
  if (!connectionState.isMediaVisible) {
    connectionState.isMediaVisible = true;
    show(canvas, true);
    show(elements.videoPlaceholder, false);
  }
}

/// Presents at most one frame per display refresh.
///
/// Decode can run at the seat's full frame rate (120 fps here), and drawing every decoded frame on the
/// main thread both wastes work and competes with the audio post path - which is audible as choppy
/// sound. Holding only the newest frame and drawing it on the next animation frame keeps the picture
/// current and the main thread free.
function presentFrame(frame) {
  diagnostics.videoFramesDecoded += 1;
  const pending = connectionState.pendingFrame;
  if (pending) {
    pending.close();
    diagnostics.videoFramesDropped += 1;
  }
  connectionState.pendingFrame = frame;
  if (connectionState.isDrawScheduled) return;
  connectionState.isDrawScheduled = true;
  requestAnimationFrame(() => {
    connectionState.isDrawScheduled = false;
    const latest = connectionState.pendingFrame;
    connectionState.pendingFrame = null;
    if (!latest) return;
    drawFrame(latest);
    latest.close();
  });
}

function decodeAccessUnit(unit) {
  diagnostics.videoUnits += 1;
  if (unit.isKeyFrame) diagnostics.videoKeyUnits += 1;
  diagnostics.videoDecoderState = connectionState.decoder ? connectionState.decoder.state : "none";
  diagnostics.videoNeedsKeyframe = connectionState.needsKeyFrame === true;
  const decoder = connectionState.decoder;
  if (!decoder || decoder.state !== "configured") return;
  if (connectionState.needsKeyFrame) {
    if (!unit.isKeyFrame) return;
    connectionState.needsKeyFrame = false;
  }
  try {
    diagnostics.videoChunks += 1;
    decoder.decode(new EncodedVideoChunk({
      type: unit.isKeyFrame ? "key" : "delta",
      timestamp: Math.round(unit.timestampNanoseconds / 1000),
      data: unit.payload
    }));
  } catch (error) {
    diagnostics.lastError = `decode: ${error.message}`;
    connectionState.needsKeyFrame = true;
  }
}

// MARK: - WebCodecs-adjacent audio

async function startAudio() {
  if (connectionState.audioContext) return;
  try {
    const context = new AudioContext({ sampleRate: AUDIO_SAMPLE_RATE, latencyHint: "interactive" });
    await context.audioWorklet.addModule("./media-audio-worklet.js");
    const node = new AudioWorkletNode(context, "pcm-player", { outputChannelCount: [AUDIO_CHANNELS] });
    node.connect(context.destination);
    connectionState.audioContext = context;
    connectionState.audioWorklet = node;
    // An invite-link join runs without a user gesture, so the context starts suspended and `resume()`
    // stays pending until the guest interacts. Awaiting it would block the whole connect path on a
    // gesture that may never come, so it is fired and forgotten; audio begins at the next chunk once
    // the resume lands.
    if (context.state === "suspended") {
      context.resume().catch(() => {});
    }
  } catch (error) {
    diagnostics.lastError = `audio: ${error.message}`;
  }
}

/// Browsers gate audio behind a gesture. A link-initiated join has none, so resume on the first
/// interaction rather than leaving the guest permanently silent.
function resumeAudioOnInteraction() {
  const resume = () => {
    const context = connectionState.audioContext;
    if (context && context.state === "suspended") context.resume().catch(() => {});
  };
  window.addEventListener("pointerdown", resume, { passive: true });
  window.addEventListener("keydown", resume);
}

function playAudioPayload(payload) {
  const worklet = connectionState.audioWorklet;
  if (!worklet) return;
  const sampleCount = payload.length / 2;
  const floats = new Float32Array(sampleCount);
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  for (let index = 0; index < sampleCount; index += 1) {
    floats[index] = view.getInt16(index * 2, true) / 32768;
  }
  worklet.port.postMessage(floats, [floats.buffer]);
  diagnostics.audioChunks += 1;
}

// MARK: - Control stream

function encodeControl(message) {
  return new TextEncoder().encode(`${JSON.stringify(message)}\n`);
}

async function sendControl(message) {
  const writer = connectionState.controlWriter;
  if (!writer) return;
  try {
    await writer.write(encodeControl(message));
  } catch (error) {
    diagnostics.lastError = `control: ${error.message}`;
  }
}

async function readControlStream(stream) {
  const reader = stream.readable.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) return;
    buffer += decoder.decode(value, { stream: true });
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line.trim().length > 0) handleControlMessage(JSON.parse(line));
      newline = buffer.indexOf("\n");
    }
  }
}

function handleControlMessage(message) {
  switch (message.kind) {
    case "joined":
      connectionState.participantID = message.participantID;
      if (message.reconnectToken) connectionState.reconnectToken = message.reconnectToken;
      saveIdentity();
      applyParticipantState(message.state, message.playerIndex);
      break;
    case "state":
      applyParticipantState(message.state, message.playerIndex);
      break;
    case "config":
      applyMediaConfig(message);
      break;
    case "error":
      setStatus(message.message ?? "The host refused the join.");
      connectionState.shouldReconnect = false;
      showNotice("Cannot join", message.message ?? "The host refused the join.", "");
      break;
    default:
      break;
  }
}

function applyMediaConfig(message) {
  if (!message.avcC) return;
  const avcC = base64ToBytes(message.avcC);
  connectionState.mediaConfig = { avcC, width: message.width, height: message.height };
  configureVideoDecoder(avcC, message.width, message.height);
  if (connectionState.reassembler) connectionState.reassembler.reset();
}

function applyParticipantState(state, playerIndex) {
  connectionState.playerIndex = playerIndex ?? connectionState.playerIndex;
  if (elements.playerNumber) {
    elements.playerNumber.textContent = connectionState.playerIndex === null ? "P?" : `P${connectionState.playerIndex + 1}`;
  }
  const isConnected = state === "connected";
  connectionState.isApproved = isConnected;
  if (state === "waitingForApproval") {
    setSessionState("Waiting", "Host approval");
    // Its own screen: the controller gate is for a connected guest without a controller, not for one
    // the host has not let in yet. The invite code is shown so it can be read to the host.
    show(elements.controllerGate, false);
    showNotice("Waiting for host approval",
               inviteCodeText.length > 0
                 ? `The host must approve you. Your invite code is ${inviteCodeText}.`
                 : "The host must approve you before the game appears.",
               "");
  } else if (isConnected) {
    setSessionState("Connected", "In game");
    hideNotice();
  } else if (state === "disconnected") {
    setSessionState("Dropped", "Reconnecting");
  }
}

// MARK: - Media stream

const MEDIA_HEADER_BYTES = 14;

/// Reads the host's reliable media stream: one length-prefixed frame per access unit or audio buffer.
async function readMediaStream(stream) {
  const reader = stream.readable.getReader();
  let buffer = new Uint8Array(0);
  while (true) {
    const { value, done } = await reader.read();
    if (done) return;
    const merged = new Uint8Array(buffer.length + value.length);
    merged.set(buffer);
    merged.set(value, buffer.length);
    buffer = merged;

    while (buffer.length >= MEDIA_HEADER_BYTES) {
      const kind = buffer[0];
      const flags = buffer[1];
      const timestampNanoseconds = readUint64(buffer, 2);
      const length = readUint32(buffer, 10);
      if (buffer.length < MEDIA_HEADER_BYTES + length) break;
      const payload = buffer.slice(MEDIA_HEADER_BYTES, MEDIA_HEADER_BYTES + length);
      buffer = buffer.slice(MEDIA_HEADER_BYTES + length);
      if (kind === 1) {
        decodeAccessUnit({ isKeyFrame: (flags & 0x01) !== 0, timestampNanoseconds, payload });
      } else if (kind === 2) {
        playAudioPayload(payload);
      }
    }
  }
}

// MARK: - Input

function firstGamepad() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  for (const pad of pads) {
    if (pad) return pad;
  }
  return null;
}

let inputLoopHandle = null;

function startInputLoop() {
  if (inputLoopHandle !== null) return;
  const tick = () => {
    inputLoopHandle = requestAnimationFrame(tick);
    const writer = connectionState.datagramWriter;
    const pad = firstGamepad();
    if (elements.gamepadName) elements.gamepadName.textContent = pad ? pad.id.slice(0, 24) : "Controller";
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = pad ? "Ready" : "Waiting";
    if (!writer || !connectionState.isApproved || !connectionState.participantID) return;
    if (!pad) {
      if (elements.controllerGate) show(elements.controllerGate, true);
      return;
    }
    if (elements.controllerGate) show(elements.controllerGate, false);

    // Order matches `OPNRemoteCoOpInputBinaryCodec`: leftTrigger, rightTrigger, then the four stick
    // axes. The Y axes are negated: the standard gamepad reports +1 as down, while the seat's input
    // (Apple's GameController convention, which the native guest sends) treats +1 as up.
    const axes = [
      (pad.buttons[6] && pad.buttons[6].value) || 0,
      (pad.buttons[7] && pad.buttons[7].value) || 0,
      pad.axes[0] ?? 0,
      -(pad.axes[1] ?? 0),
      pad.axes[2] ?? 0,
      -(pad.axes[3] ?? 0)
    ];
    const frame = encodeInputFrame(connectionState.participantID,
                                   connectionState.inputSequence,
                                   buttonsForGamepad(pad),
                                   axes,
                                   Math.round(performance.now() * 1e6));
    connectionState.inputSequence += 1;
    writer.write(frame).then(() => { diagnostics.inputFrames += 1; }).catch(() => {});
  };
  inputLoopHandle = requestAnimationFrame(tick);
}

function stopInputLoop() {
  if (inputLoopHandle !== null) {
    cancelAnimationFrame(inputLoopHandle);
    inputLoopHandle = null;
  }
}

// MARK: - Diagnostics

function updateDiagnostics() {
  if (!elements.diagnosticsList) return;
  const rows = [
    ["State", connectionState.isApproved ? "connected" : "waiting"],
    ["Player", connectionState.playerIndex === null ? "-" : `P${connectionState.playerIndex + 1}`],
    ["Video frames", `${diagnostics.videoUnits}`],
    ["Video keyframes", `${diagnostics.videoKeyUnits}`],
    ["Video chunks", `${diagnostics.videoChunks}`],
    ["Video decode", `${diagnostics.videoFramesDecoded} frames`],
    ["Video drawn", `${diagnostics.videoFramesDrawn} frames`],
    ["Video dropped", `${diagnostics.videoFramesDropped} frames`],
    ["Audio", `${diagnostics.audioChunks} chunks`],
    ["Input", `${diagnostics.inputFrames} frames`],
    ["Video config", diagnostics.videoConfig],
    ["Last error", diagnostics.lastError || "-"]
  ];
  elements.diagnosticsList.replaceChildren(
    ...rows.flatMap(([label, value]) => {
      const dt = document.createElement("dt");
      dt.textContent = label;
      const dd = document.createElement("dd");
      dd.textContent = value;
      return [dt, dd];
    })
  );
}

function diagnosticsText() {
  return [
    `OpenNOW Remote Co-Op browser guest (${PAGE_BUILD})`,
    `state=${connectionState.isApproved ? "connected" : "waiting"}`,
    `videoFrames=${diagnostics.videoUnits} keyUnits=${diagnostics.videoKeyUnits} chunks=${diagnostics.videoChunks} decoderState=${diagnostics.videoDecoderState ?? "-"} needsKeyframe=${diagnostics.videoNeedsKeyframe ?? "-"}`,
    `videoDecoded=${diagnostics.videoFramesDecoded} drawn=${diagnostics.videoFramesDrawn} dropped=${diagnostics.videoFramesDropped}`,
    `videoConfig=${diagnostics.videoConfig}`,
    `audioChunks=${diagnostics.audioChunks}`,
    `inputFrames=${diagnostics.inputFrames}`,
    `error=${diagnostics.lastError || "none"}`
  ].join("\n");
}

// MARK: - Connect

async function fetchWebTransportInfo() {
  const response = await fetch("/remote-coop/webtransport", { cache: "no-store" });
  if (!response.ok) throw new Error("browser media is unavailable from this host");
  const info = await response.json();
  if (!info || !info.port) throw new Error("the host reported no WebTransport endpoint");
  return info;
}

async function connect() {
  const info = await fetchWebTransportInfo();
  const url = `https://${info.host}:${info.port}${info.path}`;
  setStatus(`Contacting ${info.host}:${info.port}...`);
  const transport = new WebTransport(url, {
    serverCertificateHashes: [{ algorithm: "sha-256", value: base64ToBytes(info.certificateHash) }]
  });
  connectionState.transport = transport;
  // `ready` does not reject on a stalled handshake, so the QUIC idle timeout (30 s host-side) is the
  // only backstop. A short client-side deadline turns a silent hang into a message.
  await withTimeout(transport.ready, 12_000, "WebTransport handshake timed out");
  connectionState.isConnected = true;

  transport.closed.then(() => handleTransportClosed("closed")).catch(() => handleTransportClosed("closed"));

  const controlStream = await transport.createBidirectionalStream();
  connectionState.controlWriter = controlStream.writable.getWriter();
  await sendControl({
    kind: "join",
    token: inviteToken,
    displayName: displayName(),
    participantID: connectionState.participantID,
    reconnectToken: connectionState.reconnectToken
  });

  // Media rides a second reliable, ordered stream (video and audio as whole frames). Datagrams are
  // kept only for input back to the host.
  const mediaStream = await transport.createBidirectionalStream();
  connectionState.datagramWriter = transport.datagrams.writable.getWriter();

  readControlStream(controlStream).catch((error) => { diagnostics.lastError = `control read: ${error.message}`; });
  readMediaStream(mediaStream).catch((error) => { diagnostics.lastError = `media read: ${error.message}`; });
  startInputLoop();
}

function withTimeout(promise, milliseconds, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), milliseconds);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); }
    );
  });
}

function handleTransportClosed(reason) {
  connectionState.isConnected = false;
  connectionState.isApproved = false;
  stopInputLoop();
  if (!connectionState.shouldReconnect) return;
  if (connectionState.reconnectAttempts >= 6) {
    showNotice("Connection lost", "The host stopped responding.", "Check that the host is still hosting the session.");
    return;
  }
  connectionState.reconnectAttempts += 1;
  setStatus(`Reconnecting (${connectionState.reconnectAttempts})...`);
  showNotice("Connection lost", "Trying to rejoin the host.", reason);
  setTimeout(() => {
    connect().catch((error) => {
      diagnostics.lastError = error.message;
      handleTransportClosed("retry failed");
    });
  }, 1500);
}

function displayName() {
  const name = (elements.displayName?.value ?? "").trim();
  return name.length > 0 ? name.slice(0, 32) : "Guest";
}

// MARK: - Join button

async function join() {
  hideNotice();
  const input = (elements.inviteCode?.value ?? "").trim();
  if (!hasTokenFromURL && input.length > 0) inviteToken = input;
  if (inviteToken.length === 0) {
    setStatus("Enter the invite code from the host.");
    return;
  }
  elements.joinButton.disabled = true;
  setStatus("Connecting...");
  setSessionState("Joining", "Contacting host");
  show(elements.joinCard, false);
  show(elements.sessionCard, true);

  try {
    await startAudio();
    await connect();
    setStatus("Connected.");
    setNetworkState("WT");
    if (elements.networkDetail) elements.networkDetail.textContent = "WebTransport";
  } catch (error) {
    diagnostics.lastError = error.message;
    setStatus(error.message);
    showNotice("Cannot connect", "The browser could not reach the host's media endpoint.", error.message);
    elements.joinButton.disabled = false;
    show(elements.joinCard, true);
    show(elements.sessionCard, false);
  }
}

function leave() {
  connectionState.shouldReconnect = false;
  stopInputLoop();
  try { connectionState.transport?.close(); } catch {}
  connectionState.isConnected = false;
  connectionState.isApproved = false;
  show(elements.sessionCard, false);
  show(elements.joinCard, true);
  elements.joinButton.disabled = false;
  setStatus(hasTokenFromURL ? (inviteCodeText ? `Link ready · ${inviteCodeText}` : "Link ready") : "Code required");
}

function wireUI() {
  if (hasTokenFromURL) {
    const code = inviteCode(inviteFromURL.trim());
    if (code && elements.inviteCode) {
      elements.inviteCode.value = code;
      elements.inviteCode.readOnly = true;
    }
    setStatus(code ? `Link ready · ${code}` : "Link ready");
  }
  elements.joinButton?.addEventListener("click", (event) => { event.preventDefault(); join(); });
  elements.disconnectButton?.addEventListener("click", (event) => { event.preventDefault(); leave(); });
  elements.diagnosticsToggle?.addEventListener("click", () => {
    const isHidden = elements.diagnosticsPanel?.hasAttribute("hidden") ?? false;
    if (isHidden) {
      elements.diagnosticsPanel.removeAttribute("hidden");
      elements.diagnosticsToggle.setAttribute("aria-expanded", "true");
    } else {
      elements.diagnosticsPanel?.setAttribute("hidden", "");
      elements.diagnosticsToggle.setAttribute("aria-expanded", "false");
    }
  });
  elements.copyDiagnosticsButton?.addEventListener("click", () => {
    navigator.clipboard?.writeText(diagnosticsText());
  });
  setInterval(updateDiagnostics, 500);
}

wireUI();
loadIdentity();
resumeAudioOnInteraction();

// Readable from the DevTools console when the on-screen panel cannot be reached (for example a guest
// with no controller, where the controller gate is up). A single read-only text accessor.
window.__opennowDiagnostics = diagnosticsText;

// A link pre-fills the invite screen (code and all) rather than joining silently: the guest sees what
// they are joining and can read the code to the host, then joins with one press.
