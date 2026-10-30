"""Check every packaged engine variant, including its optional CPU instructions."""
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess

EXPORTS = {'pikafish_start', 'pikafish_is_running', 'pikafish_physical_memory_mb',
           'pikafish_write', 'pikafish_read', 'pikafish_can_read_assets',
           'Java_com_hocviencotuong_pikafish_1uci_PikafishAssets_register'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--abi', choices=['arm64-v8a', 'x86_64'], required=True)
    parser.add_argument('--ndk', type=Path, required=True)
    parser.add_argument('--compile-commands', type=Path,
                        help='Compilation database when this is a CMake subdirectory')
    parser.add_argument('--baseline-defines', type=Path,
                        help='Exact define list queried from the pinned upstream Makefile')
    args = parser.parse_args()
    bins = next(path for path in (args.ndk / 'toolchains/llvm/prebuilt').glob('*/bin')
                if (path / 'llvm-readelf').exists() or (path / 'llvm-readelf.exe').exists())
    suffix = '.exe' if (bins / 'llvm-readelf.exe').exists() else ''
    commands = json.loads((args.compile_commands or args.build_dir / 'compile_commands.json').read_text())
    baseline = {'-DNDEBUG', '-DIS_64BIT', '-DUSE_PREFETCH', '-DUSE_POPCNT'}
    baseline |= ({'-DARCH=armv8', '-DUSE_NEON=8'} if args.abi == 'arm64-v8a' else
                 {'-DARCH=x86-64-sse41-popcnt', '-DUSE_SSE41', '-DUSE_SSSE3', '-DUSE_SSE2'})
    if args.baseline_defines:
        baseline = set(args.baseline_defines.read_text().split())
    variants = [''] + (['_dotprod'] if args.abi == 'arm64-v8a' else [])
    report = {}
    for variant in variants:
        target = 'pikafish_core' + variant
        entry = next(item for item in commands if item['file'].endswith('evaluate.cpp') and
                     (target + '.dir') in (item.get('command') or ' '.join(item['arguments'])))
        command = entry.get('command') or ' '.join(entry['arguments'])
        defines = set(re.findall(r'(?:^|\s)(-D[^\s]+)', command))
        defines = {x for x in defines if not re.fullmatch(r'-D(?:ANDROID|_FORTIFY_SOURCE(?:=.*)?)', x)}
        expected = baseline | ({'-DUSE_NEON_DOTPROD'} if variant else set())
        assert defines == expected, (target, sorted(defines), sorted(expected))
        if variant:
            assert re.search(r'(?:^|\s)-march=armv8-a\+dotprod(?:\s|$)', command), command
        else:
            assert '+dotprod' not in command
        path = args.build_dir / ('libpikafish_uci' + variant + '.so')
        data = path.read_bytes()
        assert data[:6] == b'\x7fELF\x02\x01'
        assert struct.unpack_from('<H', data, 18)[0] == (183 if args.abi == 'arm64-v8a' else 62)
        table = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        assert size == 56 and count > 0
        loads = []
        for index in range(count):
            header = struct.unpack_from('<IIQQQQQQ', data, table + index * size)
            if header[0] == 1:
                assert header[7] >= 16384 and header[2] % 16384 == header[3] % 16384
                loads.append(header[7])
        assert loads
        symbols = subprocess.check_output([str(bins / ('llvm-readelf' + suffix)),
                                           '--dyn-syms', '--wide', str(path)], text=True)
        exports = {parts[7] for line in symbols.splitlines() if len(parts := line.split()) >= 8
                   and parts[3:5] == ['FUNC', 'GLOBAL'] and parts[6] != 'UND'}
        assert exports == EXPORTS, (path, exports)
        dynamic = subprocess.check_output([str(bins / ('llvm-readelf' + suffix)), '-d', str(path)], text=True)
        needed = re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic)
        assert 'libc++_shared.so' not in needed
        assert 'libpikafish_uci_dotprod.so' not in needed
        assert 'libpikafish_uci.so' not in needed
        dot_instructions = 0
        if args.abi == 'arm64-v8a':
            assembly = subprocess.check_output([str(bins / ('llvm-objdump' + suffix)), '-d',
                                                '--mattr=+dotprod', str(path)], text=True)
            dot_instructions = len(re.findall(r'\b[us]dot\s', assembly))
            assert (dot_instructions > 0) == bool(variant), (path, dot_instructions)
        report[path.name] = {'bytes': len(data), 'load_alignment': loads,
                             'exports': sorted(exports), 'defines': sorted(defines),
                             'dot_instructions': dot_instructions}
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
