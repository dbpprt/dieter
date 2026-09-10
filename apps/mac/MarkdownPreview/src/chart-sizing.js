const compositions = ['facet', 'repeat', 'concat', 'hconcat', 'vconcat'];

function isSingleOrLayer(spec) {
  if (!spec || typeof spec !== 'object') return false;
  if (compositions.some(key => Object.hasOwn(spec, key))) return false;
  if (['row', 'column', 'facet'].some(key => Object.hasOwn(spec.encoding ?? {}, key))) return false;
  return Object.hasOwn(spec, 'mark') || (Array.isArray(spec.layer) && spec.layer.every(isSingleOrLayer));
}

function declaresSize(spec, dimension) {
  const suffix = dimension === 'width' ? 'Width' : 'Height';
  const config = spec.config?.view ?? {};
  return Object.hasOwn(spec, dimension) ||
    [dimension, `continuous${suffix}`, `discrete${suffix}`, 'step'].some(key => Object.hasOwn(config, key)) ||
    (spec.layer ?? []).some(child => declaresSize(child, dimension));
}

function widths(spec) {
  const config = spec.config?.view ?? {};
  return [spec.width, config.width, config.continuousWidth, config.discreteWidth,
    ...((spec.layer ?? []).flatMap(widths))].filter(value => value !== undefined);
}

function hasStepWidth(spec) {
  return widths(spec).some(value => typeof value === 'object' && value !== null) ||
    Object.hasOwn(spec.config?.view ?? {}, 'step') || (spec.layer ?? []).some(hasStepWidth);
}

function withoutLayerWidths(spec) {
  const copy = {...spec};
  delete copy.width;
  if (copy.layer) copy.layer = copy.layer.map(withoutLayerWidths);
  return copy;
}

export function previewChartSizing(spec, kind, containerWidth = 0) {
  if (kind !== 'vega-lite' || !isSingleOrLayer(spec) || hasStepWidth(spec)) {
    return {spec, responsiveWidth: false, maximumWidth: Infinity};
  }
  const explicitWidths = widths(spec).filter(value => typeof value === 'number' && value > 0 && Number.isFinite(value));
  const maximumWidth = typeof spec.width === 'number' && spec.width > 0
    ? spec.width : explicitWidths.length ? Math.max(...explicitWidths) : Infinity;
  const defaultHeight = !declaresSize(spec, 'height');
  const sized = {
    ...withoutLayerWidths(spec),
    width: containerWidth > 0 ? Math.min(containerWidth, maximumWidth) : 'container',
    ...(defaultHeight ? {height: 260} : {}),
    autosize: {type: 'fit-x', contains: 'padding'},
  };
  return {spec: sized, responsiveWidth: true, maximumWidth};
}

function wrapLines(value, width, measure) {
  const lines = [];
  for (const original of (Array.isArray(value) ? value : [value]).flatMap(line => line.split('\n'))) {
    let line = '';
    for (const word of original.trim().split(/\s+/)) {
      if (!word) continue;
      if (line && measure(line + ' ' + word) <= width) { line += ' ' + word; continue; }
      if (line) { lines.push(line); line = ''; }
      if (measure(word) <= width) { line = word; continue; }
      // Very long unbroken labels need wrapping too. Sum character advances to
      // keep this bounded rather than repeatedly measuring a growing substring.
      let advance = 0;
      for (const character of word) {
        const next = measure(character);
        if (line && advance + next > width) { lines.push(line); line = ''; advance = 0; }
        line += character;
        advance += next;
      }
    }
    lines.push(line);
  }
  return lines;
}

