import mermaid from 'mermaid';
import embed from 'vega-embed';
import {View} from 'vega';
import {expressionInterpreter} from 'vega-interpreter';
import {createOfflineLoader, createRenderer} from './renderer.js';
import {fitChartSVG, observeChartWidth, prepareChartTitles, previewChartSizing} from './chart-sizing.js';
import {createMarkdownDocument} from './document-controller.js';
import './app.css';

const loader = createOfflineLoader();
const preview = createRenderer({
  document,
  root: document.querySelector('#preview'),
  async renderMermaid({id, source, theme, element}) {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
      maxTextSize: 100_000,
      maxEdges: 500,
      htmlLabels: false,
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      theme: theme === 'dark' ? 'dark' : 'default',
      themeCSS: '',
      layout: 'dagre',
      // Prevent document directives/frontmatter from weakening host policy.
      secure: ['secure', 'securityLevel', 'startOnLoad', 'suppressErrorRendering',
        'maxTextSize', 'maxEdges', 'htmlLabels', 'fontFamily', 'themeCSS', 'layout', 'flowchart'],
      flowchart: {htmlLabels: false},
    });
    const {svg} = await mermaid.render(id, source, element);
    return svg;
  },
  async renderChart({element, spec, kind, theme, onView, isCurrent}) {
    const allocated = [];
    const container = document.createElement('div');
    container.className = 'chart-container';
    element.append(container);
    const initialContainerWidth = container.clientWidth;
    const sizing = previewChartSizing(spec, kind, initialContainerWidth);
    let layoutWidth = Math.min(initialContainerWidth, sizing.maximumWidth);
    const titles = sizing.responsiveWidth ? prepareChartTitles(document, sizing.spec, layoutWidth) : {spec: sizing.spec, update() {}};
    let stopResizing;
    class PreviewView extends View {
      constructor(runtime, options) {
        super(runtime, options);
        allocated.push(this);
        if (!isCurrent()) {
          this.finalize();
          throw new Error('Render superseded.');
        }
        onView(this);
      }
      finalize() {
        stopResizing?.();
        return super.finalize();
      }
      async runAsync(...args) {
        const result = await super.runAsync(...args);
        if (!isCurrent()) return result;
        // A legend or axis label can require more space than fit-x has left for
        // marks. Retain a usable plot, then include/down-fit all surrounding text.
        if (sizing.responsiveWidth && layoutWidth > 0 && this.width() < Math.min(80, layoutWidth * 0.2)) {
          this.signal('autosize', {type: 'pad', contains: 'padding'}).width(layoutWidth).resize();
          await super.runAsync();
        }
        if (isCurrent()) fitChartSVG(container, this);
        return result;
      }
    }
    try {
      const result = await embed(container, titles.spec, {
        mode: kind,
        renderer: 'svg',
        actions: false,
        tooltip: false,
        defaultStyle: false,
        ast: true,
        expr: expressionInterpreter,
        viewClass: PreviewView,
        loader,
        config: {
          background: 'transparent',
          axisX: {labelAngle: 0, labelOverlap: true},
          ...(theme === 'dark' ? {
            axis: {labelColor: '#d4d4d8', titleColor: '#eeeeef', domainColor: '#71717a', gridColor: '#3f3f46', tickColor: '#71717a'},
            legend: {labelColor: '#d4d4d8', titleColor: '#eeeeef'},
            title: {color: '#eeeeef'},
            text: {color: '#eeeeef'},
          } : {}),
        },
      });
      if (isCurrent()) {
        stopResizing = observeChartWidth({element: container, view: result.view, isCurrent, initialWidth: initialContainerWidth,
          responsiveWidth: sizing.responsiveWidth, maximumWidth: sizing.maximumWidth,
          beforeResize(width) {
            layoutWidth = width;
            titles.update(result.view, width);
            result.view.signal('autosize', {type: 'fit-x', contains: 'padding'});
          },
          onError(error) {
            result.finalize();
            element.dataset.state = 'error';
            const message = document.createElement('p');
            message.className = 'diagram-error';
            message.setAttribute('role', 'status');
            message.textContent = `${kind}: ${String(error?.message ?? error).slice(0, 500)}`;
            element.append(message);
          },
        });
      }
      return result;
    } catch (error) {
      // Embed may fail after constructing a view but before returning its result.
      for (const view of allocated) view.finalize();
      throw error;
    }
  },
});

const api = createMarkdownDocument({document, root: document.querySelector('#preview'), preview,
  postMessage(payload) { window.webkit?.messageHandlers?.markdown?.postMessage(payload); },
});
window.dieterMarkdown = api;
window.addEventListener('pagehide', () => api.dispose());
