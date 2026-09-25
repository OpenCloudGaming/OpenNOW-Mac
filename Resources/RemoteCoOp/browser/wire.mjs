// The browser guest's wire code, with no DOM dependency.
//
// Kept separate from app.js so the byte layouts can be verified directly against the host's Swift
// encoders. Media arrives as whole frames on a reliable stream (see app.js's readMediaStream), so only
// the input frame still has a binary layout to get exactly right; it mirrors
// OPN/RemoteCoOp/RemoteCoOpInputBinaryCodec.swift.

export const INPUT_MAGIC = 0xa7;
export const INPUT_FRAME_BYTES = 62;

export function readUint32(bytes, offset) {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

export function readUint64(bytes, offset) {
  let value = 0;
  for (let index = 0; index < 8; index += 1) value = value * 256 + bytes[offset + index];
  return value;
}

/// The 16 network-order bytes of a canonical UUID string.
export function uuidToBytes(uuid) {
  const hex = uuid.replace(/-/g, "");
  const bytes = new Uint8Array(16);
  for (let index = 0; index < 16; index += 1) bytes[index] = parseInt(hex.substr(index * 2, 2), 16);
  return bytes;
}

/// The WebCodecs codec string a `avcC` record implies: `avc1.PPCCLL`.
export function codecString(avcC) {
  const hex = (value) => value.toString(16).padStart(2, "0");
  return `avc1.${hex(avcC[1])}${hex(avcC[2])}${hex(avcC[3])}`;
}

/// The seat's button bit layout (`GamepadButtons`).
export function buttonsForGamepad(gamepad) {
  const pressed = (index) => Boolean(gamepad.buttons[index] && gamepad.buttons[index].pressed);
  let buttons = 0;
  if (pressed(0)) buttons |= 1 << 0;   // south
  if (pressed(1)) buttons |= 1 << 1;   // east
  if (pressed(2)) buttons |= 1 << 2;   // west
  if (pressed(3)) buttons |= 1 << 3;   // north
  if (pressed(4)) buttons |= 1 << 4;   // left shoulder
  if (pressed(5)) buttons |= 1 << 5;   // right shoulder
  if (pressed(8)) buttons |= 1 << 6;   // select
  if (pressed(9)) buttons |= 1 << 7;   // start
  if (pressed(10)) buttons |= 1 << 8;  // left stick
  if (pressed(11)) buttons |= 1 << 9;  // right stick
  if (pressed(12)) buttons |= 1 << 10; // dpad up
  if (pressed(13)) buttons |= 1 << 11; // dpad down
  if (pressed(14)) buttons |= 1 << 12; // dpad left
  if (pressed(15)) buttons |= 1 << 13; // dpad right
  if (pressed(16)) buttons |= 1 << 18; // mode
  return buttons;
}

/// One 62-byte guest input frame, byte-for-byte what `OPNRemoteCoOpInputBinaryCodec.decode` reads.
/// `axes` is leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY.
export function encodeInputFrame(participantID, sequenceNumber, buttons, axes, sentAtNanoseconds) {
  const buffer = new ArrayBuffer(INPUT_FRAME_BYTES);
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  let offset = 0;
  bytes[offset++] = INPUT_MAGIC;
  bytes[offset++] = 1;
  bytes.set(uuidToBytes(participantID), offset);
  offset += 16;
  view.setBigUint64(offset, BigInt(sequenceNumber), true);
  offset += 8;
  view.setUint32(offset, buttons >>> 0, true);
  offset += 4;
  for (const axis of axes) {
    view.setFloat32(offset, axis, true);
    offset += 4;
  }
  view.setBigUint64(offset, BigInt(sentAtNanoseconds), true);
  return bytes;
}
