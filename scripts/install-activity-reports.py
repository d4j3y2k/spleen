#!/usr/bin/env python3
"""Install Spleen's metadata-only reports without replacing existing hooks/notify.
The runtime's ordinary hook trust review remains mandatory and untouched.
"""
import argparse, datetime, json, os, pathlib, re, shlex, shutil, tomllib
p = argparse.ArgumentParser()
p.add_argument('--codex-home', type=pathlib.Path, default=pathlib.Path.home()/'.codex')
p.add_argument('--data-dir', type=pathlib.Path, required=True)
p.add_argument('--executable', type=pathlib.Path, required=True)
p.add_argument('--install', action='store_true')
a = p.parse_args()
root = a.codex_home.resolve(); data = a.data_dir.resolve(); exe = a.executable.resolve()
assert exe.is_file() and os.access(exe, os.X_OK), 'Build Spleen first'
config_path = root/'config.toml'; hook_path = root/'hooks.json'
config = config_path.read_text() if config_path.exists() else ''
parsed = tomllib.loads(config)
hooks = json.loads(hook_path.read_text()) if hook_path.exists() else {'hooks': {}}
assert isinstance(hooks.get('hooks', {}), dict), 'Unexpected hooks configuration'
location = data/'activity-integration'
forwarder = location/'notify-forwarder.py'; forwarding = location/'forwarding.json'
current = parsed.get('notify', [])
assert isinstance(current, list) and all(isinstance(x,str) for x in current), 'Unsupported notify shape'
ours = ['/usr/bin/python3', str(forwarder)]
if current == ours:
    old = json.loads(forwarding.read_text())['original']
else:
    old = current
# Only edit a one-line root notify definition; refuse ambiguous TOML.
lines=config.splitlines(keepends=True); headers=[i for i,s in enumerate(lines) if s.lstrip().startswith('[')]
root_end=headers[0] if headers else len(lines)
matches=[i for i,s in enumerate(lines[:root_end]) if re.match(r'^\s*notify\s*=',s)]
assert len(matches) <= 1 and (not current or matches), 'Unsupported notify location'
if matches:
    i=matches[0]
    assert tomllib.loads(lines[i]).get('notify') == current, 'Multiline notify needs a manual merge'
    del lines[i]
new_config='notify = '+json.dumps(ours)+'\n'+''.join(lines)
assert tomllib.loads(new_config).get('notify') == ours
command=shlex.quote(str(exe))+' --activity-event codex --data-dir '+shlex.quote(str(data))
events=['SessionStart','SessionEnd','UserPromptSubmit','PreModelRequest','PostModelRequest','PreToolUse','PostToolUse','PermissionRequest','Stop','Interrupt','SubagentStart','SubagentStop']
for event in events:
    groups=hooks.setdefault('hooks',{}).setdefault(event,[])
    assert isinstance(groups,list), 'Unexpected hook group'
    # Only replace Spleen's exact previous helper command; other handlers stay intact.
    for group in groups:
        group['hooks']=[h for h in group.get('hooks',[]) if h.get('command') != command]
    groups[:]=[g for g in groups if g.get('hooks')]
    groups.append({'hooks':[{'type':'command','command':command,'timeout':2}]})
script='''#!/usr/bin/python3
import json, os, pathlib, subprocess, sys
settings=json.loads(pathlib.Path(__file__).with_name("forwarding.json").read_text())
payload=sys.argv[-1] if len(sys.argv)>1 else ""
try:
    subprocess.run(settings["spleen"]+[payload], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=2, check=False)
except Exception:
    pass
# Preserve the original notification's arguments, environment, stdout and exit status.
original=settings["original"]
if original:
    os.execvp(original[0],original+[payload])
'''
if not a.install:
    print('Ready: 12 lifecycle event groups; existing hooks and notification preserved; normal hook review required.')
    raise SystemExit(0)
location.mkdir(parents=True,exist_ok=True,mode=0o700)
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup=location/('backup-'+stamp); backup.mkdir(mode=0o700)
for file in (config_path,hook_path):
    if file.exists():
        shutil.copyfile(file,backup/file.name); os.chmod(backup/file.name,0o600)
def write(path,contents):
    temporary=path.with_name(path.name+'.spleen-stage')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as out: out.write(contents)
    os.replace(temporary,path)
write(forwarder,script)
write(forwarding,json.dumps({'original':old,'spleen':[str(exe),'--activity-notification','codex','--data-dir',str(data)]}))
write(hook_path,json.dumps(hooks,indent=2)+'\n')
write(config_path,new_config)
print('Installed Spleen activity reporting. Existing hooks/notification preserved. Review the new hooks in Codex Settings > Hooks before they run.')
