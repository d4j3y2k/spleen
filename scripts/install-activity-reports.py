#!/usr/bin/env python3
"""Install or remove Spleen's metadata-only Codex activity reports.

--install adds Spleen's twelve lifecycle hook handlers to <codex-home>/hooks.json and
points the root `notify` in config.toml at a forwarder kept in <codex-home>/spleen-activity/.
The forwarder reports each notification to Spleen, then runs the notify command it
replaced. --uninstall restores that command and removes Spleen's handlers and forwarder
files. Without --install or --uninstall, or with --dry-run, nothing is changed. Other
hook handlers are left alone, and Codex's own hook trust review stays mandatory.
"""
import argparse, copy, datetime, json, os, pathlib, re, shlex, shutil, stat, sys, tempfile, types
try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

PYTHON = '/usr/bin/python3'  # Apple's Python 3.9 runs the forwarder, which needs no TOML support.
FORWARDER, FORWARDING = 'notify-forwarder.py', 'forwarding.json'
FOLDER = 'spleen-activity'  # inside the Codex home, so deleting a checkout cannot strand notify
OLD_FOLDER = 'activity-integration'  # earlier installs kept the forwarder in the Spleen data directory
MAX_DEPTH = 8
EVENTS = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreModelRequest', 'PostModelRequest', 'PreToolUse',
          'PostToolUse', 'PermissionRequest', 'Stop', 'Interrupt', 'SubagentStart', 'SubagentStop']
SCRIPT = '''#!/usr/bin/python3
# Spleen activity notification forwarder, written by scripts/install-activity-reports.py.
# Reports the notification to Spleen, then runs the original notify command from
# forwarding.json with the same arguments, environment, stdout and exit status.
import json, os, pathlib, subprocess, sys
settings = json.loads(pathlib.Path(__file__).with_name("forwarding.json").read_text(encoding="utf-8"))
arguments = sys.argv[1:]
try:
    # A missing, failing or slow Spleen never stops the original command.
    subprocess.run(settings["spleen"] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=2, check=False)
except Exception:
    pass
original = settings["original"]
if original:
    os.execvp(original[0], original + arguments)
'''
ESCAPES = {'"': '\\"', '\\': '\\\\', '\b': '\\b', '\t': '\\t', '\n': '\\n', '\f': '\\f', '\r': '\\r'}


class Refusal(Exception):
    """A reason to stop; raised before any file changes unless a run is already under way."""


def is_str_list(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def toml_array(command):
    def quoted(text):
        return '"' + ''.join(ESCAPES.get(c) or (f'\\u{ord(c):04X}' if ord(c) < 32 or ord(c) == 127 else c)
                             for c in text) + '"'
    return '[' + ', '.join(quoted(part) for part in command) + ']'


def shown(command):
    return toml_array(command) if command else '(none)'


def read_bytes(path):
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def mode_of(path):
    return stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600


def dump(document):
    return json.dumps(document, indent=2, ensure_ascii=False) + '\n'


def target(path):
    """The file to read and replace for path: a symlink's target, so the link itself is kept."""
    if path.is_symlink():
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError):
            raise Refusal(f'{path} is a symbolic link to a missing file; fix the link first.') from None
        path = resolved
    if os.path.lexists(path) and not path.is_file():
        raise Refusal(f'{path} is not a regular file.')
    return path


def set_notify(text, config, command, path):
    """config.toml text with only the one-line root notify replaced, or removed when command is None."""
    lines = text.split('\n')
    tables = [i for i, line in enumerate(lines) if line.lstrip().startswith('[')]
    found = [i for i in range(tables[0] if tables else len(lines)) if re.match(r'[ \t]*notify[ \t]*=', lines[i])]
    if 'notify' in config:
        alone = None
        if len(found) == 1:
            try:
                alone = tomllib.loads(lines[found[0]].rstrip('\r'))
            except tomllib.TOMLDecodeError:
                pass
        if alone != {'notify': config['notify']}:
            raise Refusal(f'notify in {path} is not a single root-level line; a multiline notify needs a manual merge.')
    elif found:
        raise Refusal(f'{path} has a notify line that is not a plain root setting; merge it manually.')
    if command is None:
        if found:
            del lines[found[0]]
    elif found:
        lines[found[0]] = 'notify = ' + toml_array(command) + ('\r' if lines[found[0]].endswith('\r') else '')
    else:
        lines.insert(0, 'notify = ' + toml_array(command))
    result = '\n'.join(lines)
    expected = {key: value for key, value in config.items() if key != 'notify'}
    if command is not None:
        expected['notify'] = command
    try:
        unchanged = tomllib.loads(result) == expected
    except tomllib.TOMLDecodeError:
        unchanged = False
    if not unchanged:
        raise Refusal(f'Could not change notify in {path} without touching anything else; merge it manually.')
    return result


