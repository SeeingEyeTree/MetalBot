#!/usr/bin/env python3
"""
blueprint_gen.py  --  Convert build_order_result.json into a BAR blueprint.

Layout strategy
---------------
All buildings (nanos, winds, labs, mexes) are placed in strict build-order
sequence using a 2-D occupancy grid and spiral nearest-first search.  Each
building claims the nearest free cell to the anchor target, so early builds
pack near the centre and later builds grow outward naturally.  No special
groupings — every building type uses the same spiral.

Usage
-----
    python blueprint_gen.py                       # reads build_order_result.json
    python blueprint_gen.py --input my_run.json
    python blueprint_gen.py --target 0 3          # spiral centre (BAR units)
"""

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import Circle

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

NANO_RANGE = 384   # nano build radius in elmos (conservative; in-game ~500)
GRID       = 16    # elmos per BAR "unit"

# action -> (unitDefName, width_units, height_units)
ACTION_DEFS: dict[str, tuple[str, int, int]] = {
    'mex':     ('cormex',    4, 4),
    'wind':    ('corwin',    3, 3),
    'e_store': ('corestor',  4, 4),
    'bot_lab': ('corlab',    6, 6),
    'veh_lab': ('corvp',     6, 6),
    'nano':    ('cornanotc', 3, 3),
}

SKIP_ACTIONS = {'con_bot', 'cv', 'incisor'}

# Reclaim actions are not buildings, but they ARE ordered steps the bot must
# execute: reclaiming the lab refunds its metal, which the rest of the build
# order depends on.  Each maps to the action whose building it removes.
RECLAIM_OF = {'reclaim_lab': 'bot_lab', 'reclaim_vp': 'veh_lab'}

COLORS = {
    'cormex':    '#4CAF50',
    'corwin':    '#FFC107',
    'corestor':  '#00BCD4',
    'corlab':    '#9C27B0',
    'corvp':     '#E91E63',
    'cornanotc': '#2196F3',
}


# ---------------------------------------------------------------------------
# Building data model
# ---------------------------------------------------------------------------

@dataclass
class Building:
    action:          str
    unit_def:        str
    w:               int     # width in BAR units
    h:               int     # height in BAR units
    seq:             int     # 1-based index in original build order
    nano_when_built: int     # nanos that existed when this was queued
    x:               float = 0.0   # world x in elmos (set during layout)
    z:               float = 0.0   # world z in elmos

    @property
    def cx(self) -> float:
        return self.x + self.w * GRID / 2

    @property
    def cz(self) -> float:
        return self.z + self.h * GRID / 2


# ---------------------------------------------------------------------------
# Parse build order
# ---------------------------------------------------------------------------

def parse_reclaims(history: list[dict]) -> list[dict]:
    """Ordered reclaim steps: {seq, of=action whose building is removed}."""
    return [
        {'seq': seq, 'of': RECLAIM_OF[entry['action']]}
        for seq, entry in enumerate(history, 1)
        if entry['action'] in RECLAIM_OF
    ]


def parse_buildings(history: list[dict]) -> list[Building]:
    buildings: list[Building] = []
    nano_count = 0
    for seq, entry in enumerate(history, 1):
        name = entry['action']
        if name in SKIP_ACTIONS or name in RECLAIM_OF or name not in ACTION_DEFS:
            continue
        unit_def, w, h = ACTION_DEFS[name]
        buildings.append(Building(
            action=name, unit_def=unit_def, w=w, h=h,
            seq=seq, nano_when_built=nano_count,
        ))
        if name == 'nano':
            nano_count += 1
    return buildings


# ---------------------------------------------------------------------------
# Occupancy grid + spiral nearest-first placement
# ---------------------------------------------------------------------------

