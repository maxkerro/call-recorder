// Mixes the input to mono and hands it to the page in blocks of 100 ms.
class Tap extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.track = options.processorOptions.track;
    this.buf = new Float32Array(4800);
    this.n = 0;
  }
  process(inputs) {
    const ch = inputs[0];
    if (!ch || !ch.length) return true;
    const len = ch[0].length;
    for (let i = 0; i < len; i++) {
      let v = 0;
      for (let c = 0; c < ch.length; c++) v += ch[c][i];
      this.buf[this.n++] = v / ch.length;
      if (this.n === this.buf.length) {
        const out = this.buf.slice();
        this.port.postMessage({ track: this.track, buffer: out.buffer }, [out.buffer]);
        this.n = 0;
      }
    }
    return true;
  }
}
registerProcessor('tap', Tap);
