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
    Object.defineProperty(this, 'textContent', { get: () => this._textContent + this.children.map(child => child.textContent).join(''), set: value => { this._textContent = String(value); this.children = []; } });
    this._textContent = '';
    this.classList = { toggle: (name, active) => { this.attributes['class:' + name] = active; } };
    Object.defineProperty(this, 'innerHTML', { set() { throw new Error('HTML injection sink used'); } });
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  addEventListener(event, callback) { const previous = this.events[event]; this.events[event] = previous ? function (...args) { previous.apply(this, args); callback.apply(this, args); } : callback; }
  contains(target) { return this === target || this.children.some(child => child.contains(target)); }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() { this.focused = true; if (this.ownerDocument) this.ownerDocument.activeElement = this; }
}

function mount(connected = true) {
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const events = {};
  const messages = [];
  const bridge = {};
  for (const name of ['ready', 'scope', 'auto', 'measure', 'measure_item', 'refresh', 'cancel', 'resume_scan', 'locate', 'expand', 'load_all']) bridge[name] = (...args) => messages.push({ name, args });
  const document = {
    body: new Element('body'),
    getElementById(id) { assert.ok(nodes[id], 'Missing HTML element ' + id); return nodes[id]; },
    createElement(tag) { const element = new Element(tag); element.ownerDocument = document; return element; },
    addEventListener(event, callback) { events[event] = callback; }
  };
  Object.values(nodes).forEach(element => { element.ownerDocument = document; });
  const window = connected ? { sketchup: bridge } : {};
  const context = vm.createContext({ window, document, Intl, Number });
  vm.runInContext(treeSource, context);
  vm.runInContext(source, context);
  events.DOMContentLoaded();
  return { nodes, messages, events, document, api: window.ModelSizeInfo };
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
  scope: 'follow', auto: true, auto_limit: 3, busy: false, error: null, version: '1.4.1'
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
check('opening HTML outside SketchUp never pretends to measure a model', () => {
  assert.equal(offline.nodes.measure.disabled, true); assert.match(offline.nodes.status.textContent, /未连接/);
  assert.match(offline.nodes['tree-status'].textContent, /未连接/); assert.match(offline.nodes['tree-empty'].textContent, /扩展菜单/);
});

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
  tree_token: 'tree-1', tree_complete: true, tree_all_loaded: true, tree_root_count: 3, tree_scanned: 125, tree_measured: 0,
  tree_errors: 0, pending_count: 2, definition_count: 2, tree_sizes: { '501': { bytes: null }, '502': { bytes: null } },
  tree_structure: graph, note: '父级已包含子级，不能逐行相加。'
};
api.render(treeBase);
check('tree mode replaces the single-size panel and keeps range state accessible', () => {
  assert.equal(nodes.primary.hidden, true); assert.equal(nodes.properties.hidden, true);
  assert.equal(nodes['tree-view'].hidden, false); assert.equal(nodes['auto-option'].hidden, true);
  assert.equal(nodes['scope-tree'].attributes['aria-pressed'], 'true'); assert.equal(nodes.breakdown.hidden, true);
});
check('tree statistics remain available without an aggregate file total', () => {
  assert.equal(nodes['tree-root-count'].textContent, '3'); assert.equal(nodes['tree-definition-count'].textContent, '2');
  assert.equal(nodes['tree-measured-count'].textContent, '0'); assert.equal(nodes.measure.textContent, '批量计算已读取项');
});
check('tree initially draws only roots and uses a stable name tie-breaker', () => {
  assert.equal(allRows().length, 3); assert.equal(rootRows()[0].children[2].children[0].textContent, 'A 餐桌');
  assert.equal(rootRows()[0].children[3].children[0].textContent, '计算大小');
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
  assert.equal(rootRows()[0].children[3].children[0].textContent, '32.00 KB');
  assert.equal(rootRows()[1].children[3].children[0].textContent, '32.00 KB');
  assert.equal(nodes.measure.disabled, true); assert.equal(nodes['tree-sort'].disabled, true);
});
api.render({ ...partialTree, busy: false });
check('stopped measurements preserve expansion and offer continuation', () => {
  assert.equal(allRows().length, 4); assert.equal(nodes.measure.textContent, '批量计算已读取项');
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
  assert.equal(nodes.measure.textContent, '批量重新计算');
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
  assert.equal(rootRows()[0].children[3].children[0].textContent, '重试'); assert.equal(rootRows()[0].children[3].children[0].title, '没有足够空间');
  assert.equal(rootRows()[2].children[3].children[0].textContent, '64.00 KB'); assert.equal(nodes['tree-status'].textContent, '计算失败');
});
nodes['scope-tree'].events.click();
check('return to list calls the native scope callback', () => assert.equal(messages.at(-1).args[0], 'tree'));

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
api.render({ ...treeBase, tree_token: 'scanning', tree_complete: false, busy: true, job_kind: 'scan', tree_structure: null, definition_count: 2000 });
check('scanning has a distinct progress message and blocks duplicate exports', () => {
  assert.equal(nodes['tree-status'].textContent, '正在扫描'); assert.match(nodes['tree-detail'].textContent, /2,000/);
  assert.equal(nodes['tree-progress'].hidden, false); assert.equal(nodes.measure.disabled, true);
  assert.match(nodes['tree-detail'].textContent, /请求的层级/);
});
api.render({ ...treeBase, tree_token: 'scanning', tree_complete: false, busy: false, tree_structure: null });
check('paused hierarchy scans can be resumed explicitly', () => {
  assert.equal(nodes.measure.textContent, '继续读取并批量计算'); assert.equal(nodes.measure.disabled, false);
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

const lazy = { ...treeBase, tree_token: 'lazy', tree_all_loaded: false, tree_root_count: 2,
  definition_count: 1, pending_count: 0, tree_measured: 1, tree_read_seconds: 0.03,
  tree_structure: { roots: [graph.roots[0], graph.roots[2]], definitions: { '502': { name: '餐桌', loaded: false, children: null } } },
  tree_sizes: { '502': { bytes: 32768 } }
};
api.render(lazy);
check('lazy trees explain partial loading and offer explicit full reading', () => {
  assert.equal(rootRows().length, 2); assert.equal(nodes['load-all'].hidden, false);
  assert.match(nodes['tree-detail'].textContent, /展开时读取子项.*0.03/); assert.equal(nodes.measure.textContent, '批量重新计算');
});
rootRows()[0].children[0].events.click();
check('opening an unread branch sends one scoped expansion request', () => {
  assert.equal(messages.at(-1).name, 'expand'); assert.equal(messages.at(-1).args[0].path, '12');
  assert.equal(messages.at(-1).args[0].token, 'lazy'); assert.equal(allRows().length, 2);
});
api.render({ ...lazy, busy: true, job_kind: 'scan', tree_complete: false,
  tree_sizes: {}, tree_structure: { roots: null, definitions: { '502': { name: '餐桌', loaded: false, loading: true, children: null } } } });
check('reading a branch keeps existing roots, cached sizes, expansion and focus', () => {
  assert.equal(rootRows().length, 2); assert.equal(rootRows()[0].children[3].children[0].textContent, '32.00 KB');
  assert.equal(rootRows()[0].children[0].attributes['aria-expanded'], 'true'); assert.equal(rootRows()[0].children[0].focused, true);
});
api.render({ ...lazy, pending_count: 1, definition_count: 2, tree_sizes: { '501': { bytes: null } },
  tree_structure: { roots: null, definitions: {
    '502': { name: '餐桌', loaded: true, children: graph.definitions['502'].children },
    '501': { name: '台灯', loaded: false, children: null }
  } } });
check('a structure delta reveals only the requested child level', () => {
  assert.equal(allRows().length, 3); assert.equal(allRows()[1].children[2].children[0].textContent, malicious);
  assert.equal(rootRows()[0].children[3].children[0].textContent, '32.00 KB');
});
const beforeCacheToggle = messages.length;
rootRows()[0].children[0].events.click(); rootRows()[0].children[0].events.click();
check('reopening a cached branch does not ask SketchUp to read it again', () => assert.equal(messages.length, beforeCacheToggle));
rootRows()[1].children[0].events.click();
check('another instance of a loaded definition shares its children without a new read', () => {
  assert.equal(allRows().length, 4); assert.equal(messages.length, beforeCacheToggle);
});
api.render({ ...lazy, tree_complete: false, busy: true, job_kind: 'tree', tree_structure: null, tree_sizes: {} });
check('an expansion queued during measurement does not mislabel exports as scanning', () => assert.equal(nodes['tree-status'].textContent, '正在计算'));
api.render({ ...lazy, tree_structure: null, tree_sizes: {} });
nodes['load-all'].events.click();
check('full directory reading requires the explicit native callback', () => assert.equal(messages.at(-1).name, 'load_all'));
api.render({ ...lazy, tree_all_loaded: true, tree_structure: null, tree_sizes: {} });
check('the full-directory button disappears once every level is loaded', () => assert.equal(nodes['load-all'].hidden, true));

const rowActions = { ...treeBase, tree_token: 'row-actions', tree_structure: graph };
api.render(rowActions);
check('each group and component row provides an individual calculation button', () => {
  assert.ok(rootRows().every(row => row.children[3].children[0].textContent === '计算大小'));
  assert.equal(nodes['tree-status'].textContent, '层级已就绪');
});
rootRows()[0].children[3].focus();
rootRows()[0].children[3].events.click();
check('an unmeasured row sends only its path and tree token for calculation', () => {
  const message = messages.at(-1); assert.equal(message.name, 'measure_item');
  assert.equal(message.args[0].path, '12'); assert.equal(message.args[0].token, 'row-actions'); assert.equal(message.args[0].force, false);
  const beforeDoubleClick = messages.length;
  rootRows()[0].children[3].events.click();
  assert.equal(messages.length, beforeDoubleClick); assert.equal(rootRows()[0].children[3].children[0].textContent, '计算中…');
});
const rowBusy = { ...rowActions, tree_structure: null, tree_sizes: {}, busy: true, job_kind: 'tree', tree_measuring_id: '502' };
api.render(rowBusy);
check('all instances of the computing definition show the same busy state', () => {
  assert.equal(rootRows()[0].children[3].children[0].textContent, '计算中…'); assert.equal(rootRows()[1].children[3].children[0].textContent, '计算中…');
  assert.equal(rootRows()[2].children[3].children[0].textContent, '计算大小'); assert.ok(rootRows().every(row => row.children[3].disabled));
  assert.match(nodes['tree-detail'].textContent, /所点项目/);
});
const beforeBusyClick = messages.length;
rootRows()[2].children[3].events.click();
check('clicks received during a calculation cannot create another export', () => assert.equal(messages.length, beforeBusyClick));
api.render({ ...rowActions, tree_structure: null, tree_measured: 1, pending_count: 1, tree_sizes: { '502': { bytes: 32768 } } });
check('completion updates every shared instance and restores its calculation button focus', () => {
  assert.equal(rootRows()[0].children[3].children[0].textContent, '32.00 KB'); assert.equal(rootRows()[1].children[3].children[0].textContent, '32.00 KB');
  assert.equal(rootRows()[0].children[3].children[0].textContent, '32.00 KB'); assert.equal(rootRows()[0].children[3].focused, true);
  assert.equal(rootRows()[2].children[3].children[0].textContent, '计算大小');
});
rootRows()[0].children[3].events.click();
check('the recalculation action explicitly requests a fresh result for that definition', () => {
  assert.equal(messages.at(-1).args[0].force, true); assert.equal(messages.at(-1).args[0].path, '12');
});
api.render({ ...rowActions, tree_structure: null, tree_sizes: { '502': { bytes: null, error: '保存失败' } } });
check('a failed row offers a retry without marking unrelated rows as failed', () => {
  assert.equal(rootRows()[0].children[3].children[0].textContent, '重试'); assert.equal(rootRows()[2].children[3].children[0].textContent, '计算大小');
});
rootRows()[0].children[3].events.click();
check('retrying a failed row requests only that definition', () => {
  assert.equal(messages.at(-1).name, 'measure_item'); assert.equal(messages.at(-1).args[0].force, false);
});
api.render(rowActions);
check('list mode hides the back button and individual inspector controls', () => {
  assert.equal(nodes['scope-tree'].hidden, true); assert.equal(nodes['primary-actions'].hidden, true);
  assert.equal(nodes['tree-options'].hidden, false); assert.equal(app.document.body.attributes['class:tree-mode'], true);
  assert.ok(rootRows().every(row => row.children.length === 4));
});
nodes.more.open = true; nodes['scope-follow'].events.click();
check('choosing an inspector closes More and preserves the scope callback', () => {
  assert.equal(nodes.more.open, false); assert.equal(nodes['more-toggle'].focused, true);
  assert.equal(messages.at(-1).args[0], 'follow');
});
api.render(base);
check('the selection inspector has a visible calculation action and a return path', () => {
  assert.equal(nodes['primary-actions'].hidden, false); assert.equal(nodes['scope-tree'].hidden, false);
  assert.equal(nodes['tree-options'].hidden, true); assert.equal(nodes['measure-current'].disabled, false);
});
nodes['measure-current'].events.click();
check('the inspector calculation action uses the existing native operation', () => assert.equal(messages.at(-1).name, 'measure'));
api.render({ ...base, kind: 'model', scope: 'model', busy: true });
check('model mode hides automatic selection controls and blocks duplicate calculation', () => {
  assert.equal(nodes['auto-option'].hidden, true); assert.equal(nodes['measure-current'].disabled, true);
  assert.equal(nodes['running-actions'].hidden, false);
});
let prevented = false;
nodes.more.open = true; app.events.keydown({ key: 'Escape', preventDefault() { prevented = true; } });
check('Escape closes More and restores focus', () => {
  assert.equal(nodes.more.open, false); assert.equal(nodes['more-toggle'].focused, true); assert.equal(prevented, true);
});
nodes.more.open = true; app.events.click({ target: nodes.more });
check('clicks within More keep it open', () => assert.equal(nodes.more.open, true));
app.events.click({ target: new Element() });
check('clicks outside More close it', () => assert.equal(nodes.more.open, false));
const scanningGeometry = { ...treeBase, tree_token: 'geometry-progress', tree_complete: false,
  busy: true, job_kind: 'scan', tree_structure: null, tree_read_progress: { read: 250000, total: 1000000 } };
api.render(scanningGeometry);
check('raw geometry scan progress is visible while reading a layer', () => {
  assert.equal(nodes['tree-status'].textContent, '当前层 25%');
  assert.match(nodes['tree-detail'].textContent, /250,000 \/ 1,000,000/);
  assert.equal(nodes['resume-scan'].hidden, true); assert.equal(nodes.cancel.hidden, false);
});
api.render({ ...scanningGeometry, busy: false, job_kind: null });
check('a stopped scan offers a direct read-only continuation', () => {
  assert.equal(nodes['resume-scan'].hidden, false); assert.equal(nodes['running-actions'].hidden, false);
  assert.equal(nodes.cancel.hidden, true); assert.equal(nodes['resume-scan'].disabled, false);
});
nodes['resume-scan'].events.click.call(nodes['resume-scan']);
check('scan continuation sends its own callback and blocks immediate repeated clicks', () => {
  assert.equal(messages.at(-1).name, 'resume_scan'); assert.equal(nodes['resume-scan'].disabled, true);
});
api.render({ ...scanningGeometry, busy: false, job_kind: null });
check('stopping again restores the continuation button', () => assert.equal(nodes['resume-scan'].disabled, false));
api.render(treeBase);
check('a completed hierarchy hides scan continuation', () => assert.equal(nodes['resume-scan'].hidden, true));
const idEntries = ['9007199254740993', '10', '9007199254740992', '2'].map(id => ({ id, definition_id: '501', name: 'ID ' + id, kind: '组件' }));
api.render({ ...treeBase, tree_token: 'id-sort', tree_root_count: 4, tree_structure: { roots: idEntries, definitions: graph.definitions } });
nodes['tree-sort'].value = 'model'; nodes['tree-sort'].events.change.call(nodes['tree-sort']);
check('ID sorting is numeric even for unsorted native input and 64-bit identifiers', () => {
  assert.deepEqual(rootRows().map(row => row.children[2].children[0].textContent), ['ID 2', 'ID 10', 'ID 9007199254740992', 'ID 9007199254740993']);
});
console.log(checks + ' UI logic checks passed.');
