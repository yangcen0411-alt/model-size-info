'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ui = path.join(__dirname, '../src/model_size_info/ui');
const html = fs.readFileSync(path.join(ui, 'panel.html'), 'utf8');
const source = fs.readFileSync(path.join(ui, 'panel.js'), 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
assert.equal(new Set(ids).size, ids.length, 'HTML IDs must be unique');
for (const file of ['panel.css', 'panel.js']) assert.ok(fs.existsSync(path.join(ui, file)));

class Element {
  constructor(tag = 'div') {
    this.tagName = tag; this.children = []; this.events = {}; this.attributes = {}; this.textContent = ''; this.className = '';
    this.classList = { toggle: (name, active) => { this.attributes['class:' + name] = active; } };
    Object.defineProperty(this, 'innerHTML', { set() { throw new Error('HTML injection sink used'); } });
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) { this.children.push(child); }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  addEventListener(event, callback) { this.events[event] = callback; }
  setAttribute(name, value) { this.attributes[name] = value; }
}

function mount(connected = true) {
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const events = {};
  const messages = [];
  const bridge = {};
  for (const name of ['ready', 'scope', 'auto', 'measure', 'refresh', 'cancel']) bridge[name] = (...args) => messages.push({ name, args });
  const document = {
    getElementById(id) { assert.ok(nodes[id], 'Missing HTML element ' + id); return nodes[id]; },
    createElement(tag) { return new Element(tag); },
    addEventListener(event, callback) { events[event] = callback; }
  };
  const window = connected ? { sketchup: bridge } : {};
  vm.runInNewContext(source, { window, document, Intl, Number });
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
  scope: 'follow', auto: true, auto_limit: 3, busy: false, error: null, version: '1.0.0'
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
console.log(checks + ' UI logic checks passed.');
