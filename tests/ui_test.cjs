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
  for (const name of ['ready', 'scope', 'auto', 'measure', 'measure_item', 'refresh', 'cancel', 'resume_scan', 'locate', 'expand', 'load_all', 'more']) bridge[name] = (...args) => messages.push({ name, args });
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

const app = mount(), { nodes, messages, api } = app;
check('panel only sends ready when opened in SketchUp', () => assert.equal(messages[0].name, 'ready'));
for (const [bytes, value, unit] of [[null, '—', ''], [0, '0', 'B'], [1024, '1.00', 'KB'], [1048576, '1.00', 'MB']]) {
  check('binary file units for ' + bytes, () => assert.deepEqual(JSON.parse(JSON.stringify(api.formatBytes(bytes))), { value, unit }));
}
const malicious = '<img src=x onerror=alert(1)>中文 & 名称';
const roots = [
  { id: '10', definition_id: '500', name: '父组件 01', kind: '群组' },
  { id: '11', definition_id: '500', name: '父组件 02', kind: '组件' }
];
const definitions = { '500': { name: '共享父定义', loaded: false, children: null, more: false } };
const base = { kind: 'tree', version: '1.5.0', busy: false, job_kind: null, error: null,
  file: { name: '保存的模型.skp', bytes: 1048576, saved: true, modified: false },
  tree_token: 't1', tree_complete: true, tree_root_count: 2, definition_count: 1, tree_measured: 0,
  tree_measuring_id: null, tree_sizes: {}, tree_structure: { roots, definitions, root_more: false },
  note: '结果来自上次保存。', empty_message: '已保存文件中没有群组或组件。' };
