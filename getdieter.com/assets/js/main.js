/* getdieter.com — interactions + the signature install terminal */
(() => {
  "use strict";
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, reduce ? 0 : ms));
  const $ = (s, c = document) => c.querySelector(s);
  const $$ = (s, c = document) => [...c.querySelectorAll(s)];

  /* ---- Nav: scrolled state + mobile menu ---- */
  const nav = $("[data-nav]");
  const onScroll = () => nav && nav.toggleAttribute("data-scrolled", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  const toggle = $("[data-nav-toggle]");
  if (toggle) {
    toggle.addEventListener("click", () => {
      const open = document.body.toggleAttribute("data-menu");
      toggle.setAttribute("aria-expanded", String(open));
    });
    $$(".nav__links a").forEach((a) =>
      a.addEventListener("click", () => {
        document.body.removeAttribute("data-menu");
        toggle.setAttribute("aria-expanded", "false");
      })
    );
  }

  /* ---- Copy buttons ---- */
  $$("[data-copy]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const text = btn.getAttribute("data-copy");
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        const t = document.createElement("textarea");
        t.value = text; document.body.appendChild(t); t.select();
        try { document.execCommand("copy"); } catch (e) {}
        t.remove();
      }
      const label = btn.querySelector("[data-copy-label]");
      const prev = label ? label.textContent : null;
      btn.setAttribute("data-copied", "");
      if (label) label.textContent = "Copied";
      setTimeout(() => {
        btn.removeAttribute("data-copied");
        if (label && prev !== null) label.textContent = prev;
      }, 1600);
    });
  });

  /* ---- Scroll reveal ---- */
  const reveal = $$("[data-reveal]");
  if (reveal.length) {
    if (reduce || !("IntersectionObserver" in window)) {
      reveal.forEach((el) => el.setAttribute("data-visible", ""));
    } else {
      const io = new IntersectionObserver(
        (entries) => {
          entries.forEach((e) => {
            if (e.isIntersecting) {
              const d = e.target.getAttribute("data-reveal-delay");
              if (d) e.target.style.transitionDelay = d + "ms";
              e.target.setAttribute("data-visible", "");
              io.unobserve(e.target);
            }
          });
        },
        { rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
      );
      reveal.forEach((el) => io.observe(el));
    }
  }

  /* ---- Card pointer glow ---- */
  $$(".card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${e.clientX - r.left}px`);
      card.style.setProperty("--my", `${e.clientY - r.top}px`);
    });
  });

  /* ---- Docs: mobile sidebar toggle ---- */
  const docToggle = $("[data-docnav-toggle]");
  if (docToggle) {
    docToggle.addEventListener("click", () => {
      const open = document.body.toggleAttribute("data-docmenu");
      docToggle.setAttribute("aria-expanded", String(open));
    });
  }

  /* ---- Docs: inject copy buttons into code blocks ---- */
  $$(".prose .highlight").forEach((block) => {
    const code = block.querySelector("code");
    if (!code) return;
    const btn = document.createElement("button");
    btn.className = "code-copy";
    btn.type = "button";
    btn.setAttribute("aria-label", "Copy code");
    btn.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
    btn.addEventListener("click", async () => {
      const text = code.innerText.replace(/\n$/, "");
      try { await navigator.clipboard.writeText(text); }
      catch (_) {
        const t = document.createElement("textarea");
        t.value = text; document.body.appendChild(t); t.select();
        try { document.execCommand("copy"); } catch (e) {}
        t.remove();
      }
      btn.setAttribute("data-copied", "");
      setTimeout(() => btn.removeAttribute("data-copied"), 1600);
    });
    block.appendChild(btn);
  });

  /* ---- Docs: TOC scrollspy ---- */
  const tocLinks = $$(".doctoc a");
  if (tocLinks.length && "IntersectionObserver" in window) {
    const map = new Map();
    tocLinks.forEach((a) => {
      const id = decodeURIComponent((a.getAttribute("href") || "").replace(/^#/, ""));
      const h = id && document.getElementById(id);
      if (h) map.set(h, a);
    });
    let active = null;
    const spy = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            if (active) active.classList.remove("is-active");
            active = map.get(e.target);
            if (active) active.classList.add("is-active");
          }
        });
      },
      { rootMargin: "-10% 0px -75% 0px", threshold: 0 }
    );
    map.forEach((_, h) => spy.observe(h));
  }

  /* =====================================================================
     The install terminal — animated "download progress" sequence.
     Mirrors the real dieter flow: brew install → dieter setup.
     ===================================================================== */
  const term = $("[data-terminal]");
  if (term) initTerminal(term);

  function initTerminal(root) {
    const body = $(".terminal__body", root);
    const replay = $(".terminal__replay", root);
    let running = false;

    const bar = (pct) => {
      const width = 34;
      const filled = Math.round((pct / 100) * width);
      const fill = "█".repeat(filled);
      const track = "░".repeat(width - filled);
      return `<span class="pbar"><span class="pbar__fill">${fill}</span><span class="pbar__track">${track}</span><span class="pbar__pct">${String(pct).padStart(3, " ")}%</span></span>`;
    };

    // sequence step kinds: cmd | out | progress | blank | final
    const script = [
      { k: "cmd", text: "brew install dbpprt/tap/dieter" },
      { k: "out", html: `<span class="muted">==></span> Fetching <span class="accent">dbpprt/tap/dieter</span>` },
      { k: "progress", label: "downloading  dieter-1.0.0.arm64", ms: 900 },
      { k: "out", html: `<span class="muted">==></span> Installing dieter from dbpprt/tap` },
      { k: "out", html: `<span class="ok">✓</span> poured  <span class="muted">dieter, dieter-gateway</span>  <span class="muted">37.1MB</span>` },
      { k: "blank" },
      { k: "cmd", text: "dieter setup ~/Development/orbit" },
      { k: "check", text: "registered git working tree", val: "~/Development/orbit" },
      { k: "check", text: "enrolled this Mac", val: "“Studio Mac”" },
      { k: "check", text: "screen recording permission", val: "verified · dieter-capture" },
      { k: "check", text: "accessibility permission", val: "verified · no pointer moved" },
      { k: "check", text: "daemon service", val: "running · brew services" },
      { k: "arrow", text: "gateway tunnel", val: "board.dbpprt.com  connected" },
      { k: "blank" },
      { k: "final", html: `<span class="spark">◈</span> <b>Dieter's on it.</b> Open the app to conduct your fleet.` },
    ];

    async function typeCmd(text) {
      const line = document.createElement("span");
      line.className = "tl";
      line.setAttribute("data-in", "");
      body.appendChild(line);
      const prompt = `<span class="sigil">$</span> `;
      const cur = '<span class="cursor" aria-hidden="true"></span>';
      let typed = "";
      for (let i = 0; i < text.length; i++) {
        typed += text[i];
        line.innerHTML = `${prompt}<span class="cmd">${typed}</span>${cur}`;
        await sleep(reduce ? 0 : 26 + Math.random() * 34);
      }
      line.innerHTML = `${prompt}<span class="cmd">${text}</span>`;
      await sleep(260);
    }

    async function addLine(html, cls = "") {
      const line = document.createElement("span");
      line.className = "tl" + (cls ? " " + cls : "");
      line.innerHTML = html;
      body.appendChild(line);
      // force reflow then reveal
      void line.offsetWidth;
      line.setAttribute("data-in", "");
      await sleep(reduce ? 0 : 150);
    }

    async function runProgress(label, ms) {
      const line = document.createElement("span");
      line.className = "tl";
      line.setAttribute("data-in", "");
      body.appendChild(line);
      const steps = reduce ? [100] : [6, 18, 33, 51, 68, 82, 94, 100];
      for (const pct of steps) {
        line.innerHTML = `<span class="muted">${label}</span>  ${bar(pct)}`;
        await sleep(ms / steps.length);
      }
    }

    function pad(text) { return (text + " ").padEnd(30, "·").replace(/·$/, "·"); }

    async function run() {
      if (running) return;
      running = true;
      body.innerHTML = "";
      replay.removeAttribute("data-show");
      await sleep(reduce ? 0 : 250);

      for (const step of script) {
        if (step.k === "cmd") await typeCmd(step.text);
        else if (step.k === "out") await addLine(step.html);
        else if (step.k === "progress") await runProgress(step.label, step.ms);
        else if (step.k === "blank") await addLine("&nbsp;");
        else if (step.k === "final") await addLine(step.html, "is-final");
        else if (step.k === "check")
          await addLine(`<span class="ok">✓</span> <span class="cmd">${padName(step.text)}</span><span class="muted">${step.val}</span>`);
        else if (step.k === "arrow")
          await addLine(`<span class="key">→</span> <span class="cmd">${padName(step.text)}</span><span class="accent">${step.val}</span>`);
      }
      replay.setAttribute("data-show", "");
      running = false;
    }

    function padName(name) {
      const target = 30;
      const dots = Math.max(2, target - name.length);
      return `${name} <span class="muted">${"·".repeat(dots)}</span> `;
    }

    replay && replay.addEventListener("click", run);

    // Start when scrolled into view
    if (reduce || !("IntersectionObserver" in window)) {
      run();
    } else {
      const io = new IntersectionObserver(
        (entries) => {
          entries.forEach((e) => {
            if (e.isIntersecting) { run(); io.disconnect(); }
          });
        },
        { threshold: 0.4 }
      );
      io.observe(root);
    }
  }
})();
