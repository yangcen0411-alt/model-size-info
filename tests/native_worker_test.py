"""Exercise the real installed C API in our own processes, without launching SU."""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--api', required=True, type=Path)
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
api_path = args.api.resolve()
os.add_dll_directory(str(api_path.parent))
api = C.CDLL(str(api_path))

class Ref(C.Structure):
    _fields_ = [('ptr', C.c_void_p)]

class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double), ('z', C.c_double)]

def call(name, types, *values):
    function = getattr(api, name)
    function.argtypes, function.restype = types, C.c_int
    result = function(*values)
    assert result == 0, (name, result)

def get_ref(name, owner):
    result = Ref()
    call(name, [Ref, C.POINTER(Ref)], owner, C.byref(result))
    return result

def cast(name, owner):
    function = getattr(api, name)
    function.argtypes, function.restype = [Ref], Ref
    return function(owner)

def new_ref(name):
    result = Ref()
    call(name, [C.POINTER(Ref)], C.byref(result))
    return result

def fixture(path, wide=False):
    api.SUInitialize()
    model = new_ref('SUModelCreate')
    try:
        roots = get_ref('SUModelGetEntities', model)
        definition = new_ref('SUComponentDefinitionCreate')
        call('SUModelAddComponentDefinitions', [Ref, C.c_size_t, C.POINTER(Ref)], model, 1, (Ref * 1)(definition))
        inside = get_ref('SUComponentDefinitionGetEntities', definition)
        edge = Ref()
        call('SUEdgeCreate', [C.POINTER(Ref), C.POINTER(Point), C.POINTER(Point)], C.byref(edge), C.byref(Point(0, 0, 0)), C.byref(Point(1, 0, 0)))
        call('SUEntitiesAddEdges', [Ref, C.c_size_t, C.POINTER(Ref)], inside, 1, (Ref * 1)(edge))
        group = new_ref('SUGroupCreate')
        call('SUEntitiesAddGroup', [Ref, Ref], roots, group)
        call('SUComponentInstanceSetName', [Ref, C.c_char_p], cast('SUGroupToComponentInstance', group), '父组件 <中文 & 名称>'.encode())
        group_entities = get_ref('SUGroupGetEntities', group)
        for index in range(3702 if wide else 207):
            current = definition
            if wide and index < 3700:
                current = new_ref('SUComponentDefinitionCreate')
                call('SUModelAddComponentDefinitions', [Ref, C.c_size_t, C.POINTER(Ref)], model, 1, (Ref * 1)(current))
                current_entities = get_ref('SUComponentDefinitionGetEntities', current)
                line = Ref()
                call('SUEdgeCreate', [C.POINTER(Ref), C.POINTER(Point), C.POINTER(Point)], C.byref(line), C.byref(Point(0, 0, index)), C.byref(Point(1, 0, index)))
                call('SUEntitiesAddEdges', [Ref, C.c_size_t, C.POINTER(Ref)], current_entities, 1, (Ref * 1)(line))
            instance = get_ref('SUComponentDefinitionCreateInstance', current)
            destination = group_entities if wide else (roots if index < 205 else group_entities)
            call('SUEntitiesAddInstance', [Ref, Ref, C.c_void_p], destination, instance, None)
            call('SUComponentInstanceSetName', [Ref, C.c_char_p], instance, ('组件 %03d' % index).encode())
        # Raw geometry shares the root context but must not become tree rows.
        edges = (Ref * 2000)()
        for index in range(len(edges)):
            call('SUEdgeCreate', [C.POINTER(Ref), C.POINTER(Point), C.POINTER(Point)], C.byref(edges[index]), C.byref(Point(0, index+1, 0)), C.byref(Point(1, index+1, 0)))
        call('SUEntitiesAddEdges', [Ref, C.c_size_t, C.POINTER(Ref)], roots, len(edges), edges)
        call('SUModelSaveToFile', [Ref, C.c_char_p], model, str(path).encode())
    finally:
        call('SUModelRelease', [C.POINTER(Ref)], C.byref(model))
        api.SUTerminate()

