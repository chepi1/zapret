"""Optional developer-only Lua runtime; not shipped in user packages."""
import argparse
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--pkg', required=True)
parser.add_argument('--runtime', required=True)
parser.add_argument('--test', default='watchtest.lua', choices=('watchtest.lua', 'storetest.lua'))
args = parser.parse_args()
sys.path.insert(0, args.runtime)
from lupa import LuaRuntime

pkg = Path(args.pkg)
lua = LuaRuntime()
lua.execute('os.exit=function(code) TEST_EXIT=code end')
if (pkg / 'lua/ring-store.lua').exists():
    lua.execute((pkg / 'lua/ring-store.lua').read_text(encoding='utf-8-sig'))
lua.execute((pkg / 'lua/autoring.lua').read_text(encoding='utf-8-sig'))
lua.execute((pkg / 'dev/tests' / args.test).read_text(encoding='utf-8-sig'))
sys.exit(lua.globals().TEST_EXIT if lua.globals().TEST_EXIT is not None else 1)
