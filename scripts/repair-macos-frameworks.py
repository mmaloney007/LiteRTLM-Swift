"""Normalize the pinned macOS framework layout on a new package copy only."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout


def snapshot(root):
    result = {}
    for p in sorted(root.rglob('*')):
        if '.git' in p.relative_to(root).parts:
            continue
        if p.is_symlink():
            result[str(p.relative_to(root))] = {'symlink': str(p.readlink())}
        elif p.is_file():
            result[str(p.relative_to(root))] = {'sha256': digest(p), 'mode': p.stat().st_mode & 0o777}
    return result


def repair(source, destination, inventory):
    source = source.resolve(strict=True)
    destination = destination.parent.resolve(strict=True) / destination.name
    if destination.exists() or destination.is_symlink():
        raise ValueError('Destination must be absent; existing evidence is preserved')
    if source == destination or source in destination.parents:
        raise ValueError('Destination must be outside source')
    evidence = json.loads(inventory.read_text())
    if run('git', '-C', source, 'rev-parse', 'HEAD').strip() != evidence['source_sha']:
        raise ValueError('Package source pin differs from inventory')
    if run('git', '-C', source, 'status', '--porcelain', '--untracked-files=all').strip():
        raise ValueError('Package source must be clean, including untracked files')
    original = snapshot(source)
    for slice_row in evidence['slices']:
        for entry in slice_row['entries']:
            expected = {k: entry[k] for k in ('sha256', 'symlink') if k in entry}
            actual = original.get(entry['path'], {})
            if {k: actual.get(k) for k in expected} != expected:
                raise ValueError(f"Source inventory mismatch: {entry['path']}")
    for row in evidence['slices']:
        prefix = 'Frameworks/' + row['framework'] + '/' + row['library']['LibraryIdentifier'] + '/'
        actual_paths = {p for p in original if p.startswith(prefix)}
        if actual_paths != {e['path'] for e in row['entries']}:
            raise ValueError('Inventory slice coverage differs: ' + prefix)
    frameworks = []
    mapping = {}
    for row in evidence['slices']:
        lib = row['library']
        if lib['SupportedPlatform'] != 'macos':
            continue
        fw = Path('Frameworks') / row['framework'] / lib['LibraryIdentifier'] / lib['LibraryPath']
        info_path = source / fw / 'Resources/Info.plist'
        if not info_path.exists():
            info_path = source / fw / 'Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        binary = (source / fw / info['CFBundleExecutable']).resolve(strict=True)
        binary.relative_to(source)
        if run('lipo', '-archs', binary).strip() != 'arm64':
            raise ValueError('Only the pinned thin arm64 macOS slices are supported')
        ids = run('otool', '-arch', 'arm64', '-D', binary).splitlines()[1:]
        if len(ids) != 1:
            raise ValueError(f'Expected one arm64 dylib identity: {binary}')
        expected = '@rpath/' + fw.name + '/' + info['CFBundleExecutable']
        if ids[0].startswith('@rpath/lib'):
            if ids[0] in mapping:
                raise ValueError('Duplicate library identity')
            mapping[ids[0]] = expected
        elif ids[0] == '@rpath/' + fw.name + '/Versions/A/' + info['CFBundleExecutable']:
            expected = ids[0]  # Existing valid versioned identity stays unchanged.
        elif ids[0] != expected:
            raise ValueError(f'Unknown framework identity: {ids[0]}')
        frameworks.append((fw, binary.relative_to(source), ids[0], expected))
    if len(frameworks) != 7 or len(mapping) != 6:
        raise ValueError('Pinned package layout differs from measured seven-framework/six-repair baseline')
    allowed = set(mapping) | set(mapping.values()) | {r[3] for r in frameworks}
    for fw, binary, _, _ in frameworks:
        allowed.add('@rpath/' + fw.name + '/Versions/A/' + binary.name)
    plans = []
    for fw, binary, old_id, new_id in frameworks:
        deps = [line.strip().split(' (')[0] for line in run('otool', '-arch', 'arm64', '-L', source / binary).splitlines()[2:]]
        unknown = [d for d in deps if d not in allowed and not d.startswith(('/usr/lib/', '/System/Library/'))]
        if unknown:
            raise ValueError(f'Unmapped dependencies in {binary}: {unknown}')
        args = []
        if old_id != new_id:
            # Measured small headers need this unused search-path space.
            # Dependency allowlist above admits no Swift @rpath dependency.
            details = run('otool', '-l', source / binary)
            if 'path /usr/lib/swift (offset' in details:
                args += ['-delete_rpath', '/usr/lib/swift']
            args += ['-id', new_id]
        for dep in deps:
            if dep in mapping:
                args += ['-change', dep, mapping[dep]]
        if args:
            plans.append((fw, binary, args))
    # The source stays untouched. Failed copies are retained for diagnosis.
    shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    planned_args = {binary: args for _, binary, args in plans}
    # Re-seal all macOS frameworks: the input CLiteRTLM header seal is stale.
    # Header bytes are preserved and covered by the original inventory.
    for fw, binary, _, _ in frameworks:
        args = planned_args.get(binary)
        if args:
            run('install_name_tool', *args, destination / binary)
        signature_modes = {}
        for signature in (destination / fw).rglob('_CodeSignature/*'):
            if signature.is_file() and not signature.is_symlink():
                signature_modes[signature] = signature.stat().st_mode & 0o777
                signature.chmod(signature_modes[signature] | 0o200)
        try:
            run('codesign', '--force', '--sign', '-', '--preserve-metadata=identifier,entitlements,flags,runtime', destination / fw)
        finally:
            for signature, mode in signature_modes.items():
                signature.chmod(mode)
        run('codesign', '--verify', '--strict', destination / fw)
    for fw, binary, old_id, new_id in frameworks:
        top = destination / fw / binary.name
        if top.resolve(strict=True) != (destination / binary).resolve(strict=True):
            raise ValueError('Framework top-level symlink does not resolve to binary')
        if run('otool', '-arch', 'arm64', '-D', destination / binary).splitlines()[1:] != [new_id]:
            raise ValueError(f'Incorrect repaired identity: {binary}')
        deps = [line.strip().split(' (')[0] for line in run('otool', '-arch', 'arm64', '-L', destination / binary).splitlines()[2:]]
        if any(d in mapping for d in deps):
            raise ValueError(f'Unrepaired dependency: {binary}')
    after = snapshot(destination)
    changed = [p for p in sorted(original.keys() | after.keys()) if original.get(p) != after.get(p)]
    allowed_binaries = {str(binary) for _, binary, _, _ in frameworks}
    signature_roots = [str(fw) + '/' for fw, _, _, _ in frameworks]
    for path in changed:
        signature = any(path.startswith(prefix) and '_CodeSignature' in Path(path).parts for prefix in signature_roots)
        if path not in allowed_binaries and not signature:
            raise ValueError(f'Unexpected package change: {path}')
    for row in evidence['slices']:
        if row['library']['SupportedPlatform'] != 'macos':
            for entry in row['entries']:
                if original[entry['path']] != after.get(entry['path']):
                    raise ValueError(f"Non-macOS slice changed: {entry['path']}")
    if snapshot(source) != original:
        raise ValueError('Original package changed during execution')
    receipt = {'source_sha': evidence['source_sha'], 'inventory_sha256': digest(inventory),
               'source': str(source), 'destination': str(destination), 'mapping': mapping,
               'changed': {p: {'before': original.get(p), 'after': after.get(p)} for p in changed},
               'non_macos_slices_unchanged': sum(r['library']['SupportedPlatform'] != 'macos' for r in evidence['slices']), 'original_unchanged': True,
               'scope': 'Package file contents, file modes and symlink targets verified; xattrs and hard-link topology not claimed. Local ad-hoc signatures prove consistency, not vendor authenticity. Source pin and original hashes retain input provenance. Fresh app build and independent verification owed'}
    receipt_path = destination.parent / (destination.name + '-receipt.json')
    if receipt_path.exists():
        raise ValueError('Receipt already exists; preserved without overwrite')
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('inventory', type=Path)
    options = parser.parse_args()
    print(repair(options.source, options.destination, options.inventory))
