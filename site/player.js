// The before/after player. Both versions of a sample play at once, in lockstep, and holding the
// button (or Space) moves the volume from the restored one to the original, like the app does.
// Switching is therefore instant and sample-accurate, which is what makes the difference audible.

// The Homebrew command's Copy button works with or without the player.
for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copy);
    try {
      await navigator.clipboard.writeText(target.textContent);
      button.textContent = "Copied";
    } catch {
      getSelection().selectAllChildren(target);
      button.textContent = "Selected";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 1600);
  });
}

(() => {
  "use strict";

  const player = document.getElementById("player");
  if (!player || !window.AudioContext) return;

  const tabs = player.querySelector(".samples");
  const stage = player.querySelector(".stage");
  const afterImage = stage.querySelector(".spec.after");
  const beforeImage = stage.querySelector(".spec.before");
  const playhead = stage.querySelector(".playhead");
  const which = stage.querySelector(".which");
  const time = player.querySelector(".time");
  const playButton = player.querySelector(".play");
  const holdButton = player.querySelector(".hold");
  const detail = player.querySelector(".detail");

  let context = null;
  let samples = [];
  let current = null; // { id, title, detail, seconds }
  const buffers = new Map(); // id -> Promise<{ before, after }>
  let voices = null; // { before, after, gainBefore, gainAfter, startedAt, offset }
  let offset = 0; // seconds into the sample while paused
  let original = false;
  let frame = 0;

  const format = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

  function audioContext() {
    if (!context) context = new AudioContext({ latencyHint: "interactive" });
    return context;
  }

  async function decode(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url}: ${response.status}`);
    return audioContext().decodeAudioData(await response.arrayBuffer());
  }

  function load(sample) {
    if (!buffers.has(sample.id)) {
      buffers.set(sample.id, Promise.all([
        decode(`samples/${sample.id}-before.m4a`),
        decode(`samples/${sample.id}-after.m4a`),
      ]).then(([before, after]) => ({ before, after })));
    }
    return buffers.get(sample.id);
  }

  // ---------------------------------------------------------------- playback

  const isPlaying = () => voices !== null;
  const duration = () => current?.seconds ?? 0;

  function position() {
    if (!voices) return offset;
    return Math.min(duration(), voices.offset + (context.currentTime - voices.startedAt));
  }

  async function play() {
    if (!current || isPlaying()) return;
    const sample = current;
    player.classList.add("loading");
    let pair;
    try {
      await audioContext().resume();
      pair = await load(sample);
    } catch (error) {
      console.error(error);
      which.textContent = "Couldn't load this sample";
      player.classList.remove("loading");
      return;
    } finally {
      player.classList.remove("loading");
    }
    if (sample !== current || isPlaying()) return;
    if (offset >= duration() - 0.05) offset = 0;

    const startedAt = context.currentTime + 0.03;
    const make = (buffer, level) => {
      const source = context.createBufferSource();
      const gain = context.createGain();
      source.buffer = buffer;
      gain.gain.value = level;
      source.connect(gain).connect(context.destination);
      source.start(startedAt, offset);
      return { source, gain };
    };
    const before = make(pair.before, original ? 1 : 0);
    const after = make(pair.after, original ? 0 : 1);
    voices = { before: before.source, after: after.source, gainBefore: before.gain, gainAfter: after.gain, startedAt, offset };
    after.source.onended = () => {
      if (voices && voices.after === after.source) {
        stop();
        offset = 0;
        render();
      }
    };
    player.classList.add("playing", "started");
    playButton.setAttribute("aria-label", "Pause");
    tick();
  }

  function stop() {
    if (!voices) return;
    offset = position();
    for (const source of [voices.before, voices.after]) {
      source.onended = null;
      try { source.stop(); } catch { /* already stopped */ }
    }
    voices = null;
    cancelAnimationFrame(frame);
    player.classList.remove("playing");
    playButton.setAttribute("aria-label", "Play");
  }

  function togglePlay() {
    if (isPlaying()) stop(); else play();
    render();
  }

  function seek(seconds) {
    const wasPlaying = isPlaying();
    stop();
    offset = Math.max(0, Math.min(duration(), seconds));
    player.classList.add("started");
    render();
    if (wasPlaying) play();
  }

  function setOriginal(on) {
    original = on;
    player.classList.toggle("original", on);
    which.textContent = on ? "Original" : "Restored";
    if (voices) {
      // A 15 ms ramp: instant to the ear, without the click of a hard cut.
      const t = context.currentTime;
      voices.gainBefore.gain.setTargetAtTime(on ? 1 : 0, t, 0.005);
      voices.gainAfter.gain.setTargetAtTime(on ? 0 : 1, t, 0.005);
    }
  }

  function render() {
    const p = position();
    const fraction = duration() ? p / duration() : 0;
    playhead.style.left = `${fraction * 100}%`;
    time.textContent = format(p);
    stage.setAttribute("aria-valuenow", String(Math.round(fraction * 100)));
    stage.setAttribute("aria-valuetext", `${format(p)} of ${format(duration())}`);
  }

  function tick() {
    render();
    if (voices) frame = requestAnimationFrame(tick);
  }

  // ---------------------------------------------------------------- samples

  function select(sample) {
    stop();
    current = sample;
    offset = 0;
    player.classList.remove("started");
    afterImage.src = `samples/${sample.id}-after.webp`;
    beforeImage.src = `samples/${sample.id}-before.webp`;
    detail.textContent = sample.detail;
    for (const button of tabs.children) {
      const selected = button.dataset.id === sample.id;
      button.setAttribute("aria-selected", String(selected));
      button.tabIndex = selected ? 0 : -1;
    }
    render();
    load(sample).catch(() => {}); // Start fetching; errors surface on play.
  }

  async function init() {
    try {
      samples = await (await fetch("samples/samples.json")).json();
    } catch {
      player.hidden = true;
      return;
    }
    for (const sample of samples) {
      const button = document.createElement("button");
      button.type = "button";
      button.setAttribute("role", "tab");
      button.dataset.id = sample.id;
      button.textContent = sample.title;
      button.addEventListener("click", () => select(sample));
      tabs.append(button);
    }
    tabs.addEventListener("keydown", (event) => {
      if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
      const index = samples.indexOf(current) + (event.key === "ArrowRight" ? 1 : -1);
      const next = samples[(index + samples.length) % samples.length];
      select(next);
      tabs.querySelector(`[data-id="${next.id}"]`).focus();
    });
    select(samples[0]);
  }

  // ---------------------------------------------------------------- input

  playButton.addEventListener("click", togglePlay);

  // Holding plays the original; it starts playback if needed, as the app's Space key does.
  holdButton.addEventListener("pointerdown", (event) => {
    holdButton.setPointerCapture(event.pointerId);
    setOriginal(true);
    if (!isPlaying()) play();
  });
  for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) {
    holdButton.addEventListener(type, () => setOriginal(false));
  }
  holdButton.addEventListener("contextmenu", (event) => event.preventDefault());
  holdButton.addEventListener("keydown", (event) => {
    if ((event.key === "Enter" || event.key === " ") && !event.repeat) {
      event.preventDefault();
      setOriginal(true);
      if (!isPlaying()) play();
    }
  });
  holdButton.addEventListener("keyup", (event) => {
    if (event.key === "Enter" || event.key === " ") setOriginal(false);
  });

  // Space anywhere else: a tap plays or pauses, holding it plays the original until released.
  let spaceDown = 0;
  let spaceTimer = 0;
  document.addEventListener("keydown", (event) => {
    if (event.key !== " " || event.repeat || event.target.closest("button, a, input, textarea")) return;
    event.preventDefault();
    spaceDown = performance.now();
    spaceTimer = setTimeout(() => {
      setOriginal(true);
      if (!isPlaying()) play();
    }, 250);
  });
  document.addEventListener("keyup", (event) => {
    if (event.key !== " " || !spaceDown) return;
    event.preventDefault();
    clearTimeout(spaceTimer);
    if (performance.now() - spaceDown < 250) togglePlay(); else setOriginal(false);
    spaceDown = 0;
  });

  function seekTo(event) {
    const box = stage.getBoundingClientRect();
    seek(((event.clientX - box.left) / box.width) * duration());
  }
  stage.addEventListener("pointerdown", (event) => {
    stage.setPointerCapture(event.pointerId);
    seekTo(event);
  });
  stage.addEventListener("pointermove", (event) => {
    if (stage.hasPointerCapture(event.pointerId)) seekTo(event);
  });
  stage.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") seek(position() + 2);
    else if (event.key === "ArrowLeft") seek(position() - 2);
    else return;
    event.preventDefault();
  });

  init();
})();
