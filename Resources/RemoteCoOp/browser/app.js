const elements = {
  title: document.querySelector("#title"),
  subtitle: document.querySelector("#subtitle"),
  joinCard: document.querySelector("#join-card"),
  sessionCard: document.querySelector("#session-card"),
  inviteCode: document.querySelector("#invite-code"),
  inviteSource: document.querySelector("#invite-source"),
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
  controllerGate: document.querySelector("#controller-gate"),
  connectionNotice: document.querySelector("#connection-notice"),
  connectionNoticeTitle: document.querySelector("#connection-notice-title"),
  connectionNoticeBody: document.querySelector("#connection-notice-body"),
  connectionNoticeHint: document.querySelector("#connection-notice-hint"),
  controllerGateTitle: document.querySelector("#controller-gate-title"),
  controllerGateBody: document.querySelector("#controller-gate-body"),
  playerNumber: document.querySelector("#player-number"),
  disconnectButton: document.querySelector("#disconnect-button")
};

const url = new URL(window.location.href);
const inviteFromURL = url.searchParams.get("invite") ?? "";
let inviteToken = inviteFromURL.trim();
const serverFromURL = url.searchParams.get("server") ?? "";
let transport = null;
let invite = parseInvite(inviteToken);
const participantID = createParticipantID();
let approved = false;
let sequenceNumber = 0;
let lastSentState = "";
let lastSentAt = 0;
let lastInputChangedAt = 0;
let inputHistory = [];
let pollHandle = null;
let pollMode = "stopped";
let networkConfiguration = null;
let peerConnection = null;
let inputChannel = null;
let statsHandle = 0;
let diagnostics = initialDiagnostics();
let sessionState = "Connecting";
/// Whether a pad has been seen this session. The Gamepad API reports nothing until a button is
/// pressed, so "not detected" is the normal opening state rather than an error.
let controllerDetected = false;
/// Reconnect state. `participantID` is deliberately *not* regenerated across a reconnect: the host
/// holds the slot and the approval for a returning guest that names the same ID.
let reconnectAttempt = 0;
let reconnectHandle = null;
/// Set while the guest is deliberately leaving, so an intentional close is not retried.
let leaving = false;
/// Set once ICE has definitively failed or given up, so the page stops implying it is still trying.
let connectionFailure = null;
let iceDeadlineHandle = null;
/// Previous inbound-video sample, so the stats line can report the *recent* jitter buffer depth.
///
/// `jitterBufferDelay` and `jitterBufferEmittedCount` are both cumulative since the session began,
/// so dividing them gives a lifetime average: a bad first few seconds inflates it permanently, and
/// two readings taken at different points in a session are not comparable. That made the number
/// useless for telling whether a change helped. The delta between samples is the real current depth.
let previousVideoStats = null;
const playbackPromises = new WeakMap();

renderInvite(inviteToken);
renderDiagnostics();
if (inviteFromURL && elements.inviteCode) elements.inviteCode.readOnly = true;

elements.inviteCode?.addEventListener("input", () => {
  if (!inviteFromURL) normalizeInviteCodeInput();
  renderInvite(currentInviteToken());
});
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
  if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Ready";
  updateDiagnostics({ input: "controller connected" });
  setControllerDetected(true, event.gamepad.id);
});
window.addEventListener("gamepaddisconnected", () => {
  if (elements.gamepadName) elements.gamepadName.textContent = "Controller";
  if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Waiting";
  updateDiagnostics({ input: "controller disconnected" });
  setControllerDetected(false);
});
window.addEventListener("pagehide", disconnect);
document.addEventListener("visibilitychange", restartPollingIfActive);

