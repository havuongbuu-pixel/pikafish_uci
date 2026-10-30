"""Regression: patches must apply inside a Git checkout and outside it."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cmake', default='cmake')
parser.add_argument('--ruby', help='Also exercise the CocoaPods generator')
ARGS, REST = parser.parse_known_args()
MARKERS = {
    'main.cpp': 'int pikafish_main(',
    'nnue/network.h': 'bool          verify(',
    'nnue/network.cpp': 'PikafishNnueStream::open(',
}
PATCHED = [*MARKERS, 'engine.cpp', 'misc.cpp', 'misc.h']


class SourceSnapshots(unittest.TestCase):
    def test_context_independent_patches_and_stale_header_removal(self):
        inside = PACKAGE / '.source-snapshot-tests'
        inside.mkdir(exist_ok=True)
        roots = [inside.resolve(), Path(tempfile.gettempdir()).resolve()]
        snapshots = []
        upstream = PACKAGE / 'third_party/Pikafish/src'
        pristine = {name: (upstream / name).read_bytes() for name in PATCHED}
        try:
            for root in roots:
                parent = Path(tempfile.mkdtemp(prefix='pikafish-snapshot-with spaces-', dir=root))
                parent.resolve().relative_to(root)
                snapshots.append((parent, root))
                output = parent / 'upstream'
                command = [ARGS.cmake,
                           '-DPIKAFISH_INPUT_ROOT=' + str(PACKAGE / 'third_party/Pikafish'),
                           '-DPIKAFISH_OUTPUT_ROOT=' + str(output),
                           '-DPIKAFISH_PATCH_ROOT=' + str(PACKAGE / 'patches'),
                           '-P', str(PACKAGE / 'src/prepare_pikafish_sources.cmake')]
                subprocess.run(command, check=True, cwd=parent)
                for name, marker in MARKERS.items():
                    self.assertIn(marker, (output / 'src' / name).read_text())
                stale = output / 'src' / 'stale-header.h'
                stale.touch()
                subprocess.run(command, check=True, cwd=parent)
                self.assertFalse(stale.exists())
            for name in PATCHED:
                self.assertEqual((snapshots[0][0] / 'upstream/src' / name).read_bytes(),
                                 (snapshots[1][0] / 'upstream/src' / name).read_bytes())
            if ARGS.ruby:
                # Exercise the same nested working directory CocoaPods uses.
                subprocess.run([ARGS.ruby, '-e',
                                'require File.expand_path(ARGV[0]); '
                                'PikafishSources.generate!(File.expand_path(ARGV[1]))',
                                str(PACKAGE / 'src/generate_pikafish_sources.rb'),
                                str(PACKAGE / 'ios')], check=True, cwd=PACKAGE / 'ios')
                for name in PATCHED:
                    self.assertEqual((PACKAGE / 'ios/generated/upstream/src' / name).read_bytes(),
                                     (snapshots[0][0] / 'upstream/src' / name).read_bytes())
            for name, original in pristine.items():
                self.assertEqual(original, (upstream / name).read_bytes())
        finally:
            for parent, root in snapshots:
                parent.resolve().relative_to(root)
                self.assertTrue(parent.name.startswith('pikafish-snapshot-'))
                shutil.rmtree(parent)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *REST])
