"""Where did the player's MOVE orders point relative to the enemy?  (kiting analysis)

Reads a human_control_logger log ([HCL] rows) and, for the orders given to a chosen unit type (default the
slow group: cormist + corlevlr, no other types in the selection), joins each order with the latest [HCL] ctx
row (enemy centroid, nearest enemy distance to the army) to classify it:

  toward   the order moves the group toward the enemy centroid (step along the group->enemy line > +STEP)
  away     it moves the group away from it (< -STEP)          <- a kite step when the enemy is near
  side     neither (a flank / repositioning)

Prints: the split by enemy distance band, the back-step length and the enemy distance it was given at, the
enemy distance AFTER the step (target->nearest enemy, from the cmd row), and the back/forward cycle times.
Usage:  python human_kite_report.py [log] [--types cormist,corlevlr] [--min-n 3] [--near 1500]
"""
import argparse, glob, math, os, re, statistics as st

KV = re.compile(r'(\w+)=(\S+)')


def parse(line):
    d = dict(KV.findall(line))
    m = re.search(r'f=(\d+)', line)
    d['f'] = int(m.group(1)) if m else 0
    return d


def num(d, k, default=None):
    try:
        return float(d[k])
    except (KeyError, ValueError):
        return default


def find_log():
    root = os.path.expandvars(r'%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\LuaUI\Config')
    logs = sorted(glob.glob(os.path.join(root, 'metalbot_human_*.log')), key=os.path.getmtime)
    return logs[-1] if logs else None


