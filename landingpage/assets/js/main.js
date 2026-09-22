/* Progressive enhancements. Navigation and documentation remain usable without JS. */
(() => {
  "use strict";
  document.documentElement.classList.remove("no-js");
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const nav = $("[data-nav]");
  const onScroll = () =>
    nav?.toggleAttribute("data-scrolled", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  function toggleMenu(button, attribute) {
    if (!button) return;
    button.addEventListener("click", () => {
      const open = document.body.toggleAttribute(attribute);
      button.setAttribute("aria-expanded", String(open));
    });
  }
  toggleMenu($("[data-nav-toggle]"), "data-menu");
  toggleMenu($("[data-docnav-toggle]"), "data-docmenu");
  $$(".nav__links a").forEach((link) =>
    link.addEventListener("click", () => {
      document.body.removeAttribute("data-menu");
      $("[data-nav-toggle]")?.setAttribute("aria-expanded", "false");
    }),
  );
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    for (const [attribute, selector] of [
      ["data-menu", "[data-nav-toggle]"],
      ["data-docmenu", "[data-docnav-toggle]"],
    ]) {
      if (document.body.hasAttribute(attribute)) {
        document.body.removeAttribute(attribute);
        const button = $(selector);
        button?.setAttribute("aria-expanded", "false");
        button?.focus();
      }
    }
  });

  const copyIcon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
  $$(".prose .highlight").forEach((block) => {
    const code = $("code", block);
    if (!code) return;
    const button = document.createElement("button");
    button.className = "code-copy";
    button.type = "button";
    button.setAttribute("aria-label", "Copy code");
    button.dataset.copy = code.textContent.replace(/\n$/, "");
    button.innerHTML = copyIcon;
    block.append(button);
  });
  $$("[data-copy]").forEach((button) =>
    button.addEventListener("click", async () => {
      let copied = false;
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        copied = true;
      } catch {
        const input = document.createElement("textarea");
        input.value = button.dataset.copy;
        input.style.position = "fixed";
        input.style.opacity = "0";
        document.body.append(input);
        input.select();
        try {
          copied = document.execCommand("copy");
        } catch {
          /* Show failure below. */
        }
        input.remove();
        button.focus();
      }
      const previous = button.getAttribute("aria-label");
      button.setAttribute(
        "aria-label",
        copied ? "Copied" : "Copy failed; select the code manually",
      );
      button.toggleAttribute("data-copied", copied);
      setTimeout(() => {
        button.removeAttribute("data-copied");
        button.setAttribute("aria-label", previous);
      }, 1800);
    }),
  );

  const dialog = $("[data-search-dialog]");
  if (!dialog) return;
  const input = $("input", dialog);
  const status = $("#search-status", dialog);
  const results = $("[data-search-results]", dialog);
  let entries;
  let loading;
  let opener;
  async function loadIndex() {
    if (entries) return;
    if (!loading)
      loading = fetch(dialog.dataset.searchUrl)
        .then((response) => {
          if (!response.ok) throw new Error("Search unavailable");
          return response.json();
        })
        .then((data) => {
          entries = data;
        })
        .finally(() => {
          loading = null;
        });
    await loading;
  }
  function render() {
    results.replaceChildren();
    if (!entries) return;
    const terms = input.value.toLowerCase().trim().split(/\s+/).filter(Boolean);
    const ranked = entries
      .map((entry) => {
        const title = entry.title.toLowerCase();
        const text =
          `${title} ${entry.description} ${entry.content}`.toLowerCase();
        return {
          entry,
          score: terms.every((term) => text.includes(term))
            ? 1 + terms.filter((term) => title.includes(term)).length * 10
            : 0,
        };
      })
      .filter((item) => item.score)
      .sort((a, b) => b.score - a.score);
    const matches = ranked.slice(0, 12);
    status.textContent = !terms.length
      ? "Explore a guide, or type to search its contents."
      : ranked.length
        ? `${ranked.length} matching guide${ranked.length === 1 ? "" : "s"}${ranked.length > 12 ? " · showing 12" : ""}`
        : "No matching guides. Try fewer words.";
    matches.forEach(({ entry }) => {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const title = document.createElement("strong");
      const description = document.createElement("span");
      link.href = entry.url;
      title.textContent = entry.title;
      description.textContent = entry.description;
      link.append(title, description);
      item.append(link);
      results.append(item);
    });
  }
  async function openSearch() {
    if (dialog.open) return;
    opener = document.activeElement;
    dialog.showModal();
    input.focus();
    status.textContent = "Loading guides…";
    try {
      await loadIndex();
      render();
    } catch {
      status.textContent =
        "Search could not load. Use the documentation menu or try again.";
    }
  }
  $$("[data-search-open]").forEach((button) =>
    button.addEventListener("click", openSearch),
  );
  $("[data-search-close]", dialog).addEventListener("click", () =>
    dialog.close(),
  );
  dialog.addEventListener("close", () => opener?.focus());
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      dialog.close();
    }
  });
  input.addEventListener("input", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      $("a", results)?.focus();
    }
    if (event.key === "Enter") $("a", results)?.click();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      openSearch();
    }
  });
})();