function renderInvite(token) {
  invite = parseInvite(token);
  if (!invite) {
    if (elements.title) elements.title.textContent = "CO-OP";
    if (elements.subtitle) elements.subtitle.textContent = "Enter an invite code and join.";
    if (elements.inviteSource) elements.inviteSource.textContent = inviteFromURL ? "INVALID" : "REMOTE CO-OP";
    if (elements.networkState) elements.networkState.textContent = "CODE";
    if (elements.networkDetail) elements.networkDetail.textContent = "Automatic";
    elements.joinStatus.textContent = token ? "Invalid" : "Code required";
    elements.joinButton.disabled = true;
    return;
  }
  inviteToken = token.trim();
  const visibleInviteToken = inviteFromURL ? invite.code ?? "LINK" : displayInviteToken(inviteToken);
  if (elements.inviteCode && elements.inviteCode.value.trim() !== visibleInviteToken) {
    elements.inviteCode.value = visibleInviteToken;
  }
  const roomLabel = invite.code ?? invite.inviteID ?? "ready";
  if (elements.title) elements.title.textContent = "CO-OP";
  if (elements.subtitle) elements.subtitle.textContent = `Room ${roomLabel}.`;
  if (elements.inviteSource) elements.inviteSource.textContent = inviteFromURL ? "LINK" : "READY";
  if (elements.networkState) elements.networkState.textContent = "READY";
  if (elements.networkDetail) elements.networkDetail.textContent = networkModeLabel(invite.transportMode);
  elements.joinStatus.textContent = "Ready";
  elements.joinButton.disabled = false;
}

function joinRoom() {
  leaving = false;
  reconnectAttempt = 0;
  connectToRoom();
}

/// Opens signaling. Called for the first join and for every reconnect, so it must not reset
/// anything the host uses to recognise a returning guest.
///
/// Which transport is a property of the invite, not a guest choice: `signalingKind` says whether
/// this invite points at the host's own embedded server or at a hosted channel, and the two are made
/// to present an identical interface below so nothing past this function has to know which one is
/// live.
function connectToRoom() {
  clearReconnectTimer();
  inviteToken = currentInviteToken();
  invite = parseInvite(inviteToken);
  if (!invite) {
    elements.joinStatus.textContent = "Invalid";
    elements.joinButton.disabled = true;
    return;
  }
  if (invite.expiresAtEpochSeconds * 1000 <= Date.now()) {
    elements.joinStatus.textContent = "Expired";
    stopReconnecting();
    return;
  }
  resetInputHistory();
  // The peer connection does not survive a signaling drop: the host tears its side down and offers
  // a fresh one on rejoin, so a stale one here would leave two half-open peers.
  closePeerConnection();
  connectionFailure = null;
  previousVideoStats = null;
  renderConnectionNotice();
  const isRetry = reconnectAttempt > 0;
  diagnostics = initialDiagnostics();
  const usesHostedSignaling = invite.signalingKind === "hosted" && invite.signalingChannel && invite.signalingToken;
  updateDiagnostics({
    websocket: `${isRetry ? `reconnecting (attempt ${reconnectAttempt})` : "connecting"} ${usesHostedSignaling ? "hosted channel" : signalingEndpoint()}`,
    transportMode: invite.transportMode ?? "automatic"
  });
  elements.joinButton.disabled = true;
  elements.joinStatus.textContent = "Connecting";

  const callbacks = {
    onOpen: () => {
      updateDiagnostics({ websocket: "open" });
      send({
        kind: "guestJoinRequested",
        roomID: inviteRoomID(),
        participantID,
        inviteToken,
        displayName: displayName()
      });
      elements.joinCard.classList.add("hidden");
      elements.sessionCard.classList.remove("hidden");
      setState("Waiting", "Host", false);
    },
    onMessage: text => {
      let message;
      try {
        message = JSON.parse(text);
      } catch (error) {
        updateDiagnostics({ websocket: "invalid message" });
        setNetworkState("Error", "Broker");
        return;
      }
      handleMessage(message).catch(error => {
        setNetworkState("Error", "Peer");
        updateDiagnostics({ signaling: error.message || "WebRTC negotiation failed" });
      });
    },
    onClose: () => {
      stopPolling();
      updateDiagnostics({ websocket: "closed" });
      elements.joinButton.disabled = false;
      // A terminal state means the host ejected the guest or ended the invite; retrying would just
      // be refused. Leaving is the guest's own choice. Everything else is a blip worth retrying.
      if (hasTerminalState() || leaving) {
        setState(sessionState === "Connecting" ? "Closed" : sessionState, "Offline", false);
        return;
      }
      scheduleReconnect();
    },
    onError: () => updateDiagnostics({ websocket: "error" })
  };

  transport = usesHostedSignaling
    ? openAblyTransport(invite.signalingChannel, invite.signalingToken, callbacks)
    : openWebSocketTransport(signalingEndpoint(), callbacks);
}

