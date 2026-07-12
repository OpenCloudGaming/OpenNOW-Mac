const elements = {
  title: document.querySelector("#title"),
  subtitle: document.querySelector("#subtitle"),
  joinCard: document.querySelector("#join-card"),
  sessionCard: document.querySelector("#session-card"),
  displayName: document.querySelector("#display-name"),
  inviteToken: document.querySelector("#invite-token"),
  joinButton: document.querySelector("#join-button"),
  joinStatus: document.querySelector("#join-status"),
  state: document.querySelector("#session-state"),
  detail: document.querySelector("#session-detail"),
  dot: document.querySelector("#connection-dot"),
  gamepadName: document.querySelector("#gamepad-name"),
  gamepadDetail: document.querySelector("#gamepad-detail"),
  networkState: document.querySelector("#network-state"),
  networkDetail: document.querySelector("#network-detail"),
  disconnectButton: document.querySelector("#disconnect-button")
};

const url = new URL(window.location.href);
const inviteFromURL = url.searchParams.get("invite") ?? "";
const serverFromURL = url.searchParams.get("server") ?? "";
let socket = null;
let invite = null;
let participantID = crypto.randomUUID();
let approved = false;
let sequenceNumber = 0;
let lastSentState = "";
let lastSentAt = 0;
let pollHandle = 0;
let networkConfiguration = null;
let peerConnection = null;
let inputChannel = null;

elements.inviteToken.value = inviteFromURL;
renderInvite(inviteFromURL);

elements.inviteToken.addEventListener("input", () => renderInvite(elements.inviteToken.value));
elements.joinButton.addEventListener("click", joinRoom);
elements.disconnectButton.addEventListener("click", disconnect);
window.addEventListener("gamepadconnected", event => {
  elements.gamepadName.textContent = event.gamepad.id;
  elements.gamepadDetail.textContent = "Controller connected. Waiting for host approval.";
});
window.addEventListener("pagehide", disconnect);

function renderInvite(token) {
  invite = decodeInvite(token);
  if (!invite) {
    elements.title.textContent = "Join a cloud couch session";
    elements.subtitle.textContent = "Paste an invite token or open the link your host sent.";
    elements.joinStatus.textContent = "Waiting for invite.";
    return;
  }
  elements.title.textContent = invite.title ? `Join ${invite.title}` : "Join this Remote Co-Op room";
  elements.subtitle.textContent = `Room ${invite.code ?? invite.inviteID}. ${invite.requireHostApproval ? "Host approval required." : "Input starts after connection."}`;
  elements.joinStatus.textContent = "Invite loaded. Enter a name and join.";
}

function joinRoom() {
  invite = decodeInvite(elements.inviteToken.value);
  if (!invite) {
    elements.joinStatus.textContent = "Invite token is malformed.";
    return;
  }
  if (invite.expiresAtEpochSeconds * 1000 <= Date.now()) {
    elements.joinStatus.textContent = "Invite has expired.";
    return;
  }
  const endpoint = signalingEndpoint();
  socket = new WebSocket(endpoint);
  elements.joinButton.disabled = true;
  elements.joinStatus.textContent = `Connecting to ${endpoint}`;
  socket.addEventListener("open", () => {
    send({
      kind: "guestJoinRequested",
      roomID: invite.inviteID,
      participantID,
      inviteToken: elements.inviteToken.value.trim(),
      displayName: displayName()
    });
    elements.joinCard.classList.add("hidden");
    elements.sessionCard.classList.remove("hidden");
    setState("Waiting", "Waiting for host approval.", false);
  });
  socket.addEventListener("message", event => {
    handleMessage(JSON.parse(event.data)).catch(error => {
      setNetworkState("Peer setup failed", error.message || "WebRTC negotiation failed.");
    });
  });
  socket.addEventListener("close", () => {
    stopPolling();
    setState("Disconnected", "The Remote Co-Op connection closed.", false);
    elements.joinButton.disabled = false;
  });
}

async function handleMessage(message) {
  if (message.kind === "heartbeat") {
    send({ kind: "heartbeat", roomID: invite?.inviteID, participantID });
    return;
  }
  if (message.kind === "networkConfiguration") {
    configurePeerConnection(message.networkConfiguration);
    return;
  }
  if (message.kind === "peerSignal") {
    await handlePeerSignal(message.peerSignal);
    return;
  }
  if (message.kind === "participantUpdated" && message.participant?.id === participantID) {
    approved = message.participant.connectionState === "connected" && message.participant.inputEnabled === true;
    if (approved) {
      setState("Approved", `Input enabled as player ${(message.participant.playerIndex ?? 1) + 1}.`, true);
      startPolling();
    } else {
      setState("Waiting", "Host approval pending.", false);
    }
    return;
  }
  if (message.kind === "participantRemoved") {
    setState("Removed", "The host removed you from the room.", false);
    disconnect();
    return;
  }
  if (message.kind === "guestRejected") {
    setState("Rejected", message.reason ?? "The host rejected this join request.", false);
    disconnect();
    return;
  }
  if (message.kind === "inputRejected") {
    elements.gamepadDetail.textContent = `Input rejected: ${message.inputRejection ?? "unknown"}`;
    return;
  }
  if (message.kind === "inviteEnded") {
    setState("Ended", message.reason ?? "The host ended the invite.", false);
    disconnect();
  }
}