def med(xs):
    return st.median(xs) if xs else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log', nargs='?')
    ap.add_argument('--types', default='cormist,corlevlr')
    ap.add_argument('--min-n', type=int, default=3)
    ap.add_argument('--near', type=float, default=1500, help='enemy centroid this close = "in contact"')
    ap.add_argument('--step', type=float, default=150, help='net step along the enemy line that counts as toward/away')
    a = ap.parse_args()
    path = a.log or find_log()
    types = set(a.types.split(','))
    print('Log:', path)

    ctx, cmds = [], []
    for line in open(path, encoding='utf8', errors='replace'):
        if '[HCL] ctx' in line:
            ctx.append(parse(line))
        elif '[HCL] cmd' in line:
            d = parse(line)
            comp = {p.split(':')[0] for p in d.get('comp', '').split(',') if p}
            if comp and comp <= types and d.get('cmd') in ('move', 'fight') and int(d.get('n', 0)) >= a.min_n:
                cmds.append(d)
    ctx.sort(key=lambda r: r['f'])
    print('orders (%s, n>=%d): %d' % (a.types, a.min_n, len(cmds)))

    rows, ci = [], 0
    for c in cmds:
        while ci + 1 < len(ctx) and ctx[ci + 1]['f'] <= c['f']:
            ci += 1
        x = ctx[ci] if ctx and ctx[ci]['f'] <= c['f'] and c['f'] - ctx[ci]['f'] <= 450 else None
        cx, cz, tx, tz = num(c, 'cx'), num(c, 'cz'), num(c, 'tx'), num(c, 'tz')
        if None in (cx, cz, tx, tz):
            continue
        ex = num(x, 'enemy_cx') if x else None
        ez = num(x, 'enemy_cz') if x else None
        r = {'f': c['f'], 't': c['t'], 'cmd': c['cmd'], 'n': int(c['n']), 'cx': cx, 'cz': cz, 'tx': tx, 'tz': tz,
             'enemy_d': num(c, 'enemy_d', -1), 'enemy_near': int(c.get('enemy_near', 0)),
             'step': math.hypot(tx - cx, tz - cz), 'cls': 'noenemy', 'edist': None, 'along': 0}
        if ex is not None and ez is not None:
            r['edist'] = math.hypot(ex - cx, ez - cz)
            if r['edist'] > 1:
                ux, uz = (ex - cx) / r['edist'], (ez - cz) / r['edist']
                r['along'] = (tx - cx) * ux + (tz - cz) * uz
                r['cls'] = 'toward' if r['along'] > a.step else 'away' if r['along'] < -a.step else 'side'
        rows.append(r)

    print('with an enemy fix:', sum(1 for r in rows if r['edist'] is not None))
    bands = [(0, 800), (800, 1500), (1500, 2500), (2500, 1e9)]
    print('\nMove direction by distance from the group to the enemy centroid (move orders only):')
    print('  band         orders  toward  away  side   median away-step  median toward-step')
    for lo, hi in bands:
        sel = [r for r in rows if r['cmd'] == 'move' and r['edist'] is not None and lo <= r['edist'] < hi]
        if not sel:
            continue
        aw = [-r['along'] for r in sel if r['cls'] == 'away']
        tw = [r['along'] for r in sel if r['cls'] == 'toward']
        print('  %4d-%-6s %6d %6d %5d %5d   %10.0f        %10.0f' % (
            lo, 'inf' if hi > 1e8 else int(hi), len(sel), sum(r['cls'] == 'toward' for r in sel),
            len(aw), sum(r['cls'] == 'side' for r in sel), med(aw), med(tw)))

    cont = [r for r in rows if r['edist'] is not None and r['edist'] <= a.near and r['cmd'] == 'move']
    backs = [r for r in cont if r['cls'] == 'away']
    print('\nIn contact (enemy centroid within %d): %d move orders, %d away (%.0f%%), %d toward' % (
        a.near, len(cont), len(backs), 100.0 * len(backs) / max(1, len(cont)), sum(r['cls'] == 'toward' for r in cont)))
    if backs:
        print('  back step: median %.0f elmos (p25 %.0f, p75 %.0f); given with the enemy centroid at median %.0f'
              % (med([-r['along'] for r in backs]),
                 st.quantiles([-r['along'] for r in backs], n=4)[0] if len(backs) > 3 else float('nan'),
                 st.quantiles([-r['along'] for r in backs], n=4)[2] if len(backs) > 3 else float('nan'),
                 med([r['edist'] for r in backs])))
        after = [r['enemy_d'] for r in backs if r['enemy_d'] >= 0]
        if after:
            print('  nearest visible enemy to the back-step TARGET: median %.0f (p25 %.0f)' % (
                med(after), st.quantiles(after, n=4)[0] if len(after) > 3 else float('nan')))
        print('  enemy within ENEMY_R of the units when stepping back: median %.1f enemies' % med([r['enemy_near'] for r in backs]))

    # back -> forward cycles: a gesture = consecutive orders <1.5 s apart
    gest = []
    for r in rows:
        if r['edist'] is None or r['edist'] > a.near * 1.6:
            continue
        if gest and r['f'] - gest[-1]['f_end'] < 45:
            gest[-1]['f_end'] = r['f']
            gest[-1]['cls'].append(r['cls'])
            continue
        gest.append({'f': r['f'], 'f_end': r['f'], 't': r['t'], 'cls': [r['cls']], 'cmd': r['cmd'], 'along': r['along']})
    kinds = []
    for g in gest:
        k = 'away' if g['cls'].count('away') > len(g['cls']) / 2 else 'toward' if g['cls'].count('toward') > len(g['cls']) / 2 else 'side'
        kinds.append((g['f'], k, g['t']))
    cyc = []
    for i in range(1, len(kinds)):
        if kinds[i - 1][1] == 'away' and kinds[i][1] == 'toward':
            cyc.append((kinds[i][0] - kinds[i - 1][0]) / 30.0)
    print('\nGestures near the enemy (<1.5 s apart merged): %d  away=%d toward=%d side=%d' % (
        len(kinds), sum(k[1] == 'away' for k in kinds), sum(k[1] == 'toward' for k in kinds), sum(k[1] == 'side' for k in kinds)))
    if cyc:
        print('back -> forward: %d cycles, median %.1f s between the back step and the next forward step (p25 %.1f, p75 %.1f)' % (
            len(cyc), med(cyc), st.quantiles(cyc, n=4)[0] if len(cyc) > 3 else float('nan'),
            st.quantiles(cyc, n=4)[2] if len(cyc) > 3 else float('nan')))

    fights = [r for r in rows if r['cmd'] == 'fight' and r['edist'] is not None]
    print('\nFIGHT orders with an enemy fix: %d (toward %d, away %d)' % (
        len(fights), sum(r['cls'] == 'toward' for r in fights), sum(r['cls'] == 'away' for r in fights)))

    print('\nFirst 40 orders in contact (t, cmd, n, enemy dist, step along enemy line [+toward/-away], step length, enemy_d at target):')
    for r in [r for r in rows if r['edist'] is not None and r['edist'] <= a.near][:40]:
        print('  %-6s %-5s n=%-3d edist=%5.0f along=%+6.0f step=%5.0f enemy_d@target=%5.0f  %s' % (
            r['t'], r['cmd'], r['n'], r['edist'], r['along'], r['step'], r['enemy_d'], r['cls']))


def parse_loc(line):
    d = parse(line)
    own = []
    for p in d.get('own', '').split(','):
        f = p.split(':')
        if len(f) == 5:
            own.append({'def': f[0], 'x': float(f[1]), 'z': float(f[2]), 'd': float(f[3]), 'hp': float(f[4])})
    foe = []
    for p in d.get('foe', '').split(','):
        f = p.split(':')
        if len(f) == 7:
            foe.append({'def': f[0], 'x': float(f[1]), 'z': float(f[2]), 'd': float(f[3]), 'r': float(f[4]),
                        'hp': float(f[5]), 'los': int(f[6])})
    d['own_l'], d['foe_l'] = own, foe
    return d