/// A raw WebSocket, wrapped to the same four-method shape the hosted transport presents.
function openWebSocketTransport(url, { onOpen, onMessage, onClose, onError }) {
  const socket = new WebSocket(url);
  socket.addEventListener("open", onOpen);
  socket.addEventListener("message", event => onMessage(event.data));
  socket.addEventListener("close", onClose);
  socket.addEventListener("error", () => onError?.());
  return {
    isOpen: () => socket.readyState === WebSocket.OPEN,
    send: text => {
      if (socket.readyState === WebSocket.OPEN) socket.send(text);
    },
    close: () => socket.close()
  };
}

/// An Ably channel, wrapped to the same shape.
///
/// The two directions of one invite's traffic share a channel, separated by message name rather
/// than by relying on `echoMessages: false` alone - which is also set, but the separation does not
/// depend on it holding.
///
/// `clientId` is set to this guest's own participant ID, which the host-minted token permits any
/// holder to claim (a wildcard `x-ably-clientId`, not one bound to this specific guest). That is a
/// narrower guarantee than a socket connection's identity, and it is why the host's authorisation
/// gate treats a hosted sender's claim as assertion rather than proof - the real gate is the signed
/// invite and host approval, which this credential does not bypass. Impersonating a specific guest
/// still requires knowing their participant ID, a value never exposed outside that guest's own
/// session.
function openAblyTransport(channelName, token, { onOpen, onMessage, onClose, onError }) {
  const realtime = new Ably.Realtime({ token, clientId: participantID, echoMessages: false });
  const channel = realtime.channels.get(channelName);
  let opened = false;

  channel.subscribe("host", message => {
    if (typeof message.data === "string") onMessage(message.data);
  });
  // Queued by the SDK until the channel attaches, so this does not have to wait for "connected".
  channel.presence.enter().catch(error => updateDiagnostics({ websocket: `presence: ${error.message}` }));

  realtime.connection.on("connected", () => {
    if (opened) return;
    opened = true;
    onOpen();
  });
  realtime.connection.on(["failed", "suspended", "closed"], () => onClose());
  realtime.connection.on("failed", stateChange => {
    onError?.();
    if (stateChange.reason) updateDiagnostics({ websocket: `hosted signaling: ${stateChange.reason.message}` });
  });

  return {
    isOpen: () => realtime.connection.state === "connected",
    send: text => channel.publish("guest", text),
    close: () => {
      channel.presence.leave().catch(() => {});
      realtime.close();
    }
  };
}

