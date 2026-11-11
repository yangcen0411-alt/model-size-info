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
    if (bytes == null || !Number.isFinite(bytes)) return { value: '—', unit: '' };
    var units = ['B', 'KB', 'MB', 'GB', 'TB'], index = 0, size = Math.max(0, bytes);
    while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
    return { value: index === 0 ? String(Math.round(size)) : size.toFixed(2), unit: units[index] };
  }
  function sizeText(bytes) {
    var parts = formatBytes(bytes);
    return parts.value + (parts.unit ? ' ' + parts.unit : '');
  }
  var tree = window.ModelSizeTree.create({ send: send, sizeText: sizeText });
  function render(data) {
    current = data;
    tree.render(data);
    $('tree-empty').textContent = data.empty_message;
    $('tree-progress').hidden = !data.busy;
    var paused = !data.busy && !!data.tree_paused && !data.error;
    var status = data.error ? '查看提示' : (data.busy ?
      (data.job_kind === 'loading' ? '后台加载文件' : (data.job_kind === 'tree' ? '后台计算大小' : '后台读取目录')) : (paused ? '已暂停' : (data.tree_complete ? '就绪' : '等待读取')));
    $('tree-status').textContent = status;
    $('tree-status').className = 'status ' + (data.error ? 'error' : (data.busy ? 'busy' : 'ready'));
    $('tree-root-count').textContent = numbers.format(data.tree_root_count);
    $('tree-definition-count').textContent = numbers.format(data.definition_count);
    $('tree-measured-count').textContent = numbers.format(data.tree_measured);
    $('note').textContent = data.note;
    $('version').textContent = 'v' + data.version;
    $('error').textContent = data.error || '';
    $('error').hidden = !data.error;
    $('cancel').hidden = !data.busy;
    $('resume-scan').hidden = !paused;
    $('running-actions').hidden = !data.busy && !paused;
    $('refresh').disabled = !!data.busy;
    $('file-name').textContent = data.file.name; $('file-name').title = data.file.name;
    $('file-size').textContent = sizeText(data.file.bytes);
    $('file-state').textContent = !data.file.saved ? '尚未保存' : (data.file.modified ? '有未保存修改' : '已保存');
    $('source-note').hidden = !data.file.saved || !data.file.modified;
  }
  function closeMenu(focus) { $('more').open = false; if (focus) $('more-toggle').focus(); }
  $('refresh').addEventListener('click', function () { send('refresh'); });
  $('cancel').addEventListener('click', function () { send('cancel'); });
  $('resume-scan').addEventListener('click', function () {
    if (current && !current.busy) { $('resume-scan').hidden = true; send('resume_scan'); }
  });
  $('tree-collapse').addEventListener('click', function () { closeMenu(true); });
  document.addEventListener('click', function (event) {
    if ($('more').open && !$('more').contains(event.target)) closeMenu(false);
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && $('more').open) { closeMenu(true); event.preventDefault(); }
  });
  window.ModelSizeInfo = { render: render, formatBytes: formatBytes, getState: function () { return current; } };
  document.addEventListener('DOMContentLoaded', function () {
    if (window.sketchup) send('ready');
    else { $('tree-status').textContent = '未连接 SketchUp'; $('tree-empty').textContent = '请从 SketchUp 的扩展菜单打开此面板。'; }
  });
}());
