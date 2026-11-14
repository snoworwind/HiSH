"""Check rebuilt artifacts: ELF architecture, Linux arm64 Image header, QEMU entry
points, and that the libraries and images committed to the repo match the build.

Usage: python scripts/verify-source-build.py
"""
from __future__ import annotations

from pathlib import Path
import hashlib
import struct

root = Path(__file__).resolve().parent.parent
base = root / '.temp/source-build'
MACHINES = {183: 'AArch64', 62: 'x86-64'}
install_dirs = [base / 'install', base / 'linux/install', base / 'linux-x86_64/install']
qemu_builds = {
    'arm64-v8a': base / 'linux/qemu-build',
    'x86_64': base / 'linux-x86_64/qemu-build',
}


def check_elf(path: Path, expected: int) -> str:
    header = path.read_bytes()[:64]
    assert header[:4] == b'\x7fELF', f'{path}: not an ELF file'
    assert header[4:6] == b'\x02\x01', f'{path}: not ELF64 little-endian'
    machine = struct.unpack_from('<H', header, 18)[0]
    assert machine == expected, f'{path}: e_machine {machine}, expected {MACHINES[expected]} ({expected})'
    return MACHINES[expected]


def dynamic_symbols(path: Path) -> set[str]:
    """Read the dynamic symbol table of a shared object."""
    data = path.read_bytes()
    e_shoff, = struct.unpack_from('<Q', data, 40)
    e_shentsize, e_shnum = struct.unpack_from('<HH', data, 58)
    sections = []
    for index in range(e_shnum):
        off = e_shoff + index * e_shentsize
        sh_name, sh_type = struct.unpack_from('<II', data, off)
        sh_offset, sh_size, sh_link, sh_info = struct.unpack_from('<QQII', data, off + 24)
        sh_entsize, = struct.unpack_from('<Q', data, off + 56)
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_info, sh_entsize))
    symbols = set()
    for sh_type, sh_offset, sh_size, sh_link, sh_info, sh_entsize in sections:
        if sh_type != 11:  # SHT_DYNSYM
            continue
        strtab = sections[sh_link]
        count = sh_size // sh_entsize if sh_entsize else 0
        for index in range(count):
            off = sh_offset + index * sh_entsize
            st_name, = struct.unpack_from('<I', data, off)
            end = data.index(b'\0', strtab[1] + st_name)
            symbols.add(data[strtab[1] + st_name:end].decode())
    return symbols


checked = 0
for install in install_dirs:
    abi = 'x86_64' if 'x86_64' in str(install) else 'AArch64'
    expected = 62 if abi == 'x86_64' else 183
    for path in sorted((install / 'lib').glob('*.so*')):
        if path.is_symlink() or not path.is_file():
            continue
        machine = check_elf(path, expected)
        checked += 1
        print(f'{machine} ELF OK: {path.relative_to(base)}')

kernel = base / 'install/kernel_aarch64'
if kernel.exists():
    header = kernel.read_bytes()[:64]
    assert header[56:60] == b'ARM\x64', 'Invalid Linux arm64 Image magic'
    image_size = struct.unpack_from('<Q', header, 16)[0]
    assert image_size > 0, 'Invalid Image size'
    print(f'Linux arm64 Image header OK; declared image size {image_size}')

images = base / 'images'
kernel_image = images / 'kernel_aarch64'
if kernel_image.exists():
    header = kernel_image.read_bytes()[:64]
    assert header[56:60] == b'ARM\x64', 'Invalid Linux arm64 Image magic in images/'
    image_size = struct.unpack_from('<Q', header, 16)[0]
    release = (base / 'logs/kernel-release.txt')
    release = release.read_text().strip() if release.exists() else 'unknown'
    print(f'images/kernel_aarch64: Linux {release} Image OK, {kernel_image.stat().st_size} bytes')

rootfs = images / 'rootfs_aarch64.qcow2'
if rootfs.exists():
    with open(rootfs, 'rb') as fh:
        magic = fh.read(4)
    assert magic == b'QFI\xfb', f'images/rootfs_aarch64.qcow2: bad qcow2 magic {magic!r}'
    print(f'images/rootfs_aarch64.qcow2: qcow2 header OK, {rootfs.stat().st_size} bytes')

# The committed VM images must be byte-identical to the recorded source build;
# this is what stops a downloaded image from silently replacing a built one.
manifest_path = base / 'manifest.json'
committed = {
    'kernel_aarch64': root / 'feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64',
    'rootfs_aarch64.qcow2': root / 'feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2',
}
if manifest_path.exists():
    import json

    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    recorded = {Path(entry['file']).name: entry['sha256'] for entry in manifest.get('images', [])}
    for name, path in committed.items():
        if name not in recorded:
            print(f'WARNING: no manifest entry for images/{name}')
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest == recorded[name], (
            f'{path}: sha256 {digest} does not match the recorded source build {recorded[name]}'
        )
        print(f'committed {name} matches manifest.json ({digest[:16]}...)')
else:
    print('manifest.json missing: skipping committed-image comparison')

for abi, build in qemu_builds.items():
    expected = 62 if abi == 'x86_64' else 183
    system_lib = build / 'libqemu-system-aarch64.so'
    img_lib = build / 'libqemu-img.so'
    slirp = build / 'libslirp.so.0.4.0'
    if not system_lib.exists():
        print(f'not built yet: {system_lib.relative_to(base)}')
        continue
    machine = check_elf(system_lib, expected)
    symbols = dynamic_symbols(system_lib)
    assert 'qemu_system_entry' in symbols, f'{system_lib} lacks qemu_system_entry'
    check_elf(img_lib, expected)
    check_elf(slirp, expected)
    assert 'qemu_img_entry' in dynamic_symbols(img_lib), f'{img_lib} lacks qemu_img_entry'
    print(f'{machine} ELF OK with qemu_system_entry/qemu_img_entry exports: {system_lib.relative_to(base)} '
          f'({system_lib.stat().st_size} bytes)')

    # The libraries committed to feature/hish_main/libs must be the ones just built.
    installed = root / f'feature/hish_main/libs/{abi}'
    for built, name in ((system_lib, 'libqemu-system-aarch64.so'),
                        (img_lib, 'libqemu-img.so'),
                        (slirp, 'libslirp.so.0')):
        candidate = installed / name
        if not candidate.exists():
            print(f'WARNING: missing committed library {candidate.relative_to(root)}')
            continue
        same = hashlib.sha256(built.read_bytes()).hexdigest() == hashlib.sha256(candidate.read_bytes()).hexdigest()
        assert same, f'{candidate} is not the library built by scripts/build-source-linux.sh'
        print(f'committed {abi}/{name} matches the source build')

print(f'{checked} shared library files have the expected ELF64 headers')
print('These are format checks, not runtime tests.')
