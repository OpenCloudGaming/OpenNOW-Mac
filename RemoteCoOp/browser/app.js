const elements = {
  title: document.querySelector("#title"),
  subtitle: document.querySelector("#subtitle"),
  joinCard: document.querySelector("#join-card"),
  sessionCard: document.querySelector("#session-card"),
  displayName: document.querySelector("#display-name"),
  joinButton: document.querySelector("#join-button"),
  joinStatus: document.querySelector("#join-status"),
  state: document.querySelector("#session-state"),
  detail: document.querySelector("#session-detail"),
  dot: document.querySelector("#connection-dot"),
  gamepadName: document.querySelector("#gamepad-name"),
  gamepadDetail: document.querySelector("#gamepad-detail"),
  networkState: document.querySelector("#network-state"),
  networkDetail: document.querySelector("#network-detail"),
  diagnosticsPanel: document.querySelector("#diagnostics-panel"),
  diagnosticsToggle: document.querySelector("#diagnostics-toggle"),
  diagnosticsList: document.querySelector("#diagnostics-list"),
  copyDiagnosticsButton: document.querySelector("#copy-diagnostics-button"),
  playerBadge: document.querySelector("#player-badge"),
  playerNumber: document.querySelector("#player-number"),
  disconnectButton: document.querySelector("#disconnect-button")
};

const url = new URL(window.location.href);
const inviteFromURL = url.searchParams.get("invite") ?? "";
const inviteToken = inviteFromURL.trim();
const serverFromURL = url.searchParams.get("server") ?? "";
let socket = null;
let invite = null;
const participantID = createParticipantID();
let approved = false;
let sequenceNumber = 0;
let lastSentState = "";
let lastSentAt = 0;
let pollHandle = null;
let pollMode = "stopped";
let networkConfiguration = null;
let peerConnection = null;
let inputChannel = null;
let statsHandle = 0;
let diagnostics = initialDiagnostics();
let sessionState = "Connecting";
const playbackPromises = new WeakMap();

renderInvite(inviteToken);
renderDiagnostics();

elements.joinButton.addEventListener("click", joinRoom);
elements.diagnosticsToggle?.addEventListener("click", toggleDiagnostics);
elements.copyDiagnosticsButton?.addEventListener("click", event => {
  event.preventDefault();
  event.stopPropagation();
  copyDiagnostics();
});
elements.disconnectButton?.addEventListener("click", disconnect);
window.addEventListener("gamepadconnected", event => {
  if (elements.gamepadName) elements.gamepadName.textContent = event.gamepad.id;
  if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Controller connected. Waiting for host approval.";
  updateDiagnostics({ input: "controller connected" });
});
window.addEventListener("pagehide", disconnect);
document.addEventListener("visibilitychange", restartPollingIfActive);

function renderInvite(token) {
  invite = decodeInvite(token);
  if (!invite) {
    if (elements.title) elements.title.textContent = "Join a cloud couch session";
    if (elements.subtitle) elements.subtitle.textContent = "Open the invite link your host sent.";
    elements.joinStatus.textContent = inviteToken ? "Invite link is invalid." : "Waiting for invite link.";
    elements.joinButton.disabled = true;
    return;
  }
  if (elements.title) elements.title.textContent = invite.title ? `Join ${invite.title}` : "Join this Remote Co-Op room";
  if (elements.subtitle) elements.subtitle.textContent = `Room ${invite.code ?? invite.inviteID}. ${invite.requireHostApproval ? "Host approval required." : "Input starts after connection."}`;
  elements.joinStatus.textContent = "Invite loaded. Enter a name and join.";
  elements.joinButton.disabled = false;
}

