"""Check upstream L3 semantics as data; never execute a batch fixture."""
import importlib.util
from pathlib import Path
import sys
sys.dont_write_bytecode = True

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('converter', root / 'dev/flowseal2zapret2.py')
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)
sections = converter.convert(root / 'dev/fixtures/flowseal-1.10.4/alt5.bat.txt')
for section in ('general', 'google', 'discord_media'):
    assert '# match-l3: ipv4' in sections[section], section
assert not any(line.startswith('# match-l3:') for line in sections['game_tcp'])
for value in ('', 'invalid', 'ipv4,ipv6'):
    try:
        converter.parse_opts([('--filter-l3', value)])
    except ValueError:
        pass
    else:
        raise AssertionError('Unsupported family was silently accepted: ' + value)
assert converter.read_ours(root / 'strategies/alt5.txt')['general'][0] == '# match-l3: ipv4'
print('ok upstream ALT5 L3 conditions preserved; invalid conditions rejected')
