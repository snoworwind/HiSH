"""Install pinned, source-built QEMU libraries into HiSH; preserve a backup."""
from datetime import datetime
from pathlib import Path
import shutil
import struct

root = Path(__file__).resolve().parent.parent
base = root / '.temp/source-build'
source = dict(line.split('=', 1) for line in
              (root / 'deps/libqemu/source.env').read_text().splitlines()
              if line and not line.startswith('#'))
revision = source['QEMU_REVISION']
copies = []
stale_tci = []
for abi, stage, machine in [('arm64-v8a', 'linux', 183), ('x86_64', 'linux-x86_64', 62)]:
    build = base / stage / 'qemu-build'
    assert (build / 'source-revision.txt').read_text().strip() == revision, f'{build}: stale source revision'
    libraries = [('libqemu-system-aarch64.so', 'libqemu-system-aarch64.so'),
                 ('libqemu-img.so', 'libqemu-img.so'),
                 ('libslirp.so.0.4.0', 'libslirp.so.0')]
    tci = 'libqemu-system-aarch64-tci.so'
    if (build / tci).exists():
        assert (build / 'source-revision-tci.txt').read_text().strip() == revision, f'{build}: stale TCI revision'
        libraries.append((tci, tci))
    else:
        stale_tci.append(root / 'feature/hish_main/libs' / abi / tci)
    for built, installed in libraries:
        path = build / built
        with path.open('rb') as stream:
            header = stream.read(64)
        assert header[:6] == b'\x7fELF\x02\x01', f'{path}: expected ELF64 little-endian'
        assert struct.unpack_from('<HH', header, 16) == (3, machine), f'{path}: wrong ELF type or architecture'
        copies.append((path, root / 'feature/hish_main/libs' / abi / installed))

# Validate every input before replacing any library. Back up only the files
# being replaced, including a stale interpreter library if it must be removed.
backup = base / 'backups' / ('qemu-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
for destination in [dest for _, dest in copies] + stale_tci:
    if destination.exists():
        saved = backup / destination.relative_to(root / 'feature/hish_main/libs')
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(destination, saved)
for built, destination in copies:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, destination)
    print(f'Installed {destination.relative_to(root)}')
for destination in stale_tci:
    if destination.exists():
        destination.unlink()
print(f'QEMU {source["QEMU_VERSION"]}, revision {revision}')
print(f'Previous libraries backed up to {backup}')