function joinRoom() {
  invite = decodeInvite(inviteToken);
  if (!invite) {
    elements.joinStatus.textContent = "Invite link is invalid.";
    return;
  }
  if (invite.expiresAtEpochSeconds * 1000 <= Date.now()) {
    elements.joinStatus.textContent = "Invite has expired.";
    return;
  }
  const endpoint = signalingEndpoint();
  diagnostics = initialDiagnostics();
  updateDiagnostics({ websocket: `connecting ${endpoint}`, transportMode: invite.transportMode ?? "automatic" });
  socket = new WebSocket(endpoint);
  elements.joinButton.disabled = true;
  elements.joinStatus.textContent = `Connecting to ${endpoint}`;
  socket.addEventListener("open", () => {
    updateDiagnostics({ websocket: "open" });
    send({
      kind: "guestJoinRequested",
      roomID: invite.inviteID,
      participantID,
      inviteToken,
      displayName: displayName()
    });
    elements.joinCard.classList.add("hidden");
    elements.sessionCard.classList.remove("hidden");
    setState("Waiting", "Waiting for host approval.", false);
  });
  socket.addEventListener("message", event => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (error) {
      updateDiagnostics({ websocket: "invalid message" });
      setNetworkState("Broker message failed", error.message || "Invalid JSON from signaling broker.");
      return;
    }
    handleMessage(message).catch(error => {
      setNetworkState("Peer setup failed", error.message || "WebRTC negotiation failed.");
      updateDiagnostics({ signaling: error.message || "WebRTC negotiation failed" });
    });
  });
  socket.addEventListener("close", () => {
    stopPolling();
    updateDiagnostics({ websocket: "closed" });
    if (!hasTerminalState()) setState("Disconnected", "The Remote Co-Op connection closed.", false);
    elements.joinButton.disabled = false;
  });
  socket.addEventListener("error", () => updateDiagnostics({ websocket: "error" }));
}

async function handleMessage(message) {
  if (message.kind === "heartbeat") {
    send({ kind: "heartbeat", roomID: invite?.inviteID, participantID });
    return;
  }
  if (message.kind === "networkConfiguration") {
    updateDiagnostics({ signaling: "network configuration received" });
    configurePeerConnection(message.networkConfiguration);
    return;
  }
  if (message.kind === "peerSignal") {
    if (!isForThisParticipant(message)) return;
    updateDiagnostics({ signaling: `peer signal ${message.peerSignal?.kind ?? "unknown"}` });
    await handlePeerSignal(message.peerSignal);
    return;
  }
  if (message.kind === "participantUpdated" && sameParticipantID(message.participant?.id, participantID)) {
    approved = message.participant.connectionState === "connected" && message.participant.inputEnabled === true;
    if (approved) {
      const playerNumber = (message.participant.playerIndex ?? 1) + 1;
      setState("Approved", `Input enabled as player ${playerNumber}.`, true, playerNumber);
      updateDiagnostics({ approval: "approved", playerSlot: `player ${playerNumber}` });
      startPolling();
    } else {
      setState("Waiting", "Host approval pending.", false);
      updateDiagnostics({ approval: "waiting" });
    }
    return;
  }
  if (message.kind === "participantRemoved") {
    if (!isForThisParticipant(message)) return;
    setState("Removed", "The host removed you from the room.", false);
    updateDiagnostics({ approval: "removed" });
    disconnect();
    return;
  }
  if (message.kind === "guestRejected") {
    if (!isForThisParticipant(message)) return;
    setState("Rejected", message.reason ?? "The host rejected this join request.", false);
    updateDiagnostics({ approval: `rejected: ${message.reason ?? "host rejected join"}` });
    disconnect(false);
    return;
  }
  if (message.kind === "inputRejected") {
    if (!isForThisParticipant(message)) return;
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = `Input rejected: ${message.inputRejection ?? "unknown"}`;
    updateDiagnostics({ input: `rejected: ${message.inputRejection ?? "unknown"}` });
    return;
  }
  if (message.kind === "inviteEnded") {
    setState("Ended", message.reason ?? "The host ended the invite.", false);
    updateDiagnostics({ approval: `ended: ${message.reason ?? "host ended invite"}` });
    disconnect();
  }
}

function isForThisParticipant(message) {
  const target = message.participantID ?? message.participant?.id;
  return !target || sameParticipantID(target, participantID);
}

function sameParticipantID(left, right) {
  return typeof left === "string" && typeof right === "string" && left.toLowerCase() === right.toLowerCase();
}

