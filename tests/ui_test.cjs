'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ui = path.join(__dirname, '../src/model_size_info/ui');
const html = fs.readFileSync(path.join(ui, 'panel.html'), 'utf8');
const source = fs.readFileSync(path.join(ui, 'panel.js'), 'utf8');
const treeSource = fs.readFileSync(path.join(ui, 'tree.js'), 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
assert.equal(new Set(ids).size, ids.length, 'HTML IDs must be unique');
for (const file of ['panel.css', 'panel.js', 'tree.js']) assert.ok(fs.existsSync(path.join(ui, file)));

class Element {
  constructor(tag = 'div') {
    this.tagName = tag; this.children = []; this.events = {}; this.attributes = {}; this.textContent = ''; this.className = '';
    this.style = {};
    this.classList = { toggle: (name, active) => { this.attributes['class:' + name] = active; } };
    Object.defineProperty(this, 'innerHTML', { set() { throw new Error('HTML injection sink used'); } });
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  addEventListener(event, callback) { this.events[event] = callback; }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() { this.focused = true; }
}

function mount(connected = true) {
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const events = {};
  const messages = [];
  const bridge = {};
  for (const name of ['ready', 'scope', 'auto', 'measure', 'refresh', 'cancel', 'locate']) bridge[name] = (...args) => messages.push({ name, args });
  const document = {
    getElementById(id) { assert.ok(nodes[id], 'Missing HTML element ' + id); return nodes[id]; },
    createElement(tag) { return new Element(tag); },
    addEventListener(event, callback) { events[event] = callback; }
  };
  const window = connected ? { sketchup: bridge } : {};
  const context = vm.createContext({ window, document, Intl, Number });
  vm.runInContext(treeSource, context);
  vm.runInContext(source, context);
  events.DOMContentLoaded();
  return { nodes, messages, api: window.ModelSizeInfo };
}

let checks = 0;
function check(name, fn) { fn(); checks++; console.log('PASS: ' + name); }
const app = mount();
const { api, nodes, messages } = app;
check('native ready callback is sent on page load', () => assert.equal(messages[0].name, 'ready'));
for (const [bytes, value, unit] of [[null, '—', ''], [0, '0', 'B'], [1023, '1023', 'B'], [1024, '1.00', 'KB'], [1048576, '1.00', 'MB'], [1073741824, '1.00', 'GB']]) {
  check('binary byte units for ' + bytes, () => { const result = api.formatBytes(bytes); assert.equal(result.value, value); assert.equal(result.unit, unit); });
}
const base = {
  kind: 'selection', title: '家具组件', subtitle: '组件', measurement_label: '独立组件 SKP 体积', bytes: 1048576,
  measurement_state: 'ready', measured_at: null, selected_count: 1, definition_count: 1, direct_entities: 102,
  instance_count: 8, loose_count: 0, pending_count: 0, rows: [{ id: '1', name: '家具组件', kind: '组件', selected_instances: 1, bytes: 1048576 }],
  file: { name: '模型.skp', bytes: 2097152, saved: true, modified: false }, note: '组件定义的独立文件体积。',
  scope: 'follow', auto: true, auto_limit: 3, busy: false, error: null, version: '1.1.1'
};
api.render(base);
check('selection renders size and properties', () => { assert.equal(nodes['size-value'].textContent, '1.00'); assert.equal(nodes['size-unit'].textContent, 'MB'); assert.equal(nodes['instance-count'].textContent, '8'); });
check('single selection hides unnecessary breakdown', () => assert.equal(nodes.breakdown.hidden, true));
check('selected scope uses accessible pressed state', () => { assert.equal(nodes['scope-follow'].attributes['aria-pressed'], 'true'); assert.equal(nodes['scope-model'].attributes['aria-pressed'], 'false'); });
const malicious = '<img src=x onerror=alert(1)>中文 & 名称';
api.render({ ...base, title: malicious, selected_count: 2, rows: [{ ...base.rows[0], name: malicious }] });
check('model and definition names are inserted only as literal text', () => { assert.equal(nodes['object-name'].textContent, malicious); assert.equal(nodes['definition-list'].children[0].children[0].children[0].textContent, malicious); });
api.render({ ...base, busy: true, bytes: null, pending_count: 2 });
check('busy state shows progress and blocks duplicate measurement', () => { assert.equal(nodes.progress.hidden, false); assert.equal(nodes.measure.disabled, true); assert.equal(nodes.cancel.hidden, false); });
api.render({ ...base, bytes: null, measurement_state: 'pending', pending_count: 4, definition_count: 4 });
check('large selections explain manual measurement', () => assert.match(nodes['size-detail'].textContent, /点击.*4/));
api.render({ ...base, bytes: null, measurement_state: 'partial', loose_count: 2 });
check('mixed raw geometry never shows a fabricated aggregate', () => { assert.equal(nodes['size-value'].textContent, '—'); assert.match(nodes['size-detail'].textContent, /无法完整测量/); });
api.render({ ...base, kind: 'model', scope: 'model', bytes: null, measurement_state: 'unsaved', direct_entities: 0, instance_count: null, rows: [], file: { name: '尚未保存的模型', bytes: null, saved: false, modified: true } });
check('unsaved models can still be measured as a current copy', () => { assert.equal(nodes.measure.textContent, '测量当前模型'); assert.equal(nodes.measure.disabled, false); assert.match(nodes['size-detail'].textContent, /尚未保存/); assert.equal(nodes['instances-row'].hidden, true); });
api.render({ ...base, error: '临时目录无法写入' });
check('errors are visible without sticking in busy state', () => { assert.equal(nodes.error.hidden, false); assert.equal(nodes.error.textContent, '临时目录无法写入'); assert.equal(nodes.status.textContent, '测量失败'); assert.equal(nodes.measure.disabled, false); });
api.render({ ...base, bytes: null, measurement_state: 'unsupported', rows: [] });
check('unsupported selections cannot trigger an export', () => assert.equal(nodes.measure.disabled, true));
nodes['scope-model'].events.click(); nodes['scope-follow'].events.click();
nodes.auto.checked = false; nodes.auto.events.change.call(nodes.auto);
nodes.measure.events.click(); nodes.refresh.events.click(); nodes.cancel.events.click();
check('all controls call the correct native bridge with typed arguments', () => {
  assert.deepEqual(messages.slice(1), [
    { name: 'scope', args: ['model'] }, { name: 'scope', args: ['follow'] }, { name: 'auto', args: [false] },
    { name: 'measure', args: [] }, { name: 'refresh', args: [] }, { name: 'cancel', args: [] }
  ]);
});
const offline = mount(false);
check('opening HTML outside SketchUp never pretends to measure a model', () => { assert.equal(offline.nodes.measure.disabled, true); assert.match(offline.nodes.status.textContent, /未连接/); });

function rootRows() { return nodes['component-tree'].children.filter(item => item.children[0] && item.children[0].className === 'tree-row').map(item => item.children[0]); }
function allRows(element = nodes['component-tree']) {
  const rows = [];
  for (const child of element.children) {
    if (child.className === 'tree-row') rows.push(child);
    rows.push(...allRows(child));
  }
  return rows;
}
const graph = {
  roots: [
    { id: '10', definition_id: '502', name: 'B 餐桌', kind: '组件', locked: true },
    { id: '11', definition_id: '501', name: 'C 台灯', kind: '组件' },
    { id: '12', definition_id: '502', name: 'A 餐桌', kind: '群组' }
  ],
  definitions: {
    '502': { name: '餐桌', children: [{ id: '20', definition_id: '501', name: malicious, kind: '组件', hidden: true }] },
    '501': { name: '台灯', children: [] }
  }
};
const treeBase = { ...base, kind: 'tree', scope: 'tree', rows: [], bytes: null,
  tree_token: 'tree-1', tree_complete: true, tree_root_count: 3, tree_scanned: 125, tree_measured: 0,
  tree_errors: 0, pending_count: 2, definition_count: 2, tree_sizes: { '501': { bytes: null }, '502': { bytes: null } },
  tree_structure: graph, note: '父级已包含子级，不能逐行相加。'
};
api.render(treeBase);
check('tree mode replaces the single-size panel and keeps range state accessible', () => {
  assert.equal(nodes.primary.hidden, true); assert.equal(nodes.properties.hidden, true);
  assert.equal(nodes['tree-view'].hidden, false); assert.equal(nodes['auto-option'].hidden, true);
  assert.equal(nodes['scope-tree'].attributes['aria-pressed'], 'true'); assert.equal(nodes.breakdown.hidden, true);
});
check('tree header counts roots and unique definitions without an aggregate file total', () => {
  assert.equal(nodes['tree-root-count'].textContent, '3'); assert.equal(nodes['tree-definition-count'].textContent, '2');
  assert.equal(nodes['tree-measured-count'].textContent, '0'); assert.equal(nodes.measure.textContent, '测量组件树');
});
check('tree initially draws only roots and uses a stable name tie-breaker', () => {
  assert.equal(allRows().length, 3); assert.equal(rootRows()[0].children[2].children[0].textContent, 'A 餐桌');
  assert.equal(rootRows()[0].children[3].textContent, '待测量');
});
rootRows()[0].children[0].events.click();
check('expanding a branch lazily draws its nested children', () => {
  assert.equal(allRows().length, 4); assert.equal(rootRows()[0].children[0].attributes['aria-expanded'], 'true');
  assert.equal(allRows()[1].children[2].children[0].textContent, malicious);
  assert.match(allRows()[1].children[2].children[1].textContent, /隐藏/);
});
allRows()[1].children[2].events.click();
check('clicking a nested name sends the exact parent-instance path and tree token', () => {
  const message = messages.at(-1); assert.equal(message.name, 'locate');
  assert.equal(message.args[0].path, '12.20'); assert.equal(message.args[0].token, 'tree-1');
});
const partialTree = { ...treeBase, tree_structure: null, busy: true, tree_measured: 1, pending_count: 1,
  tree_sizes: { '502': { bytes: 32768 }, '501': { bytes: null } } };
const originalRow = rootRows()[0];
api.render(partialTree);
check('progress updates patch sizes without destroying expanded rows or focus', () => {
  assert.equal(rootRows()[0], originalRow); assert.equal(allRows().length, 4);
  assert.equal(rootRows()[0].children[3].textContent, '32.00 KB');
  assert.equal(rootRows()[1].children[3].textContent, '32.00 KB');
  assert.equal(nodes.measure.disabled, true); assert.equal(nodes['tree-sort'].disabled, true);
});
api.render({ ...partialTree, busy: false });
check('stopped measurements preserve expansion and offer continuation', () => {
  assert.equal(allRows().length, 4); assert.equal(nodes.measure.textContent, '继续测量');
  assert.equal(nodes.cancel.hidden, true); assert.equal(nodes.measure.disabled, false);
});
const measuredTree = { ...partialTree, busy: true, pending_count: 0, tree_measured: 2,
  tree_sizes: { '502': { bytes: 32768 }, '501': { bytes: 65536 } } };
api.render(measuredTree);
check('rows hold their order while an export queue runs', () => assert.equal(rootRows()[0].children[2].children[0].textContent, 'A 餐桌'));
api.render({ ...measuredTree, busy: false });
check('finishing applies size sorting within each level and keeps open branches', () => {
  assert.equal(rootRows()[0].children[2].children[0].textContent, 'C 台灯');
  assert.equal(rootRows()[1].children[2].children[0].textContent, 'A 餐桌'); assert.equal(allRows().length, 4);
  assert.equal(nodes.measure.textContent, '重新测量组件树');
});
nodes['tree-sort'].value = 'model'; nodes['tree-sort'].events.change.call(nodes['tree-sort']);
check('object-ID sorting restores the supplied directory order', () => assert.equal(rootRows()[0].children[2].children[0].textContent, 'B 餐桌'));
nodes['tree-sort'].value = 'name'; nodes['tree-sort'].events.change.call(nodes['tree-sort']);
check('name sorting works independently of measured size', () => assert.equal(rootRows()[0].children[2].children[0].textContent, 'A 餐桌'));
nodes['tree-collapse'].events.click();
check('collapse all keeps roots and removes only expanded children', () => assert.equal(allRows().length, 3));
api.render({ ...measuredTree, busy: false, error: '1 个定义测量失败', tree_errors: 1,
  tree_sizes: { '502': { bytes: null, error: '没有足够空间' }, '501': { bytes: 65536 } } });
check('definition failures display a specific tooltip and keep successful values', () => {
  assert.equal(rootRows()[0].children[3].textContent, '失败'); assert.equal(rootRows()[0].children[3].title, '没有足够空间');
  assert.equal(rootRows()[2].children[3].textContent, '64.00 KB'); assert.equal(nodes['tree-status'].textContent, '部分失败');
});
nodes['scope-tree'].events.click();
check('tree tab calls the native scope callback', () => assert.equal(messages.at(-1).args[0], 'tree'));

const many = Array.from({ length: 205 }, (_, i) => ({ id: String(1000 + i), definition_id: '501', name: '对象 ' + i, kind: '组件' }));
api.render({ ...treeBase, tree_token: 'tree-many', tree_root_count: 205, tree_structure: { roots: many, definitions: graph.definitions } });
check('large sibling collections start with one bounded page', () => {
  assert.equal(rootRows().length, 100); assert.match(nodes['component-tree'].children.at(-1).children[0].textContent, /剩余 105/);
});
nodes['component-tree'].children.at(-1).children[0].events.click();
check('the next page retains earlier rows and reports remaining items', () => {
  assert.equal(rootRows().length, 200); assert.match(nodes['component-tree'].children.at(-1).children[0].textContent, /剩余 5/);
});
nodes['component-tree'].children.at(-1).children[0].events.click();
check('pagination can reach every object without a silent truncation limit', () => assert.equal(rootRows().length, 205));
api.render({ ...treeBase, tree_token: 'tree-new' });
check('a refreshed graph resets old pages and branch expansion', () => assert.equal(allRows().length, 3));
const recursive = { id: '60', definition_id: '900', name: '循环对象', kind: '组件' };
api.render({ ...treeBase, tree_token: 'cycle', tree_structure: { roots: [recursive], definitions: { '900': { name: '循环', children: [recursive] } } } });
rootRows()[0].children[0].events.click();
check('recursive references stop at a labeled non-expandable child', () => {
  assert.equal(allRows().length, 2); assert.equal(allRows()[1].children[0].disabled, true);
  assert.match(allRows()[1].children[2].children[1].textContent, /循环引用/);
});
api.render({ ...treeBase, tree_token: 'scanning', tree_complete: false, busy: true, tree_structure: null, tree_scanned: 2000 });
check('scanning has a distinct progress message and blocks duplicate exports', () => {
  assert.equal(nodes['tree-status'].textContent, '正在扫描'); assert.match(nodes['tree-detail'].textContent, /2,000/);
  assert.equal(nodes['tree-progress'].hidden, false); assert.equal(nodes.measure.disabled, true);
  assert.match(nodes['tree-detail'].textContent, /群组.*组件.*跳过面、线/);
});
api.render({ ...treeBase, tree_token: 'scanning', tree_complete: false, busy: false, tree_structure: null });
check('paused hierarchy scans can be resumed explicitly', () => {
  assert.equal(nodes.measure.textContent, '继续扫描并测量'); assert.equal(nodes.measure.disabled, false);
  assert.match(nodes['tree-empty'].textContent, /暂停/);
});
api.render({ ...treeBase, tree_token: 'empty', tree_root_count: 0, tree_measured: 0, pending_count: 0, definition_count: 0,
  tree_structure: { roots: [], definitions: {} } });
check('an empty tree explains the result and disables pointless measurement', () => {
  assert.match(nodes['tree-empty'].textContent, /没有群组或组件/); assert.equal(nodes.measure.disabled, true); assert.equal(allRows().length, 0);
});
api.render(base);
check('switching back restores the existing selection panel', () => {
  assert.equal(nodes.primary.hidden, false); assert.equal(nodes['tree-view'].hidden, true); assert.equal(nodes['auto-option'].hidden, false);
});
console.log(checks + ' UI logic checks passed.');
