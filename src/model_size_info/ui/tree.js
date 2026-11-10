(function () {
  'use strict';
  // The native side sends a compact definition graph. Children are created only
  // when opened; repeated definitions never expand all possible paths at once.
  window.ModelSizeTree = {
    create: function (options) {
      var $ = function (id) { return document.getElementById(id); };
      var list = $('component-tree');
      var token = null;
      var graph = null;
      var sizes = {};
      var expanded = Object.create(null);
      var limits = Object.create(null);
      var visible = [];
      var selected = null;
      var busy = false;
      var jobKind = null;
      var measuringId = null;
      var calculationFocusPath = null;
      var sort = 'size';
      var pageSize = 100;
      var collator = new Intl.Collator('zh-CN', { numeric: true, sensitivity: 'base' });

      function nameOf(node) {
        var definition = graph.definitions[node.definition_id];
        return node.name || (definition && definition.name) || ('未命名' + node.kind);
      }

      function childrenOf(node) {
        var definition = graph.definitions[node.definition_id];
        return definition && definition.children ? definition.children : [];
      }

      function loaded(node) {
        var definition = graph.definitions[node.definition_id];
        return definition && definition.loaded !== false && definition.children != null;
      }

      function clear(element) {
        while (element.firstChild) element.removeChild(element.firstChild);
      }

      function updateMeasurement(entry) {
        var measurement = sizes[entry.id] || {};
        var calculating = busy && measuringId === entry.id;
        var measured = !measurement.error && measurement.bytes != null;
        var label = calculating ? '计算中…' : (measurement.error ? '重试' : (measurement.bytes == null ? '计算大小' : '重新计算'));
        entry.size.className = 'tree-size' + (measurement.error ? ' failed' : (!measured ? ' pending' : ''));
        entry.size.textContent = measured && !calculating ? options.sizeText(measurement.bytes) : label;
        entry.size.title = measurement.error || (measured ? measurement.bytes.toLocaleString('zh-CN') + ' 字节' : '');
        entry.action.disabled = busy;
        entry.action.className = 'tree-measure' + (calculating ? ' calculating' : (measured ? ' measured' : ''));
        entry.action.setAttribute('aria-label', label + ' ' + entry.label);
        entry.action.title = measurement.error ? measurement.error + '。点击重试。' :
          (measured ? '点击重新计算“' + entry.label + '”的大小。' : '计算“' + entry.label + '”的文件大小，包含子级。');
      }

      function ordered(nodes) {
        var entries = nodes.map(function (node, index) { return { node: node, index: index }; });
        return entries.sort(function (a, b) {
          if (sort === 'model') {
            return collator.compare(a.node.id, b.node.id);
          }
          if (sort === 'size') {
            var aSize = sizes[a.node.definition_id] || {};
            var bSize = sizes[b.node.definition_id] || {};
            var aValue = aSize.error || aSize.bytes == null ? -1 : aSize.bytes;
            var bValue = bSize.error || bSize.bytes == null ? -1 : bSize.bytes;
            if (aValue !== bValue) return bValue - aValue;
          }
          return collator.compare(nameOf(a.node), nameOf(b.node)) || a.index - b.index;
        });
      }

      function selectRow(path) {
        selected = path;
        visible.forEach(function (entry) { entry.row.classList.toggle('located', entry.path === path); });
        options.send('locate', { token: token, path: path });
      }

      function renderLevel(parent, nodes, prefix, ancestors, depth) {
        var entries = ordered(nodes);
        var count = Math.min(limits[prefix] || pageSize, entries.length);
        entries.slice(0, count).forEach(function (entry) {
          var node = entry.node;
          var path = prefix ? prefix + '.' + node.id : node.id;
          var children = childrenOf(node);
          var cycle = ancestors.indexOf(node.definition_id) >= 0;
          var isLoaded = loaded(node);
          var canOpen = (!isLoaded || children.length > 0) && !cycle;
          var opened = canOpen && !!expanded[path];
          var item = document.createElement('li');
          var row = document.createElement('div'); row.className = 'tree-row';
          row.style.paddingLeft = (8 + Math.min(depth, 6) * 12) + 'px';
          row.classList.toggle('located', selected === path);
          var toggle = document.createElement('button'); toggle.className = 'tree-toggle';
          toggle.textContent = canOpen ? (opened ? '▾' : '▸') : '·';
          toggle.disabled = !canOpen;
          toggle.setAttribute('aria-label', (opened ? '收起' : '展开') + nameOf(node));
          if (canOpen) toggle.setAttribute('aria-expanded', String(opened));
          toggle.addEventListener('click', function () {
            expanded[path] = !expanded[path]; draw(path, true);
            if (expanded[path] && !loaded(node)) options.send('expand', { token: token, path: path });
          });
          var badge = document.createElement('span'); badge.className = 'tree-badge' + (node.kind === '群组' ? ' group' : '');
          badge.textContent = node.kind === '群组' ? '组' : '件'; badge.setAttribute('aria-hidden', 'true');
          var name = document.createElement('button'); name.className = 'tree-name';
          var title = document.createElement('span'); title.className = 'tree-name-title'; title.textContent = nameOf(node);
          var meta = document.createElement('span'); meta.className = 'tree-meta';
          meta.textContent = node.kind + (children.length ? ' · ' + children.length + ' 个子项' : '') +
            (!isLoaded && !cycle ? ' · 展开读取' : '') +
            (node.hidden ? ' · 隐藏' : '') + (node.locked ? ' · 锁定' : '') + (cycle ? ' · 循环引用' : '');
          meta.setAttribute('aria-hidden', 'true');
          name.title = nameOf(node) + ' · ' + meta.textContent + '。点击定位，嵌套对象会打开父级编辑环境。';
          name.appendChild(title); name.appendChild(meta);
          name.addEventListener('click', function () { selectRow(path); });
          var size = document.createElement('span');
          var action = document.createElement('button'); action.type = 'button';
          action.addEventListener('click', function () {
            if (busy) return;
            var measurement = sizes[node.definition_id] || {};
            busy = true;
            jobKind = 'tree';
            measuringId = node.definition_id;
            calculationFocusPath = path;
            visible.forEach(updateMeasurement);
            options.send('measure_item', { token: token, path: path, force: measurement.bytes != null });
          });
          action.appendChild(size);
          row.appendChild(toggle); row.appendChild(badge); row.appendChild(name); row.appendChild(action);
          item.appendChild(row); parent.appendChild(item);
          var visibleEntry = { path: path, id: node.definition_id, size: size, row: row,
            toggle: toggle, name: name, action: action, label: nameOf(node) };
          visible.push(visibleEntry);
          updateMeasurement(visibleEntry);
          if (opened) {
            var nested = document.createElement('ul'); nested.className = 'tree-children';
            item.appendChild(nested);
            if (isLoaded) renderLevel(nested, children, path, ancestors.concat(node.definition_id), depth + 1);
            else {
              var placeholder = document.createElement('li'); placeholder.className = 'tree-placeholder';
              placeholder.textContent = busy ? (jobKind === 'tree' ? '等待测量结束后读取…' : '正在读取此层级…') : '等待读取。收起后展开可继续。';
              nested.appendChild(placeholder);
            }
          }
        });
        if (count < entries.length) {
          var moreItem = document.createElement('li'); moreItem.className = 'tree-more';
          var more = document.createElement('button'); more.className = 'text-button';
          more.textContent = '再显示 ' + Math.min(pageSize, entries.length - count) + ' 项（剩余 ' + (entries.length - count) + '）';
          more.addEventListener('click', function () { limits[prefix] = count + pageSize; draw(); });
          moreItem.appendChild(more); parent.appendChild(moreItem);
        }
      }

      function draw(focusPath, focusToggle) {
        var scroll = list.scrollTop;
        if (!focusPath) visible.some(function (entry) {
          if (document.activeElement === entry.toggle || document.activeElement === entry.name || document.activeElement === entry.action) {
            focusPath = entry.path;
            focusToggle = document.activeElement === entry.toggle ? 'toggle' : (document.activeElement === entry.action ? 'action' : null);
            return true;
          }
          return false;
        });
        clear(list); visible = [];
        if (graph) renderLevel(list, graph.roots, '', [], 0);
        list.scrollTop = scroll;
        if (focusPath) visible.some(function (entry) {
          if (entry.path !== focusPath) return false;
          var target = entry.name;
          if (focusToggle === 'action' && !entry.action.disabled) target = entry.action;
          else if (focusToggle && focusToggle !== 'action' && !entry.toggle.disabled) target = entry.toggle;
          target.focus(); return true;
        });
      }

      $('tree-sort').addEventListener('change', function () { sort = this.value; draw(); });
      $('tree-collapse').addEventListener('click', function () { expanded = Object.create(null); draw(); });

      function render(data) {
        var changed = token !== data.tree_token;
        if (changed) {
          token = data.tree_token; graph = null; expanded = Object.create(null);
          limits = Object.create(null); selected = null; sizes = {}; calculationFocusPath = null;
        }
        Object.keys(data.tree_sizes || {}).forEach(function (id) { sizes[id] = data.tree_sizes[id]; });
        if (data.tree_structure) {
          if (!graph) graph = { roots: [], definitions: {} };
          if (data.tree_structure.roots != null) graph.roots = data.tree_structure.roots;
          Object.keys(data.tree_structure.definitions).forEach(function (id) { graph.definitions[id] = data.tree_structure.definitions[id]; });
          changed = true;
        }
        var finished = busy && !data.busy;
        busy = data.busy; jobKind = data.job_kind; measuringId = data.tree_measuring_id || null;
        if (changed || finished) draw(finished ? calculationFocusPath : null, 'action');
        else visible.forEach(updateMeasurement);
        if (finished) calculationFocusPath = null;
        $('tree-empty').hidden = !!(graph && graph.roots.length);
        $('tree-empty').textContent = data.tree_complete ? '模型中没有群组或组件。' :
          (data.busy ? '正在读取模型层级…' : '读取已暂停，点击“继续读取”恢复。');
        $('tree-collapse').disabled = !graph || !graph.roots.length;
        // Keep a stable sibling order during exports; apply the chosen order once
        // the queue finishes, so rows and expanded branches do not jump around.
        $('tree-sort').disabled = data.busy;
      }

      return { render: render };
    }
  };
}());