function startPolling() {
  if (pollHandle) return;
  const poll = time => {
    if (!approved || socket?.readyState !== WebSocket.OPEN) return;
    const gamepad = navigator.getGamepads().find(Boolean);
    if (!gamepad) {
      if (elements.gamepadName) elements.gamepadName.textContent = "No gamepad detected";
      if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Connect a controller and press any button.";
      return;
    }
    if (elements.gamepadName) elements.gamepadName.textContent = gamepad.id;
    const input = inputPacket(gamepad, time);
    const state = inputStateKey(input);
    if (state === lastSentState && time - lastSentAt < 250) return;
    lastSentState = state;
    lastSentAt = time;
    sendInput(input);
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = `Sending input sequence ${input.sequenceNumber}.`;
  };
  const interval = inputPollIntervalMilliseconds();
  if (interval > 0) {
    pollMode = "interval";
    pollHandle = window.setInterval(() => poll(performance.now()), interval);
    updateDiagnostics({ inputSampling: `${Math.round(1_000 / interval)} Hz interval` });
    poll(performance.now());
    return;
  }
  pollMode = "animationFrame";
  updateDiagnostics({ inputSampling: "display frame" });
  const frame = time => {
    poll(time);
    pollHandle = requestAnimationFrame(frame);
  };
  pollHandle = requestAnimationFrame(frame);
}

function stopPolling() {
  if (!pollHandle) return;
  if (pollMode === "interval") {
    clearInterval(pollHandle);
  } else {
    cancelAnimationFrame(pollHandle);
  }
  pollHandle = null;
  pollMode = "stopped";
  updateDiagnostics({ inputSampling: "stopped" });
}

function restartPollingIfActive() {
  if (!approved || !pollHandle) return;
  stopPolling();
  startPolling();
}

function inputPollIntervalMilliseconds() {
  if (latencyMode() !== "lowLatency") return 0;
  return document.visibilityState === "visible" ? 4 : 16;
}

function inputPacket(gamepad, sampledAtMilliseconds = performance.now()) {
  return {
    participantID,
    sequenceNumber: ++sequenceNumber,
    buttons: buttonMask(gamepad),
    leftTrigger: analogButton(gamepad, 6),
    rightTrigger: analogButton(gamepad, 7),
    leftStickX: axis(gamepad, 0),
    leftStickY: axis(gamepad, 1),
    rightStickX: axis(gamepad, 2),
    rightStickY: axis(gamepad, 3),
    sentAtNanoseconds: Math.round(sampledAtMilliseconds * 1_000_000),
    sampledAtMilliseconds
  };
}

function inputStateKey(input) {
  return JSON.stringify({
    buttons: input.buttons,
    leftTrigger: input.leftTrigger,
    rightTrigger: input.rightTrigger,
    leftStickX: input.leftStickX,
    leftStickY: input.leftStickY,
    rightStickX: input.rightStickX,
    rightStickY: input.rightStickY
  });
}

function buttonMask(gamepad) {
  const map = new Map([[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [5, 5], [8, 6], [9, 7], [10, 8], [11, 9], [12, 10], [13, 11], [14, 12], [15, 13]]);
  let mask = 0;
  for (const [buttonIndex, bit] of map) {
    if (gamepad.buttons[buttonIndex]?.pressed) mask |= 1 << bit;
  }
  return mask;
}

function analogButton(gamepad, index) {
  const value = gamepad.buttons[index]?.value ?? 0;
  return clamp(value, 0, 1);
}

function axis(gamepad, index) {
  return clamp(gamepad.axes[index] ?? 0, -1, 1);
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, Number.isFinite(value) ? value : 0));
}

