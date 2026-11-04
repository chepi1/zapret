"""Pinned upstream batch files are parsed as data, never executed."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('converter', root/'dev/flowseal2zapret2.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
fixtures = root/'dev/fixtures/flowseal-1.10.4'
records = json.loads((fixtures/'manifest.json').read_text('utf-8'))['profiles']


class ConverterTests(unittest.TestCase):
    def reject_source(self, text):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work)/'source.bat.txt'; path.write_text(text, 'utf-8')
            with self.assertRaises(ValueError):
                c.convert(path)

    def test_review_udp_options_must_be_supported_and_consumed(self):
        text = (fixtures/'alt1.bat.txt').read_text('utf-8')
        for option in ('--dpi-desync-fooling=notreal', '--dpi-desync-fooling=badsum',
                       '--ip-id=zero', '--dpi-desync-cutoff=n2',
                       '--dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin"'):
            with self.subTest(option=option):
                self.reject_source(text.replace('--filter-udp=443', '--filter-udp=443 '+option, 1))

    def test_review_repeated_singletons_cannot_hide_or_erase_values(self):
        text = (fixtures/'alt1.bat.txt').read_text('utf-8')
        changes = [('--dpi-desync=fake', '--dpi-desync=invented --dpi-desync=fake'),
                   ('--dpi-desync-fooling=ts', '--dpi-desync-fooling=notreal --dpi-desync-fooling=ts'),
                   ('--dpi-desync-fooling=ts', '--dpi-desync-fooling=badseq --dpi-desync-fooling=ts'),
                   ('--dpi-desync-repeats=6', '--dpi-desync-repeats=100 --dpi-desync-repeats=6')]
        for before, after in changes:
            with self.subTest(option=after):
                self.reject_source(text.replace(before, after, 1))

    def test_review_global_capture_masks_are_both_required_and_unique(self):
        text = (fixtures/'alt1.bat.txt').read_text('utf-8')
        for key in ('tcp', 'udp'):
            match = re.search(r'--wf-'+key+r'=\S+', text).group()
            with self.subTest(mask=key, operation='remove'):
                self.reject_source(text.replace(match, '', 1))
            with self.subTest(mask=key, operation='duplicate'):
                self.reject_source(text.replace(match, match+' '+match, 1))

    def test_review_blob_identity_requires_the_declared_package_path(self):
        for value in (r'C:\different\quic_initial_www_google_com.bin',
                      'quic_initial_www_google_com.bin', '%BIN%../quic_initial_www_google_com.bin'):
            with self.subTest(path=value):
                with self.assertRaises(ValueError):
                    c.blob_of(value)

    def test_review_fakedsplit_cannot_truncate_multiple_positions(self):
        options = c.parse_opts([('--dpi-desync', 'fake,fakedsplit'), ('--dpi-desync-split-pos', '1,midsld')])
        with self.assertRaises(ValueError):
            c.tcp_section(options, 'general')

    def test_review_tls_modifiers_have_a_supported_grammar(self):
        for value in ('notreal', 'rnd,notreal', 'none,rnd', 'sni=', 'sni=x:repeats=99'):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    c.parse_opts([('--dpi-desync-fake-tls', '%BIN%tls_clienthello_www_google_com.bin'),
                                  ('--dpi-desync-fake-tls-mod', value)])
        options = c.parse_opts([('--dpi-desync', 'fake'), ('--dpi-desync-fake-tls-mod', 'none')])
        self.assertTrue(any('tls_mod=none' in line for line in c.tcp_section(options, 'general')))

    def test_review_required_voice_and_game_conditions_cannot_disappear(self):
        text = (fixtures/'alt1.bat.txt').read_text('utf-8')
        self.reject_source(text.replace('--filter-l7=discord,stun ', '', 1))
        position = text.rfind('--dpi-desync-any-protocol=1')
        self.assertGreaterEqual(position, 0)
        for replacement in ('', '--dpi-desync-any-protocol=0'):
            with self.subTest(any_protocol=replacement):
                self.reject_source(text[:position]+text[position:].replace('--dpi-desync-any-protocol=1', replacement, 1))
        self.reject_source(re.sub(r'--dpi-desync-fake-stun="[^"]+"\s*', '', text, count=1))

    def source_tree(self, work):
        source, output = Path(work)/'source', Path(work)/'output'
        source.mkdir(); output.mkdir()
        for row in records:
            shutil.copyfile(fixtures/row['fixture'], source/row['source'])
            shutil.copyfile(root/f"strategies/alt{row['id']}.txt", output/f"alt{row['id']}.txt")
        return source, output

    def cli(self, source, output, *args):
        return subprocess.run([sys.executable, '-I', str(root/'dev/flowseal2zapret2.py'),
                               str(source), str(output), *args], capture_output=True,
                              encoding='utf-8', errors='replace', timeout=25)

    def test_frozen_upstream_hashes_and_current_actions(self):
        self.assertEqual(len(records), 22)
        for row in records:
            with self.subTest(id=row['id']):
                data = (fixtures/row['fixture']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), row['sha256'])
                self.assertEqual(hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest(), row['git_blob'])
                c.warnings.clear()
                generated = c.convert(fixtures/row['fixture'])
                current = c.read_ours(root/f"strategies/alt{row['id']}.txt")
                self.assertEqual(len(c.warnings), 4 if row['id'] == '41' else 0)
                for section in c.ORDER:
                    self.assertEqual(generated.get(section), current.get(section), section)

    def test_altorder_uses_existing_compatible_lua_implementation(self):
        options = c.parse_opts([('--dpi-desync', 'hostfakesplit'),
                                ('--dpi-desync-hostfakesplit-mod', 'host=example.org,altorder=1')])
        self.assertTrue(any('hostfakesplit_alt:' in line for line in c.tcp_section(options, 'general')))

    def test_unrepresentable_options_and_values_are_errors(self):
        cases = [('--invented-option', '1'), ('--dpi-desync-any-protocol', '2'),
                 ('--ip-id', 'random'), ('--filter-l7', 'invented'),
                 ('--dpi-desync-fake-http', '!'),
                 ('--dpi-desync-fakedsplit-pattern', '%BIN%unknown.bin'),
                 ('--dpi-desync-hostfakesplit-mod', 'host=x,altorder=2'),
                 ('--hostlist-exclude-domains', 'extra.example')]
        for item in cases:
            with self.subTest(option=item):
                with self.assertRaises(ValueError):
                    c.parse_opts([item])
        with self.assertRaises(ValueError):
            c.blob_of('%BIN%unrecognized.bin')
        with self.assertRaises(ValueError):
            c.blob_of('0xGG')
        with self.assertRaises(ValueError):
            c.fooling(c.parse_opts([('--dpi-desync-fooling', 'invented')]))
        with self.assertRaises(ValueError):
            c.tcp_section(c.parse_opts([('--dpi-desync', 'invented')]), 'general')
        for key, value in [('--filter-tcp', '2053,2083,2087,2096,8443,9999'),
                           ('--filter-udp', '19294-19344,50000-50100,9999')]:
            with self.subTest(selector=value):
                with self.assertRaises(ValueError):
                    c.classify([(key, value)])

    def test_invalid_bytes_tokens_and_duplicate_profiles_are_errors(self):
        original = (fixtures/'alt1.bat.txt').read_text('utf-8')
        bad_sources = [original.replace('--filter-udp=443', '--filter-udp=443 stray-token', 1),
                       original.replace('--filter-udp=443', '--filter-udp=443 --bad_option=1', 1),
                       original.replace('--wf-tcp=', '--wf-unknown=', 1),
                       original.replace('--wf-tcp=80,443,', '--wf-tcp=81,443,', 1),
                       original.replace('--filter-tcp=2053,2083,2087,2096,8443', '--filter-tcp=2053,2083,2087,2096,8443 --ipset="%LISTS%ipset-all.txt"', 1),
                       original.replace('--hostlist-exclude="%LISTS%list-exclude.txt" ', '', 1),
                       original.replace('--filter-udp=443', '--filter-udp=443 --filter-tcp=80', 1),
                       original.replace('--filter-udp=443', '--filter-udp=443,9999 --filter-l7=quic', 1),
                       original.replace('--filter-udp=443', '--filter-udp=443 --filter-l3=ipv4', 1),
                       original.replace('--new', '--new --filter-udp=443 --dpi-desync=fake --new', 1)]
        with tempfile.TemporaryDirectory() as work:
            path = Path(work)/'profile.bat.txt'
            for text in bad_sources:
                path.write_text(text, 'utf-8')
                with self.subTest(source=text[:20]):
                    with self.assertRaises(ValueError):
                        c.convert(path)
            path.write_bytes(original.encode()+b'\xff')
            with self.assertRaises(UnicodeError):
                c.read_profiles(path)

    def test_check_compares_all22_and_returns_nonzero_on_mismatch(self):
        with tempfile.TemporaryDirectory() as work:
            source, output = self.source_tree(work)
            result = self.cli(source, output, '--check', '--allow-known-differences')
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            (output/'alt1.txt').write_text('[general]\n--lua-desync=invented\n', 'utf-8')
            result = self.cli(source, output, '--check', '--allow-known-differences')
            self.assertNotEqual(result.returncode, 0, 'check silently accepted a changed non-CHECK strategy')

    def test_check_reader_rejects_hidden_or_unknown_sections(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work)/'strategy.txt'
            for text in ('[general]\n--a\n[general]\n--b\n',
                         '[general]\n--a\n[unexpected]\n--b\n', '--a\n[general]\n--b\n'):
                path.write_text(text, 'utf-8')
                with self.subTest(text=text):
                    with self.assertRaises(ValueError):
                        c.read_ours(path)
            path.write_bytes(b'\xef\xbb\xbf# name: test\n[general]\n--a\n')
            self.assertEqual(c.read_ours(path), {'general': ['--a']})

    def test_late_unknown_option_cannot_overwrite_earlier_profiles(self):
        with tempfile.TemporaryDirectory() as work:
            source, output = self.source_tree(work)
            sentinel = b'personal uncommitted strategy\n'
            (output/'alt1.txt').write_bytes(sentinel)
            late = source/'general (FAKE TLS AUTO ALT3).bat'
            late.write_text(late.read_text('utf-8').replace('--dpi-desync=', '--unrecognized=1 --dpi-desync=', 1), 'utf-8')
            result = self.cli(source, output, '--allow-known-differences')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((output/'alt1.txt').read_bytes(), sentinel)

    def test_known_differences_require_explicit_acceptance(self):
        with tempfile.TemporaryDirectory() as work:
            source, output = self.source_tree(work)
            before = {p.name: p.read_bytes() for p in output.iterdir()}
            result = self.cli(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual({p.name: p.read_bytes() for p in output.iterdir()}, before)
            result = self.cli(source, output, '--allow-known-differences')
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            for sid, *_ in c.STRATEGIES:
                self.assertEqual(c.read_ours(output/f'alt{sid}.txt'), c.read_ours(root/f'strategies/alt{sid}.txt'), sid)
            self.assertIn('# compatibility:', (output/'alt41.txt').read_text('utf-8'))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
