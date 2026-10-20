import os
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publish', ROOT / 'scripts/publish-github.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)

class PublicationTests(unittest.TestCase):
    def test_sensitive_files_and_personal_text_block_before_external_scan(self):
        cases = [('.env', 'fixture'), ('memories.json', '{}'), ('call-history.json', '{}'), ('signing.p12', 'fixture'),
                 ('source.swift', '/Users/' + 'example' + '/private'),
                 ('README.md', 'person' + '@' + 'example.invalid')]
        for name, content in cases:
            with self.subTest(name=name, content=content), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / name).write_text(content)
                with patch.object(publish, 'run') as scan, self.assertRaises(SystemExit):
                    publish.scan(root, Path('/test-scanner'))
                scan.assert_not_called()

    def test_valid_source_runs_scanner_with_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'README.md').write_text('Synthetic source.')
            with patch.object(publish, 'run') as scan:
                publish.scan(root, Path('/test-scanner'))
            self.assertIn('--redact', scan.call_args.args)

    def test_git_environment_cannot_override_public_identity(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            'GIT_AUTHOR_NAME': 'Private Fixture', 'GIT_COMMITTER_NAME': 'Private Fixture',
            'GIT_AUTHOR_EMAIL': 'private' + '@' + 'example.invalid',
            'GIT_COMMITTER_EMAIL': 'private' + '@' + 'example.invalid'
        }):
            root = Path(directory)
            publish.run('git', 'init', '-q', cwd=root)
            for key, value in [('user.name', 'Public Fixture'), ('user.email', '123+fixture' + '@' + 'users.noreply.github.com'), ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
                publish.run('git', 'config', key, value, cwd=root)
            publish.run('git', 'commit', '-q', '--allow-empty', '-m', 'Synthetic test', cwd=root)
            metadata = publish.run('git', 'log', '-1', '--format=%an%n%ae%n%cn%n%ce%n%G?', cwd=root, capture=True).splitlines()
            self.assertEqual(metadata, ['Public Fixture', '123+fixture' + '@' + 'users.noreply.github.com', 'Public Fixture', '123+fixture' + '@' + 'users.noreply.github.com', 'N'])

    def test_icon_metadata_removed_without_changing_image_data(self):
        def chunks(data):
            offset = 8; result = []
            while offset < len(data):
                size = struct.unpack('>I', data[offset:offset + 4])[0]
                result.append((data[offset+4:offset+8], data[offset:offset+size+12]))
                offset += size + 12
            return result
        original = (ROOT / 'Resources/AppIcon.png').read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'icon.png'; path.write_bytes(original)
            publish.strip_image_metadata(path)
            cleaned = chunks(path.read_bytes())
            self.assertEqual([c for c in cleaned if c[0] == b'IDAT'], [c for c in chunks(original) if c[0] == b'IDAT'])
            self.assertTrue(all(c[0] in [b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'gAMA', b'cHRM', b'sRGB'] for c in cleaned))

if __name__ == '__main__': unittest.main()