def load_hooks(data, path):
    if data is None:
        return {'hooks': {}}
    try:
        document = json.loads(data.decode('utf-8'))
    except ValueError:
        raise Refusal(f'{path} is not valid UTF-8 JSON.') from None
    events = document.get('hooks', {}) if isinstance(document, dict) else None
    if not (isinstance(events, dict) and all(
            isinstance(groups, list) and all(
                isinstance(group, dict) and isinstance(group.get('hooks', []), list)
                and all(isinstance(handler, dict) for handler in group.get('hooks', [])) for group in groups)
            for groups in events.values())):
        raise Refusal(f'{path} has an unexpected shape; merge the hooks manually.')
    return document


def is_spleen(handler):
    """Any Spleen activity handler, whatever executable or data directory it names."""
    command = handler.get('command')
    return isinstance(command, str) and '--activity-event codex' in command and '--data-dir' in command


def strip_spleen(document, keep=None):
    """A copy without Spleen's handlers, except the first one equal to `keep` in each of EVENTS."""
    document = copy.deepcopy(document)
    removed, kept, emptied = [], set(), []
    for event, groups in document.get('hooks', {}).items():
        result = []
        for group in groups:
            handlers = group.get('hooks', [])
            remaining = []
            for handler in handlers:
                if not is_spleen(handler):
                    remaining.append(handler)
                elif handler == keep and event in EVENTS and event not in kept:
                    remaining.append(handler)
                    kept.add(event)
                else:
                    removed.append(handler['command'])
            if len(remaining) == len(handlers):
                result.append(group)
            elif remaining:
                result.append(dict(group, hooks=remaining))
        if groups and not result:
            emptied.append(event)
        document['hooks'][event] = result
    return document, removed, kept, emptied


def data_dirs_of(commands):
    found = []
    for command in commands:
        try:
            words = shlex.split(command)
        except ValueError:
            continue
        if '--data-dir' in words[:-1]:
            directory = words[words.index('--data-dir') + 1]
            if directory not in found:
                found.append(directory)
    return found


def handlers_line(verb, count, commands, kind='Spleen'):
    if not count:
        return ''
    directories = ', '.join(data_dirs_of(commands))
    return f'{verb} {count} {kind} hook handler{"" if count == 1 else "s"}' + (f' ({directories})' if directories else '')


def helper_of(command):
    """The forwarder path when command has the shape of a Spleen notify forwarder."""
    if is_str_list(command) and len(command) == 2 and command[0] == PYTHON and os.path.basename(command[1]) == FORWARDER:
        return pathlib.Path(command[1])
    return None


def read_settings(path):
    try:
        settings = json.loads(path.read_bytes().decode('utf-8'))
    except (OSError, ValueError):
        return None
    return settings if isinstance(settings, dict) and is_str_list(settings.get('original')) else None


def unwrap(command, config_path, codex):
    """The notify command beneath any Spleen forwarders, and those forwarders from the outermost in."""
    chain = []
    while True:
        helper = helper_of(command)
        if helper is None:
            return command, chain
        if helper in chain or len(chain) == MAX_DEPTH:
            raise Refusal(f'notify in {config_path} nests Spleen forwarders in a loop or more than {MAX_DEPTH} deep. '
                          'Set it back to your own command by hand, then run this again.')
        settings = read_settings(helper.with_name(FORWARDING)) if helper.is_absolute() else None
        if settings is None:
            raise Refusal(broken_forwarder(helper, config_path, codex))
        chain.append(helper)
        command = settings['original']