def local_report(path, types, min_n, step_min):
    """Uses the [HCL] loc rows (precise, local): the lead unit, the nearest enemy, ranges, who can hit whom."""
    cmds, locs = [], {}
    for line in open(path, encoding='utf8', errors='replace'):
        if '[HCL] loc' in line and 'src=cmd' in line:
            d = parse_loc(line)
            locs[d['f']] = d
        elif '[HCL] cmd' in line:
            d = parse(line)
            comp = {p.split(':')[0] for p in d.get('comp', '').split(',') if p}
            if comp and comp <= types and d.get('cmd') in ('move', 'fight', 'attack', 'stop') and int(d.get('n', 0)) >= min_n:
                cmds.append(d)
    rows = []
    for c in cmds:
        L = locs.get(c['f'])
        if not L or not L['own_l'] or not L['foe_l']:
            continue
        lead, foe = L['own_l'][0], L['foe_l'][0]
        tx, tz = num(c, 'tx'), num(c, 'tz')
        if tx is None or tz is None:
            rows.append({'t': c['t'], 'cmd': c['cmd'], 'L': L, 'cls': 'stop', 'along': 0, 'step': 0, 'after': None})
            continue
        # the step is measured from the LEAD unit toward/away from ITS nearest enemy
        dx, dz = foe['x'] - lead['x'], foe['z'] - lead['z']
        dd = math.hypot(dx, dz) or 1
        ux, uz = dx / dd, dz / dd
        along = (tx - lead['x']) * ux + (tz - lead['z']) * uz
        after = min(math.hypot(tx - f['x'], tz - f['z']) for f in L['foe_l'])
        cls = 'toward' if along > step_min else 'away' if along < -step_min else 'side'
        rows.append({'t': c['t'], 'cmd': c['cmd'], 'L': L, 'cls': cls, 'along': along,
                     'step': math.hypot(tx - lead['x'], tz - lead['z']), 'after': after})
    print('\n=== LOCAL VIEW (loc rows): %d orders with enemies within reach ===' % len(rows))
    if not rows:
        print('  none - the log has no [HCL] loc rows (play with the updated human_control_logger.lua)')
        return
    mv = [r for r in rows if r['cmd'] == 'move']
    for cls in ('toward', 'away', 'side'):
        sel = [r for r in mv if r['cls'] == cls]
        if not sel:
            continue
        print('  MOVE %-6s %4d | lead_d median %5.0f | step median %5.0f | enemy->target median %5.0f | '
              'they_hit %.1f we_hit %.1f of foe_n %.1f | lead_d/rng_max %.2f'
              % (cls, len(sel), med([r['L']['lead_d'] if False else float(r['L']['lead_d']) for r in sel]),
                 med([r['step'] for r in sel]), med([r['after'] for r in sel if r['after'] is not None]),
                 med([float(r['L']['they_hit']) for r in sel]), med([float(r['L']['we_hit']) for r in sel]),
                 med([float(r['L']['foe_n']) for r in sel]),
                 med([float(r['L']['lead_d']) / max(1.0, float(r['L']['rng_max'])) for r in sel])))
    away = [r for r in mv if r['cls'] == 'away']
    if away:
        print('\n  KITE STEPS (MOVE away from the nearest enemy):')
        print('   given when the lead unit was  %.0f from the nearest enemy (p25 %.0f, p75 %.0f); %.0f%% of the Lashers'
              ' range' % (med([float(r['L']['lead_d']) for r in away]),
                          st.quantiles([float(r['L']['lead_d']) for r in away], n=4)[0] if len(away) > 3 else float('nan'),
                          st.quantiles([float(r['L']['lead_d']) for r in away], n=4)[2] if len(away) > 3 else float('nan'),
                          100 * med([float(r['L']['lead_d']) / max(1.0, float(r['L']['rng_max'])) for r in away])))
        print('   they_hit>0 in %.0f%% of them (an enemy could already hit one of ours); we_hit>0 in %.0f%%'
              % (100.0 * sum(int(r['L']['they_hit']) > 0 for r in away) / len(away),
                 100.0 * sum(int(r['L']['we_hit']) > 0 for r in away) / len(away)))
        print('   after the step the nearest enemy to the TARGET is %.0f away; enemy types nearest: %s' % (
            med([r['after'] for r in away if r['after'] is not None]),
            ', '.join('%s x%d' % kv for kv in sorted(
                {k: sum(1 for r in away if r['L']['foe_l'][0]['def'] == k) for k in {r['L']['foe_l'][0]['def'] for r in away}}.items(),
                key=lambda kv: -kv[1])[:5])))
    print('\n  Last 25 local MOVE orders (t, class, lead_d, step along the lead->nearest-enemy line, they_hit/we_hit, nearest enemy type):')
    for r in mv[-25:]:
        print('   %-6s %-6s lead_d=%5s along=%+6.0f step=%5.0f they_hit=%s we_hit=%s foe=%s' % (
            r['t'], r['cls'], r['L']['lead_d'], r['along'], r['step'], r['L']['they_hit'], r['L']['we_hit'],
            r['L']['foe_l'][0]['def']))


if __name__ == '__main__':
    main()
    _ap = argparse.ArgumentParser(add_help=False)
    _ap.add_argument('log', nargs='?')
    _ap.add_argument('--types', default='cormist,corlevlr')
    _ap.add_argument('--min-n', type=int, default=3)
    _ap.add_argument('--step', type=float, default=150)
    _a, _ = _ap.parse_known_args()
    local_report(_a.log or find_log(), set(_a.types.split(',')), _a.min_n, _a.step)
