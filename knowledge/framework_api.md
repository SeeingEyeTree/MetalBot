# bar_framework API Reference

All modules live under `bar_framework/` and are loaded via:

```lua
local M = VFS.Include("LuaUI/Widgets/bar_framework/<filename>.lua")
```

The module table is returned; assign it to a local and call functions as `M.function_name(...)`.

---

## resource_utils.lua

Economy and resource-state helpers. All functions take a `teamID`.

```lua
local RU = VFS.Include("LuaUI/Widgets/bar_framework/resource_utils.lua")
```

| Function | Returns | Description |
|---|---|---|
| `RU.get(teamID)` | table | Snapshot: `{metal, metal_inc, metal_storage, energy, energy_inc, energy_storage}` |
| `RU.is_metal_stalling(teamID, threshold?)` | bool | True when metal store < `threshold` fraction of capacity (default 0.15) |
| `RU.is_energy_stalling(teamID, threshold?)` | bool | True when energy store < `threshold` fraction (default 0.15) |
| `RU.is_economy_healthy(teamID)` | bool | True when neither metal nor energy is stalling |
| `RU.metal_fill(teamID)` | float 0–1 | Metal storage currently filled (0 = empty, 1 = full) |

**Example: pause construction when metal is low**

```lua
local RU = VFS.Include("LuaUI/Widgets/bar_framework/resource_utils.lua")

function widget:GameFrame(n)
    if n % 30 ~= 0 then return end
    if RU.is_metal_stalling(myTeam) then
        -- pause lowest-priority builder
    end
end
```

---

## unit_query.lua

Unit classification and team-wide queries. All functions take a `teamID` or `defID`.

```lua
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
```

### Classification (by defID)

| Function | Returns | Description |
|---|---|---|
| `UQ.is_commander(defID)` | bool | True if unit is a commander |
| `UQ.is_factory(defID)` | bool | True if unit is a factory (lab) |
| `UQ.is_builder(defID)` | bool | True if unit is a mobile or static builder (not a factory) |
| `UQ.metal_cost(defID)` | int | Metal cost of unit def (0 if unknown) |

### Team-wide queries (by teamID)

| Function | Returns | Description |
|---|---|---|
| `UQ.get_by_role(teamID)` | table | `{combat={...}, builders={...}, factories={...}, commanders={...}}` — unitID lists |
| `UQ.army_metal_value(teamID)` | float | Sum of metal costs of all alive non-commander units |
| `UQ.army_count(teamID)` | int | Count of alive non-commander units |
| `UQ.get_commander(teamID)` | int\|nil | Commander unitID, or nil if dead/not found |

### Spatial queries

| Function | Returns | Description |
|---|---|---|
| `UQ.enemies_near(x, z, radius, myAllyTeam)` | table | Enemy unitIDs within `radius` elmos of (x, z), clamped to map bounds |

**Example: detect incoming raid**

```lua
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")

function widget:GameFrame(n)
    if n % 90 ~= 0 then return end
    local cmdID = UQ.get_commander(myTeam)
    if not cmdID then return end
    local cx, _, cz = Spring.GetUnitPosition(cmdID)
    local threats = UQ.enemies_near(cx, cz, 500, Spring.GetUnitAllyTeam(cmdID))
    if #threats > 0 then
        -- commander under threat
    end
end
```

---

## Notes for agents

- Both modules use **`local M = {}; return M`** — never use `widget:` callbacks inside them.
- Load them at widget startup (top level, not inside a function) to avoid repeated VFS lookups.
- `UQ.get_by_role` iterates all team units on every call — cache the result if called >1×/frame.
- `Spring.GetTeamUnits(teamID)` respects visibility: P0 (fullview=1) can query both teams;
  P1 can only reliably query its own team. All UQ functions inherit this constraint.
- Max 60 upvalues per Lua 5.1 function — avoid capturing large tables as upvalues inside loops.