class OccupancyGrid:
    """
    Tracks occupied BAR-unit cells.  Coordinates are in BAR units (1 unit = 16 elmos).
    Buildings are placed with zero gap (adjacent cells can touch, matching how
    the existing prod_grid_vp.lua blueprints are laid out).
    """

    def __init__(self) -> None:
        self._cells: set[tuple[int, int]] = set()

    def can_place(self, ox: int, oz: int, w: int, h: int) -> bool:
        """True if the w×h footprint starting at (ox, oz) is entirely free."""
        for dx in range(w):
            for dz in range(h):
                if (ox + dx, oz + dz) in self._cells:
                    return False
        return True

    def mark(self, ox: int, oz: int, w: int, h: int) -> None:
        for dx in range(w):
            for dz in range(h):
                self._cells.add((ox + dx, oz + dz))

    def unmark(self, ox: int, oz: int, w: int, h: int) -> None:
        for dx in range(w):
            for dz in range(h):
                self._cells.discard((ox + dx, oz + dz))

    def find_nearest(
        self,
        tx: int, tz: int,
        w: int, h: int,
        max_r: int = 60,
    ) -> tuple[int, int] | None:
        """
        Return the (ox, oz) origin cell nearest to target (tx, tz) where a
        w×h building fits.  Proximity is measured centre-to-centre.

        Uses column-pruning: once a best distance is known, any dx whose
        x-component alone exceeds it skips all dz values for that column.
        """
        best: tuple[float, int, int] | None = None
        half_w = (w - 1) / 2
        half_h = (h - 1) / 2
        for dx in range(-max_r, max_r + 1):
            cx = (dx + half_w) ** 2
            if best is not None and cx > best[0]:
                continue  # entire column can't beat best
            for dz in range(-max_r, max_r + 1):
                ox, oz = tx + dx, tz + dz
                if not self.can_place(ox, oz, w, h):
                    continue
                dist = cx + (dz + half_h) ** 2
                if best is None or dist < best[0]:
                    best = (dist, ox, oz)
        if best is None:
            return None
        return best[1], best[2]

    def place(self, b: Building, ox: int, oz: int) -> None:
        b.x = ox * GRID
        b.z = oz * GRID
        self.mark(ox, oz, b.w, b.h)

    def find_and_place(self, b: Building, tx: int, tz: int, max_r: int = 60) -> bool:
        """Find nearest free spot and place b there. Returns True on success."""
        result = self.find_nearest(tx, tz, b.w, b.h, max_r=max_r)
        if result is None:
            return False
        self.place(b, *result)
        return True


# ---------------------------------------------------------------------------
# Layout engine
# ---------------------------------------------------------------------------