function send(message) {
  if (socket?.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
}

function sendInput(input) {
  const sampledAtMilliseconds = input.sampledAtMilliseconds ?? performance.now();
  const wireInput = { ...input };
  delete wireInput.sampledAtMilliseconds;
  const message = { kind: "guestInput", roomID: invite.inviteID, participantID, input: wireInput };
  if (inputChannel?.readyState === "open") {
    inputChannel.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
    recordInputSent(input, "data channel", sampledAtMilliseconds);
    return;
  }
  if (networkConfiguration?.websocketInputFallbackEnabled !== false) {
    send(message);
    recordInputSent(input, "WebSocket fallback", sampledAtMilliseconds);
  } else {
    updateDiagnostics({ input: "blocked: no open data channel and fallback disabled" });
  }
}

function configurePeerConnection(configuration) {
  networkConfiguration = configuration ?? automaticFallbackConfiguration();
  closePeerConnection();
  updateDiagnostics({
    transportMode: networkConfiguration.transportMode ?? "automatic",
    latencyMode: latencyMode(),
    icePolicy: networkConfiguration.iceTransportPolicy ?? "all",
    iceServers: describeIceServers(networkConfiguration.iceServers ?? []),
    localCandidates: 0,
    remoteCandidates: 0,
    selectedRoute: "waiting",
    inputChannel: networkConfiguration.dataChannelInputEnabled === false ? "disabled by configuration" : "creating",
    signaling: "creating peer connection"
  });
  const rtcConfiguration = {
    iceServers: networkConfiguration.iceServers ?? [],
    iceTransportPolicy: networkConfiguration.iceTransportPolicy ?? "all"
  };
  peerConnection = new RTCPeerConnection(rtcConfiguration);
  configureReceiverLatency(peerConnection.addTransceiver("video", { direction: "recvonly" }).receiver);
  configureReceiverLatency(peerConnection.addTransceiver("audio", { direction: "recvonly" }).receiver);
  if (networkConfiguration.dataChannelInputEnabled !== false) bindInputChannel(peerConnection.createDataChannel("input", { ordered: false, maxRetransmits: 0 }));
  peerConnection.addEventListener("datachannel", event => bindInputChannel(event.channel));
  peerConnection.addEventListener("icecandidate", event => {
    if (!event.candidate) return;
    updateDiagnostics({ localCandidates: diagnostics.localCandidates + 1 });
    send({
      kind: "peerSignal",
      roomID: invite.inviteID,
      participantID,
      peerSignal: {
        kind: "iceCandidate",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex
      }
    });
  });
  peerConnection.addEventListener("connectionstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("iceconnectionstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("icegatheringstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("signalingstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("track", event => attachRemoteTrack(event.track, event.receiver));
  setNetworkState(networkLabel(), networkConfiguration.directPeerCandidateWarning || connectionDetail());
  updatePeerConnectionState();
  startStatsPolling();
}

async function handlePeerSignal(signal) {
  if (!signal) return;
  if (!peerConnection) configurePeerConnection(automaticFallbackConfiguration());
  if (signal.kind === "offer") {
    updateDiagnostics({ signaling: "offer received" });
    await peerConnection.setRemoteDescription({ type: "offer", sdp: signal.sdp });
    const answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    send({ kind: "peerSignal", roomID: invite.inviteID, participantID, peerSignal: { kind: "answer", sdp: answer.sdp } });
    setNetworkState(networkLabel(), "WebRTC answer sent. Waiting for ICE connectivity.");
    updateDiagnostics({ signaling: "answer sent" });
    return;
  }
  if (signal.kind === "answer") {
    await peerConnection.setRemoteDescription({ type: "answer", sdp: signal.sdp });
    updateDiagnostics({ signaling: "answer received" });
    return;
  }
  if (signal.kind === "iceCandidate" && signal.candidate) {
    updateDiagnostics({ remoteCandidates: diagnostics.remoteCandidates + 1, signaling: "remote ICE candidate received" });
    await peerConnection.addIceCandidate({ candidate: signal.candidate, sdpMid: signal.sdpMid ?? null, sdpMLineIndex: signal.sdpMLineIndex ?? null });
  }
}

function bindInputChannel(channel) {
  inputChannel = channel;
  updateDiagnostics({ inputChannel: `${channel.label || "input"} ${channel.readyState}` });
  channel.addEventListener("open", () => {
    setNetworkState(networkLabel(), "Input data channel connected.");
    updateDiagnostics({ inputChannel: `${channel.label || "input"} open`, input: "data channel ready" });
  });
  channel.addEventListener("close", () => {
    setNetworkState(networkLabel(), "Input data channel closed. WebSocket fallback remains available.");
    updateDiagnostics({ inputChannel: `${channel.label || "input"} closed` });
  });
  channel.addEventListener("error", () => updateDiagnostics({ inputChannel: `${channel.label || "input"} error` }));
}

function closePeerConnection() {
  stopStatsPolling();
  inputChannel?.close();
  inputChannel = null;
  peerConnection?.close();
  peerConnection = null;
  updateDiagnostics({ rtcConnection: "closed", iceConnection: "closed", inputChannel: "closed" });
}

function automaticFallbackConfiguration() {
  return {
    transportMode: invite?.transportMode ?? "automatic",
    iceTransportPolicy: invite?.transportMode === "relayOnly" ? "relay" : "all",
    latencyMode: invite?.latencyMode ?? "quality",
    iceServers: [],
    dataChannelInputEnabled: true,
    websocketInputFallbackEnabled: true,
    directPeerCandidateWarning: "Using invite defaults until the broker provides ICE settings."
  };
}

function networkLabel() {
  const mode = networkConfiguration?.transportMode ?? invite?.transportMode ?? "automatic";
  if (mode === "relayOnly") return "Private relay";
  if (mode === "directOnly") return "Direct only";
  return "Automatic";
}

function connectionDetail() {
  const connection = peerConnection?.connectionState ?? "new";
  const ice = peerConnection?.iceConnectionState ?? "new";
  return `WebRTC ${connection}; ICE ${ice}; policy ${networkConfiguration?.iceTransportPolicy ?? "all"}.`;
}

function setNetworkState(title, detail) {
  if (elements.networkState) elements.networkState.textContent = title;
  if (elements.networkDetail) elements.networkDetail.textContent = detail;
}

function initialDiagnostics() {
  return {
    websocket: "idle",
    approval: "not joined",
    playerSlot: "unassigned",
    transportMode: invite?.transportMode ?? "automatic",
    latencyMode: invite?.latencyMode ?? "quality",
    playoutDelay: "default",
    icePolicy: "all",
    iceServers: "not received",
    rtcConnection: "not started",
    rtcSignaling: "not started",
    iceConnection: "not started",
    iceGathering: "not started",
    signaling: "idle",
    localCandidates: 0,
    remoteCandidates: 0,
    selectedRoute: "not selected",
    inputChannel: "not created",
    input: "waiting",
    inputSampling: "stopped",
    inputPackets: 0,
    lastInputSequence: 0,
    lastInputSentAt: 0,
    lastInputSampleToSendMs: 0,
    video: "waiting",
    audio: "waiting",
    stats: "waiting"
  };
}

function updateDiagnostics(patch) {
  diagnostics = { ...diagnostics, ...patch };
  renderDiagnostics();
}

function renderDiagnostics() {
  if (!elements.diagnosticsList) return;
  const fragment = document.createDocumentFragment();
  for (const [label, value] of diagnosticsRows()) {
    const title = document.createElement("dt");
    title.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = value;
    fragment.append(title, detail);
  }
  elements.diagnosticsList.replaceChildren(fragment);
}

function diagnosticsRows() {
  return [
    ["WebSocket", diagnostics.websocket],
    ["Approval", `${diagnostics.approval}; ${diagnostics.playerSlot}`],
    ["Transport", `${diagnostics.transportMode}; ${diagnostics.latencyMode}; policy ${diagnostics.icePolicy}; ${diagnostics.iceServers}`],
    ["WebRTC", `connection ${diagnostics.rtcConnection}; signaling ${diagnostics.rtcSignaling}; ICE ${diagnostics.iceConnection}; gathering ${diagnostics.iceGathering}`],
    ["Signaling", diagnostics.signaling],
    ["Candidates", `local ${diagnostics.localCandidates}; remote ${diagnostics.remoteCandidates}`],
    ["Selected route", diagnostics.selectedRoute],
    ["Media", `video ${diagnostics.video}; audio ${diagnostics.audio}; playout ${diagnostics.playoutDelay}`],
    ["Input", inputDiagnosticsDetail()],
    ["Stats", diagnostics.stats]
  ];
}

function inputDiagnosticsDetail() {
  if (!diagnostics.lastInputSentAt) return `${diagnostics.input}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; 0 packets`;
  const ageMilliseconds = Math.max(0, Math.round(performance.now() - diagnostics.lastInputSentAt));
  return `${diagnostics.input}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; ${diagnostics.inputPackets} packets; last sequence ${diagnostics.lastInputSequence}; sample-to-send ${diagnostics.lastInputSampleToSendMs} ms; ${ageMilliseconds} ms ago`;
}

async function copyDiagnostics() {
  const text = diagnosticsRows().map(([label, value]) => `${label}: ${value}`).join("\n");
  try {
    await navigator.clipboard.writeText(text);
    if (!elements.copyDiagnosticsButton) return;
    const previous = elements.copyDiagnosticsButton.textContent;
    elements.copyDiagnosticsButton.textContent = "Copied";
    setTimeout(() => { elements.copyDiagnosticsButton.textContent = previous; }, 1_200);
  } catch (error) {
    updateDiagnostics({ stats: `copy failed: ${error.message || "clipboard unavailable"}` });
  }
}

function toggleDiagnostics() {
  if (!elements.diagnosticsPanel || !elements.diagnosticsToggle) return;
  const isOpen = elements.diagnosticsToggle.getAttribute("aria-expanded") === "true";
  elements.diagnosticsToggle.setAttribute("aria-expanded", String(!isOpen));
  elements.diagnosticsPanel.hidden = isOpen;
}

function updatePeerConnectionState() {
  if (!peerConnection) return;
  updateDiagnostics({
    rtcConnection: peerConnection.connectionState ?? "unknown",
    rtcSignaling: peerConnection.signalingState ?? "unknown",
    iceConnection: peerConnection.iceConnectionState ?? "unknown",
    iceGathering: peerConnection.iceGatheringState ?? "unknown"
  });
  setNetworkState(networkLabel(), connectionDetail());
}

function recordInputSent(input, transport, sampledAtMilliseconds = performance.now()) {
  updateDiagnostics({
    input: transport,
    inputPackets: diagnostics.inputPackets + 1,
    lastInputSequence: input.sequenceNumber,
    lastInputSentAt: performance.now(),
    lastInputSampleToSendMs: Math.max(0, Math.round((performance.now() - sampledAtMilliseconds) * 10) / 10)
  });
}

function describeIceServers(servers) {
  const counts = { stun: 0, turn: 0, turns: 0 };
  for (const server of servers) {
    for (const value of iceServerURLs(server)) {
      if (value.startsWith("stun:")) counts.stun += 1;
      if (value.startsWith("turn:")) counts.turn += 1;
      if (value.startsWith("turns:")) counts.turns += 1;
    }
  }
  const parts = [];
  if (counts.stun > 0) parts.push(`${counts.stun} STUN`);
  if (counts.turn > 0) parts.push(`${counts.turn} TURN`);
  if (counts.turns > 0) parts.push(`${counts.turns} TURNS`);
  return parts.length > 0 ? parts.join(", ") : "no ICE servers";
}

function iceServerURLs(server) {
  if (Array.isArray(server.urls)) return server.urls;
  return typeof server.urls === "string" ? [server.urls] : [];
}

function startStatsPolling() {
  if (statsHandle) return;
  samplePeerStats();
  statsHandle = setInterval(samplePeerStats, 1_500);
}

function stopStatsPolling() {
  if (!statsHandle) return;
  clearInterval(statsHandle);
  statsHandle = 0;
}

async function samplePeerStats() {
  if (!peerConnection) return;
  try {
    const report = await peerConnection.getStats();
    updateDiagnostics({
      selectedRoute: selectedRouteFromStats(report),
      stats: inboundStatsSummary(report)
    });
  } catch (error) {
    updateDiagnostics({ stats: `stats failed: ${error.message || "getStats failed"}` });
  }
}

function selectedRouteFromStats(report) {
  let pair = null;
  for (const stats of report.values()) {
    if (stats.type === "transport" && stats.selectedCandidatePairId) {
      pair = report.get(stats.selectedCandidatePairId);
      break;
    }
  }
  if (!pair) {
    for (const stats of report.values()) {
      if (stats.type === "candidate-pair" && (stats.selected || (stats.nominated && stats.state === "succeeded"))) {
        pair = stats;
        break;
      }
    }
  }
  if (!pair) return diagnostics.selectedRoute;
  const local = report.get(pair.localCandidateId);
  const remote = report.get(pair.remoteCandidateId);
  const rtt = typeof pair.currentRoundTripTime === "number" ? `; RTT ${Math.round(pair.currentRoundTripTime * 1_000)} ms` : "";
  return `${candidateSummary(local)} -> ${candidateSummary(remote)}${rtt}`;
}

function candidateSummary(candidate) {
  if (!candidate) return "unknown";
  const type = candidate.candidateType ?? "candidate";
  const protocol = candidate.protocol ? `/${candidate.protocol}` : "";
  const relay = candidate.relayProtocol ? `/${candidate.relayProtocol}` : "";
  return `${type}${protocol}${relay}`;
}

function inboundStatsSummary(report) {
  const parts = [];
  for (const stats of report.values()) {
    if (stats.type !== "inbound-rtp" || stats.isRemote) continue;
    const kind = stats.kind ?? stats.mediaType;
    if (kind === "video") parts.push(videoStatsSummary(stats));
    if (kind === "audio") parts.push(audioStatsSummary(stats));
  }
  return parts.length > 0 ? parts.join("; ") : diagnostics.stats;
}

function videoStatsSummary(stats) {
  const size = stats.frameWidth && stats.frameHeight ? `${stats.frameWidth}x${stats.frameHeight}` : "size pending";
  const fps = typeof stats.framesPerSecond === "number" ? `${Math.round(stats.framesPerSecond)} fps` : "fps pending";
  const loss = stats.packetsLost > 0 ? `, ${stats.packetsLost} lost` : "";
  const jitterFrames = stats.jitterBufferEmittedCount ?? 0;
  const jitterDelay = jitterFrames > 0 && typeof stats.jitterBufferDelay === "number" ? `, jitter buffer ${Math.round((stats.jitterBufferDelay / jitterFrames) * 1_000)} ms` : "";
  const decodedFrames = stats.framesDecoded ?? 0;
  const decodeDelay = decodedFrames > 0 && typeof stats.totalDecodeTime === "number" ? `, decode ${Math.round((stats.totalDecodeTime / decodedFrames) * 1_000)} ms` : "";
  const dropped = stats.framesDropped > 0 ? `, ${stats.framesDropped} dropped` : "";
  return `video ${size} ${fps}, ${formatBytes(stats.bytesReceived ?? 0)} received${loss}${dropped}${jitterDelay}${decodeDelay}`;
}

function audioStatsSummary(stats) {
  const jitter = typeof stats.jitter === "number" ? `, jitter ${Math.round(stats.jitter * 1_000)} ms` : "";
  const loss = stats.packetsLost > 0 ? `, ${stats.packetsLost} lost` : "";
  return `audio ${formatBytes(stats.bytesReceived ?? 0)} received${jitter}${loss}`;
}

function latencyMode() {
  return networkConfiguration?.latencyMode ?? invite?.latencyMode ?? "quality";
}

function configureReceiverLatency(receiver) {
  if (!receiver || latencyMode() !== "lowLatency") return;
  try {
    if ("playoutDelayHint" in receiver) {
      receiver.playoutDelayHint = 0;
      updateDiagnostics({ playoutDelay: "0 ms hint" });
    } else {
      updateDiagnostics({ playoutDelay: "unsupported" });
    }
  } catch (error) {
    updateDiagnostics({ playoutDelay: `hint failed: ${error.message || "unavailable"}` });
  }
}

function formatBytes(value) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)} MB`;
  if (value >= 1_000) return `${Math.round(value / 1_000)} KB`;
  return `${value} B`;
}

function updateMediaDiagnostics(track, media, state) {
  const descriptor = track.kind === "video" ? videoDescriptor(media, state) : audioDescriptor(track, state);
  updateDiagnostics(track.kind === "video" ? { video: descriptor } : { audio: descriptor });
}

function videoDescriptor(media, state) {
  const size = media.videoWidth && media.videoHeight ? ` ${media.videoWidth}x${media.videoHeight}` : "";
  return `${state}${size}`;
}

function audioDescriptor(track, state) {
  return `${state}; ${track.readyState}`;
}

function attachRemoteTrack(track, receiver) {
  configureReceiverLatency(receiver);
  const media = track.kind === "audio" ? remoteAudioElement() : remoteVideoElement();
  media.autoplay = true;
  media.playsInline = true;
  media.controls = false;
  media.muted = track.kind === "video";
  const stream = appendTrack(media.srcObject, track);
  if (media.srcObject !== stream) media.srcObject = stream;
  updateMediaDiagnostics(track, media, "attached");
  track.addEventListener("mute", () => updateMediaDiagnostics(track, media, "muted"));
  track.addEventListener("unmute", () => updateMediaDiagnostics(track, media, "live"));
  track.addEventListener("ended", () => updateMediaDiagnostics(track, media, "ended"));
  media.addEventListener("loadedmetadata", () => {
    updateMediaDiagnostics(track, media, "metadata loaded");
    requestMediaPlayback(track, media);
  });
  media.addEventListener("canplay", () => requestMediaPlayback(track, media));
  media.addEventListener("playing", () => updateMediaDiagnostics(track, media, "playing"));
  requestMediaPlayback(track, media);
}

function requestMediaPlayback(track, media, attempt = 0) {
  if (!media.play || (!media.paused && !media.ended) || playbackPromises.has(media)) return;
  const playback = media.play();
  if (!playback) return;
  playbackPromises.set(media, playback);
  playback.then(() => {
    if (playbackPromises.get(media) === playback) playbackPromises.delete(media);
    updateMediaDiagnostics(track, media, "playing");
  }).catch(error => {
    if (playbackPromises.get(media) === playback) playbackPromises.delete(media);
    const message = error?.message || "user gesture required";
    if (error?.name === "AbortError" && attempt < 5) {
      updateMediaDiagnostics(track, media, `play retry ${attempt + 1}: ${message}`);
      window.setTimeout(() => requestMediaPlayback(track, media, attempt + 1), 120 * (attempt + 1));
      return;
    }
    const prefix = error?.name === "NotAllowedError" ? "autoplay blocked" : "playback failed";
    updateMediaDiagnostics(track, media, `${prefix}: ${message}`);
  });
}

function remoteVideoElement() {
  const existing = document.querySelector("#remote-video");
  if (existing) return existing;
  const media = document.createElement("video");
  media.id = "remote-video";
  const container = document.querySelector(".video-placeholder");
  container?.classList.add("streaming");
  container?.replaceChildren(media);
  return media;
}

function remoteAudioElement() {
  const existing = document.querySelector("#remote-audio");
  if (existing) return existing;
  const media = document.createElement("audio");
  media.id = "remote-audio";
  document.body.append(media);
  return media;
}

function appendTrack(currentObject, track) {
  const mediaStream = currentObject instanceof MediaStream ? currentObject : new MediaStream();
  if (!mediaStream.getTracks().some(existing => existing.id === track.id)) mediaStream.addTrack(track);
  return mediaStream;
}

function disconnect(notifyHost = true) {
  approved = false;
  stopPolling();
  closePeerConnection();
  if (notifyHost && socket?.readyState === WebSocket.OPEN) send({ kind: "guestDisconnected", roomID: invite?.inviteID, participantID });
  socket?.close();
  socket = null;
}

function setState(title, detail, connected, playerNumber = null) {
  sessionState = title;
  if (elements.state) elements.state.textContent = title;
  if (elements.detail) elements.detail.textContent = detail;
  elements.dot?.classList.toggle("connected", connected);
  if (!elements.state && elements.networkState && elements.networkDetail) {
    elements.networkState.textContent = title;
    elements.networkDetail.textContent = detail;
  }
  updatePlayerBadge(title, playerNumber);
}

function hasTerminalState() {
  return ["Ended", "Rejected", "Removed"].includes(sessionState);
}

function updatePlayerBadge(state, playerNumber = null) {
  if (!elements.playerBadge || !elements.playerNumber) return;
  if (Number.isInteger(playerNumber)) {
    elements.playerNumber.textContent = `P${playerNumber}`;
    elements.playerBadge.setAttribute("aria-label", `Controller player ${playerNumber}`);
    return;
  }
  if (["Rejected", "Removed", "Ended", "Disconnected"].includes(state)) {
    elements.playerNumber.textContent = "!";
    elements.playerBadge.setAttribute("aria-label", state);
    return;
  }
  elements.playerNumber.textContent = "P?";
  elements.playerBadge.setAttribute("aria-label", "Waiting for controller assignment");
}

function displayName() {
  const value = elements.displayName.value.trim();
  return value.length > 0 ? value : "Guest";
}

function createParticipantID() {
  const cryptoProvider = globalThis.crypto;
  if (typeof cryptoProvider?.randomUUID === "function") return cryptoProvider.randomUUID();

  const bytes = new Uint8Array(16);
  if (typeof cryptoProvider?.getRandomValues === "function") {
    cryptoProvider.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  return Array.from(bytes, (byte, index) => {
    const value = byte.toString(16).padStart(2, "0");
    return [4, 6, 8, 10].includes(index) ? `-${value}` : value;
  }).join("");
}

function signalingEndpoint() {
  if (serverFromURL) return serverFromURL;
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/remote-coop`;
}

function decodeInvite(token) {
  const payload = token.trim().split(".")[0];
  if (!payload) return null;
  try {
    return JSON.parse(new TextDecoder().decode(base64URLDecode(payload)));
  } catch {
    return null;
  }
}

function base64URLDecode(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(value.length + (4 - (value.length % 4 || 4)), "=");
  return Uint8Array.from(atob(base64), character => character.charCodeAt(0));
}