async function handleMessage(message) {
  if (message.kind === "heartbeat") {
    if (message.roomID && invite) invite.inviteID = message.roomID;
    send({ kind: "heartbeat", roomID: inviteRoomID(), participantID });
    return;
  }
  if (message.kind === "networkConfiguration") {
    if (message.roomID && invite) invite.inviteID = message.roomID;
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
      // Back in the room with the slot intact, so the next drop starts its backoff from scratch.
      stopReconnecting();
      const playerNumber = (message.participant.playerIndex ?? 1) + 1;
      setState("Approved", `P${playerNumber}`, true, playerNumber);
      updateDiagnostics({ approval: "approved", playerSlot: `player ${playerNumber}` });
      startPolling();
    } else {
      setState("Waiting", "Host", false);
      updateDiagnostics({ approval: "waiting" });
    }
    return;
  }
  if (message.kind === "participantRemoved") {
    if (!isForThisParticipant(message)) return;
    setState("Removed", "Host", false);
    updateDiagnostics({ approval: "removed" });
    disconnect();
    return;
  }
  if (message.kind === "guestRejected") {
    if (!isForThisParticipant(message)) return;
    setState("Rejected", message.reason ?? "Host", false);
    updateDiagnostics({ approval: `rejected: ${message.reason ?? "host rejected join"}` });
    disconnect(false);
    return;
  }
  if (message.kind === "inputRejected") {
    if (!isForThisParticipant(message)) return;
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Rejected";
    updateDiagnostics({ input: `rejected: ${message.inputRejection ?? "unknown"}` });
    return;
  }
  if (message.kind === "inviteEnded") {
    setState("Ended", message.reason ?? "Host", false);
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
    if (!approved || !transport?.isOpen()) return;
    const gamepad = navigator.getGamepads().find(Boolean);
    if (!gamepad) {
      if (elements.gamepadName) elements.gamepadName.textContent = "Controller";
      if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Waiting";
      // `gamepadconnected` does not fire in every browser until a button is pressed, and a pad can
      // also drop out mid-session, so the gate is driven from the poll rather than from the event
      // alone.
      setControllerDetected(false);
      return;
    }
    if (elements.gamepadName) elements.gamepadName.textContent = gamepad.id;
    setControllerDetected(true, gamepad.id);
    const input = inputPacket(gamepad, time);
    const state = inputStateKey(input);
    const changed = state !== lastSentState;
    if (changed) lastInputChangedAt = time;
    if (!changed && !shouldSendUnchangedInput(time)) return;
    lastSentState = state;
    lastSentAt = time;
    sendInput(input);
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Live";
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

function shouldSendUnchangedInput(time) {
  if (latencyMode() !== "lowLatency") return time - lastSentAt >= 250;
  if (time - lastInputChangedAt <= inputRecoveryWindowMilliseconds()) return true;
  // Low latency had the recovery burst and nothing after it, so once a state went unchanged past
  // the window a single lost packet on the unreliable channel held that input at the host forever.
  // The native guest's redundancy policy already resends on this interval.
  return time - lastSentAt >= keepaliveIntervalMilliseconds();
}

function keepaliveIntervalMilliseconds() {
  return 100;
}

function inputHistoryLimit() {
  return latencyMode() === "lowLatency" ? 8 : 1;
}

function inputRecoveryWindowMilliseconds() {
  return 96;
}

function inputPacket(gamepad, sampledAtMilliseconds = performance.now()) {
  return {
    participantID,
    sequenceNumber: ++sequenceNumber,
    buttons: buttonMask(gamepad),
    leftTrigger: analogButton(gamepad, 6),
    rightTrigger: analogButton(gamepad, 7),
    leftStickX: axis(gamepad, 0),
    leftStickY: verticalAxis(gamepad, 1),
    rightStickX: axis(gamepad, 2),
    rightStickY: verticalAxis(gamepad, 3),
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

/// A vertical stick axis, converted to the convention the rest of the pipeline uses.
///
/// The Gamepad API reports vertical axes with **down positive** (W3C: -1 is up). Everything this
/// feeds is **up positive**: the host's own pad comes from GameController's
/// `thumbstick.yAxis.value`, and the wire format is XInput's, where +32767 is up. Both meet in
/// `GamepadState.leftStickY`, so passing the browser's value through unchanged inverted vertical
/// aim for every guest while the host's own stick behaved correctly.
///
/// Converted here rather than on the host, because the host cannot tell which convention a packet
/// came from - `GamepadState` has one meaning and this is the edge that has to honour it.
function verticalAxis(gamepad, index) {
  // `0 - x` rather than `-x`, so a centred stick reports 0 instead of -0. Both serialise to 0 on
  // the wire, but -0 shows up in change-detection keys and diffs as a value that looks wrong.
  return clamp(0 - (gamepad.axes[index] ?? 0), -1, 1);
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, Number.isFinite(value) ? value : 0));
}

function send(message) {
  if (!transport?.isOpen()) return;
  transport.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
}

function sendInput(input) {
  const sampledAtMilliseconds = input.sampledAtMilliseconds ?? performance.now();
  const wireInput = { ...input };
  delete wireInput.sampledAtMilliseconds;
  pushInputHistory(wireInput);
  const message = { kind: "guestInput", roomID: inviteRoomID(), participantID, input: wireInput, inputs: inputHistory };
  if (inputChannel?.readyState === "open") {
    inputChannel.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
    recordInputSent(input, "data channel", sampledAtMilliseconds);
    return;
  }
  if (networkConfiguration?.websocketInputFallbackEnabled !== false && latencyMode() !== "lowLatency") {
    send({ kind: "guestInput", roomID: inviteRoomID(), participantID, input: wireInput });
    recordInputSent(input, "WebSocket fallback", sampledAtMilliseconds);
  } else {
    updateDiagnostics({ input: "blocked: waiting for low latency data channel" });
  }
}

function pushInputHistory(input) {
  inputHistory.push(input);
  inputHistory = inputHistory.slice(-inputHistoryLimit());
}

function resetInputHistory() {
  sequenceNumber = 0;
  lastSentState = "";
  lastSentAt = 0;
  lastInputChangedAt = 0;
  inputHistory = [];
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
      roomID: inviteRoomID(),
      participantID,
      peerSignal: {
        kind: "iceCandidate",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex
      }
    });
  });
  startICEDeadline();
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
    send({ kind: "peerSignal", roomID: inviteRoomID(), participantID, peerSignal: { kind: "answer", sdp: answer.sdp } });
    setNetworkState(networkLabel(), "ICE");
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
    setNetworkState(networkLabel(), "Fallback");
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
  const mode = invite?.latencyMode ?? "quality";
  return {
    transportMode: invite?.transportMode ?? "automatic",
    iceTransportPolicy: invite?.transportMode === "relayOnly" ? "relay" : "all",
    latencyMode: mode,
    iceServers: [],
    dataChannelInputEnabled: true,
    websocketInputFallbackEnabled: mode !== "lowLatency",
    directPeerCandidateWarning: "Using invite defaults until the broker provides ICE settings."
  };
}

