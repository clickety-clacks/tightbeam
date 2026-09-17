#!/usr/bin/env python3
"""Apply or roll back an exact-build, two-file Astra overlay while its gateway is stopped."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def beneath(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise RuntimeError('manifest paths must be relative and stay inside their root')
    if not path.resolve().is_relative_to(root.resolve()):
        raise RuntimeError('manifest target escapes its root')
    return path


def atomic_write(path, content, mode):
    fd, name = tempfile.mkstemp(prefix='.astra-overlay-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def run(action, bundle, package_root, base_dir, backup_dir):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    if manifest.get('format') != 1 or len(manifest.get('files', [])) != 2:
        raise RuntimeError('unsupported overlay manifest')
    roots = {'package': package_root, 'base': base_dir}
    entries = []
    for index, item in enumerate(manifest['files']):
        target = beneath(roots[item['scope']], item['path'])
        payload = beneath(bundle, item['payload'])
        if digest(payload) != item['patched_sha256']:
            raise RuntimeError(f'payload hash mismatch: {item["payload"]}')
        current = digest(target)
        if current not in (item['original_sha256'], item['patched_sha256']):
            raise RuntimeError(f'unrecognized installed bytes: {target}')
        entries.append((item, target, payload, backup_dir / f'{index}.original', current))
    baseline = all(current == item['original_sha256'] for item, _, _, _, current in entries)
    patched = all(current == item['patched_sha256'] for item, _, _, _, current in entries)
    if not (baseline or patched):
        raise RuntimeError('mixed overlay state; refusing to guess or repair')
    if action == 'check':
        print('Compatible baseline' if baseline else 'Overlay installed')
        return
    port = int(json.loads((base_dir / 'gateway.json').read_text())['port'])
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=1):
            raise RuntimeError(f'gateway port {port} is listening; stop the gateway first')
    except ConnectionRefusedError:
        pass
    # Other network errors do not prove the gateway is stopped.
    if action == 'apply':
        if not baseline:
            raise RuntimeError('overlay already installed; no changes made')
        backup_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        for item, target, _, backup, _ in entries:
            shutil.copy2(target, backup)
            if digest(backup) != item['original_sha256']:
                raise RuntimeError('backup verification failed')
        (backup_dir / 'targets.json').write_text(json.dumps([str(t.resolve()) for _, t, _, _, _ in entries]))
        replacements = [(target, payload.read_bytes()) for _, target, payload, _, _ in entries]
    else:
        if not patched:
            raise RuntimeError('baseline already installed; no changes made')
        expected_targets = [str(t.resolve()) for _, t, _, _, _ in entries]
        if json.loads((backup_dir / 'targets.json').read_text()) != expected_targets:
            raise RuntimeError('backup belongs to different target paths')
        for item, _, _, backup, _ in entries:
            if digest(backup) != item['original_sha256']:
                raise RuntimeError('rollback backup hash mismatch')
        replacements = [(target, backup.read_bytes()) for _, target, _, backup, _ in entries]
    before = [(target, target.read_bytes(), target.stat().st_mode & 0o777) for target, _ in replacements]
    try:
        for (target, content), (_, _, mode) in zip(replacements, before):
            atomic_write(target, content, mode)
    except BaseException:
        for target, content, mode in before:
            atomic_write(target, content, mode)
        raise
    print('Overlay applied' if action == 'apply' else 'Original bytes restored')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'apply', 'rollback'])
    for name in ['bundle', 'package-root', 'base-dir', 'backup-dir']:
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    try:
        run(args.action, args.bundle, args.package_root, args.base_dir, args.backup_dir)
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        parser.exit(1, f'Refused: {error}\n')


if __name__ == '__main__':
    main()
