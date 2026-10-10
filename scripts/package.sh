#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test -f "$ROOT/dist/mail-client.jar" || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
python3 - "$ROOT" <<'PY'
import pathlib,sys,zipfile,hashlib
r=pathlib.Path(sys.argv[1])
import subprocess
version=subprocess.check_output([sys.executable,str(r/'scripts/check-version.py')],text=True).strip()
name=f'mail-client-v{version}'
out=r/'dist'/f'{name}.zip'
skip={'tools','.git','.dart_tool','build','target','data','test-results','Pods','.symlinks','ephemeral','.idea','__pycache__'}
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(r.rglob('*')):
        if not p.is_file() or p.is_symlink(): continue
        rel=p.relative_to(r)
        if any(x in skip for x in rel.parts): continue
        if rel.parts[0]=='dist' and rel.name!='mail-client.jar': continue
        if str(rel).startswith('server/src/main/resources/static/'): continue
        if rel.name=='.env' or rel.name.startswith('.env.') and rel.name!='.env.example': continue
        if rel.name.startswith('.attach_pid'): continue
        if rel.name.endswith('.log') or rel.name=='local.properties' or rel.name.startswith('.flutter-plugins'): continue
        if rel.name.endswith(('.iml','.xcuserstate')) or rel.name in {'Generated.xcconfig','flutter_export_environment.sh','.DS_Store'}: continue
        z.write(p,pathlib.Path(name)/rel)
sha=hashlib.sha256(out.read_bytes()).hexdigest()
(r/'dist/SHA256SUMS').write_text(f'{sha}  {out.name}\n')
print(out);print(sha)
PY
