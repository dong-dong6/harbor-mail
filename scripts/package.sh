#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test -f "$ROOT/dist/mail-client.jar" || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
python3 - "$ROOT" <<'PY'
import pathlib,sys,zipfile,hashlib,json,datetime
r=pathlib.Path(sys.argv[1])
import subprocess
version=subprocess.check_output([sys.executable,str(r/'scripts/check-version.py')],text=True).strip()
name=f'mail-client-v{version}'
out=r/'dist'/f'{name}.zip'
jar=(r/'dist/mail-client.jar').read_bytes()
build_info=json.loads((r/'docs/BUILD_INFO.json').read_text())
build_info.update(version=version, jarBytes=len(jar), jarSha256=hashlib.sha256(jar).hexdigest(),
                  packagedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
try:
    build_info['packagedSourceCommit']=subprocess.check_output(
        ['git','rev-parse','HEAD'],cwd=r,text=True,stderr=subprocess.DEVNULL).strip()
    build_info['packagedSourceDirty']=bool(subprocess.check_output(
        ['git','status','--porcelain','--untracked-files=no'],cwd=r,text=True).strip())
except (subprocess.CalledProcessError, FileNotFoundError):
    build_info['packagedSourceCommit']='unavailable-source-archive'
skip={'node_modules','tools','.git','.dart_tool','build','target','data','test-results','Pods','.symlinks','ephemeral','.idea','__pycache__'}
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(r.rglob('*')):
        if not p.is_file() or p.is_symlink(): continue
        rel=p.relative_to(r)
        if any(x in skip for x in rel.parts): continue
        if rel.parts[0]=='dist' and rel.name!='mail-client.jar': continue
        if str(rel).startswith('server/src/main/resources/static/'): continue
        if rel.as_posix()=='server/src/main/resources/META-INF/public-web-assets.json': continue
        if rel.name=='.env' or rel.name.startswith('.env.') and rel.name!='.env.example': continue
        if rel.name.startswith('.attach_pid'): continue
        if rel.name.endswith('.log') or rel.name=='local.properties' or rel.name.startswith('.flutter-plugins'): continue
        if rel.name.endswith(('.iml','.xcuserstate')) or rel.name in {'Generated.xcconfig','flutter_export_environment.sh','.DS_Store'}: continue
        if rel.as_posix()=='docs/BUILD_INFO.json':
            z.writestr(str(pathlib.Path(name)/rel),json.dumps(build_info,ensure_ascii=False,indent=2)+'\n')
        else:
            z.write(p,pathlib.Path(name)/rel)
sha=hashlib.sha256(out.read_bytes()).hexdigest()
(r/'dist/SHA256SUMS').write_text(f'{sha}  {out.name}\n')
print(out);print(sha)
PY