function networkLabel() {
  const mode = networkConfiguration?.transportMode ?? invite?.transportMode ?? "automatic";
  if (mode === "relayOnly") return "Relay";
  if (mode === "directOnly") return "Direct";
  return "Auto";
}

function connectionDetail() {
  const connection = peerConnection?.connectionState ?? "new";
  const ice = peerConnection?.iceConnectionState ?? "new";
  return `${connection}/${ice}`;
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
    controller: "not detected",
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
  // The controller state is part of this line because it is the usual answer to "the channel is
  // open and nothing is arriving": guest input is gamepad-only, and a browser reports no pad at all
  // until a button is pressed.
  if (!diagnostics.lastInputSentAt) return `${diagnostics.input}; controller ${diagnostics.controller}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; 0 packets`;
  const ageMilliseconds = Math.max(0, Math.round(performance.now() - diagnostics.lastInputSentAt));
  return `${diagnostics.input}; controller ${diagnostics.controller}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; ${diagnostics.inputPackets} packets; last sequence ${diagnostics.lastInputSequence}; sample-to-send ${diagnostics.lastInputSampleToSendMs} ms; ${ageMilliseconds} ms ago`;
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
  const iceState = peerConnection.iceConnectionState ?? "unknown";
  updateDiagnostics({
    rtcConnection: peerConnection.connectionState ?? "unknown",
    rtcSignaling: peerConnection.signalingState ?? "unknown",
    iceConnection: iceState,
    iceGathering: peerConnection.iceGatheringState ?? "unknown"
  });
  if (iceState === "connected" || iceState === "completed") {
    clearConnectionFailure();
  } else if (iceState === "failed" || peerConnection.connectionState === "failed") {
    // Terminal. `disconnected` is deliberately not treated this way: ICE recovers from it on its
    // own, and reporting a failure there would cry wolf on every brief network blip.
    reportConnectionFailure("failed");
  }
  setNetworkState(networkLabel(), connectionDetail());
}