function startPolling() {
  if (pollHandle) return;
  const poll = time => {
    pollHandle = requestAnimationFrame(poll);
    if (!approved || socket?.readyState !== WebSocket.OPEN) return;
    const gamepad = navigator.getGamepads().find(Boolean);
    if (!gamepad) {
      elements.gamepadName.textContent = "No gamepad detected";
      elements.gamepadDetail.textContent = "Connect a controller and press any button.";
      return;
    }
    elements.gamepadName.textContent = gamepad.id;
    const input = inputPacket(gamepad);
    const state = JSON.stringify(input);
    if (state === lastSentState && time - lastSentAt < 250) return;
    lastSentState = state;
    lastSentAt = time;
    sendInput(input);
    elements.gamepadDetail.textContent = `Sending input sequence ${input.sequenceNumber}.`;
  };
  pollHandle = requestAnimationFrame(poll);
}

function stopPolling() {
  if (!pollHandle) return;
  cancelAnimationFrame(pollHandle);
  pollHandle = 0;
}

function inputPacket(gamepad) {
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
    sentAtNanoseconds: Math.round(performance.now() * 1_000_000)
  };
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
  const message = { kind: "guestInput", roomID: invite.inviteID, participantID, input };
  if (inputChannel?.readyState === "open") {
    inputChannel.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
    return;
  }
  if (networkConfiguration?.websocketInputFallbackEnabled !== false) send(message);
}

function configurePeerConnection(configuration) {
  networkConfiguration = configuration ?? automaticFallbackConfiguration();
  closePeerConnection();
  const rtcConfiguration = {
    iceServers: networkConfiguration.iceServers ?? [],
    iceTransportPolicy: networkConfiguration.iceTransportPolicy ?? "all"
  };
  peerConnection = new RTCPeerConnection(rtcConfiguration);
  peerConnection.addTransceiver("video", { direction: "recvonly" });
  peerConnection.addTransceiver("audio", { direction: "recvonly" });
  if (networkConfiguration.dataChannelInputEnabled !== false) bindInputChannel(peerConnection.createDataChannel("input", { ordered: false, maxRetransmits: 0 }));
  peerConnection.addEventListener("datachannel", event => bindInputChannel(event.channel));
  peerConnection.addEventListener("icecandidate", event => {
    if (!event.candidate) return;
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
  peerConnection.addEventListener("connectionstatechange", () => setNetworkState(networkLabel(), connectionDetail()));
  peerConnection.addEventListener("iceconnectionstatechange", () => setNetworkState(networkLabel(), connectionDetail()));
  peerConnection.addEventListener("track", event => attachRemoteTrack(event.track, event.streams[0]));
  setNetworkState(networkLabel(), networkConfiguration.directPeerCandidateWarning || connectionDetail());
}

async function handlePeerSignal(signal) {
  if (!signal) return;
  if (!peerConnection) configurePeerConnection(automaticFallbackConfiguration());
  if (signal.kind === "offer") {
    await peerConnection.setRemoteDescription({ type: "offer", sdp: signal.sdp });
    const answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    send({ kind: "peerSignal", roomID: invite.inviteID, participantID, peerSignal: { kind: "answer", sdp: answer.sdp } });
    setNetworkState(networkLabel(), "WebRTC answer sent. Waiting for ICE connectivity.");
    return;
  }
  if (signal.kind === "answer") {
    await peerConnection.setRemoteDescription({ type: "answer", sdp: signal.sdp });
    return;
  }
  if (signal.kind === "iceCandidate" && signal.candidate) {
    await peerConnection.addIceCandidate({ candidate: signal.candidate, sdpMid: signal.sdpMid ?? null, sdpMLineIndex: signal.sdpMLineIndex ?? null });
  }
}

function bindInputChannel(channel) {
  inputChannel = channel;
  channel.addEventListener("open", () => setNetworkState(networkLabel(), "Input data channel connected."));
  channel.addEventListener("close", () => setNetworkState(networkLabel(), "Input data channel closed. WebSocket fallback remains available."));
}

function closePeerConnection() {
  inputChannel?.close();
  inputChannel = null;
  peerConnection?.close();
  peerConnection = null;
}

function automaticFallbackConfiguration() {
  return {
    transportMode: invite?.transportMode ?? "automatic",
    iceTransportPolicy: invite?.transportMode === "relayOnly" ? "relay" : "all",
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
  elements.networkState.textContent = title;
  elements.networkDetail.textContent = detail;
}

function attachRemoteTrack(track, stream) {
  const existing = document.querySelector("#remote-media");
  const media = existing ?? document.createElement(track.kind === "audio" ? "audio" : "video");
  media.id = "remote-media";
  media.autoplay = true;
  media.playsInline = true;
  media.controls = false;
  media.srcObject = stream ?? new MediaStream([track]);
  if (!existing) document.querySelector(".video-placeholder")?.replaceChildren(media);
}

function disconnect() {
  approved = false;
  stopPolling();
  closePeerConnection();
  if (socket?.readyState === WebSocket.OPEN) send({ kind: "guestDisconnected", roomID: invite?.inviteID, participantID });
  socket?.close();
  socket = null;
}

function setState(title, detail, connected) {
  elements.state.textContent = title;
  elements.detail.textContent = detail;
  elements.dot.classList.toggle("connected", connected);
}

function displayName() {
  const value = elements.displayName.value.trim();
  return value.length > 0 ? value : "Guest";
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