def layout(
    buildings: list[Building],
    target:    tuple[int, int] = (0, 0),
    max_r:     int = 100,
    reclaims:  list[dict] | None = None,
) -> list[Building]:
    """
    Place every building in build order using spiral nearest-first search.

    Each building is placed at the nearest unoccupied cell to `target`
    (in BAR units).  Buildings are processed strictly in seq order so the
    result mirrors the actual build sequence: early buildings sit close to
    the anchor, later ones grow outward naturally.  No special grouping —
    nanos, winds, mexes, labs all compete for the same grid.
    """
    grid = OccupancyGrid()
    tx, tz = target

    # Merge placements and reclaims into one seq-ordered pass, so a reclaimed
    # building's cells are free for everything built after it (mirrors the
    # negative `area` the sim applies for a reclaim).
    events: list[tuple[int, str, object]] = [(b.seq, 'build', b) for b in buildings]
    events += [(r['seq'], 'reclaim', r) for r in (reclaims or [])]
    events.sort(key=lambda e: e[0])

    for seq, kind, item in events:
        if kind == 'build':
            if not grid.find_and_place(item, tx, tz, max_r=max_r):
                print(f'  WARNING: could not place {item.action} seq={seq}')
            continue
        # Reclaim: the most recently placed building of the removed type.
        victim = max(
            (b for b in buildings if b.action == item['of'] and b.seq < seq),
            key=lambda b: b.seq, default=None,
        )
        if victim is None:
            print(f"  WARNING: reclaim seq={seq} has no preceding {item['of']}")
            continue
        item['building'] = victim
        grid.unmark(int(victim.x // GRID), int(victim.z // GRID), victim.w, victim.h)
    return buildings


# ---------------------------------------------------------------------------
# Coverage check
# ---------------------------------------------------------------------------

def check_coverage(buildings: list[Building]) -> list[str]:
    """Verify every non-mex eco building is within NANO_RANGE of at least one nano."""
    nanos    = [b for b in buildings if b.action == 'nano']
    warnings: list[str] = []
    for b in buildings:
        if b.action in ('mex', 'nano'):
            continue
        in_range = any(math.hypot(b.cx - n.cx, b.cz - n.cz) <= NANO_RANGE for n in nanos)
        if not in_range:
            nearest = min((math.hypot(b.cx - n.cx, b.cz - n.cz) for n in nanos), default=float('inf'))
            warnings.append(
                f'  {b.action} seq={b.seq} at ({b.cx:.0f}, {b.cz:.0f})'
                f' — nearest nano {nearest:.0f} elmos away (range={NANO_RANGE})'
            )
    return warnings


# ---------------------------------------------------------------------------
# Overlap + coverage stats
# ---------------------------------------------------------------------------

def nano_stats(buildings: list[Building]) -> None:
    nanos = [b for b in buildings if b.action == 'nano']
    eco   = [b for b in buildings if b.action not in ('mex', 'nano')]
    if not nanos:
        return
    overlaps = [
        sum(1 for m in nanos if m is not n and math.hypot(n.cx - m.cx, n.cz - m.cz) < 2 * NANO_RANGE)
        for n in nanos
    ]
    coverage = [
        sum(1 for b in eco if math.hypot(n.cx - b.cx, n.cz - b.cz) <= NANO_RANGE)
        for n in nanos
    ]
    eco_n = max(len(eco), 1)
    print(f'Nano stats:  each nano overlaps {sum(overlaps)/len(nanos):.1f} others on avg'
          f' (max {max(overlaps)})  |  covers {sum(coverage)/len(nanos)/eco_n*100:.0f}% of eco on avg')

    # Cluster diameter
    if len(nanos) > 1:
        diam = max(
            math.hypot(a.cx - b.cx, a.cz - b.cz)
            for a in nanos for b in nanos if a is not b
        )
        print(f'Nano cluster diameter: {diam:.0f} elmos'
              f'  (effective BP zone radius ~{NANO_RANGE - diam/2:.0f} elmos from centre)')


# ---------------------------------------------------------------------------
# Lua output
# ---------------------------------------------------------------------------

def write_lua(buildings: list[Building], path: str, header: str = '',
              reclaims: list[dict] | None = None) -> None:
    lines = [
        '-- Auto-generated build-order blueprint',
        f'-- {header}',
        '--',
        '-- Positions in elmos relative to blueprint anchor.',
        '-- Load with:',
        "--   local bp    = VFS.Include('LuaUI/Widgets/blueprints/general/build_order_blueprint.lua')",
        "--   local state = BP_PLACER.NewDistributed(bp, anchorX, anchorZ, 0)",
        '--',
        '-- x/z are BUILDING CENTRES in elmos, relative to the blueprint anchor.',
        '-- Entries with a="reclaim" are not builds: reclaim the building already',
        '-- standing at that spot (its metal refund is part of the build order).',
        '-- NOTE: mex positions are ORDER placeholders; real positions depend on map mex spots.',
        '',
        'local M = {}',
        'M.layout = {',
    ]
    counts: dict[str, int] = {}
    entries: list[tuple[int, str]] = []
    for b in sorted(buildings, key=lambda b: b.seq):
        counts[b.unit_def] = counts.get(b.unit_def, 0) + 1
        xi, zi = int(round(b.cx)), int(round(b.cz))
        label = f'{b.action} #{counts[b.unit_def]}'
        entries.append((b.seq,
            f'    {{n="{b.unit_def}", x={xi:7d}, z={zi:7d}, f=0}},  -- {label}'))
    for r in (reclaims or []):
        victim = r.get('building')
        if victim is None:
            continue
        xi, zi = int(round(victim.cx)), int(round(victim.cz))
        entries.append((r['seq'],
            f'    {{n="{victim.unit_def}", a="reclaim",'
            f' x={xi:7d}, z={zi:7d}, f=0}},  -- reclaim {victim.action}'))
    for _, line in sorted(entries, key=lambda e: e[0]):
        lines.append(line)
    lines += ['}', 'return M', '']
    Path(path).write_text('\n'.join(lines), encoding='utf-8')
    print(f'Saved blueprint  -> {path}')


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------

def visualize(buildings: list[Building], path: str, title: str = '') -> None:
    fig, ax = plt.subplots(figsize=(22, 14))

    nanos = [b for b in buildings if b.action == 'nano']

    # Nano coverage rings (drawn behind buildings, lightest first)
    for i, n in enumerate(sorted(nanos, key=lambda nb: nb.seq)):
        ax.add_patch(Circle(
            (n.cx, n.cz), NANO_RANGE,
            fill=True,  facecolor='#2196F3', alpha=0.06,
            edgecolor='#2196F3', linewidth=0.7, linestyle='--',
        ))

    # Building footprints
    counts: dict[str, int] = {}
    for b in sorted(buildings, key=lambda b: b.seq):
        counts[b.unit_def] = counts.get(b.unit_def, 0) + 1
        color = COLORS.get(b.unit_def, '#888888')
        ax.add_patch(mpatches.FancyBboxPatch(
            (b.x, b.z), b.w * GRID, b.h * GRID,
            boxstyle='square,pad=0',
            facecolor=color, edgecolor='black',
            linewidth=0.4, alpha=0.88,
        ))
        cnt = counts[b.unit_def]
        lbl = f'N{cnt}' if b.action == 'nano' else f'{b.action[0].upper()}{cnt}'
        fs = 4.0 if b.w <= 3 else 5.5
        ax.text(b.cx, b.cz, lbl,
                ha='center', va='center', fontsize=fs,
                color='white', fontweight='bold', clip_on=True)

    # Commander origin
    ax.plot(0, 0, 'r+', markersize=14, markeredgewidth=2.5, zorder=10)
    ax.text(4, -18, 'COM', fontsize=8, color='red', fontweight='bold')

    ax.set_aspect('equal')
    ax.autoscale_view()
    ax.margins(0.04)
    ax.set_xlabel('x (elmos)', fontsize=10)
    ax.set_ylabel('z (elmos)', fontsize=10)
    ax.set_title(title or 'Build Order Blueprint', fontsize=12, fontweight='bold')
    ax.grid(True, alpha=0.18)

    legend = [mpatches.Patch(color=c, label=n) for n, c in COLORS.items()]
    legend.append(mpatches.Patch(
        facecolor='#2196F3', alpha=0.20, edgecolor='#2196F3',
        linestyle='--', label=f'nano range ({NANO_RANGE} elmos)',
    ))
    ax.legend(handles=legend, loc='upper right', fontsize=8, framealpha=0.85)

    plt.tight_layout()
    plt.savefig(path, dpi=150, bbox_inches='tight')
    print(f'Saved visualization -> {path}')
    plt.show()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        description='Convert build_order_result.json to a BAR blueprint',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument('--input',  default='build_order_result.json')
    p.add_argument('--output', default='build_order_blueprint')
    p.add_argument('--target', type=int, nargs=2, default=[0, 0],
                   metavar=('X', 'Z'),
                   help='BAR-unit coords that all buildings spiral toward (default: 0 0 = anchor)')
    args = p.parse_args()

    # Load
    in_path = Path(args.input)
    if not in_path.exists():
        print(f'ERROR: {in_path} not found. Run build_order_sim.py first.')
        return
    with in_path.open() as f:
        data = json.load(f)

    mode       = data.get('optimization_mode', '?')
    metal_rate = data.get('final_metal_rate',  '?')
    incisors   = data.get('final_incisor_count', 0)
    print(f'Loaded {in_path}  ({len(data["actions"])} actions, mode={mode})')

    # Parse
    buildings = parse_buildings(data['actions'])
    reclaims  = parse_reclaims(data['actions'])
    if reclaims:
        print(f'Reclaim steps: {len(reclaims)}')
    by_type: dict[str, int] = {}
    for b in buildings:
        by_type[b.action] = by_type.get(b.action, 0) + 1
    print('Buildings:', '  '.join(f'{a}×{c}' for a, c in sorted(by_type.items())))

    # Layout
    buildings = layout(buildings, target=tuple(args.target), reclaims=reclaims)

    # Stats
    nano_stats(buildings)

    eco_all = [b for b in buildings if b.action != 'mex']
    if eco_all:
        x_lo = min(b.x for b in eco_all)
        x_hi = max(b.x + b.w * GRID for b in eco_all)
        z_lo = min(b.z for b in eco_all)
        z_hi = max(b.z + b.h * GRID for b in eco_all)
        print(f'Eco cluster: {x_hi-x_lo:.0f} × {z_hi-z_lo:.0f} elmos')

    # Coverage
    warnings = check_coverage(buildings)
    if warnings:
        print(f'Coverage warnings ({len(warnings)}):')
        for w in warnings:
            print(w)
    else:
        nanos = [b for b in buildings if b.action == 'nano']
        if nanos:
            print('Coverage: all eco buildings within nano range (OK)')

    # Output
    if mode == 'max_rate':
        desc = f'max_rate — {metal_rate} m/s'
    elif mode in ('max_units', 'balanced'):
        desc = f'{mode} — {incisors} Incisors, {metal_rate} m/s'
    else:
        desc = f'{mode} — {metal_rate} m/s'

    write_lua(buildings, f'{args.output}.lua', desc, reclaims=reclaims)
    visualize(buildings, f'{args.output}.png', f'Build Order Blueprint  |  {desc}')


if __name__ == '__main__':
    main()
