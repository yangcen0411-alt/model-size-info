"""Build the installable SketchUp RBZ and a separate source archive."""
import argparse
import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

parser = argparse.ArgumentParser()
parser.add_argument('--output-dir', type=Path, default=Path('dist'))
args = parser.parse_args()
project = Path(__file__).resolve().parent
destination = args.output_dir.resolve()
destination.mkdir(parents=True, exist_ok=True)
source = project / 'src'
version = re.search(r"extension\.version = '([^']+)'", (source / 'model_size_info.rb').read_text(encoding='utf-8'))
assert version, 'Extension version was not found'
name = 'model_size_info_v' + version.group(1)

runtime_files = sorted(path for path in source.rglob('*') if path.is_file())
with ZipFile(destination / (name + '.rbz'), 'w', ZIP_DEFLATED) as archive:
    for path in runtime_files:
        archive.write(path, path.relative_to(source).as_posix())

with ZipFile(destination / (name + '_source.zip'), 'w', ZIP_DEFLATED) as archive:
    for path in sorted(project.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(project)
        if any(part in {'dist', '__pycache__'} for part in relative.parts):
            continue
        if path.suffix in {'.rbz', '.zip', '.pyc'} or destination in path.parents:
            continue
        archive.write(path, relative.as_posix())

expected = {'model_size_info.rb', 'model_size_info/main.rb', 'model_size_info/analyzer.rb',
            'model_size_info/component_tree.rb', 'model_size_info/panel.rb', 'model_size_info/ui/panel.html',
            'model_size_info/ui/panel.css', 'model_size_info/ui/panel.js',
            'model_size_info/ui/tree.js', 'model_size_info/LICENSE.txt'}
with ZipFile(destination / (name + '.rbz')) as archive:
    assert archive.testzip() is None, 'RBZ archive failed CRC verification'
    assert set(archive.namelist()) == expected, 'RBZ structure does not match the expected extension layout'
    assert all(not item.startswith('/') and '..' not in Path(item).parts for item in archive.namelist())
print('Built and verified: ' + str(destination / (name + '.rbz')))
print('Source archive: ' + str(destination / (name + '_source.zip')))
