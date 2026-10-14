"""Run one Lua test file through lupa's Lua 5.1, from the repo root: python tests/run_lua.py tests/test_kite.lua"""
import os
import sys

import lupa.lua51 as L

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
path = sys.argv[1]
lua = L.LuaRuntime()
# os.exit(1) inside a test must fail this process too
lua.execute("os.exit = function(code) error('TEST_EXIT_' .. tostring(code), 0) end")
try:
    lua.execute(open(path, encoding="utf-8").read())
except Exception as e:  # noqa: BLE001
    msg = str(e)
    if msg.startswith("TEST_EXIT_0"):      # a test that ended with os.exit(0) passed
        sys.exit(0)
    print(e)
    sys.exit(1)
