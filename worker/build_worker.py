"""Build the Windows x64 helper using the installed .NET Framework compiler."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parent.parent
compiler = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
target = root / 'src/model_size_info/worker/ModelSizeWorker.exe'
target.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([str(compiler), '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
                '/reference:System.Web.Extensions.dll', '/out:' + str(target),
                str(root / 'worker/ModelSizeWorker.cs')], check=True)
print('Built ' + str(target))
