// yaz.mike4.dev: the voice ribbon, the dictation replay, scroll reveals and
// the release manifest. No dependencies; every effect has a still fallback.
(() => {
  "use strict";

  document.documentElement.classList.add("js");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------------------------------------------------------------------------
  // Entrances: release the transform once done, never leave anything hidden.

  const appear = document.querySelectorAll(".appear");
  appear.forEach((el) => el.addEventListener("animationend", (e) => {
    if (e.target === el) el.classList.add("is-in");
  }));
  requestAnimationFrame(() => requestAnimationFrame(() => {
    const running = [...appear].some((el) =>
      (el.getAnimations ? el.getAnimations() : []).some((a) => a.playState === "running" || a.playState === "finished"));
    if (!running) appear.forEach((el) => el.classList.add("is-in"));
  }));

  // ---------------------------------------------------------------------------
  // The voice ribbon: bars across the width of the hero, quiet until you hold
  // the key. Drawn on a canvas so it costs one paint per frame.

  const canvas = document.getElementById("voice");
  const hero = document.querySelector(".hero");
  const ctx = canvas ? canvas.getContext("2d") : null;
  const voice = { level: 0.06, target: 0.06, speaking: false, y: 0, w: 0, h: 0, bars: 0, visible: true };

  function measure() {
    if (!canvas) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const rect = hero.getBoundingClientRect();
    voice.w = rect.width;
    voice.h = rect.height;
    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // The ribbon runs through the gap between the transcript and the key.
    const meta = document.getElementById("stage-meta").getBoundingClientRect();
    const key = document.getElementById("holdkey").getBoundingClientRect();
    voice.y = (meta.bottom + key.top) / 2 - rect.top;
    voice.bars = Math.max(48, Math.floor(rect.width / (rect.width < 600 ? 7 : 9)));
  }

  // Cheap smooth noise per bar.
  const noise = (i, t) => 0.5 + 0.5 * Math.sin(i * 1.7 + t * 2.3) * Math.cos(i * 0.63 - t * 1.4);

  function draw(t) {
    if (!ctx) return;
    const { w, h, y, bars } = voice;
    ctx.clearRect(0, 0, w, h);
    const gap = w / bars;
    const maxH = Math.min(h * 0.17, 150);
    for (let i = 0; i < bars; i++) {
      const x = gap * (i + 0.5);
      const u = (x / w) * 2 - 1;                       // -1 … 1 across the width
      const shape = Math.exp(-u * u * 2.2);            // fuller in the middle
      const n = noise(i, t);
      const amp = maxH * voice.level * shape * (0.25 + 0.75 * n) + 1.5;
      const alpha = 0.12 + 0.78 * shape * Math.min(1, voice.level * 2.2 + 0.2);
      ctx.strokeStyle = `rgba(255, ${Math.round(90 + 40 * (1 - shape))}, 46, ${alpha.toFixed(3)})`;
      ctx.lineWidth = Math.max(2, gap * 0.36);
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(x, y - amp);
      ctx.lineTo(x, y + amp);
      ctx.stroke();
    }
  }

  let frame = 0;
  let syllable = 0;
  function tick(now) {
    frame = 0;
    const t = now / 1000;
    if (voice.speaking) {
      // Syllables: a pulse every ~180 ms with some swing, like speech.
      if (now > syllable) {
        voice.target = 0.45 + Math.random() * 0.55;
        syllable = now + 120 + Math.random() * 140;
      } else {
        voice.target *= 0.985;
      }
    } else {
      voice.target = 0.05 + 0.02 * Math.sin(t * 0.8);
    }
    voice.level += (voice.target - voice.level) * 0.14;
    draw(t);
    if (voice.visible && !document.hidden) frame = requestAnimationFrame(tick);
  }
  function start() { if (!frame && !reduce) frame = requestAnimationFrame(tick); }

  if (canvas) {
    measure();
    if (reduce) { voice.level = 0.35; draw(1); }
    else start();
    let resizeTimer = 0;
    addEventListener("resize", () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => { measure(); if (reduce) draw(1); }, 120);
    });
    document.fonts && document.fonts.ready.then(() => { measure(); if (reduce) draw(1); });
    new IntersectionObserver((entries) => {
      voice.visible = entries[0].isIntersecting;
      if (voice.visible) start();
    }).observe(hero);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) start(); });
  }

  // ---------------------------------------------------------------------------
  // The replay: what Whisper hears while you hold the key, then what yaz
  // writes. The manglings are the ones measured in fixtures/; the repairs
  // are what yaz's term and number rules make of them.

  const sentence = [
    { raw: "Sılacık'ta", fixed: "Slack'ta" },
    { raw: "yaz:" },
    { raw: "Puhrıkı Esti", fixed: "pull request" },
    { raw: "saat" },
    { raw: "on beş otuzda", fixed: "15.30'da" },
    { raw: "merge" },
    { raw: "olacak." },
  ];
  const transcript = document.getElementById("transcript");
  const meta = document.getElementById("stage-meta");
  const key = document.getElementById("holdkey");
  const keyLabel = document.getElementById("holdkey-label");
  const minHold = 350;
  let pressedAt = 0;
  let shown = 0;
  let wordTimer = 0;
  let finishTimers = [];
  let interacted = false;
  let busy = false;

  function setMeta(html) { meta.innerHTML = html || "&nbsp;"; }

  function clearTimers() {
    clearInterval(wordTimer);
    finishTimers.forEach(clearTimeout);
    finishTimers = [];
  }

  function wordSpan(part, index) {
    const span = document.createElement("span");
    span.className = "w w-new" + (part.fixed ? " w-raw" : "");
    span.dataset.index = String(index);
    span.textContent = part.raw;
    return span;
  }

  function showNextWord() {
    if (shown >= sentence.length) return;
    if (shown === 0) transcript.textContent = "";
    else transcript.append(" ");
    transcript.append(wordSpan(sentence[shown], shown));
    shown += 1;
  }

  function press() {
    if (busy) return;
    clearTimers();
    pressedAt = performance.now();
    shown = 0;
    voice.speaking = true;
    syllable = 0;
    key.classList.add("is-down", "is-live");
    key.setAttribute("aria-pressed", "true");
    keyLabel.textContent = "Listening…";
    setMeta("● recording");
    showNextWord();
    wordTimer = setInterval(showNextWord, 230);
  }

  function release() {
    if (!pressedAt) return;
    const held = performance.now() - pressedAt;
    pressedAt = 0;
    clearInterval(wordTimer);
    voice.speaking = false;
    key.classList.remove("is-down");
    key.setAttribute("aria-pressed", "false");
    if (held < minHold) {
      key.classList.remove("is-live");
      keyLabel.textContent = "Hold to speak";
      transcript.innerHTML = '<span class="transcript-hint">A tap under 0.35 s is dropped, as in the app. Hold a little longer.</span>';
      setMeta("");
      return;
    }
    busy = true;
    // Whisper transcribes the whole recording at release: the rest arrives.
    while (shown < sentence.length) showNextWord();
    keyLabel.textContent = "Writing…";
    setMeta("transcribing");
    finishTimers.push(setTimeout(() => {
      let fixes = 0;
      transcript.querySelectorAll(".w-raw").forEach((span, i) => {
        finishTimers.push(setTimeout(() => {
          const part = sentence[Number(span.dataset.index)];
          span.textContent = part.fixed;
          span.className = "w w-fixed";
        }, reduce ? 0 : i * 160));
        fixes += 1;
      });
      finishTimers.push(setTimeout(() => {
        setMeta(`<b>${fixes} fixes</b> · written on your Mac`);
        key.classList.remove("is-live");
        keyLabel.textContent = "Hold to speak again";
        busy = false;
      }, reduce ? 0 : fixes * 160 + 300));
    }, reduce ? 0 : 520));
  }

  if (key && transcript) {
    key.setAttribute("aria-pressed", "false");
    key.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      interacted = true;
      key.setPointerCapture(e.pointerId);
      press();
    });
    key.addEventListener("pointerup", release);
    key.addEventListener("pointercancel", release);
    key.addEventListener("keydown", (e) => {
      if ((e.key === " " || e.key === "Enter") && !e.repeat) { e.preventDefault(); interacted = true; press(); }
    });
    key.addEventListener("keyup", (e) => { if (e.key === " " || e.key === "Enter") release(); });
    addEventListener("keydown", (e) => { if (e.key === "Alt" && !e.repeat) { interacted = true; press(); } });
    addEventListener("keyup", (e) => { if (e.key === "Alt") release(); });
    addEventListener("blur", release);

    // Play it once by itself, so a visitor who never touches a key still
    // sees the point of the page.
    setTimeout(() => {
      if (interacted) return;
      press();
      setTimeout(() => { if (!interacted) release(); }, reduce ? 400 : sentence.length * 230 + 500);
    }, reduce ? 300 : 1900);
  }

  // ---------------------------------------------------------------------------
  // Scroll: the manifesto lights up word by word; blocks rise once.

  const manifesto = document.getElementById("manifesto");
  if (manifesto) {
    const wrapWords = (node) => {
      [...node.childNodes].forEach((child) => {
        if (child.nodeType === Node.TEXT_NODE) {
          const frag = document.createDocumentFragment();
          child.textContent.split(/(\s+)/).forEach((part) => {
            if (!part) return;
            if (/^\s+$/.test(part)) { frag.append(part); return; }
            const span = document.createElement("span");
            span.className = "sp";
            span.textContent = part;
            frag.append(span);
          });
          child.replaceWith(frag);
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          wrapWords(child);
        }
      });
    };
    wrapWords(manifesto);
    const pieces = [...manifesto.querySelectorAll(".sp")];
    const N = pieces.length;
    let ticking = false;
    const update = () => {
      ticking = false;
      const r = manifesto.getBoundingClientRect();
      const vh = innerHeight;
      const p = reduce ? 1 : Math.min(1, Math.max(0, (0.85 * vh - r.top) / (0.6 * vh + r.height * 0.6)));
      pieces.forEach((s, i) => {
        const a = i / N - 0.08;
        const b = i / N + 0.04;
        const k = Math.min(1, Math.max(0, (p - a) / (b - a)));
        s.style.opacity = (0.14 + 0.86 * k).toFixed(3);
      });
    };
    addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    addEventListener("resize", update);
    update();
  }

  const reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduce) {
    // Siblings rise one after another.
    reveals.forEach((el) => {
      const siblings = [...el.parentElement.children].filter((c) => c.classList.contains("reveal"));
      el.style.transitionDelay = `${Math.min(siblings.indexOf(el), 6) * 0.08}s`;
    });
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-in");
        io.unobserve(entry.target);
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -8% 0px" });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("is-in"));
  }

  // The agent terminal plays its exchange once, when it comes into view.
  const terminal = document.getElementById("terminal");
  if (terminal) {
    const lines = [...terminal.querySelectorAll(".t-line")];
    const schedule = [0, 650, 1500, 2200, 4000, 4800];
    const play = () => {
      lines.forEach((line, i) => setTimeout(() => {
        line.classList.add("is-shown");
        if (line.classList.contains("t-voice")) {
          terminal.classList.add("is-talking");
          setTimeout(() => terminal.classList.remove("is-talking"), 1600);
        }
      }, reduce ? 0 : schedule[i] || i * 700));
    };
    if ("IntersectionObserver" in window && !reduce) {
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); play(); }
      }, { threshold: 0.4 });
      io.observe(terminal);
    } else {
      play();
    }
  }

  // ---------------------------------------------------------------------------
  // Download details from the release manifest.

  const fmtSize = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`;

  fetch("downloads/latest.json", { cache: "no-cache" })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((m) => {
      document.querySelectorAll("[data-download]").forEach((a) => { a.href = m.url; });
      document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = `Version ${m.version}`; });
      document.querySelectorAll("[data-download-label]").forEach((el) => {
        el.textContent = `Download yaz ${m.version} · ${fmtSize(m.size)}`;
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