/// How long to let ICE work before calling it. Generous: a LAN pair connects in well under a second
/// and a STUN-assisted pair across the internet usually inside a few seconds, so anything still
/// trying at this point is not going to succeed.
const ICE_DEADLINE_MS = 25_000;

function startICEDeadline() {
  clearICEDeadline();
  iceDeadlineHandle = window.setTimeout(() => {
    iceDeadlineHandle = null;
    const state = peerConnection?.iceConnectionState;
    if (state === "connected" || state === "completed") return;
    // Not a browser-reported failure: ICE will keep saying "checking" indefinitely when no candidate
    // pair can be validated, which is exactly the case a host with no relay cannot fix.
    reportConnectionFailure("timeout");
  }, ICE_DEADLINE_MS);
}

function clearICEDeadline() {
  if (!iceDeadlineHandle) return;
  window.clearTimeout(iceDeadlineHandle);
  iceDeadlineHandle = null;
}

function reportConnectionFailure(reason) {
  if (connectionFailure) return;
  connectionFailure = reason;
  clearICEDeadline();
  updateDiagnostics({ signaling: `no network route (${reason})` });
  renderConnectionNotice();
}

function clearConnectionFailure() {
  clearICEDeadline();
  if (!connectionFailure) return;
  connectionFailure = null;
  previousVideoStats = null;
  renderConnectionNotice();
}