// Plain titles become private variable parameters in a render-only spec copy.
// Signal updates rewrap them without recreating the view or losing selections.
export function prepareChartTitles(document, spec, width) {
  if (!spec.title) return {spec, update() {}};
  const title = typeof spec.title === 'string' || Array.isArray(spec.title) ? {text: spec.title} : {...spec.title};
  const serialized = JSON.stringify(spec);
  const fields = [];
  const params = [...(spec.params ?? [])];
  let nextID = 0;
  for (const key of ['text', 'subtitle']) {
    const original = title[key];
    if (!(typeof original === 'string' || (Array.isArray(original) && original.every(value => typeof value === 'string')))) continue;
    let name;
    do { name = `__dieter_preview_title_${nextID++}`; } while (serialized.includes(name));
    const prefix = key === 'subtitle' ? 'subtitle' : '';
    const config = spec.config?.title ?? {};
    const fontSize = title[prefix ? 'subtitleFontSize' : 'fontSize'] ?? config[prefix ? 'subtitleFontSize' : 'fontSize'] ?? (prefix ? 12 : 13);
    const font = title[prefix ? 'subtitleFont' : 'font'] ?? config[prefix ? 'subtitleFont' : 'font'] ?? spec.config?.font ?? 'sans-serif';
    const weight = title[prefix ? 'subtitleFontWeight' : 'fontWeight'] ?? config[prefix ? 'subtitleFontWeight' : 'fontWeight'] ?? (prefix ? 'normal' : 'bold');
    const canvas = document.createElement('canvas').getContext('2d');
    if (canvas) canvas.font = `${weight} ${typeof fontSize === 'number' ? fontSize : 13}px ${typeof font === 'string' ? font : 'sans-serif'}`;
    const measure = value => canvas ? canvas.measureText(value).width : value.length * 7;
    const wrapped = available => wrapLines(original, Math.max(40, available - 32), measure);
    fields.push({name, wrapped});
    params.push({name, value: wrapped(width > 0 ? width : 300)});
    title[key] = {expr: name};
  }
  return {spec: {...spec, title, params}, update(view, available) {
    for (const field of fields) view.signal(field.name, field.wrapped(available));
  }};
}

// Vega can leave content outside its nominal SVG viewport even with fit-x.
// Expand to include its full public scenegraph bounds, then down-fit the entire
// SVG. Intrinsic width/height attributes stay untouched, so resizing back up
// does not accumulate scale and small charts are never stretched.
export function fitChartSVG(element, view) {
  const svg = element.querySelector?.('svg');
  if (!svg) return;
  const intrinsicWidth = Number(svg.getAttribute('width'));
  const intrinsicHeight = Number(svg.getAttribute('height'));
  if (!(intrinsicWidth >= 0 && intrinsicHeight > 0)) return;
  let left = 0, top = 0, right = intrinsicWidth, bottom = intrinsicHeight;
  const bounds = view.scenegraph?.().root?.bounds;
  const origin = view.origin?.() ?? [0, 0];
  const padding = view.padding?.() ?? {};
  if (bounds && [bounds.x1, bounds.y1, bounds.x2, bounds.y2, ...origin].every(Number.isFinite)) {
    const dx = origin[0] + (padding.left ?? 0), dy = origin[1] + (padding.top ?? 0);
    left = Math.min(left, Math.floor(bounds.x1 + dx - 1));
    top = Math.min(top, Math.floor(bounds.y1 + dy - 1));
    right = Math.max(right, Math.ceil(bounds.x2 + dx + 1));
    bottom = Math.max(bottom, Math.ceil(bounds.y2 + dy + 1));
  }
  const width = right - left, height = bottom - top;
  const available = element.clientWidth;
  const scale = available > 0 && width > 0 ? Math.min(1, available / width) : 1;
  svg.setAttribute('viewBox', `${left} ${top} ${width} ${height}`);
  svg.style.width = `${width * scale}px`;
  svg.style.height = `${height * scale}px`;
}

// Observe only a container whose width is set by CSS, never the rendered SVG.
// Coalesce changes while a view update is pending, ignore height-only layout
// changes, and avoid concurrent runAsync calls or ResizeObserver feedback loops.
export function observeChartWidth({element, view, isCurrent, onError, responsiveWidth = true, maximumWidth = Infinity,
  beforeResize = () => {}, initialWidth = element.clientWidth, ResizeObserver = globalThis.ResizeObserver}) {
  if (!ResizeObserver) return () => {};
  let lastWidth = initialWidth;
  let pendingWidth = 0;
  let running = false;
  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    pendingWidth = 0;
    observer.disconnect();
  };
  async function update() {
    if (running) return;
    running = true;
    try {
      while (pendingWidth && !stopped) {
        if (!isCurrent()) { stop(); break; }
        const width = pendingWidth;
        pendingWidth = 0;
        if (responsiveWidth) {
          const target = Math.min(width, maximumWidth);
          beforeResize(target);
          await view.width(target).resize().runAsync();
        }
        if (!stopped && isCurrent()) fitChartSVG(element, view);
      }
    } catch (error) {
      stop();
      if (isCurrent()) onError(error);
    } finally {
      running = false;
    }
  }
  function resized() {
    if (stopped) return;
    if (!isCurrent()) { stop(); return; }
    const width = element.clientWidth;
    if (width <= 0 || width === lastWidth) return;
    lastWidth = width;
    pendingWidth = width;
    void update();
  }
  const observer = new ResizeObserver(resized);
  observer.observe(element);
  // The pane can change while embed is awaiting its initial render.
  resized();
  return stop;
}
