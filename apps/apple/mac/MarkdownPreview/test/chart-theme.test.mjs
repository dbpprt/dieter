import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { chartThemeConfig } from "../src/chart-theme.js";

test("transparent chart text follows the reader, opaque and translucent colors choose contrasting defaults", () => {
  const { window } = new JSDOM("<body></body>");
  try {
    for (const kind of ["vega-lite", "vega"]) {
      for (const theme of ["light", "dark"]) {
        for (const background of [undefined, null, "transparent"]) {
          const config = chartThemeConfig(window.document, { background }, kind, theme);
          assert.equal(config.title.color, theme === "dark" ? "#ededf0" : "#242428");
          assert.equal(config.title.subtitleColor, config.legend.labelColor);
          assert.equal(config.text[kind === "vega" ? "fill" : "color"], config.title.color);
        }
        for (const background of [
          "white",
          "#ffffff",
          "rgb(255,255,255)",
          "rgba(255,255,255,.95)",
        ]) {
          assert.equal(
            chartThemeConfig(window.document, { background }, kind, theme).title.color,
            "#242428",
          );
        }
        for (const background of ["black", "#111", "navy", "rgba(0,0,0,.95)"]) {
          assert.equal(
            chartThemeConfig(window.document, { background }, kind, theme).title.color,
            "#ededf0",
          );
        }
        const spec = { background: null, config: { background: "white" } };
        const original = JSON.stringify(spec);
        assert.equal(
          chartThemeConfig(window.document, spec, kind, theme).title.color,
          theme === "dark" ? "#ededf0" : "#242428",
        );
        assert.equal(JSON.stringify(spec), original);
      }
    }
    assert.equal(window.document.body.children.length, 0, "Temporary color probes are removed");
  } finally {
    window.close();
  }
});