/// Explains the outcome and names the one thing that would change it.
///
/// Worth being specific: with no TURN relay in the picture, "no route" is a property of the two
/// networks rather than something the guest can retry their way out of. Telling them to reload would
/// waste their time.
function renderConnectionNotice() {
  if (!elements.connectionNotice) return;
  const show = Boolean(connectionFailure) && !hasTerminalState();
  elements.connectionNotice.classList.toggle("hidden", !show);
  if (!show) {
    renderControllerGate();
    return;
  }
  const localOnly = (networkConfiguration?.iceServers ?? []).length === 0;
  if (elements.connectionNoticeTitle) {
    elements.connectionNoticeTitle.textContent = connectionFailure === "timeout" ? "No route found" : "Connection failed";
  }
  if (elements.connectionNoticeBody) {
    elements.connectionNoticeBody.textContent = localOnly
      ? "This session only accepts guests on the host's own network."
      : "Your device and the host could not find a network path to each other.";
  }
  if (elements.connectionNoticeHint) {
    elements.connectionNoticeHint.textContent = localOnly
      ? "Join from the same network as the host, or ask them to switch Transport to Auto."
      : "Ask the host to run a tunnel, or try a different network. Some routers cannot connect directly to each other.";
  }
  // The controller prompt is irrelevant when there is nothing to send input over.
  elements.controllerGate?.classList.add("hidden");
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

function currentInviteToken() {
  if (inviteFromURL) return inviteFromURL.trim();
  return elements.inviteCode?.value.trim().toUpperCase() ?? "";
}

function normalizeInviteCodeInput() {
  if (!elements.inviteCode) return;
  const normalized = elements.inviteCode.value.toUpperCase().replace(/[^A-Z0-9.\-_]/g, "");
  if (elements.inviteCode.value !== normalized) elements.inviteCode.value = normalized;
}

function displayInviteToken(token) {
  const trimmed = token.trim();
  return /^[A-Z0-9]{6}$/i.test(trimmed) ? trimmed.toUpperCase() : trimmed;
}

function networkModeLabel(mode) {
  if (mode === "relayOnly") return "Relay";
  if (mode === "directOnly") return "Direct";
  return "Auto";
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
  // The Media line records the element's size at playback start and never updated, so it kept
  // reporting the first ramp-up frame (480x270) while the stream had long since reached full size.
  if (stats.frameWidth && stats.frameHeight) {
    updateDiagnostics({ video: `playing ${stats.frameWidth}x${stats.frameHeight}` });
  }
  const fps = typeof stats.framesPerSecond === "number" ? `${Math.round(stats.framesPerSecond)} fps` : "fps pending";
  const loss = stats.packetsLost > 0 ? `, ${stats.packetsLost} lost` : "";
  const jitterDelay = windowedAverageMs(stats, previousVideoStats, "jitterBufferDelay", "jitterBufferEmittedCount");
  const decodeDelay = windowedAverageMs(stats, previousVideoStats, "totalDecodeTime", "framesDecoded");
  const dropped = stats.framesDropped > 0 ? `, ${stats.framesDropped} dropped` : "";
  previousVideoStats = {
    jitterBufferDelay: stats.jitterBufferDelay,
    jitterBufferEmittedCount: stats.jitterBufferEmittedCount,
    totalDecodeTime: stats.totalDecodeTime,
    framesDecoded: stats.framesDecoded
  };
  const jitter = jitterDelay === null ? "" : `, jitter buffer ${jitterDelay} ms`;
  const decode = decodeDelay === null ? "" : `, decode ${decodeDelay} ms`;
  return `video ${size} ${fps}, ${formatBytes(stats.bytesReceived ?? 0)} received${loss}${dropped}${jitter}${decode}`;
}

/// Average over the interval between two samples, in milliseconds.
///
/// WebRTC exposes these as cumulative totals, so the only way to see a *current* value is to divide
/// the change in one by the change in the other. Falls back to the lifetime average for the very
/// first sample, when there is no previous reading to difference against.
function windowedAverageMs(stats, previous, totalKey, countKey) {
  const total = stats[totalKey];
  const count = stats[countKey];
  if (typeof total !== "number" || typeof count !== "number") return null;
  if (previous && typeof previous[totalKey] === "number" && typeof previous[countKey] === "number") {
    const deltaCount = count - previous[countKey];
    const deltaTotal = total - previous[totalKey];
    // A zero delta means nothing was emitted this interval; the previous figure is the best answer.
    if (deltaCount > 0) return Math.round((deltaTotal / deltaCount) * 1_000);
  }
  if (count > 0) return Math.round((total / count) * 1_000);
  return null;
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
    // Two APIs for the same intent, because neither is universal. `jitterBufferTarget` is the
    // standards-track one and is what current Chrome actually honours; `playoutDelayHint` is the
    // older non-standard property. Setting both is how a page asks every engine for the shallowest
    // buffer it will accept, which is what a low-latency game stream wants - the buffer exists to
    // smooth a lossy WAN, and this session is a LAN with single-digit RTT.
    //
    // Neither is a guarantee: the buffer still grows when frames arrive irregularly, so a value
    // above the target means the *sender* is pacing unevenly rather than the request being ignored.
    const applied = [];
    if ("jitterBufferTarget" in receiver) {
      receiver.jitterBufferTarget = 0;
      applied.push("0 ms target");
    }
    if ("playoutDelayHint" in receiver) {
      receiver.playoutDelayHint = 0;
      applied.push("0 ms hint");
    }
    updateDiagnostics({ playoutDelay: applied.length > 0 ? applied.join(" + ") : "unsupported" });
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
  leaving = true;
  stopReconnecting();
  clearICEDeadline();
  approved = false;
  stopPolling();
  resetInputHistory();
  closePeerConnection();
  if (notifyHost && transport?.isOpen()) send({ kind: "guestDisconnected", roomID: inviteRoomID(), participantID });
  transport?.close();
  transport = null;
}

/// Backoff schedule in milliseconds, then give up.
///
/// Front-loaded because the common case is a Wi-Fi roam that resolves in under a second, and the
/// host holds the slot for 45 seconds - so there is no value in still trying after that.
const RECONNECT_DELAYS_MS = [400, 800, 1_500, 3_000, 5_000, 8_000, 12_000];

function scheduleReconnect() {
  if (reconnectHandle) return;
  if (reconnectAttempt >= RECONNECT_DELAYS_MS.length) {
    setState("Disconnected", "Reload to rejoin", false);
    updateDiagnostics({ websocket: "gave up reconnecting" });
    return;
  }
  const delay = RECONNECT_DELAYS_MS[reconnectAttempt];
  reconnectAttempt += 1;
  setState("Reconnecting", `Attempt ${reconnectAttempt}`, false);
  updateDiagnostics({ websocket: `reconnecting in ${delay} ms` });
  reconnectHandle = window.setTimeout(() => {
    reconnectHandle = null;
    connectToRoom();
  }, delay);
}

function clearReconnectTimer() {
  if (!reconnectHandle) return;
  window.clearTimeout(reconnectHandle);
  reconnectHandle = null;
}

function stopReconnecting() {
  clearReconnectTimer();
  reconnectAttempt = 0;
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
  renderConnectionNotice();
  renderControllerGate();
}

/// Shows or hides the controller prompt.
///
/// Only meaningful once approved: before that the guest is waiting on the host, and a "press any
/// button" prompt would be pointing at the wrong thing.
function setControllerDetected(detected, name = "") {
  const changed = controllerDetected !== detected;
  controllerDetected = detected;
  if (changed) {
    updateDiagnostics({ controller: detected ? `detected: ${name || "controller"}` : "not detected" });
  }
  renderControllerGate();
}

function renderControllerGate() {
  if (!elements.controllerGate) return;
  const shouldShow = approved && !controllerDetected && !hasTerminalState() && !connectionFailure;
  elements.controllerGate.classList.toggle("hidden", !shouldShow);
  elements.controllerGate.classList.toggle("is-detected", controllerDetected);
  if (!shouldShow) return;
  if (elements.controllerGateTitle) elements.controllerGateTitle.textContent = "Press any button";
  if (elements.controllerGateBody) {
    elements.controllerGateBody.textContent = "Your browser only sees a controller once you press one of its buttons.";
  }
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

/// Stable for the lifetime of this tab, reload included.
///
/// The host holds a departing guest's slot, approval and player number against their participant ID
/// for a grace period, so a page that minted a fresh one on every load came back as a stranger and
/// was refused for having no free slot - after the page itself told them to reload to rejoin.
const PARTICIPANT_ID_STORAGE_KEY = "opennow.remote-coop.participantID";

function createParticipantID() {
  try {
    const stored = window.sessionStorage.getItem(PARTICIPANT_ID_STORAGE_KEY);
    if (stored) return stored;
  } catch {}
  const generated = generateParticipantID();
  try {
    window.sessionStorage.setItem(PARTICIPANT_ID_STORAGE_KEY, generated);
  } catch {}
  return generated;
}

function generateParticipantID() {
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
  const override = signalingOverride(serverFromURL);
  if (override) return override;
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/remote-coop`;
}

/// The `server` query parameter, accepted only when it cannot downgrade the connection.
///
/// The join request carries the signed invite token, so a link whose `server` pointed at a
/// plaintext socket handed that token - and every input packet after it - to whoever was on the
/// path, from a page the browser was still showing as secure.
function signalingOverride(value) {
  if (!value) return null;
  try {
    const url = new URL(value, window.location.href);
    if (url.protocol === "wss:") return url.toString();
    if (url.protocol === "ws:" && window.location.protocol !== "https:") return url.toString();
    return null;
  } catch {
    return null;
  }
}

function inviteRoomID() {
  return invite?.inviteID || undefined;
}

function parseInvite(token) {
  const decoded = decodeInvite(token);
  if (decoded) return decoded;
  const code = token.trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(code)) return null;
  return {
    inviteID: null,
    code,
    expiresAtEpochSeconds: Number.POSITIVE_INFINITY,
    requireHostApproval: true,
    transportMode: "automatic",
    latencyMode: "lowLatency",
    // A bare code has never carried the payload a hosted invite needs, so this can only mean the
    // embedded server - and did, before hosted signaling existed at all.
    signalingKind: "embedded"
  };
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
