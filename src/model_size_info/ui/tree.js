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

      function labelSize(element, id) {
        var measurement = sizes[id] || {};
        element.className = 'tree-size' + (measurement.error ? ' failed' : (measurement.bytes == null ? ' pending' : ''));
        element.textContent = measurement.error ? '失败' : (measurement.bytes == null ? '待测量' : options.sizeText(measurement.bytes));
        element.title = measurement.error || (measurement.bytes == null ? '点击下方按钮测量' : measurement.bytes.toLocaleString('zh-CN') + ' 字节');
      }

      function ordered(nodes) {
        var entries = nodes.map(function (node, index) { return { node: node, index: index }; });
        if (sort === 'model') return entries;
        return entries.sort(function (a, b) {
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
          row.style.paddingLeft = (8 + Math.min(depth, 9) * 15) + 'px';
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
          name.title = nameOf(node) + '；点击选择并缩放到此对象，嵌套对象会打开父级编辑环境';
          var title = document.createElement('span'); title.className = 'tree-name-title'; title.textContent = nameOf(node);
          var meta = document.createElement('span'); meta.className = 'tree-meta';
          meta.textContent = node.kind + (children.length ? ' · ' + children.length + ' 个子项' : '') +
            (!isLoaded && !cycle ? ' · 展开读取' : '') +
            (node.hidden ? ' · 隐藏' : '') + (node.locked ? ' · 锁定' : '') + (cycle ? ' · 循环引用' : '');
          name.appendChild(title); name.appendChild(meta);
          name.addEventListener('click', function () { selectRow(path); });
          var size = document.createElement('span'); labelSize(size, node.definition_id);
          row.appendChild(toggle); row.appendChild(badge); row.appendChild(name); row.appendChild(size);
          item.appendChild(row); parent.appendChild(item);
          visible.push({ path: path, id: node.definition_id, size: size, row: row, toggle: toggle, name: name });
          if (opened) {
            var nested = document.createElement('ul'); nested.className = 'tree-children';
            item.appendChild(nested);
            if (isLoaded) renderLevel(nested, children, path, ancestors.concat(node.definition_id), depth + 1);
            else {
              var placeholder = document.createElement('li'); placeholder.className = 'tree-placeholder';
              placeholder.textContent = busy ? (jobKind === 'tree' ? '等待测量结束后读取…' : '正在读取此层级…') : '等待读取；收起后展开可继续。';
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
          if (document.activeElement === entry.toggle || document.activeElement === entry.name) {
            focusPath = entry.path; focusToggle = document.activeElement === entry.toggle; return true;
          }
          return false;
        });
        clear(list); visible = [];
        if (graph) renderLevel(list, graph.roots, '', [], 0);
        list.scrollTop = scroll;
        if (focusPath) visible.some(function (entry) {
          if (entry.path !== focusPath) return false;
          (focusToggle && !entry.toggle.disabled ? entry.toggle : entry.name).focus(); return true;
        });
      }

      $('tree-sort').addEventListener('change', function () { sort = this.value; draw(); });
      $('tree-collapse').addEventListener('click', function () { expanded = Object.create(null); draw(); });

      function render(data) {
        var changed = token !== data.tree_token;
        if (changed) {
          token = data.tree_token; graph = null; expanded = Object.create(null);
          limits = Object.create(null); selected = null; sizes = {};
        }
        Object.keys(data.tree_sizes || {}).forEach(function (id) { sizes[id] = data.tree_sizes[id]; });
        if (data.tree_structure) {
          if (!graph) graph = { roots: [], definitions: {} };
          if (data.tree_structure.roots != null) graph.roots = data.tree_structure.roots;
          Object.keys(data.tree_structure.definitions).forEach(function (id) { graph.definitions[id] = data.tree_structure.definitions[id]; });
          changed = true;
        }
        var finished = busy && !data.busy;
        busy = data.busy; jobKind = data.job_kind;
        if (changed || finished) draw();
        else visible.forEach(function (entry) { labelSize(entry.size, entry.id); });
        $('tree-empty').hidden = !!(graph && graph.roots.length);
        $('tree-empty').textContent = data.tree_complete ? '模型中没有群组或组件。' :
          (data.busy ? '正在读取模型层级…' : '扫描已暂停，点击下方按钮继续。');
        $('tree-collapse').disabled = !graph || !graph.roots.length;
        // Keep a stable sibling order during exports; apply the chosen order once
        // the queue finishes, so rows and expanded branches do not jump around.
        $('tree-sort').disabled = data.busy;
      }

      return { render: render };
    }
  };
}());
