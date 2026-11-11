# encoding: UTF-8
require_relative 'logic_test'
tree = ModelFootprintTools::SizeInfo::ComponentTree.new
root = { 'definition_id' => '', 'offset' => 0, 'next' => 2, 'total' => 205, 'nodes' => ROOT_NODES.first(2) }
tree.apply(root)
check('large levels expose a partial first page and the full root count') { tree.roots.length == 2 && tree.root_total == 205 && tree.more?('') }
check('structure packets mark unread child definitions explicitly') { tree.delta[:definitions]['500']['children'].nil? && tree.delta[:root_more] }
tree.acknowledge_delta
check('unchanged structure has no retransmission') { tree.delta.nil? }
check('paths select the correct shared parent instance') { tree.resolve('11').last['id'] == '11' }
tree.apply('definition_id' => '500', 'offset' => 0, 'next' => 1, 'total' => 1, 'nodes' => CHILD_NODES)
check('child levels are shared while instance paths remain distinct') { tree.resolve('10.20').last['id'] == '20' && tree.resolve('11.20').last['id'] == '20' }
check('child deltas omit the unchanged roots') { tree.delta[:roots].nil? && tree.delta[:definitions]['500']['loaded'] }
['', '../10', '10..20', '12.20', '10.999', nil, '1.' * 5000].each do |path|
  rejected = false
  begin; tree.resolve(path); rescue RuntimeError; rejected = true; end
  check('invalid or unrelated instance paths are rejected') { rejected }
end
tree.acknowledge_delta
tree.resend
check('HTML reload can request a cached graph without native reads') { tree.delta[:roots].length == 2 && tree.delta[:definitions].length == 2 }
bad = false
begin; tree.apply(root); rescue RuntimeError; bad = true; end
check('duplicate or stale page offsets are rejected') { bad }
many = Array.new(100) { |i| node(1000+i, 502) }
tree.apply('definition_id' => '', 'offset' => 2, 'next' => 102, 'total' => 205, 'nodes' => many)
check('next page appends exactly one bounded batch') { tree.offset('') == 102 && tree.more?('') }
high = ModelFootprintTools::SizeInfo::ComponentTree.new
high.apply('definition_id' => '', 'offset' => 0, 'next' => 1, 'total' => 1, 'nodes' => [node('9007199254740995', '9007199254740993')])
check('64-bit native IDs remain exact decimal strings') { high.resolve('9007199254740995').last['definition_id'] == '9007199254740993' }

[
  { 'definition_id' => '', 'offset' => 0, 'next' => 1, 'total' => 0, 'nodes' => [node(1, 2)] },
  { 'definition_id' => '', 'offset' => 0, 'next' => 1, 'total' => 1, 'nodes' => [node('bad', 2)] },
  { 'definition_id' => '', 'offset' => 0, 'next' => 2, 'total' => 2, 'nodes' => [node(1, 2), node(1, 3)] },
  { 'definition_id' => '', 'offset' => 0, 'next' => 101, 'total' => 101, 'nodes' => Array.new(101) { |i| node(i+1, 2) } }
].each do |packet|
  fresh = ModelFootprintTools::SizeInfo::ComponentTree.new
  rejected = false
  begin; fresh.apply(packet); rescue RuntimeError; rejected = true; end
  check('invalid worker pages are rejected before mutating the graph') { rejected && fresh.roots.empty? && fresh.definitions.empty? }
end

puts "#{$checks} total Ruby checks passed."