def broken_forwarder(helper, config_path, codex):
    message = [f"Codex's notify runs a Spleen forwarder whose {FORWARDING} is missing or unreadable:", f'  {helper}',
               'That file recorded the notify command the forwarder wraps, so it cannot be restored automatically.',
               f'Set notify in {config_path} back to your own command, or delete the line if you had none,',
               'then run this script again to finish.']
    saved = sorted((codex/FOLDER/'backups').glob('*/config.toml'), reverse=True)
    if helper.is_absolute():
        saved += sorted(helper.parent.glob('backup-*/config.toml'), reverse=True)
    if saved:
        message.append('Backed-up config.toml files, newest first, may show the earlier line:')
        message += [f'  {path}: {notify_in(path)}' for path in saved[:6]]
    return '\n'.join(message)


def notify_in(path):
    try:
        command = tomllib.loads(path.read_bytes().decode('utf-8')).get('notify')
    except (OSError, ValueError):
        return 'unreadable'
    if command is None:
        return 'no notify'
    if not is_str_list(command):
        return 'unsupported notify'
    return f'notify = {toml_array(command)}' + (' (a Spleen forwarder)' if helper_of(command) else '')


def own_files(folder):
    """The forwarder files in folder, each checked to be one this installer writes."""
    found = []
    script, settings = folder/FORWARDER, folder/FORWARDING
    if script.is_file() and not script.is_symlink():
        data = script.read_bytes()
        if (len(data) < 8192 and data.startswith(b'#!/usr/bin/python3\n')
                and b'with_name("forwarding.json")' in data and b'os.execvp(' in data):
            found.append(script)
    if settings.is_file() and not settings.is_symlink():
        parsed = read_settings(settings)
        if parsed and is_str_list(parsed.get('spleen')) and '--activity-notification' in parsed['spleen']:
            found.append(settings)
    return found


class Plan:
    def __init__(self, folder):
        self.folder, self.lines, self.unchanged, self.backup = folder, [], [], None
        self.saves, self.writes, self.deletes, self.empty_folders, self.done = [], [], [], [], []

    def keep_copies(self, state):
        if state.config_bytes is not None:
            self.saves.append((state.config_file, 'config.toml'))
        if state.hooks_bytes is not None:
            self.saves.append((state.hooks_file, 'hooks.json'))

    def save_forwarding(self, path):
        self.saves.append((path, f'forwarding-{sum(name.startswith("forwarding-") for _, name in self.saves) + 1}.json'))

    def write(self, path, text, mode, before):
        try:
            self.writes.append((path, text.encode('utf-8'), mode, before))
        except UnicodeEncodeError:
            raise Refusal(f'Cannot write {path}: the text is not valid Unicode.') from None

    def delete(self, path):
        if path.name == FORWARDING:
            self.save_forwarding(path)
        self.deletes.append(path)


