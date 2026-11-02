// yaz.mike4.dev: the dictation demo and the download details. No dependencies.
(() => {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------------------------------------------------------------------------
  // The demo replays a measured run (fixtures/t2.wav, M4 Pro): what Whisper
  // wrote, then what the vocabulary layer made of it. Numbers are from the
  // README, not invented for the page.

  const SEGMENTS = [
    { text: "Yarın saat 14'te toplantı var. Ahmet'e " },
    { raw: "Sılacık", fix: "Slack", score: "0.749" },
    { text: " üzerinden mesaj atmayı unutma. " },
    { raw: "Puhrıkı Esti'de", fix: "pull request'de", score: "0.832" },
    { text: " merge etmem lazım. " },
    { raw: "C.I.P. eline", fix: "CI pipeline", score: "0.799" },
    { text: " yeşile döndüğünde deploy ederiz." },
  ];
  const MIN_HOLD_MS = 350;      // SpeechGate.defaultMinSeconds
  const TRANSCRIBE_MS = 506;    // measured latency for 5.6 s of speech

  const field = document.getElementById("field-text");
  const pill = document.getElementById("pill");
  const pillLabel = document.getElementById("pill-label");
  const key = document.getElementById("holdkey");
  const log = document.getElementById("log");
  const demo = document.getElementById("demo");

  let state = "idle";           // idle | recording | working
  let pressedAt = 0;
  let timers = [];
  let played = false;

  const later = (ms, fn) => timers.push(setTimeout(fn, reduceMotion ? 0 : ms));
  const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };

  function logLine(text, cls) {
    const li = document.createElement("li");
    if (cls) li.className = cls;
    li.textContent = text;
    log.appendChild(li);
    while (log.children.length > 4) log.removeChild(log.firstChild);
  }

  function showPill(mode, label) {
    pill.className = "pill is-visible " + (mode ? "is-" + mode : "");
    pillLabel.textContent = label;
  }
  const hidePill = () => { pill.className = "pill"; };

  function renderTranscript(fixed) {
    field.textContent = "";
    for (const seg of SEGMENTS) {
      if (seg.text) { field.append(seg.text); continue; }
      const span = document.createElement("span");
      span.className = "term " + (fixed ? "is-fixed" : "is-raw");
      span.dataset.fix = seg.fix;
      span.textContent = fixed ? seg.fix : seg.raw;
      field.appendChild(span);
    }
  }

  function press() {
    if (state !== "idle") return;
    clearTimers();
    played = true;
    state = "recording";
    pressedAt = performance.now();
    key.classList.add("is-down");
    field.textContent = "";
    log.textContent = "";
    showPill("recording", "listening");
    logLine("● recording", "dim");
  }

  function release() {
    if (state !== "recording") return;
    key.classList.remove("is-down");
    const held = performance.now() - pressedAt;

    // The first quality gate: Whisper returns nothing for a tap.
    if (held < MIN_HOLD_MS) {
      state = "idle";
      showPill("", "too short — dropped");
      logLine(`○ recording too short (${(held / 1000).toFixed(2)} s, needs at least 0.35 s)`, "warn");
      later(1100, hidePill);
      return;
    }

    state = "working";
    showPill("working", "transcribing");
    later(TRANSCRIBE_MS, () => {
      // One paste, not a stream of keystrokes: that is how yaz inserts text.
      hidePill();
      renderTranscript(false);
      field.classList.remove("is-pasted");
      void field.offsetWidth;
      field.classList.add("is-pasted");
      logLine("→ 0.51 s (transcribe 0.51) · whisper large-v3-turbo", "dim");

      // Then the vocabulary layer repairs each term, keeping the suffix.
      const terms = Array.from(field.querySelectorAll(".term"));
      terms.forEach((span, i) => {
        later(650 + i * 520, () => {
          const seg = SEGMENTS.filter((s) => s.raw)[i];
          span.textContent = seg.fix;
          span.className = "term is-fixed";
          logLine(`  vocabulary: ${seg.raw} → ${seg.fix} (${seg.score})`, "ok");
        });
      });
      later(650 + terms.length * 520, () => { state = "idle"; });
    });
  }

  if (key && field) {
    key.addEventListener("pointerdown", (e) => { e.preventDefault(); key.setPointerCapture(e.pointerId); press(); });
    key.addEventListener("pointerup", release);
    key.addEventListener("pointercancel", release);
    key.addEventListener("keydown", (e) => {
      if ((e.key === " " || e.key === "Enter") && !e.repeat) { e.preventDefault(); press(); }
    });
    key.addEventListener("keyup", (e) => {
      if (e.key === " " || e.key === "Enter") { e.preventDefault(); release(); }
    });
    // Option stands in for the right-option hotkey; the browser cannot see fn.
    window.addEventListener("keydown", (e) => { if (e.key === "Alt" && !e.repeat) press(); });
    window.addEventListener("keyup", (e) => { if (e.key === "Alt") release(); });
    window.addEventListener("blur", release);

    // Play it once when the demo comes into view, as if someone held the key.
    const autoplay = () => {
      if (played) return;
      if (reduceMotion) { renderTranscript(true); logLine("  vocabulary: Sılacık → Slack (0.749)", "ok"); return; }
      press();
      setTimeout(release, 2400);
    };
    if ("IntersectionObserver" in window) {
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); setTimeout(autoplay, 700); }
      }, { threshold: 0.5 });
      io.observe(demo);
    } else {
      setTimeout(autoplay, 700);
    }
  }

  // ---------------------------------------------------------------------------
  // Download details from the release manifest.

  const fmtSize = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`;

  fetch("downloads/latest.json", { cache: "no-cache" })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((m) => {
      const url = m.url;
      document.querySelectorAll("[data-download]").forEach((a) => { a.href = url; });
      document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = `Version ${m.version}`; });
      document.querySelectorAll("[data-download-label]").forEach((el) => {
        el.textContent = `Download yaz ${m.version} (${fmtSize(m.size)})`;
      });
      document.querySelectorAll("[data-file]").forEach((el) => { el.textContent = m.file; });
      const sha = document.getElementById("sha256");
      if (sha) sha.textContent = m.sha256;
    })
    .catch(() => {
      const sha = document.getElementById("sha256");
      if (sha) sha.textContent = "see the release page on GitHub";
    });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = document.querySelector(button.dataset.copy);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select it";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1600);
    });
  });
})();