function rows(element = nodes['component-tree']) {
  const result = [];
  for (const child of element.children) {
    if (child.className === 'tree-row') result.push(child);
    result.push(...rows(child));
  }
  return result;
}
api.render(base);
check('default panel shows saved file size and compact rows', () => {
  assert.equal(nodes['file-size'].textContent, '1.00 MB'); assert.equal(rows().length, 2);
  assert.ok(rows().every(row => row.children.length === 4 && row.children[3].textContent === '计算大小'));
});
rows()[0].children[3].focus(); rows()[0].children[3].events.click();
check('calculation sends one exact saved path and blocks duplicate clicks immediately', () => {
  assert.equal(messages.at(-1).name, 'measure_item'); assert.equal(messages.at(-1).args[0].path, '10');
  assert.equal(messages.at(-1).args[0].force, false);
  const before = messages.length; rows()[0].children[3].events.click(); assert.equal(messages.length, before);
});
api.render({ ...base, tree_structure: null, busy: true, job_kind: 'tree', tree_measuring_id: '500' });
check('shared instances show the same background calculation state', () => {
  assert.ok(rows().every(row => row.children[3].textContent === '计算中…' && row.children[3].disabled));
  assert.equal(nodes['tree-status'].textContent, '后台计算大小'); assert.equal(nodes.cancel.hidden, false);
});
api.render({ ...base, tree_structure: null, tree_measured: 1, tree_sizes: { '500': { bytes: 2048 } } });
check('a result replaces the button label and restores focus', () => {
  assert.ok(rows().every(row => row.children[3].textContent === '2.00 KB'));
  assert.equal(rows()[0].children[3].focused, true);
});
rows()[0].children[3].events.click();
check('clicking a result explicitly requests recalculation', () => assert.equal(messages.at(-1).args[0].force, true));
api.render({ ...base, tree_structure: null, tree_sizes: { '500': { bytes: null, error: '保存失败' } } });
check('failed definitions offer a retry and show the cause', () => {
  assert.equal(rows()[0].children[3].textContent, '重试'); assert.match(rows()[0].children[3].title, /保存失败/);
});
rows()[0].children[0].events.click();
check('expanding requests only the selected branch', () => {
  assert.equal(messages.at(-1).name, 'expand'); assert.equal(messages.at(-1).args[0].path, '10');
});
const child = { id: '20', definition_id: '501', name: malicious, kind: '组件', hidden: true };
api.render({ ...base, tree_structure: { roots: null, root_more: false, definitions: {
  '500': { name: '共享父定义', loaded: true, children: [child], more: false },
  '501': { name: '子定义', loaded: false, children: null, more: false }
} } });
check('a directory delta retains roots and inserts literal child names', () => {
  assert.equal(rows().length, 3); assert.equal(rows()[1].children[2].children[0].textContent, malicious);
  assert.match(rows()[1].children[2].title, /隐藏/);
});
rows()[1].children[2].events.click();
check('nested selection retains the complete instance path', () => assert.equal(messages.at(-1).args[0].path, '10.20'));
nodes['tree-collapse'].events.click();
check('collapse hides expanded descendants without losing roots', () => assert.equal(rows().length, 2));
const page1 = Array.from({ length: 100 }, (_, i) => ({ id: String(1000+i), definition_id: '500', name: '项目 ' + i, kind: '组件' }));
api.render({ ...base, tree_token: 'pages', tree_root_count: 205, tree_structure: { roots: page1, definitions, root_more: true } });
nodes['component-tree'].children.at(-1).children[0].events.click();
check('more pages are explicitly requested from the background worker', () => {
  assert.equal(rows().length, 100); assert.equal(messages.at(-1).name, 'more'); assert.equal(messages.at(-1).args[0].path, '');
});
const page2 = page1.concat(Array.from({ length: 100 }, (_, i) => ({ ...page1[i], id: String(1100+i) })));
api.render({ ...base, tree_token: 'pages', tree_root_count: 205, tree_structure: { roots: page2, definitions, root_more: true } });
check('a requested server page becomes reachable without hidden truncation', () => assert.equal(rows().length, 200));
api.render({ ...base, tree_token: 'loading', tree_structure: null, busy: true, job_kind: 'loading' });
check('file loading is shown as a cancellable background phase', () => {
  assert.equal(nodes['tree-status'].textContent, '后台加载文件'); assert.equal(nodes.cancel.hidden, false);
  nodes.cancel.events.click(); assert.equal(messages.at(-1).name, 'cancel');
});
api.render({ ...base, tree_token: 'loading', tree_structure: null, tree_complete: false, tree_paused: true });
check('stopped reads provide an explicit resume action', () => {
  assert.equal(nodes['resume-scan'].hidden, false); nodes['resume-scan'].events.click();
  assert.equal(messages.at(-1).name, 'resume_scan');
});
api.render({ ...base, tree_structure: null, file: { ...base.file, modified: true } });
check('unsaved changes are identified as outside the saved snapshot', () => assert.equal(nodes['source-note'].hidden, false));
api.render({ ...base, tree_token: 'unsaved', tree_structure: { roots: [], definitions: {} },
  file: { name: '尚未保存的模型', bytes: null, saved: false, modified: true }, empty_message: '请先保存模型，再点击刷新。' });
check('an unsaved document never displays a fabricated size', () => {
  assert.equal(nodes['file-size'].textContent, '—'); assert.match(nodes['tree-empty'].textContent, /请先保存/);
});
nodes.more.open = true; let prevented = false;
app.events.keydown({ key: 'Escape', preventDefault() { prevented = true; } });
check('Escape closes More and returns keyboard focus', () => {
  assert.equal(nodes.more.open, false); assert.equal(nodes['more-toggle'].focused, true); assert.equal(prevented, true);
});
nodes.more.open = true; app.events.click({ target: new Element() });
check('clicking outside More closes it', () => assert.equal(nodes.more.open, false));
const offline = mount(false);
check('local HTML does not pretend to be connected', () => assert.match(offline.nodes['tree-status'].textContent, /未连接/));
console.log(checks + ' UI checks passed.');
