# archive

Retired on 2026-10-12 when LINE_CLICK_v16 became the main bot. Everything here was moved, not deleted, and the
pre-cleanup state is also the git commit "Snapshot before repo cleanup". Nothing here is deployed.

| Folder | What |
|---|---|
| `bots/` | LINE_BOT (economy-only line bot, ancestor of LINE_CLICK), TILE_BOT, SPINE_BOT, MECH_BOT, DRAGON_BOT |
| `candidates/` | LINE_CLICK_v2 ... v15, v16_base, the dated 2026-09-2x candidates, TILE_V2*, LINE_NOSPINE, ECO_V2 |
| `framework/` | `tile_crew`, `slot_crew`, `nano_lift` (only TILE_BOT / TILE_V2 used them) |
| `tests/` | tests for the archived bots/modules (`test_tile_bot`, `test_mech_bot`, `test_slot_*`) |
| `root/` | old repo-root files: stale `macro_controller.lua` / `lab_controller.lua`, `build_order_*` outputs, `line_sweep.py` (tuned LINE_BOT) |
| (older) | `bot.lua`, `new_bot.lua`, `original_bot_tmp` |

**Caveat for archived candidates:** they were written against the old framework defaults (flags off). The defaults are
now v16's, so an archived candidate that is copied back and run will behave differently unless it pins the old values
(see the "pre-v16 ... pinned" blocks in `candidates/LINE_CLICK`). `tests/test_click_army.lua` still smoke-runs a few of
them from here.
