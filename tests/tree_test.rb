# encoding: UTF-8
require_relative 'logic_test'

passed = []
check = lambda do |name, &block|
  raise "FAIL: #{name}" unless block.call
  passed << name
  puts "PASS: #{name}"
end
tree_class = ModelFootprintTools::SizeInfo::ComponentTree
model = TestModel.new
model.title = '树状测试模型'
leaf = TestDefinition.new(501, '<桌腿 & 中文>', 4096)
parent = TestDefinition.new(502, '餐桌', 32768)
unused = TestDefinition.new(503, '未使用的定义', 9000)
child = Sketchup::ComponentInstance.new(leaf, '桌腿 1')
child.hidden = true
parent.entities << child
first = Sketchup::Group.new(parent, '餐桌 A')
second = Sketchup::ComponentInstance.new(parent, '餐桌 B')
second.locked = true
model.entities.concat([first, Sketchup::Face.new, second])
model.definitions.concat([leaf, parent, unused])
index = tree_class.new(model)
check.call('directory scanning yields after a bounded slice') { !index.step(1) && index.scanned_definitions == 1 && index.scanned_instances == 0 }
index.step(2) until index.complete?
payload = index.payload
check.call('tree orders siblings by object ID and excludes loose faces') { payload[:roots].map { |node| node[:id] } == [first, second].map { |item| item.persistent_id.to_s } }
check.call('shared definitions are indexed once and unused definitions are omitted') { index.definitions.map(&:persistent_id).sort == [501, 502] && payload[:definitions].length == 2 }
check.call('nested component relationships preserve literal Unicode names') { payload[:definitions]['502'][:children][0][:name] == '桌腿 1' && payload[:definitions]['501'][:name] == '<桌腿 & 中文>' }
check.call('hidden and locked instances are included in tree data') { payload[:definitions]['502'][:children][0][:hidden] && payload[:roots][1][:locked] }
path = "#{second.persistent_id}.#{child.persistent_id}"
check.call('a nested path resolves through the chosen shared parent instance') { index.resolve(path) == [second, child] }
begin
  index.resolve("#{first.persistent_id}.#{second.persistent_id}")
  raise 'Expected hierarchy validation failure'
rescue RuntimeError => error
  check.call('forged paths cannot jump to an unrelated sibling') { error.message.include?('层级') }
end
['', '../501', '1..2', nil, '1.' * 5000].each do |invalid|
  begin
    index.resolve(invalid)
    raise 'Expected invalid path failure'
  rescue RuntimeError => error
    check.call("invalid path is rejected: #{invalid.inspect[0, 24]}") { error.message.include?('路径无效') }
  end
end
child.erased = true
begin
  index.resolve(path)
  raise 'Expected deleted object failure'
rescue RuntimeError => error
  check.call('deleted objects cannot be located from a stale tree') { error.message.include?('已变化') }
end
child.erased = false

# Shared nesting grows exponentially in paths but only linearly in graph size.
graph_model = TestModel.new
previous = TestDefinition.new(600, 'base', 1)
graph_model.definitions << previous
25.times do |number|
  definition = TestDefinition.new(601 + number, "layer #{number}", 1)
  graph_model.definitions << definition
  2.times { definition.entities << Sketchup::ComponentInstance.new(previous) }
  previous = definition
end
graph_model.entities << Sketchup::ComponentInstance.new(previous)
compact = tree_class.new(graph_model)
compact.step until compact.complete?
check.call('deeply shared nesting stays compact instead of expanding millions of paths') { compact.definitions.length == 26 && compact.entry_count == 51 }
loop_definition = TestDefinition.new(700, 'cycle', 1)
loop_instance = Sketchup::ComponentInstance.new(loop_definition)
loop_definition.entities << loop_instance
loop_model = TestModel.new
loop_root = Sketchup::ComponentInstance.new(loop_definition)
loop_model.entities << loop_root
loop_model.definitions << loop_definition
loop_tree = tree_class.new(loop_model)
loop_tree.step until loop_tree.complete?
check.call('a malformed recursive graph finishes scanning') { loop_tree.definitions.length == 1 }
begin
  loop_tree.resolve("#{loop_root.persistent_id}.#{loop_instance.persistent_id}")
  raise 'Expected cyclic path failure'
rescue RuntimeError => error
  check.call('recursive paths are rejected during location') { error.message.include?('循环') }
end

