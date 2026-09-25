// Plays the host's game audio.
//
// The host sends 48 kHz stereo Int16 PCM as WebTransport datagrams. The main thread converts each
// chunk to Float32 and posts it here. Datagrams arrive in jittery bursts, so - exactly like the native
// guest's playout buffer - this keeps a small cushion before it starts playing and drops the oldest
// audio past a ceiling, rather than replaying every gap as silence, which is what "choppy" is.

class PcmPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.offset = 0;
    this.queuedSamples = 0;
    this.isPrimed = false;
    this.sampleRateKnown = globalThis.sampleRate || 48000;
    // 70 ms of cushion: enough to ride out ordinary datagram jitter without adding audible latency.
    this.targetSamples = Math.round(this.sampleRateKnown * 0.07) * 2;
    // 500 ms ceiling. Past this the guest is not keeping up; dropping the oldest keeps latency bounded
    // instead of growing a backlog the user hears late.
    this.maximumSamples = Math.round(this.sampleRateKnown * 0.5) * 2;
    this.port.onmessage = (event) => {
      const chunk = event.data;
      if (!chunk || chunk.length === 0) return;
      this.queue.push(chunk);
      this.queuedSamples += chunk.length;
      while (this.queuedSamples > this.maximumSamples && this.queue.length > 1) {
        const dropped = this.queue.shift();
        this.queuedSamples -= dropped.length;
        if (this.queue.length === 1) this.offset = 0;
      }
      if (!this.isPrimed && this.queuedSamples >= this.targetSamples) this.isPrimed = true;
    };
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    const left = output[0];
    const right = output.length > 1 ? output[1] : output[0];
    const frames = left.length;
    let written = 0;

    if (!this.isPrimed) {
      left.fill(0);
      if (right !== left) right.fill(0);
      return true;
    }

    // `chunk` is interleaved stereo: two samples per frame. The output arrays are one sample per
    // channel per frame, so a frame consumes two input samples - treating a sample as a frame wrote
    // every other output frame and advanced by half a frame, which is the crackling this replaces.
    while (written < frames) {
      if (this.queue.length === 0) {
        left.fill(0, written);
        if (right !== left) right.fill(0, written);
        this.isPrimed = false;
        break;
      }
      const chunk = this.queue[0];
      const availableFrames = (chunk.length - this.offset) >> 1;
      const takeFrames = Math.min(availableFrames, frames - written);
      for (let frame = 0; frame < takeFrames; frame += 1) {
        const sample = this.offset + frame * 2;
        const leftSample = chunk[sample];
        left[written + frame] = leftSample;
        if (right !== left) right[written + frame] = chunk[sample + 1] ?? leftSample;
      }
      written += takeFrames;
      const consumedSamples = takeFrames * 2;
      this.offset += consumedSamples;
      this.queuedSamples -= consumedSamples;
      if (this.offset >= chunk.length) {
        this.queue.shift();
        this.offset = 0;
      }
    }
    return true;
  }
}

registerProcessor("pcm-player", PcmPlayer);