class Worker:
    def __init__(self, directory, source):
        self.directory = directory
        self.counter = 0
        self.process = subprocess.Popen([str(project/'src/model_size_info/worker/ModelSizeWorker.exe'), str(directory), str(api_path), str(source), str(os.getpid())], creationflags=0x08000000)

    def receive(self):
        target = self.directory/'response.json'
        deadline = time.monotonic()+30
        while not target.exists():
            assert self.process.poll() is None, 'worker exited before sending a response'
            assert time.monotonic() < deadline, 'worker timeout'
            time.sleep(.02)
        value = json.loads(target.read_text(encoding='utf-8'))
        target.unlink()
        return value

    def send(self, operation, definition_id='', offset=0, force=False):
        self.counter += 1
        payload = dict(request_id=self.counter, operation=operation, definition_id=definition_id, offset=offset, force=force)
        (self.directory/'request.tmp').write_text(json.dumps(payload), encoding='utf-8')
        (self.directory/'request.tmp').rename(self.directory/'request.json')
        result = self.receive()
        assert result['request_id'] == self.counter
        return result

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=10)

checks = 0
def check(label, condition):
    global checks
    assert condition, label
    checks += 1
    print('PASS:', label)

with tempfile.TemporaryDirectory(prefix='model-size-native-') as temp:
    root = Path(temp)
    source = root/"中文 & (saved 'model').skp"
    fixture(source)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    session = root/'session'; session.mkdir()
    worker = Worker(session, source)
    try:
        ready = worker.receive()
        check('real SDK opens a Unicode path in the isolated worker', ready.get('ready') and ready['source_bytes'] == source.stat().st_size)
        check('Windows accepts and reports the background memory limit', 0 < ready['memory_limit'] <= 6*1024**3)
        first = worker.send('list')
        check('raw edges are excluded and responses are bounded to 100 nodes', first['ok'] and len(first['nodes']) == 100 and first['total'] == 206)
        second = worker.send('list', offset=100)
        third = worker.send('list', offset=200)
        all_nodes = first['nodes']+second['nodes']+third['nodes']
        check('all 206 containers can be reached through explicit pages', len(all_nodes) == len({node['id'] for node in all_nodes}) == 206 and third['next'] == 206)
        group = next(node for node in all_nodes if node['kind'] == '群组')
        check('Chinese and HTML-like names remain literal data', group['name'] == '父组件 <中文 & 名称>')
        children = worker.send('list', group['definition_id'])
        check('child listing preserves shared component definitions', children['ok'] and len(children['nodes']) == 2 and len({node['definition_id'] for node in children['nodes']}) == 1)
        parent_size = worker.send('measure', group['definition_id'])
        child_id = children['nodes'][0]['definition_id']
        child_size = worker.send('measure', child_id)
        check('parent and child exports return real SKP byte sizes', parent_size['ok'] and child_size['ok'] and parent_size['bytes'] > 100 and child_size['bytes'] > 100)
        check('repeated instances reuse a definition result', worker.send('measure', child_id)['bytes'] == child_size['bytes'])
        check('forced recalculation remains a valid independent export', worker.send('measure', child_id, force=True)['ok'])
        check('invalid saved IDs are rejected', worker.send('measure', '9223372036854775806')['ok'] is False)
        check('temporary exported components are cleaned up', not (session/'measurement.skp').exists())
        check('source SKP bytes remain unchanged', hashlib.sha256(source.read_bytes()).hexdigest() == digest)
    finally:
        worker.close()
    check('an owned worker can be terminated without closing SketchUp', worker.process.poll() is not None)
    restart = root/'restart'; restart.mkdir()
    worker = Worker(restart, source)
    try:
        assert worker.receive()['ready']
        check('after cancellation a new worker resolves saved definition IDs without replaying the tree', worker.send('measure', child_id)['ok'])
    finally:
        worker.close()
    corrupt = root/'broken.skp'; corrupt.write_bytes(b'invalid skp')
    failure = root/'failure'; failure.mkdir()
    worker = Worker(failure, corrupt)
    try:
        check('a damaged file returns a background error', worker.receive()['ok'] is False)
    finally:
        worker.close()
    wide_source = root/'3700-distinct-definitions.skp'
    fixture(wide_source, wide=True)
    wide_hash = hashlib.sha256(wide_source.read_bytes()).hexdigest()
    wide_session = root/'wide'; wide_session.mkdir()
    worker = Worker(wide_session, wide_source)
    try:
        assert worker.receive()['ready']
        wide_root = worker.send('list')
        parent_id = wide_root['nodes'][0]['definition_id']
        first_page = worker.send('list', parent_id)
        check('a real 3700-definition nested model returns one bounded page', wide_root['total'] == 1 and first_page['total'] == 3702 and len(first_page['nodes']) == len({node['definition_id'] for node in first_page['nodes']}) == 100)
        check('the wide parent can be exported in the worker without changing the source', worker.send('measure', parent_id)['ok'] and hashlib.sha256(wide_source.read_bytes()).hexdigest() == wide_hash)
    finally:
        worker.close()
print(str(checks)+' native worker checks passed.')
