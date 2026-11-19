// Dependency graph page for BeadsDesktop. Receives a JSON payload from Swift via `render(payload)`.
// All text from the repository is drawn on canvas by Cytoscape (never inserted as HTML).
'use strict';

cytoscape.use(cytoscapeDagre);

let cy = null;
let lastKey = null;

function post(name, body) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
  if (h) h.postMessage(body);
}

function palette(dark) {
  return dark ? {
    text: '#f2f2f7', subtle: '#8e8e93', node: '#2c2c2e', border: '#48484a', edge: '#636366',
    accent: '#0a84ff', outside: '#1c1c1e',
  } : {
    text: '#1c1c1e', subtle: '#8e8e93', node: '#ffffff', border: '#d1d1d6', edge: '#aeaeb2',
    accent: '#007aff', outside: '#f2f2f7',
  };
}

const columnColor = {
  backlog: '#8e8e93', ready: '#0a84ff', inProgress: '#ff9f0a', blocked: '#ff453a', done: '#30d158',
};

function truncate(s, n) { return s.length > n ? s.slice(0, n - 1) + '…' : s; }

function elements(p) {
  const nodes = p.nodes.map(n => ({
    data: {
      id: 'n:' + n.id,
      beadId: n.id,
      label: n.id + '\n' + truncate(n.title, 46),
      color: columnColor[n.column] || '#8e8e93',
      inside: n.inside ? 1 : 0,
      anchor: n.id === p.anchor ? 1 : 0,
      closed: n.status === 'closed' ? 1 : 0,
      epic: n.type === 'epic' ? 1 : 0,
    },
  }));
  // Namespaced ids: node ids come from the repository and must never collide with edge ids.
  const edges = p.edges.map((e, i) => ({
    data: { id: 'e:' + i, source: 'n:' + e.source, target: 'n:' + e.target, type: e.type },
  }));
  return nodes.concat(edges);
}

function style(c) {
  return [
    { selector: 'node', style: {
      'shape': 'round-rectangle', 'width': 190, 'height': 46, 'background-color': c.node,
      'border-width': 1, 'border-color': c.border, 'label': 'data(label)', 'color': c.text,
      'font-size': 10, 'text-wrap': 'wrap', 'text-max-width': 176, 'text-valign': 'center', 'text-halign': 'center',
      'font-family': '-apple-system, system-ui, sans-serif',
    } },
    // Border in the board-column color (Ready blue, In Progress orange, Blocked red, Done green).
    { selector: 'node', style: { 'border-width': 2, 'border-color': 'data(color)' } },
    { selector: 'node[inside = 0]', style: { 'background-color': c.outside, 'border-style': 'dashed', 'opacity': 0.8 } },
    { selector: 'node[closed = 1]', style: { 'opacity': 0.55 } },
    { selector: 'node[epic = 1]', style: { 'border-width': 3, 'font-weight': 'bold' } },
    { selector: 'node[anchor = 1]', style: { 'underlay-color': c.accent, 'underlay-padding': 5, 'underlay-opacity': 0.35,
                                             'underlay-shape': 'round-rectangle' } },
    { selector: 'node:selected', style: { 'underlay-color': c.accent, 'underlay-padding': 6, 'underlay-opacity': 0.6,
                                          'underlay-shape': 'round-rectangle', 'overlay-opacity': 0 } },
    { selector: 'edge', style: {
      'width': 1.5, 'line-color': c.edge, 'target-arrow-color': c.edge, 'target-arrow-shape': 'triangle',
      'curve-style': 'bezier', 'arrow-scale': 0.9,
    } },
    // Blocking edges red-ish, hierarchy dashed without arrow, other links dotted.
    { selector: 'edge[type = "blocks"], edge[type = "waits-for"], edge[type = "conditional-blocks"]',
      style: { 'line-color': '#ff6961', 'target-arrow-color': '#ff6961' } },
    { selector: 'edge[type = "parent-child"]', style: { 'line-style': 'dashed', 'target-arrow-shape': 'none' } },
    { selector: 'edge[type != "blocks"][type != "waits-for"][type != "conditional-blocks"][type != "parent-child"]',
      style: { 'line-style': 'dotted', 'target-arrow-shape': 'vee' } },
  ];
}

// Called from Swift. Returns a small status object for logging.
window.render = function (payload) {
  const p = typeof payload === 'string' ? JSON.parse(payload) : payload;
  const c = palette(!!p.dark);
  document.getElementById('empty').style.display = p.nodes.length ? 'none' : 'flex';

  // Same graph (e.g. a refresh with no relevant change, or only selection changed): keep layout and viewport.
  const key = p.key;
  if (cy && key === lastKey) {
    cy.style(style(c));
    select(p.selected);
    return { nodes: cy.nodes().length, relayout: false };
  }
  lastKey = key;
  if (cy) cy.destroy();
  cy = cytoscape({
    container: document.getElementById('cy'),
    elements: elements(p),
    style: style(c),
    wheelSensitivity: 0.25,
    minZoom: 0.1,
    maxZoom: 2.5,
    boxSelectionEnabled: false,
    autoungrabify: false,
  });
  cy.layout({ name: 'dagre', rankDir: 'LR', nodeSep: 18, rankSep: 70, edgeSep: 8, animate: false, fit: true,
              padding: 30 }).run();
  const anchor = cy.getElementById('n:' + p.anchor);
  if (anchor && anchor.length && cy.nodes().length > 25) {
    cy.zoom(Math.max(cy.zoom(), 0.6));
    cy.center(anchor);
  }
  select(p.selected);
  cy.on('tap', 'node', evt => post('select', evt.target.data('beadId')));
  cy.on('tap', evt => { if (evt.target === cy) post('select', ''); });
  return { nodes: cy.nodes().length, relayout: true };
};

function select(id) {
  if (!cy) return;
  cy.nodes(':selected').unselect();
  if (id) cy.getElementById('n:' + id).select();
}

post('ready', '');