Sketchup.active_model = model
panel = ModelFootprintTools::SizeInfo::Panel.new
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
dialog.event('scope', 'tree')
UI.drain
data = dialog.last_data
check.call('entering tree mode scans without exporting automatically') { data['kind'] == 'tree' && data['tree_complete'] && data['definition_count'] == 2 && data['tree_measured'] == 0 && parent.exports == 0 }
check.call('completed graph is sent on first completion') { data['tree_structure']['roots'].length == 2 && data['tree_structure']['definitions'].length == 2 }
token = data['tree_token']
dialog.event('measure')
UI.tick
check.call('incremental measurement reports progress and shares the parent size') { dialog.last_data['tree_measured'] == 1 && dialog.last_data['tree_sizes']['502']['bytes'] == 32768 && dialog.last_data['busy'] }
check.call('progress updates do not resend the full graph') { dialog.last_data['tree_structure'].nil? }
panel.selection_changed
check.call('changing selection in tree mode does not cancel queued exports') { dialog.last_data['busy'] && UI.timer_count == 1 }
dialog.event('cancel')
UI.drain
check.call('stopping the queue preserves completed measurements') { dialog.last_data['tree_measured'] == 1 && parent.exports == 1 && leaf.exports == 0 }
dialog.event('measure')
UI.drain
check.call('continuing exports only the remaining unique definitions') { dialog.last_data['tree_measured'] == 2 && parent.exports == 1 && leaf.exports == 1 && unused.exports == 0 }
check.call('tree sizes are not summed into a misleading total') { dialog.last_data['bytes'].nil? && dialog.last_data['note'].include?('父级已包含子级') }

model.on_navigate = -> { panel.model_changed; panel.selection_changed }
dialog.event('locate', { 'token' => token, 'path' => "#{first.persistent_id}.#{child.persistent_id}" })
check.call('nested location opens the correct edit context and zooms to the actual instance') { model.active_path == [first] && model.selection == [child] && model.active_view.zoomed == [child] && dialog.last_data['error'].nil? }
check.call('navigation observers do not invalidate measured tree sizes') { dialog.last_data['tree_token'] == token && dialog.last_data['tree_measured'] == 2 && UI.timer_count == 0 }
dialog.event('locate', { 'token' => token, 'path' => first.persistent_id.to_s })
check.call('locating a root exits nested editing and selects the root') { model.active_path.nil? && model.selection == [first] }
dialog.event('locate', { 'token' => token, 'path' => path })
check.call('locked edit contexts report a location error without changing the lock') { dialog.last_data['error'].include?('无法定位') && second.locked? }

parent.fail_save = true
dialog.event('measure')
UI.drain
check.call('one failed definition does not stop measurements of other definitions') { dialog.last_data['tree_errors'] == 1 && dialog.last_data['tree_measured'] == 1 && !dialog.last_data['busy'] && leaf.exports == 2 }
check.call('a failed forced export does not keep an old successful byte count') { dialog.last_data['tree_sizes']['502']['bytes'].nil? && !dialog.last_data['tree_sizes']['502']['error'].nil? }
parent.fail_save = false
dialog.event('measure')
UI.drain
check.call('retrying failures preserves successful measurements and clears error messages') { dialog.last_data['tree_measured'] == 2 && dialog.last_data['tree_errors'] == 0 && dialog.last_data['error'].nil? && leaf.exports == 2 }
panel.model_changed
UI.drain
new_token = dialog.last_data['tree_token']
check.call('model edits refresh the graph and invalidate old byte counts') { new_token != token && dialog.last_data['tree_measured'] == 0 && dialog.last_data['tree_structure']['roots'].length == 2 }
dialog.event('locate', { 'token' => token, 'path' => first.persistent_id.to_s })
check.call('a location request from an obsolete tree is rejected') { dialog.last_data['error'].include?('组件树已更新') }
dialog.close
check.call('closing a tree panel detaches observers and cancels all jobs') { UI.timer_count == 0 && model.observer_count == 0 && model.selection.observers.empty? && Sketchup.observer_count == 0 }

large_model = TestModel.new
many_definition = TestDefinition.new(504, '重复组件', 32)
large_model.definitions << many_definition
4100.times { large_model.entities << Sketchup::ComponentInstance.new(many_definition) }
Sketchup.active_model = large_model
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.tick
check.call('a component-heavy directory yields before completing') { !dialog.last_data['tree_complete'] && dialog.last_data['tree_scanned'] > 0 && dialog.last_data['tree_scanned'] <= 2000 && dialog.last_data['busy'] }
dialog.event('cancel')
UI.drain
check.call('tree scanning can be stopped between slices') { !dialog.last_data['tree_complete'] && !dialog.last_data['busy'] && UI.timer_count == 0 }
dialog.event('measure')
UI.drain
check.call('stopped scans resume and then measure the discovered definitions') { dialog.last_data['tree_complete'] && dialog.last_data['tree_root_count'] == 4100 && dialog.last_data['tree_measured'] == 1 && !dialog.last_data['busy'] }
dialog.close

empty_model = TestModel.new
Sketchup.active_model = empty_model
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
check.call('an empty model produces an empty completed tree') { dialog.last_data['tree_complete'] && dialog.last_data['definition_count'] == 0 && dialog.last_data['tree_structure']['roots'].empty? }
dialog.event('measure')
check.call('empty trees do not create export jobs') { !dialog.last_data['busy'] && UI.timer_count == 0 }
dialog.close

