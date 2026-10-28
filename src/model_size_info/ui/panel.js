(function () {
  'use strict';
  var current = null;
  var $ = function (id) { return document.getElementById(id); };
  var numbers = new Intl.NumberFormat('zh-CN');

  function send(name, value) {
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      if (arguments.length > 1) window.sketchup[name](value);
      else window.sketchup[name]();
    }
  }

  function formatBytes(bytes) {
    if (bytes === null || bytes === undefined || !Number.isFinite(bytes)) return { value: '—', unit: '' };
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    var size = Math.max(0, bytes);
    while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
    return { value: index === 0 ? String(Math.round(size)) : size.toFixed(2), unit: units[index] };
  }

  function sizeText(bytes) {
    var parts = formatBytes(bytes);
    return parts.value + (parts.unit ? ' ' + parts.unit : '');
  }

  function setText(id, value) { $(id).textContent = value; }
  function setHidden(id, value) { $(id).hidden = value; }
  function count(value) { return value === null || value === undefined ? '—' : numbers.format(value); }

  function renderRows(rows) {
    var list = $('definition-list');
    while (list.firstChild) list.removeChild(list.firstChild);
    rows.forEach(function (row) {
      var item = document.createElement('div'); item.className = 'definition-item';
      var info = document.createElement('div'); info.className = 'definition-text';
      var name = document.createElement('div'); name.className = 'definition-name'; name.textContent = row.name; name.title = row.name;
      var meta = document.createElement('div'); meta.className = 'definition-meta';
      meta.textContent = row.kind + ' · 选中 ' + count(row.selected_instances) + ' 个实例';
      var size = document.createElement('div'); size.className = 'definition-size' + (row.bytes === null ? ' pending' : '');
      size.textContent = row.bytes === null ? '待测量' : sizeText(row.bytes);
      info.appendChild(name); info.appendChild(meta); item.appendChild(info); item.appendChild(size); list.appendChild(item);
    });
  }

  function render(data) {
    current = data;
    var model = data.kind === 'model';
    var parts = formatBytes(data.bytes);
    setText('kind', data.subtitle);
    setText('object-name', data.title); $('object-name').title = data.title;
    setText('measurement-label', data.measurement_label);
    setText('size-value', parts.value); setText('size-unit', parts.unit);
    var detail = data.bytes === null ? '等待测量' : numbers.format(data.bytes) + ' 字节';
    if (data.measured_at) detail += ' · 测量于 ' + data.measured_at;
    if (data.measurement_state === 'unsaved') detail = '尚未保存，可直接测量当前模型副本。';
    if (data.measurement_state === 'unsupported') detail = '请先选中群组或组件。';
    if (data.measurement_state === 'partial') detail = '当前选择无法完整测量；下方仅列出可测量的定义。';
    if (data.pending_count > 0 && !data.busy) {
      detail = data.auto && data.definition_count <= data.auto_limit ? '稍候，正在准备测量…' : '点击下方按钮测量 ' + data.pending_count + ' 个定义。';
      if (data.loose_count > 0) detail += ' 散图元未计入。';
    }
    if (data.busy) detail = data.pending_count > 0 ? '正在测量，剩余 ' + data.pending_count + ' 个定义…' : '正在保存临时副本…';
    if (data.error) detail = '本次测量未完成，请查看下方提示。';
    setText('size-detail', detail);
    setText('selected-count', count(data.selected_count));
    setText('definition-label', model ? '模型中的定义' : '不同定义');
    setText('definition-count', count(data.definition_count));
    setText('entities-label', model ? '顶层图元' : '内部图元（当前层）');
    setText('direct-entities', count(data.direct_entities));
    setText('instance-count', count(data.instance_count));
    setHidden('selected-row', model); setHidden('entities-row', data.direct_entities === null); setHidden('instances-row', data.instance_count === null);
    setHidden('breakdown', model || (data.rows.length < 2 && data.selected_count < 2));
    renderRows(data.rows);
    setText('note', data.note);
    setText('error', data.error || ''); setHidden('error', !data.error);
    setHidden('progress', !data.busy); setHidden('cancel', !data.busy);
    setText('measure', model ? '测量当前模型' : (data.bytes === null ? '测量选中定义' : '重新测量'));
    $('measure').disabled = data.busy || (!model && !data.rows.length);
    $('refresh').disabled = data.busy;
    $('auto').checked = data.auto;
    setText('file-name', data.file.name); $('file-name').title = data.file.name;
    setText('file-size', sizeText(data.file.bytes));
    setText('file-state', !data.file.saved ? '尚未保存' : (data.file.modified ? '有未保存修改' : '已保存'));
    $('scope-follow').classList.toggle('active', data.scope === 'follow');
    $('scope-model').classList.toggle('active', data.scope === 'model');
    $('scope-follow').setAttribute('aria-pressed', String(data.scope === 'follow'));
    $('scope-model').setAttribute('aria-pressed', String(data.scope === 'model'));
    setText('version', 'v' + data.version);
    var status = data.error ? '测量失败' : (data.busy ? '正在测量' : (data.bytes !== null ? '已更新' : '等待测量'));
    setText('status', status);
    $('status').className = 'status ' + (data.error ? 'error' : (data.busy ? 'busy' : (data.bytes !== null ? 'ready' : '')));
  }

  $('scope-follow').addEventListener('click', function () { send('scope', 'follow'); });
  $('scope-model').addEventListener('click', function () { send('scope', 'model'); });
  $('auto').addEventListener('change', function () { send('auto', this.checked); });
  $('measure').addEventListener('click', function () { send('measure'); });
  $('cancel').addEventListener('click', function () { send('cancel'); });
  $('refresh').addEventListener('click', function () { send('refresh'); });

  window.ModelSizeInfo = { render: render, formatBytes: formatBytes, getState: function () { return current; } };
  document.addEventListener('DOMContentLoaded', function () {
    if (window.sketchup) send('ready');
    else {
      setText('status', '未连接 SketchUp');
      setText('size-detail', '请从 SketchUp 的扩展菜单打开此面板。');
      $('measure').disabled = true;
    }
  });
}());
