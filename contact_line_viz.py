"""
contact_line_viz.py  --  Animated visualization of the node-based contact line.

Simulates 32 independent nodes using lateral+adv parameterization (mirrors the
Lua implementation). Key scenarios:
  Frame  0–19  Default NE target; nodes form a defensive arc around the base.
  Frame 20–39  Enemy found to the NORTH; advDir rotates ~45°. All nodes reorient
               instantly — no clumping or misalignment.
  Frame 40–59  Enemy units engage 4-6 central nodes so the polyline bows back.
               Non-engaged wing nodes anti-lag forward to maintain a convex shape.

Run with:  python contact_line_viz.py
Requires:  pip install matplotlib numpy
"""

import numpy as np
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.animation as animation
from matplotlib.patches import FancyArrowPatch, Polygon
from matplotlib.collections import LineCollection

# ── Constants (mirrors Lua tunables) ──────────────────────────────────────────

MAP_X, MAP_Z        = 8192, 8192
MAP_MARGIN          = 200
NODE_COUNT          = 32
NODE_ENEMY_RADIUS   = 600
NODE_ADVANCE_STEP   = 120
NODE_MAX_BULGE      = 500
NODE_MAX_LAG        = 600
ARC_RADIUS          = 1500
NODE_MIN_SPACING    = 100
EDGE_STUCK_MARGIN   = 150
THRUST_NODE_HALF    = 5
THRUST_FRAC         = 0.55
LOCAL_ENEMY_RADIUS  = 500
ADVANCE_MIN_UNITS   = 5
MIN_ENEMY_SAMPLE    = 3
TARGET_EMA_ALPHA    = 0.25

# ── Unit roster ───────────────────────────────────────────────────────────────

UNIT_DEFS = [
    ("corsumo",  600),
    ("cormort",  300),
    ("cormort",  300),
    ("cormort",  300),
    ("corraid",  120),
    ("corraid",  120),
    ("corraid",  120),
    ("corraid",  120),
    ("corgator",  90),
    ("corgator",  90),
    ("corgator",  90),
    ("corgator",  90),
    ("corgator",  90),
]

# ── Simulation state ───────────────────────────────────────────────────────────

BASE_X, BASE_Z           = 800,  800
DEFAULT_TX, DEFAULT_TZ   = MAP_X * 0.8, MAP_Z * 0.8   # default NE
NORTH_TX, NORTH_TZ       = MAP_X * 0.5, MAP_Z * 0.95  # enemy revealed to N at frame 20
ENEMY_BASE_X = NORTH_TX
ENEMY_BASE_Z = NORTH_TZ

rng = np.random.default_rng(42)


