# Lua 5.1 check

MetalBot targets Lua 5.1. Before submitting a code change, compile each changed Lua file
without producing an output file:

```sh
luac5.1 -p candidates/LINE_CLICK/unit_controller.lua
```

Some systems install the same compiler as `luac`:

```sh
luac -v
luac -p candidates/LINE_CLICK/unit_controller.lua
```

Confirm that `luac -v` reports Lua 5.1 before relying on the second command.
A successful check prints nothing and exits with status `0`. Syntax errors and
Lua 5.1 compile-time limits, including the maximum of 60 upvalues per function,
produce an error and a non-zero exit status.


## Running bot code without the engine

`tests/spring_stub.lua` is a crude stand-in for the Spring widget API: a hand-made set of Cortex
unit defs, and a world where build orders finish instantly and move orders teleport. It cannot say
whether a bot plays well. It can load real widgets and bar_framework modules under plain Lua 5.1,
drive them through many game-minutes of `GameFrame` calls, and catch Lua errors that would
otherwise only show up as a widget silently failing in a match.

```sh
lua5.1 tests/test_mech_bot.lua        # MECH_BOT module checks + a ~36 game-minute smoke run
lua5.1 tests/test_mech_bot.lua -v     # same, printing every Spring.Echo
```

It takes a few minutes and exits non-zero on any failed check or Lua error. `luac5.1 -p` should
still be run on every changed file: the stub runs whatever Lua 5.1 accepts, but the 60-upvalue and
200-local limits are compile-time errors.


## Running the tests through lupa (no Lua install needed)

`lupa.lua51` runs the same Lua 5.1 the engine uses. From the repo root:

```sh
python -c "import lupa.lua51 as L; L.LuaRuntime().execute(open('tests/test_click_army.lua',encoding='utf-8').read())"
```

Suites: test_click_army, test_slow_front, test_scout_lanes, test_line_crew, test_tile_bot, test_human_logger (all passed 2026-10-08), test_mech_bot, test_slot_*.
