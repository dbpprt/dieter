// Theme defaults belong to the shared renderer. Author-specified colors still
// win when Vega/Vega-Lite merge the specification with these defaults.
export function chartThemeConfig(document, spec, kind, theme) {
  const readerDark = theme === "dark";
  const background = Object.hasOwn(spec, "background") ? spec.background : spec.config?.background;
  let dark = readerDark;
  if (typeof background === "string") {
    // Let the browser resolve CSS named/hex/rgb colors without loading a
    // resource or interpreting a Vega signal. Blend translucent colors with
    // the reader before choosing foreground defaults.
    const probe = document.createElement("span");
    probe.style.color = background;
    probe.hidden = true;
    if (probe.style.color) {
      document.body.append(probe);
      const color = document.defaultView.getComputedStyle(probe).color;
      probe.remove();
      const match = color.match(/^rgba?\(([^)]+)\)$/);
      if (match) {
        const [r, g, b, alpha = 1] = match[1].split(/[,\s/]+/).map(Number);
        const base = readerDark ? 30 : 255;
        const channels = [r, g, b].map((value) => {
          const s = (value * alpha + base * (1 - alpha)) / 255;
          return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
        });
        const luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        dark = luminance < 0.179;
      }
    }
  }
  const foreground = dark ? "#ededf0" : "#242428";
  const label = dark ? "#d4d4d8" : "#44444b";
  const line = dark ? "#71717a" : "#888888";
  return {
    background: "transparent",
    axisX: { labelAngle: 0, labelOverlap: true },
    axis: {
      labelColor: label,
      titleColor: foreground,
      domainColor: line,
      gridColor: dark ? "#606068" : "#dedee3",
      tickColor: line,
    },
    legend: { labelColor: label, titleColor: foreground },
    title: { color: foreground, subtitleColor: label },
    text: kind === "vega" ? { fill: foreground } : { color: foreground },
    // Raw Vega titles/subtitles use these styles rather than VL's title colors.
    ...(kind === "vega"
      ? { style: { "group-title": { fill: foreground }, "group-subtitle": { fill: label } } }
      : {}),
  };
}