# Performance regressions: these fixtures deliberately reject every attempt to
# enumerate or copy raw geometry. A visual-only filter would fail immediately.
directory_model = TestModel.new
used_parent = TestDefinition.new(801, 'used group', 512)
used_leaf = TestDefinition.new(802, 'used leaf', 128)
orphan_parent = TestDefinition.new(803, 'unused parent', 256)
orphan_leaf = TestDefinition.new(804, 'unused leaf', 64)
root_group = Sketchup::Group.new(used_parent)
reachable_child = Sketchup::ComponentInstance.new(used_leaf)
orphan_child = Sketchup::ComponentInstance.new(orphan_leaf)
orphan_shared = Sketchup::ComponentInstance.new(used_leaf)
used_parent.entities << reachable_child
orphan_parent.entities.concat([orphan_child, orphan_shared])
directory_model.entities << root_group
directory_model.definitions.concat([orphan_leaf, used_leaf, orphan_parent, used_parent])
collections = [directory_model.entities, used_parent.entities, used_leaf.entities, orphan_parent.entities, orphan_leaf.entities]
collections.each { |collection| collection.forbid_iteration = true }
fast = tree_class.new(directory_model)
fast.step until fast.complete?
check.call('directory scan never enumerates root, nested, or unused geometry') { collections.all? { |collection| collection.iteration_count == 0 } }
check.call('only actual instances are inspected regardless of raw geometry count') { fast.scanned_instances == 4 && fast.entry_count == 2 }
check.call('unused subtrees are pruned even when they contain component instances') { fast.definitions.map(&:persistent_id).sort == [801, 802] && !fast.payload[:definitions].key?('803') && !fast.payload[:definitions].key?('804') }
check.call('a shared leaf in an unused parent does not appear in the live hierarchy') { fast.payload[:definitions]['801'][:children].map { |item| item[:id] } == [reachable_child.persistent_id.to_s] }
check.call('temporary candidate maps are released after the reachable graph is built') { fast.instance_variable_get(:@candidate_children).nil? && fast.instance_variable_get(:@candidate_instances).nil? }
reachable_child.parent = root_group
group_parent_tree = tree_class.new(directory_model)
group_parent_tree.step until group_parent_tree.complete?
check.call('group parent wrappers resolve to the containing definition without geometry access') { group_parent_tree.resolve("#{root_group.persistent_id}.#{reachable_child.persistent_id}") == [root_group, reachable_child] }
reachable_child.parent = used_parent

image_definition = TestDefinition.new(805, 'image', 32)
image_definition.image = true
def image_definition.instances; raise 'Image instance list must be skipped'; end
directory_model.definitions << image_definition
image_tree = tree_class.new(directory_model)
image_tree.step until image_tree.complete?
check.call('image definitions are skipped before reading their instance lists') { image_tree.scanned_definitions == 5 && image_tree.definitions.length == 2 }
erased_instance = Sketchup::ComponentInstance.new(used_leaf)
directory_model.entities << erased_instance
erased_instance.erased = true
erased_tree = tree_class.new(directory_model)
erased_tree.step until erased_tree.complete?
check.call('deleted entries in native instance arrays are safely ignored') { erased_tree.root_count == 1 && erased_tree.scanned_instances == 4 }

slice_tree = tree_class.new(directory_model)
check.call('a zero time budget still makes bounded progress and returns to the caller') { !slice_tree.step(2000, 0) && slice_tree.scanned_definitions == 1 }
slice_tree.step(1) until slice_tree.complete?
check.call('a scan resumed through many tiny slices produces the same hierarchy') { slice_tree.payload == erased_tree.payload }

# A million selected faces must not be copied into Ruby just to render a tree.
directory_model.selection.define_singleton_method(:to_a) { raise 'Whole-model snapshot must not copy selection' }
whole_analyzer = ModelFootprintTools::SizeInfo::Analyzer.new(directory_model)
check.call('whole-model stats skip raw selection materialization') { whole_analyzer.snapshot('model')[:kind] == 'model' }
Sketchup.active_model = directory_model
panel.show
dialog = panel.instance_variable_get(:@dialog)
dialog.event('ready')
UI.drain
check.call('tree panel opens with geometry and selection enumeration prohibited') { dialog.last_data['tree_complete'] && dialog.last_data['definition_count'] == 2 && dialog.last_data['tree_scanned'] == 4 && dialog.last_data['error'].nil? }
original_tree = panel.instance_variable_get(:@tree_index)
dialog.event('scope', 'model')
UI.drain
dialog.event('scope', 'tree')
UI.drain
check.call('reopening an unchanged component tree reuses its existing directory') { panel.instance_variable_get(:@tree_index).equal?(original_tree) && !dialog.last_data['busy'] }
dialog.event('measure')
UI.drain
check.call('skipping geometry during scanning preserves complete file measurements') { dialog.last_data['tree_sizes']['801']['bytes'] == 512 && dialog.last_data['tree_sizes']['802']['bytes'] == 128 && used_parent.entities.length == 3 && directory_model.entities.length == 2 }
dialog.close
puts "#{passed.length} tree checks passed."