def normalize(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-6 else v


class SimState:
    def __init__(self):
        self.targetX = None
        self.targetZ = None
        self.adv     = np.array([0.0, 0.0])
        self.perp    = np.array([0.0, 0.0])
        self.diag    = 0.0
        self.half_w  = 0.0
        self.enemies = []       # [(x, z), ...]
        self.thrust_idx = NODE_COUNT // 2

        self.unit_positions = {}
        for i in range(len(UNIT_DEFS)):
            self.unit_positions[i] = np.array([
                BASE_X + rng.uniform(-300, 300),
                BASE_Z + rng.uniform(-300, 300),
            ])

        self._recompute_dir(DEFAULT_TX, DEFAULT_TZ)
        self.half_w = NODE_MIN_SPACING * (NODE_COUNT - 1) / 2
        self.nodes = self._init_nodes()

    def _recompute_dir(self, tx, tz):
        base = np.array([BASE_X, BASE_Z])
        tgt  = np.array([tx, tz])
        diff = tgt - base
        dist = np.linalg.norm(diff)
        self.adv  = normalize(diff)
        self.perp = np.array([-self.adv[1], self.adv[0]])
        self.diag = dist

    def _min_adv(self, lateral):
        """Minimum adv to bring world pos within map bounds."""
        min_adv = 0.0
        px, pz  = self.perp * lateral
        if self.adv[0] > 1e-6:
            req = (MAP_MARGIN - BASE_X - px) / self.adv[0]
            if req > min_adv: min_adv = req
        elif self.adv[0] < -1e-6:
            req = (MAP_X - MAP_MARGIN - BASE_X - px) / self.adv[0]
            if req > min_adv: min_adv = req
        if self.adv[1] > 1e-6:
            req = (MAP_MARGIN - BASE_Z - pz) / self.adv[1]
            if req > min_adv: min_adv = req
        elif self.adv[1] < -1e-6:
            req = (MAP_Z - MAP_MARGIN - BASE_Z - pz) / self.adv[1]
            if req > min_adv: min_adv = req
        return max(0.0, min_adv)

    def _max_adv(self, lateral):
        """Maximum adv before world pos exits map bounds."""
        max_adv = self.diag * 2
        px, pz  = self.perp * lateral
        if self.adv[0] > 1e-6:
            max_adv = min(max_adv, (MAP_X - MAP_MARGIN - BASE_X - px) / self.adv[0])
        elif self.adv[0] < -1e-6:
            max_adv = min(max_adv, (MAP_MARGIN - BASE_X - px) / self.adv[0])
        if self.adv[1] > 1e-6:
            max_adv = min(max_adv, (MAP_Z - MAP_MARGIN - BASE_Z - pz) / self.adv[1])
        elif self.adv[1] < -1e-6:
            max_adv = min(max_adv, (MAP_MARGIN - BASE_Z - pz) / self.adv[1])
        return max(0.0, max_adv)

    def _node_world(self, node):
        return (BASE_X + self.adv[0] * node['adv'] + self.perp[0] * node['lateral'],
                BASE_Z + self.adv[1] * node['adv'] + self.perp[1] * node['lateral'])

    def _init_nodes(self):
        ns = []
        for i in range(NODE_COUNT):
            t        = (i / (NODE_COUNT - 1)) * 2 - 1   # -1 to 1
            lateral  = t * self.half_w
            min_adv  = self._min_adv(lateral)
            arc_bump = ARC_RADIUS * max(0.0, np.cos(np.pi * 0.5 * t))
            adv      = min(min_adv + arc_bump, self._max_adv(lateral))
            ns.append({'lateral': lateral, 'adv': adv, 'engaged': False, 'atEdge': False})
        return ns

    def _find_thrust(self):
        best_score, best_idx = -1, NODE_COUNT // 2
        for i in range(NODE_COUNT):
            lo = max(0, i - THRUST_NODE_HALF)
            hi = min(NODE_COUNT, i + THRUST_NODE_HALF + 1)
            score = sum(1 for j in range(lo, hi) if self.nodes[j]['engaged'])
            cd = abs(i - NODE_COUNT / 2)
            if score > best_score or (score == best_score and cd < abs(best_idx - NODE_COUNT / 2)):
                best_score = score
                best_idx   = i
        return best_idx

    def _assign_positions(self):
        units  = sorted(enumerate(UNIT_DEFS), key=lambda x: -x[1][1])
        total  = sum(c for _, (_, c) in units)
        cutoff = total * THRUST_FRAC

        tlo = max(0, self.thrust_idx - THRUST_NODE_HALF)
        thi = min(NODE_COUNT - 1, self.thrust_idx + THRUST_NODE_HALF)
        tspan = thi - tlo + 1
        all_wing   = list(range(0, tlo)) + list(range(thi + 1, NODE_COUNT))
        wing_nodes = [i for i in all_wing if not self.nodes[i]['atEdge']] or all_wing

        accum, thrust_list, wing_list = 0, [], []
        for uid, (_, cost) in units:
            accum += cost
            if accum <= cutoff or not thrust_list:
                thrust_list.append(uid)
            else:
                wing_list.append(uid)

        positions = {}
        for i, uid in enumerate(thrust_list):
            positions[uid] = tlo + i % tspan
        if wing_nodes:
            for i, uid in enumerate(wing_list):
                positions[uid] = wing_nodes[i % len(wing_nodes)]
        else:
            for i, uid in enumerate(wing_list):
                positions[uid] = tlo + i % tspan

        return positions, tlo, thi

    def _update_enemy_target(self, enemy_units):
        """Median centroid with EMA — mirrors Lua UpdateEnemyTarget."""
        if len(enemy_units) < MIN_ENEMY_SAMPLE:
            return
        exs = sorted(e[0] for e in enemy_units)
        ezs = sorted(e[1] for e in enemy_units)
        mid  = len(exs) // 2
        medX = exs[mid]
        medZ = ezs[mid]
        if self.targetX is not None:
            self.targetX = self.targetX * (1 - TARGET_EMA_ALPHA) + medX * TARGET_EMA_ALPHA
            self.targetZ = self.targetZ * (1 - TARGET_EMA_ALPHA) + medZ * TARGET_EMA_ALPHA
        else:
            self.targetX = medX
            self.targetZ = medZ

    def step(self, frame):
        # ── Enemy reveal at frame 20: direction rotates to NORTH ──────────────
        if frame == 20:
            self._update_enemy_target([(NORTH_TX, NORTH_TZ)] * MIN_ENEMY_SAMPLE)

        # ── Spawn enemy units near centre nodes at frame 40, clear at frame 55 ─
        if frame == 40:
            mid_node = self.nodes[NODE_COUNT // 2]
            wx, wz   = self._node_world(mid_node)
            self.enemies = [(wx + rng.uniform(-500, 500),
                             wz + rng.uniform(-300, 300)) for _ in range(5)]
        if frame == 55:
            self.enemies = []

        # Recalculate direction every step if target is known
        if self.targetX is not None:
            self._recompute_dir(self.targetX, self.targetZ)

        can_advance = (self.targetX is not None) and (len(UNIT_DEFS) >= ADVANCE_MIN_UNITS)

        # Update nodes
        for node in self.nodes:
            wx, wz = self._node_world(node)
            engaged = any(
                np.hypot(ex - wx, ez - wz) < NODE_ENEMY_RADIUS
                for ex, ez in self.enemies
            )
            node['engaged'] = engaged
            if can_advance and not engaged:
                node['adv'] += NODE_ADVANCE_STEP
            max_adv = self._max_adv(node['lateral'])
            node['adv']    = min(node['adv'], max_adv)
            node['adv']    = max(0.0, node['adv'])
            node['atEdge'] = (max_adv - node['adv']) <= EDGE_STUCK_MARGIN

        # Smoothing — 2 passes
        for _ in range(2):
            # Anti-bulge
            for i in range(1, NODE_COUNT - 1):
                avg = (self.nodes[i - 1]['adv'] + self.nodes[i + 1]['adv']) * 0.5
                if self.nodes[i]['adv'] > avg + NODE_MAX_BULGE:
                    self.nodes[i]['adv'] = avg + NODE_MAX_BULGE
            # Anti-lag (non-engaged only)
            for i in range(1, NODE_COUNT - 1):
                avg = (self.nodes[i - 1]['adv'] + self.nodes[i + 1]['adv']) * 0.5
                if not self.nodes[i]['engaged'] and self.nodes[i]['adv'] < avg - NODE_MAX_LAG:
                    self.nodes[i]['adv'] += (avg - NODE_MAX_LAG - self.nodes[i]['adv']) * 0.4

        self.thrust_idx = self._find_thrust()
        positions, tlo, thi = self._assign_positions()

        # Drift unit positions toward assigned node
        for uid, node_idx in positions.items():
            wx, wz = self._node_world(self.nodes[node_idx])
            tgt = np.array([wx, wz])
            cur = self.unit_positions[uid]
            self.unit_positions[uid] = cur + (tgt - cur) * 0.2

        return positions, tlo, thi


sim = SimState()

# ── Matplotlib setup ───────────────────────────────────────────────────────────

fig, ax = plt.subplots(figsize=(9, 9))
ax.set_xlim(0, MAP_X)
ax.set_ylim(0, MAP_Z)
ax.set_aspect('equal')
ax.set_facecolor('#1a1a2e')
fig.patch.set_facecolor('#0f0f23')
ax.tick_params(colors='#aaaacc')
for spine in ax.spines.values():
    spine.set_edgecolor('#333366')
ax.set_xlabel("Map X  (world units)", color='#aaaacc')
ax.set_ylabel("Map Z  (world units)", color='#aaaacc')
ax.set_title("Node-Based Contact Line — lateral+adv parameterization", color='#ddddff', fontsize=12)

# Map margin
ax.add_patch(mpatches.Rectangle(
    (MAP_MARGIN, MAP_MARGIN), MAP_X - 2*MAP_MARGIN, MAP_Z - 2*MAP_MARGIN,
    fill=False, edgecolor='#444466', linestyle='--', linewidth=0.8, zorder=1))

# Static: base marker
ax.plot(BASE_X, BASE_Z, '*', color='#44ff88', markersize=18, zorder=10)
ax.annotate("BASE", (BASE_X, BASE_Z), textcoords="offset points",
            xytext=(12, 6), color='#44ff88', fontsize=9)

# Dynamic artists
enemy_marker, = ax.plot([], [], 'x', color='#ff4444', markersize=16,
                         markeredgewidth=3, zorder=10)
enemy_label   = ax.annotate("", (0, 0), textcoords="offset points",
                             xytext=(10, 6), color='#ff4444', fontsize=9)

# Advance direction arrow (updates when direction rotates)
dir_arrow_patch = FancyArrowPatch((0,0),(1,1), arrowstyle='->', color='#44aaff',
                                   linewidth=1.5, mutation_scale=14, zorder=4, alpha=0.7)
ax.add_patch(dir_arrow_patch)

# Node polyline
node_line, = ax.plot([], [], '-', color='#ffaa00', linewidth=2, zorder=5, alpha=0.9)

# Node dots
node_scatter = ax.scatter([], [], s=40, zorder=7, edgecolors='white', linewidths=0.5)

# Thrust window polygon
thrust_poly = Polygon([[0,0]], closed=True, alpha=0.12, color='#ff8800',
                       zorder=3, linewidth=0)
ax.add_patch(thrust_poly)

# Unit scatters
thrust_scatter = ax.scatter([], [], c='#ff4444', s=[], zorder=8,
                             edgecolors='white', linewidths=0.5)
wing_scatter   = ax.scatter([], [], c='#4488ff', s=[], zorder=8,
                             edgecolors='white', linewidths=0.5)

# Enemy units
enemy_scatter = ax.scatter([], [], c='#ff2222', marker='D', s=120, zorder=9,
                            edgecolors='#ffaaaa', linewidths=1)

arrow_artists = []

hud = ax.text(0.02, 0.97, "", transform=ax.transAxes,
              color='#ddddff', fontsize=9, va='top', fontfamily='monospace',
              bbox=dict(boxstyle='round,pad=0.4', facecolor='#111133',
                        edgecolor='#334466', alpha=0.85))

legend_elements = [
    mpatches.Patch(color='#ff4444', label='Thrust units (~55% metal value)'),
    mpatches.Patch(color='#4488ff', label='Wing units'),
    plt.Line2D([0],[0], color='#ffaa00', linewidth=2, label='Contact curve (clear nodes)'),
    plt.Line2D([0],[0], color='#ff2222', marker='o', linestyle='None',
               markersize=7, label='Engaged node'),
    plt.Line2D([0],[0], color='#44aaff', linewidth=1.5, label='advDir (rotates at frame 20)'),
    plt.Line2D([0],[0], color='#44ff88', marker='*', linestyle='None',
               markersize=10, label='Our base'),
]
ax.legend(handles=legend_elements, loc='lower right',
          facecolor='#111133', edgecolor='#334466', labelcolor='#ddddff', fontsize=8)


def update(frame):
    global arrow_artists

    positions, tlo, thi = sim.step(frame)

    for a in arrow_artists:
        a.remove()
    arrow_artists = []

    # Node world positions (computed from lateral+adv + current advDir)
    xs = [sim._node_world(n)[0] for n in sim.nodes]
    zs = [sim._node_world(n)[1] for n in sim.nodes]
    node_line.set_data(xs, zs)

    node_xy     = np.array(list(zip(xs, zs)))
    node_colors = ['#ff3333' if n['engaged'] else '#ffaa00' for n in sim.nodes]
    node_scatter.set_offsets(node_xy)
    node_scatter.set_color(node_colors)

    # Thrust window polygon
    tw_nodes = sim.nodes[tlo : thi + 1]
    if len(tw_nodes) >= 2:
        half_w  = 150
        adv_v   = sim.adv
        tw_world = [sim._node_world(n) for n in tw_nodes]
        poly_pts = (
            [[p[0] - adv_v[0]*half_w, p[1] - adv_v[1]*half_w] for p in tw_world] +
            [[p[0] + adv_v[0]*half_w, p[1] + adv_v[1]*half_w] for p in reversed(tw_world)]
        )
        thrust_poly.set_xy(poly_pts)
    else:
        thrust_poly.set_xy([[0,0]])

    # advDir indicator arrow
    arrow_cx  = BASE_X + sim.adv[0] * 800
    arrow_cz  = BASE_Z + sim.adv[1] * 800
    dir_arrow_patch.set_positions((BASE_X, BASE_Z), (arrow_cx, arrow_cz))

    # Unit dots
    t_xy, t_sz = [], []
    w_xy, w_sz = [], []
    for uid, node_idx in positions.items():
        upos = sim.unit_positions[uid]
        cost = UNIT_DEFS[uid][1]
        node = sim.nodes[node_idx]
        wx, wz = sim._node_world(node)

        arrow = FancyArrowPatch(
            posA=(upos[0], upos[1]),
            posB=(wx, wz),
            arrowstyle='->', color='#666688', linewidth=0.7,
            mutation_scale=8, zorder=6, alpha=0.5)
        ax.add_patch(arrow)
        arrow_artists.append(arrow)

        if tlo <= node_idx <= thi:
            t_xy.append(upos)
            t_sz.append(max(40, cost * 0.25))
        else:
            w_xy.append(upos)
            w_sz.append(max(40, cost * 0.25))

    thrust_scatter.set_offsets(np.array(t_xy) if t_xy else np.empty((0,2)))
    thrust_scatter.set_sizes(t_sz if t_sz else [])
    wing_scatter.set_offsets(np.array(w_xy) if w_xy else np.empty((0,2)))
    wing_scatter.set_sizes(w_sz if w_sz else [])

    # Enemy units
    if sim.enemies:
        enemy_scatter.set_offsets(np.array(sim.enemies))
    else:
        enemy_scatter.set_offsets(np.empty((0,2)))

    # Enemy base marker
    if frame >= 20:
        enemy_marker.set_data([ENEMY_BASE_X], [ENEMY_BASE_Z])
        enemy_label.set_text("ENEMY BASE")
        enemy_label.xy = (ENEMY_BASE_X, ENEMY_BASE_Z)
    else:
        enemy_marker.set_data([], [])
        enemy_label.set_text("")

    # HUD
    engaged_count = sum(1 for n in sim.nodes if n['engaged'])
    thrust_metal  = sum(UNIT_DEFS[uid][1] for uid, ni in positions.items()
                        if tlo <= ni <= thi)
    total_metal   = sum(c for _, c in UNIT_DEFS)

    if frame < 20:
        phase = "DEFEND — default NE target"
    elif frame < 40:
        phase = "DIRECTION ROTATED TO NORTH"
    elif engaged_count > 0:
        phase = f"ENGAGED ({engaged_count} nodes)"
    else:
        phase = "ADVANCING"

    adv_deg = np.degrees(np.arctan2(sim.adv[0], sim.adv[1]))
    hud.set_text(
        f"Frame: {frame:>3}   Phase: {phase}\n"
        f"advDir: ({sim.adv[0]:+.2f}, {sim.adv[1]:+.2f})  "
        f"bearing: {adv_deg:.0f}°\n"
        f"Thrust node: {sim.thrust_idx+1:>2}  Window: [{tlo+1}–{thi+1}]\n"
        f"Thrust: {len(t_xy)} units "
        f"({thrust_metal}/{total_metal} = {thrust_metal/total_metal*100:.0f}% metal)\n"
        f"Wings:  {len(w_xy)} units"
    )

    return (node_line, node_scatter, thrust_poly, thrust_scatter,
            wing_scatter, enemy_scatter, enemy_marker, hud)


ani = animation.FuncAnimation(
    fig, update, frames=60, interval=200, blit=False, repeat=True
)

plt.tight_layout()
plt.show()