def replace(path, data, mode):
    """Write data beside path and rename it over path, so readers see the old or the new file."""
    descriptor, staging = tempfile.mkstemp(prefix=f'.{path.name}.', suffix='.spleen-stage', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(staging, mode)
        os.replace(staging, path)
    except BaseException:
        if os.path.lexists(staging):
            os.unlink(staging)
        raise


def carry_out(plan):
    """Take a fresh private backup, then change the files in plan order."""
    backups = plan.folder/'backups'
    for folder in (plan.folder, backups):
        folder.mkdir(mode=0o700, exist_ok=True)
        os.chmod(folder, 0o700)
    destination = backups/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    destination.mkdir(mode=0o700)
    os.chmod(destination, 0o700)
    for source, name in plan.saves:
        shutil.copyfile(source, destination/name)
        os.chmod(destination/name, 0o600)
    plan.backup = destination
    for path, data, mode, before in plan.writes:
        if read_bytes(path) != before:
            raise Refusal(f'{path} changed while this script was running; run it again.')
        replace(path, data, mode)
        plan.done.append(path)
    for path in plan.deletes:
        path.unlink()
        plan.done.append(path)
    for folder in plan.empty_folders:
        try:
            folder.rmdir()
        except OSError:
            pass  # still holds backups or other files


def inspect(codex):
    """Read and check everything before any change."""
    if not codex.is_dir():
        raise Refusal(f'{codex} does not exist; pass --codex-home with your Codex configuration folder.')
    state = types.SimpleNamespace(codex=codex, config_path=codex/'config.toml', hooks_path=codex/'hooks.json')
    state.config_file, state.hooks_file = target(state.config_path), target(state.hooks_path)
    state.config_bytes, state.hooks_bytes = read_bytes(state.config_file), read_bytes(state.hooks_file)
    try:
        state.config_text = (state.config_bytes or b'').decode('utf-8')
        state.config = tomllib.loads(state.config_text)
    except ValueError as error:
        raise Refusal(f'{state.config_path} is not valid UTF-8 TOML ({error}).') from None
    current = state.config.get('notify')
    if current is not None and not is_str_list(current):
        raise Refusal(f'notify in {state.config_path} is not a list of strings; merge it manually.')
    state.hooks = load_hooks(state.hooks_bytes, state.hooks_path)
    state.original, state.chain = unwrap(current or [], state.config_path, codex)
    return state


def plan_install(state, exe, data):
    if not (exe.is_file() and os.access(exe, os.X_OK)):
        raise Refusal(f'Build Spleen first: {exe} is not an executable file.')
    plan = Plan(state.codex/FOLDER)
    if os.path.lexists(plan.folder) and not plan.folder.is_dir():
        raise Refusal(f'{plan.folder} exists but is not a folder.')
    plan.keep_copies(state)
    forwarder, forwarding = plan.folder/FORWARDER, plan.folder/FORWARDING
    notify, current = [PYTHON, str(forwarder)], state.config.get('notify')
    settings = {'original': state.original,
                'spleen': [str(exe), '--activity-notification', 'codex', '--data-dir', str(data)]}
    handler = {'type': 'command', 'command': shlex.quote(str(exe)) + ' --activity-event codex --data-dir '
               + shlex.quote(str(data)), 'timeout': 2}
    hooks, removed, kept, _ = strip_spleen(state.hooks, keep=handler)
    for event in EVENTS:
        if event not in kept:
            hooks.setdefault('hooks', {}).setdefault(event, []).append({'hooks': [dict(handler)]})
    if (read_settings(forwarding) if forwarding.is_file() else None) != settings:
        if forwarding.is_file():
            plan.save_forwarding(forwarding)
        plan.write(forwarding, dump(settings), 0o600, read_bytes(forwarding))
    if read_bytes(forwarder) != SCRIPT.encode():
        plan.write(forwarder, SCRIPT, 0o600, read_bytes(forwarder))
    if hooks != state.hooks:
        plan.write(state.hooks_file, dump(hooks), mode_of(state.hooks_file), state.hooks_bytes)
    if current != notify:
        plan.write(state.config_file, set_notify(state.config_text, state.config, notify, state.config_path),
                   mode_of(state.config_file), state.config_bytes)
    for helper in state.chain:  # earlier layouts only; another Codex home's forwarder stays
        if helper.parent.name == OLD_FOLDER:
            for path in own_files(helper.parent):
                plan.delete(path)
                plan.lines.append(f'delete the earlier forwarder file {path}; its backups stay')
            plan.empty_folders.append(helper.parent)
    added = len(EVENTS) - len(kept)
    plan.lines[:0] = [line for line in [
        f'set notify = {toml_array(notify)}' + (f' (was {shown(current)})' if current else '') if current != notify
        else 'keep notify: it already runs the forwarder',
        f'forward each notification to Spleen ({data}, executable {exe}), then run the original notify',
        f'original notify, restored by --uninstall: {shown(state.original)}',
        'write ' + ' and '.join(path.name for path, *_ in plan.writes if path in (forwarder, forwarding))
        + f' in {plan.folder}' if any(path in (forwarder, forwarding) for path, *_ in plan.writes) else '',
        handlers_line('add', added, [handler['command']]) + (' with a 2-second timeout' if added else ''),
        handlers_line('remove', len(removed), removed, 'earlier Spleen'),
        'other hook handlers stay as they are'] if line]
    plan.unchanged = [f'Spleen activity reporting is already installed in {state.codex} for this executable and data '
                      'directory; nothing changed.', f'  original notify, restored by --uninstall: {shown(state.original)}']
    return plan


def plan_uninstall(state, data_dir):
    plan = Plan(state.codex/FOLDER)
    plan.keep_copies(state)
    if state.chain:
        restored = state.original or None
        plan.write(state.config_file, set_notify(state.config_text, state.config, restored, state.config_path),
                   mode_of(state.config_file), state.config_bytes)
        plan.lines.append(f'restore notify = {toml_array(restored)}' if restored
                          else 'remove the notify line: there was none before Spleen')
    else:
        plan.lines.append('keep notify: it does not run a Spleen forwarder')
    hooks, removed, _, emptied = strip_spleen(state.hooks)
    for event in emptied:
        del hooks['hooks'][event]
    if removed:
        plan.write(state.hooks_file, dump(hooks), mode_of(state.hooks_file), state.hooks_bytes)
        plan.lines += [handlers_line('remove', len(removed), removed), 'other hook handlers stay as they are']
    places = [plan.folder] + [helper.parent for helper in state.chain if helper.parent.name == OLD_FOLDER]
    directories = [d for d in data_dirs_of(removed) if os.path.isabs(d)] + ([str(data_dir)] if data_dir else [])
    places += [pathlib.Path(directory)/OLD_FOLDER for directory in directories]
    notes, seen = [], set()
    for place in places:
        if os.path.realpath(place) in seen:
            continue
        seen.add(os.path.realpath(place))
        mine = own_files(place)
        for path in mine:
            plan.delete(path)
            plan.lines.append(f'delete {path}')
        notes += [f'leave {path} in place: not recognized as written by this installer'
                  for path in (place/FORWARDER, place/FORWARDING) if os.path.lexists(path) and path not in mine]
        if mine and place.name == OLD_FOLDER:
            plan.empty_folders.append(place)
    plan.lines += notes + [f'leave the backups in {plan.folder/"backups"}'] if plan.writes or plan.deletes else []
    plan.unchanged = [f'Spleen activity reporting is not installed in {state.codex}; nothing changed.'] + [
        '  ' + note for note in notes]
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--codex-home', type=pathlib.Path, default=pathlib.Path.home()/'.codex',
                        help='Codex configuration folder (default: ~/.codex)')
    parser.add_argument('--data-dir', type=pathlib.Path, help='Spleen data directory that receives the reports')
    parser.add_argument('--executable', type=pathlib.Path, help='Spleen executable that the hooks and forwarder run')
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--install', action='store_true', help='make the changes the preview shows')
    action.add_argument('--uninstall', action='store_true',
                        help='restore the original notify and remove Spleen hook handlers and forwarder files')
    parser.add_argument('--dry-run', action='store_true', help='only show what --install or --uninstall would change')
    a = parser.parse_args()
    if tomllib is None:
        parser.exit(2, 'Spleen activity setup requires Python 3.11 or later (tomllib). Run this script with that '
                       'interpreter; Apple\'s Python 3.9 is too old. No files changed.\n')
    if not a.uninstall and (a.data_dir is None or a.executable is None):
        parser.error('--data-dir and --executable are required unless --uninstall is given')
    try:
        state = inspect(a.codex_home.expanduser().resolve())
        if a.uninstall:
            plan = plan_uninstall(state, a.data_dir.expanduser().resolve() if a.data_dir else None)
        else:
            plan = plan_install(state, a.executable.expanduser().resolve(), a.data_dir.expanduser().resolve())
    except (Refusal, OSError) as problem:
        sys.stderr.write(f'{problem}\nNo files changed.\n')
        return 1
    if not plan.writes and not plan.deletes:
        print('\n'.join(plan.unchanged))
        return 0
    footer = ('Codex runs the new hooks only after you review and trust them (Settings > Hooks, or /hooks).'
              if not a.uninstall else 'Codex sessions that are already open may keep the removed hooks until reopened.')
    if a.dry_run or not (a.install or a.uninstall):
        flag = '--uninstall' if a.uninstall else '--install'
        print(f'Preview only; no files changed. Running with {flag} would:')
        print('\n'.join('  ' + line for line in plan.lines))
        print(f'  back up the current files to {plan.folder/"backups"}/<UTC time>/')
        print(footer)
        return 0
    try:
        carry_out(plan)
    except (Refusal, OSError) as problem:
        changed = ', '.join(str(path) for path in plan.done) or 'nothing yet'
        sys.stderr.write(f'Stopped: {problem}\nAlready changed: {changed}. Backup: {plan.backup or "none taken"}.\n')
        return 1
    print(f'{"Uninstalled" if a.uninstall else "Installed"} Spleen activity reporting '
          f'{"from" if a.uninstall else "in"} {state.codex}:')
    print('\n'.join('  ' + line for line in plan.lines))
    print(f'  backup of the earlier files: {plan.backup}')
    print(footer)
    return 0


if __name__ == '__main__':
    sys.exit(main())
