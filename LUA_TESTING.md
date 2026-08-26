# Lua 5.1 check

MetalBot targets Lua 5.1. Before submitting a code change, compile the bot
without producing an output file:

```sh
luac5.1 -p bot.lua
```

Some systems install the same compiler as `luac`:

```sh
luac -v
luac -p bot.lua
```

Confirm that `luac -v` reports Lua 5.1 before relying on the second command.
A successful check prints nothing and exits with status `0`. Syntax errors and
Lua 5.1 compile-time limits, including the maximum of 60 upvalues per function,
produce an error and a non-zero exit status.

