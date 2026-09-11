// Synchronize normalized vertical position, never pixel coordinates: native
// source text and rendered diagrams have different document heights.
export function createPreviewScroll({document, root, postMessage}) {
  const window = document.defaultView;
  let disposed = false;
  let frame = null;
  let intentFrame = null;
  let userIntent = false;
  let lastExtent = extent();
  let lastTop = top();
  let progress = lastExtent > 0 ? lastTop / lastExtent : 0;

  function scroller() { return document.scrollingElement ?? document.documentElement; }
  function extent() { return Math.max(0, scroller().scrollHeight - scroller().clientHeight); }
  function top() { return Math.max(0, Math.min(scroller().scrollTop, extent())); }
  function updatePosition() {
    if (disposed) return;
    const nextExtent = extent();
    const nextTop = progress * nextExtent;
    // Record the actual clamped position before the asynchronous scroll event.
    // That event is then a no-op, even if several peer updates were coalesced.
    if (Math.abs(scroller().scrollTop - nextTop) > 0.5) scroller().scrollTop = nextTop;
    lastExtent = nextExtent;
    lastTop = top();
  }

  function publishScroll() {
    frame = null;
    if (disposed) return;
    const nextExtent = extent();
    if (nextExtent !== lastExtent && !userIntent) {
      updatePosition();
      return;
    }
    const nextTop = top();
    const moved = Math.abs(nextTop - lastTop) > 0.5;
    lastExtent = nextExtent;
    lastTop = nextTop;
    clearIntent();
    if (!moved) return;
    progress = nextExtent > 0 ? nextTop / nextExtent : 0;
    postMessage({type: 'scroll', progress});
  }
  function onScroll() {
    if (disposed || frame !== null) return;
    frame = window.requestAnimationFrame(publishScroll);
  }
  function onInput(event) {
    if (event.type !== 'keydown' || ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) {
      clearIntent();
      userIntent = true;
      // Input alone is not scrolling. Retain intent through the browser's
      // scroll-event frame, then expire it even if no scroll was possible.
      intentFrame = window.requestAnimationFrame(() => {
        intentFrame = window.requestAnimationFrame(clearIntent);
      });
    }
  }
  function clearIntent() {
    userIntent = false;
    if (intentFrame !== null) window.cancelAnimationFrame(intentFrame);
    intentFrame = null;
  }
  function onResize() {
    if (userIntent && Math.abs(top() - lastTop) > 0.5) {
      if (frame !== null) window.cancelAnimationFrame(frame);
      publishScroll();
      return;
    }
    if (extent() !== lastExtent) updatePosition();
  }
  window.addEventListener('scroll', onScroll, {passive: true});
  window.addEventListener('resize', onResize);
  // A pointer click can focus the preview without scrolling. Scrollbar drags
  // are detected by their actual scroll events, not by pointer-down alone.
  const inputEvents = ['wheel', 'touchmove', 'keydown'];
  for (const type of inputEvents) document.addEventListener(type, onInput, {capture: true, passive: true});
  const observer = window.ResizeObserver ? new window.ResizeObserver(onResize) : null;
  observer?.observe(root);

  function setScrollProgress(value, token) {
    if (disposed || typeof value !== 'number' || !Number.isFinite(value)) return {applied: false};
    progress = Math.max(0, Math.min(1, value));
    clearIntent();
    updatePosition();
    return {applied: true, progress, ...(typeof token === 'string' && token.length <= 128 ? {token} : {})};
  }
  function prepareForRender() {
    if (disposed) return;
    // A user event may be waiting for the next animation frame. Capture its
    // position before replacing the document, without treating reflow as input.
    if (extent() === lastExtent && lastExtent > 0) progress = top() / lastExtent;
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    clearIntent();
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    observer?.disconnect();
    window.removeEventListener('scroll', onScroll);
    window.removeEventListener('resize', onResize);
    for (const type of inputEvents) document.removeEventListener(type, onInput, true);
  }
  return Object.freeze({setScrollProgress, prepareForRender, preservePosition: updatePosition, dispose});
}
