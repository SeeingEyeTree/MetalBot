#!/usr/bin/env python3
"""
BAR build-order optimizer.

Four optimization modes (select with --mode):
  max_rate       Maximize metal income rate (m/s) at --end-time seconds (default).
  time_to_target Minimize the time to first reach --target m/s metal rate.
  max_units      Maximize Incisor units built within --end-time seconds.
  balanced       Maximize m/s while hitting an Incisor army target (--army-target).
                 Score = projected_m/s * min(1, projected_incisors / army_target).
                 Once the army target is met the optimizer pivots to pure eco.

Resource cap rules:
  - Metal cap starts at 1000; each mex adds 50.
  - Energy cap starts at 1000; each Energy Storage adds 6000.
  - Stored resources are capped on entry to each action.
  - During construction resources trickle through (not limited by cap).
  - Excess generated while at cap between actions is destroyed.

Usage:
    python build_order_sim.py                            # max_rate, 6 min
    python build_order_sim.py --mode time_to_target      # fastest 80 m/s
    python build_order_sim.py --mode time_to_target --target 100
    python build_order_sim.py --mode max_units           # max Incisors in 6 min
    python build_order_sim.py --mode balanced            # balance army + eco
    python build_order_sim.py --mode balanced --army-target 40
    python build_order_sim.py --mode max_rate --end-time 300
Outputs:
    build_order_result.png   -- timeline chart
    build_order_result.json  -- action sequence + final state
"""

import argparse
import copy
import json
import math
from dataclasses import dataclass, field
from typing import Optional
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

# ---------------------------------------------------------------------------
# Game constants
# ---------------------------------------------------------------------------

SIM_END    = 360.0   # seconds (6 minutes)
BEAM_WIDTH = 2000

# name -> {metal, energy, bp, dm, de, dbp,
#          dmetal_cap, denergy_cap,
#          req_lab, gives_lab, gives_con, removes_lab, metal_refund,
#          req_veh_lab, gives_veh_lab, gives_incisor}
ACTIONS: dict[str, dict] = {
    'mex':        dict(metal=50,  energy=500,  bp=1870, dm=2.37, de=-3.0, dbp=0,
                       dmetal_cap=50,  denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'wind':       dict(metal=43,  energy=175,  bp=1680, dm=0.0,  de=25.0, dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'e_store':    dict(metal=175, energy=1800, bp=4260, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=6000,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'bot_lab':    dict(metal=470, energy=1050, bp=5000, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=True,  gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'con_bot':    dict(metal=120, energy=1750, bp=3550, dm=0.0,  de=0.0,  dbp=85,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=True,  gives_lab=False, gives_con=True,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False,
                       factory_bp=150),
    'nano':       dict(metal=230, energy=3200, bp=5300, dm=0.0,  de=0.0,  dbp=200,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'reclaim_lab':dict(metal=0,   energy=0,    bp=5000, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=True,  gives_lab=False, gives_con=False,
                       removes_lab=True,  metal_refund=470,
                       req_veh_lab=False, gives_veh_lab=False, gives_incisor=False),
    'veh_lab':    dict(metal=570, energy=1550, bp=5650, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=False, gives_veh_lab=True,  gives_incisor=False),
    'cv':         dict(metal=145, energy=2100, bp=4160, dm=0.0,  de=0.0,  dbp=95,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=True,  gives_veh_lab=False, gives_incisor=False,
                       gives_cv=True,  factory_bp=150),
    'reclaim_vp': dict(metal=0,   energy=0,    bp=5650, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=570,
                       req_veh_lab=True,  gives_veh_lab=False, gives_incisor=False),
    'incisor':    dict(metal=120, energy=1100, bp=2300, dm=0.0,  de=0.0,  dbp=0,
                       dmetal_cap=0,   denergy_cap=0,
                       req_lab=False, gives_lab=False, gives_con=False,
                       removes_lab=False, metal_refund=0,
                       req_veh_lab=True,  gives_veh_lab=False, gives_incisor=True,
                       factory_bp=150),
}

ACTION_LABELS = {
    'mex':         'Mex',
    'wind':        'Wind',
    'e_store':     'E-Store',
    'bot_lab':     'Bot Lab',
    'con_bot':     'Con Bot',
    'nano':        'Nano',
    'reclaim_lab': 'Reclaim Lab',
    'veh_lab':     'Veh Lab',
    'cv':          'Con Veh',
    'reclaim_vp':  'Reclaim VP',
    'incisor':     'Incisor',
}

ACTION_COLORS = {
    'mex':         '#4CAF50',
    'wind':        '#FFC107',
    'e_store':     '#00BCD4',
    'bot_lab':     '#9C27B0',
    'con_bot':     '#FF5722',
    'nano':        '#2196F3',
    'reclaim_lab': '#795548',
    'veh_lab':     '#E91E63',
    'cv':          '#FF5722',
    'reclaim_vp':  '#607D8B',
    'incisor':     '#FF9800',
}

MULTI_LABEL_ACTIONS = {'mex', 'wind', 'nano', 'e_store', 'incisor'}


# ---------------------------------------------------------------------------
# Simulation state
# ---------------------------------------------------------------------------

@dataclass
class GameState:
    time:          float = 0.0
    metal:         float = 1000.0
    energy:        float = 1000.0
    metal_rate:    float = 2.0
    energy_rate:   float = 30.0
    build_power:   float = 300.0
    metal_cap:     float = 1000.0
    energy_cap:    float = 1000.0
    has_bot_lab:   bool  = False
    has_con_bot:   bool  = False
    has_veh_lab:   bool  = False
    has_cv:        bool  = False
    incisor_count: int   = 0
    history:       list  = field(default_factory=list)

    # ------------------------------------------------------------------
    def valid_actions(self, mode: str = 'max_rate') -> list[str]:
        acts = ['mex', 'wind', 'e_store']
        if not self.has_bot_lab:
            acts.append('bot_lab')
        if self.has_bot_lab:
            acts.append('con_bot')
            acts.append('reclaim_lab')
        if self.has_con_bot or self.has_cv:
            acts.append('nano')
        if mode in ('max_units', 'balanced'):
            if not self.has_veh_lab:
                acts.append('veh_lab')
            if self.has_veh_lab:
                acts.append('cv')
                acts.append('reclaim_vp')
                acts.append('incisor')
        return acts

    # ------------------------------------------------------------------
    def apply_action(self, name: str) -> Optional['GameState']:
        """
        Execute an action with capped storage and trickle-resource mechanics.

        Storage cap applies to what is available at the START of the build.
        Income trickles through during construction (not limited by cap).
        Remaining stored resources are capped at the new cap on completion.

        Build time = max(bp_cost/bp,
                         (m_cost - eff_metal) / metal_rate,   <- if short
                         (e_cost - eff_energy) / energy_rate) <- if short
        """
        a = ACTIONS[name]
        if a['req_lab'] and not self.has_bot_lab:
            return None
        if a['req_veh_lab'] and not self.has_veh_lab:
            return None

        s = copy.copy(self)
        s.history = list(self.history)

        # Available stored resources are capped
        eff_m = min(s.metal, s.metal_cap)
        eff_e = min(s.energy, s.energy_cap)

        m_cost = a['metal']
        e_cost = a['energy']

        # Seconds of trickle income needed to cover any shortfall
        t_m = 0.0
        if eff_m < m_cost:
            if s.metal_rate <= 0:
                return None
            t_m = (m_cost - eff_m) / s.metal_rate

        t_e = 0.0
        if eff_e < e_cost:
            if s.energy_rate <= 0:
                return None
            t_e = (e_cost - eff_e) / s.energy_rate

        t_bp = a['bp'] / (s.build_power + a.get('factory_bp', 0))
        build_time = max(t_bp, t_m, t_e)

        start_t = s.time
        end_t   = start_t + build_time

        # Net resources: initial stored (capped) + trickle income - cost
        new_m = eff_m + s.metal_rate  * build_time - m_cost
        new_e = eff_e + s.energy_rate * build_time - e_cost

        if new_m < -0.001 or new_e < -0.001:
            return None

        # Apply completion effects
        s.time        = end_t
        s.metal_rate  += a['dm']
        s.energy_rate += a['de']
        s.build_power += a['dbp']
        s.metal_cap   += a['dmetal_cap']
        s.energy_cap  += a['denergy_cap']

        if a['gives_lab']:              s.has_bot_lab   = True
        if a['gives_con']:              s.has_con_bot   = True
        if a['removes_lab']:            s.has_bot_lab   = False
        if a['gives_veh_lab']:          s.has_veh_lab   = True
        if a.get('gives_cv', False):    s.has_cv        = True
        if a.get('removes_veh_lab', False): s.has_veh_lab = False
        if a['gives_incisor']:          s.incisor_count += 1

        # Cap remaining storage at the (possibly updated) caps
        s.metal  = min(max(0.0, new_m) + a['metal_refund'], s.metal_cap)
        s.energy = min(max(0.0, new_e), s.energy_cap)

        s.history.append({
            'action':               name,
            'start_time':           round(start_t,       2),
            'end_time':             round(end_t,         2),
            'metal_rate_after':     round(s.metal_rate,  3),
            'energy_rate_after':    round(s.energy_rate, 3),
            'build_power_after':    round(s.build_power, 1),
            'metal_cap_after':      round(s.metal_cap,   0),
            'energy_cap_after':     round(s.energy_cap,  0),
            'incisor_count_after':  s.incisor_count,
        })

        return s

    # ------------------------------------------------------------------
    def score_max_rate(self, end_time: float) -> float:
        """
        Projected metal rate: current m/s plus an optimistic estimate of
        future m/s from mexes that fit in the remaining time at current BP.
        Rewards high BP (infrastructure) so those paths aren't pruned early.
        Higher is better.
        """
        remaining = max(0.0, end_time - self.time)
        mex_time  = 1870.0 / self.build_power
        return self.metal_rate + (remaining / mex_time) * 2.37

    # ------------------------------------------------------------------
    def score_time_to_target(self, target_rate: float) -> float:
        """
        Projected time to reach target_rate: current time plus the time
        needed to build enough mexes at current BP.  Lower is better;
        we negate so that the beam (which sorts descending) picks fastest paths.
        """
        if self.metal_rate >= target_rate:
            return 0.0
        mexes_needed = (target_rate - self.metal_rate) / 2.37
        mex_time     = 1870.0 / self.build_power
        return -(self.time + mexes_needed * mex_time)

    # ------------------------------------------------------------------
    def score_max_units(self, end_time: float) -> float:
        """
        Projected Incisor count: current count plus the better of:
          (a) spamming Incisors immediately at the current bottleneck rate, or
          (b) investing in cv+nano first (if veh_lab exists but nano isn't unlocked)
              then spamming at the improved rate.

        This prevents premature pruning of high-economy / low-BP states that
        would benefit from the cv->nano BP investment before production.
        """
        remaining = max(0.0, end_time - self.time)
        m_rate = max(self.metal_rate,  0.001)
        e_rate = max(self.energy_rate, 0.001)

        if not self.has_veh_lab:
            eff_m = min(self.metal, self.metal_cap)
            eff_e = min(self.energy, self.energy_cap)
            t_m = max(0.0, 570  - eff_m) / m_rate
            t_e = max(0.0, 1550 - eff_e) / e_rate
            t_bp = 5650.0 / self.build_power
            remaining = max(0.0, remaining - max(t_bp, t_m, t_e))

        # Factory BP (150) always contributes to incisor build time when VP exists
        factory_bp = 150 if self.has_veh_lab else 0
        spam_rate = max(2300.0/(self.build_power + factory_bp), 120.0/m_rate, 1100.0/e_rate)
        spam_score = remaining / spam_rate

        # If veh_lab is ready but nano not unlocked, consider cv+nano investment
        if self.has_veh_lab and not (self.has_con_bot or self.has_cv):
            # CV uses factory BP too
            cv_time     = max(4160.0 / (self.build_power + 150), 2100.0 / e_rate)
            bp_after_cv = self.build_power + 95
            nano_time   = max(5300.0 / bp_after_cv,              3200.0 / e_rate)
            infra_time  = cv_time + nano_time
            if remaining > infra_time:
                bp_after_nano = bp_after_cv + 200
                # Incisor still uses factory BP after nano
                infra_rate = max(2300.0/(bp_after_nano + 150), 120.0/m_rate, 1100.0/e_rate)
                infra_score = (remaining - infra_time) / infra_rate
                spam_score = max(spam_score, infra_score)

        return self.incisor_count + spam_score

    # ------------------------------------------------------------------
    def score_balanced(self, end_time: float, army_target: int,
                        em_ratio: float = 10.0) -> float:
        """
        Score = army_fraction * projected_m/s * em_penalty

        army_fraction  = min(1, projected_incisors / army_target)
                         Saturates at 1.0 so the optimizer pivots to eco once
                         the army target is on track.

        em_penalty     = time-scaled ratio penalty for energy:metal imbalance.
                         At t=0 the penalty is 0 (no effect on early decisions).
                         At t=end_time a deficit of 'current vs target e:m ratio'
                         reduces the score proportionally.  This nudges the
                         optimizer toward a balanced economy by the end of the run
                         without constraining early eco-building choices.
        """
        remaining = max(0.0, end_time - self.time)
        m_rate = max(self.metal_rate,  0.001)
        e_rate = max(self.energy_rate, 0.001)

        # --- Projected incisor count (mirrors score_max_units logic) ---
        adj_remaining = remaining
        if not self.has_veh_lab:
            eff_m = min(self.metal, self.metal_cap)
            eff_e = min(self.energy, self.energy_cap)
            t_m   = max(0.0, 570  - eff_m) / m_rate
            t_e   = max(0.0, 1550 - eff_e) / e_rate
            t_bp  = 5650.0 / self.build_power
            adj_remaining = max(0.0, remaining - max(t_bp, t_m, t_e))

        factory_bp = 150 if self.has_veh_lab else 0
        spam_rate  = max(2300.0/(self.build_power + factory_bp), 120.0/m_rate, 1100.0/e_rate)
        proj_incisors = self.incisor_count + adj_remaining / spam_rate

        if self.has_veh_lab and not (self.has_con_bot or self.has_cv):
            cv_time      = max(4160.0 / (self.build_power + 150), 2100.0 / e_rate)
            bp_after_cv  = self.build_power + 95
            nano_time    = max(5300.0 / bp_after_cv, 3200.0 / e_rate)
            infra_time   = cv_time + nano_time
            if adj_remaining > infra_time:
                bp_after_nano = bp_after_cv + 200
                infra_rate    = max(2300.0/(bp_after_nano + 150), 120.0/m_rate, 1100.0/e_rate)
                proj_incisors = max(proj_incisors,
                                    self.incisor_count + (adj_remaining - infra_time) / infra_rate)

        # --- Projected metal rate (mirrors score_max_rate logic) ---
        mex_time  = 1870.0 / self.build_power
        proj_rate = self.metal_rate + (remaining / mex_time) * 2.37

        # --- Army fraction (caps at 1.0 to avoid over-building army) ---
        army_fraction = min(1.0, proj_incisors / max(1, army_target))

        score = army_fraction * proj_rate

        # --- Time-scaled energy:metal ratio penalty ---
        # weight = 0 at t=0 (no constraint), 1 at t=end_time (full constraint)
        # deficit = how far below the target ratio we are, as a fraction 0..1
        if em_ratio > 0:
            time_fraction = min(1.0, self.time / max(end_time, 1.0))
            current_ratio = self.energy_rate / m_rate
            if current_ratio < em_ratio:
                deficit = (em_ratio - current_ratio) / em_ratio
                penalty = 1.0 - deficit * (time_fraction ** 2)
                score  *= max(0.05, penalty)

        return score


# ---------------------------------------------------------------------------
# Beam search
# ---------------------------------------------------------------------------

def beam_search(
    end_time:    float = SIM_END,
    beam_width:  int   = BEAM_WIDTH,
    mode:        str   = 'max_rate',
    target_rate: float = 80.0,
    army_target: int   = 35,
    em_ratio:    float = 10.0,
) -> GameState:
    """
    mode='max_rate':
        Expand up to end_time; rank by projected final m/s.
    mode='time_to_target':
        Expand until metal_rate >= target_rate; rank by projected arrival time.
    mode='max_units':
        Expand up to end_time; rank by projected Incisor count.
    mode='balanced':
        Expand up to end_time; rank by projected_m/s * army_fraction.
        army_fraction = min(1, projected_incisors / army_target).
        Final pick: best m/s among states that met army_target.
    """
    MAX_SEARCH = 600.0

    beam: list[GameState] = [GameState()]
    completed: list[GameState] = []

    for _step in range(500):
        candidates: list[GameState] = []

        for state in beam:
            can_expand = False

            for action in state.valid_actions(mode=mode):
                ns = state.apply_action(action)
                if ns is None:
                    continue

                if mode in ('max_rate', 'max_units', 'balanced'):
                    if ns.time > end_time:
                        continue
                    candidates.append(ns)
                    can_expand = True

                else:  # time_to_target
                    if ns.time > MAX_SEARCH:
                        continue
                    if ns.metal_rate >= target_rate:
                        completed.append(ns)
                    else:
                        candidates.append(ns)
                    can_expand = True

            if not can_expand:
                completed.append(state)

        if not candidates:
            break

        if mode == 'max_rate':
            candidates.sort(key=lambda s: s.score_max_rate(end_time), reverse=True)
        elif mode == 'max_units':
            candidates.sort(key=lambda s: s.score_max_units(end_time), reverse=True)
        elif mode == 'balanced':
            candidates.sort(key=lambda s: s.score_balanced(end_time, army_target, em_ratio), reverse=True)
        else:  # time_to_target
            if completed:
                best_t = min(s.time for s in completed)
                candidates = [s for s in candidates if s.time < best_t]
                if not candidates:
                    break
            candidates.sort(key=lambda s: s.score_time_to_target(target_rate), reverse=True)

        beam = candidates[:beam_width]

    all_states = completed + beam
    if mode == 'max_rate':
        return max(all_states, key=lambda s: s.metal_rate)
    elif mode == 'max_units':
        return max(all_states, key=lambda s: s.incisor_count)
    elif mode == 'balanced':
        met = [s for s in all_states if s.incisor_count >= army_target]
        if met:
            return max(met, key=lambda s: s.metal_rate)
        # Target not reached — return best eco among closest-to-target states
        best_army = max(all_states, key=lambda s: s.incisor_count).incisor_count
        close     = [s for s in all_states if s.incisor_count == best_army]
        return max(close, key=lambda s: s.metal_rate)
    else:
        if completed:
            return min(completed, key=lambda s: s.time)
        return max(completed + beam, key=lambda s: s.metal_rate)


# ---------------------------------------------------------------------------
# CLI output
# ---------------------------------------------------------------------------

def print_result(state: GameState,
                 mode: str = 'max_rate',
                 target_rate: float = 80.0,
                 end_time: float = SIM_END,
                 em_ratio: float = 10.0) -> None:
    h = state.history
    show_incisors = mode in ('max_units', 'balanced')
    print()
    print('=' * 88)
    if mode == 'max_rate':
        print(f'  OPTIMAL BUILD ORDER  --  {state.metal_rate:.3f} m/s at {end_time:.0f} s')
    elif mode == 'max_units':
        print(f'  MAX UNITS  --  {state.incisor_count} Incisors in {end_time:.0f} s')
    elif mode == 'balanced':
        actual_ratio = state.energy_rate / max(state.metal_rate, 0.001)
        print(f'  BALANCED  --  {state.incisor_count} Incisors  |  {state.metal_rate:.3f} m/s  |  e:m ratio {actual_ratio:.1f} at {end_time:.0f} s')
    else:
        achieved = state.metal_rate >= target_rate
        if achieved:
            print(f'  FASTEST TO {target_rate:.0f} m/s  --  reached at t = {state.time:.2f} s')
        else:
            print(f'  TARGET {target_rate:.0f} m/s NOT REACHED  --  best {state.metal_rate:.3f} m/s')
    print('=' * 88)
    hdr = (f"{'#':>3}  {'Action':<12}  {'Start':>7}  {'End':>7}  "
           f"{'m/s':>6}  {'e/s':>7}  {'BP':>6}  {'M-cap':>6}  {'E-cap':>7}")
    if show_incisors:
        hdr += f"  {'Incisors':>8}"
    print(hdr)
    print('-' * 88)
    counts: dict[str, int] = {}
    for i, entry in enumerate(h, 1):
        name = entry['action']
        counts[name] = counts.get(name, 0) + 1
        label = ACTION_LABELS[name]
        if name in MULTI_LABEL_ACTIONS or counts[name] > 1:
            label += f' #{counts[name]}'
        marker = ''
        if mode == 'time_to_target' and entry['metal_rate_after'] >= target_rate:
            prev_rate = h[i-2]['metal_rate_after'] if i > 1 else 2.0
            if prev_rate < target_rate:
                marker = ' <-- TARGET'
        row = (f"{i:>3}  {label:<12}  "
               f"{entry['start_time']:>6.1f}s  {entry['end_time']:>6.1f}s  "
               f"{entry['metal_rate_after']:>6.3f}  {entry['energy_rate_after']:>7.2f}  "
               f"{entry['build_power_after']:>6.0f}  "
               f"{entry['metal_cap_after']:>6.0f}  {entry['energy_cap_after']:>7.0f}"
               f"{marker}")
        if show_incisors:
            row += f"  {entry['incisor_count_after']:>8}"
        print(row)
    print('=' * 88)
    print(f"  Final metal rate  : {state.metal_rate:.3f} m/s")
    print(f"  Final energy rate : {state.energy_rate:.2f} e/s")
    print(f"  Final build power : {state.build_power:.0f} bp")
    print(f"  Metal stored      : {state.metal:.1f} / {state.metal_cap:.0f} m")
    print(f"  Energy stored     : {state.energy:.1f} / {state.energy_cap:.0f} e")
    if mode in ('max_units', 'balanced'):
        print(f"  Incisors built    : {state.incisor_count}")
    if mode == 'balanced' and em_ratio > 0:
        actual_ratio = state.energy_rate / max(state.metal_rate, 0.001)
        print(f"  E:M ratio         : {actual_ratio:.1f}  (target: {em_ratio:.1f})")
    print(f"  Final time        : {state.time:.1f} s")
    print('=' * 88)
    print()


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------

def visualize_result(state: GameState,
                     save_path: str = 'build_order_result.png',
                     mode: str = 'max_rate',
                     target_rate: float = 80.0,
                     end_time: float = SIM_END) -> None:
    h = state.history

    times          = [0.0]
    metal_rates    = [2.0]
    energy_rates   = [30.0]
    build_powers   = [300.0]
    energy_caps    = [1000.0]
    incisor_counts = [0]

    for entry in h:
        times.append(entry['end_time'])
        metal_rates.append(entry['metal_rate_after'])
        energy_rates.append(entry['energy_rate_after'])
        build_powers.append(entry['build_power_after'])
        energy_caps.append(entry['energy_cap_after'])
        incisor_counts.append(entry['incisor_count_after'])

    x_end = state.time if mode == 'time_to_target' else end_time
    times.append(x_end)
    metal_rates.append(metal_rates[-1])
    energy_rates.append(energy_rates[-1])
    build_powers.append(build_powers[-1])
    energy_caps.append(energy_caps[-1])
    incisor_counts.append(incisor_counts[-1])

    n_panels = 4 if mode in ('max_units', 'balanced') else 3
    fig, axes = plt.subplots(n_panels, 1, figsize=(16, 4 * n_panels), sharex=True)

    if mode == 'max_rate':
        title = (f'Optimal Build Order  --  {state.metal_rate:.3f} m/s  |  '
                 f'{state.metal:.0f}/{state.metal_cap:.0f} m  '
                 f'{state.energy:.0f}/{state.energy_cap:.0f} e  at {end_time:.0f} s')
    elif mode == 'max_units':
        title = (f'Max Units  --  {state.incisor_count} Incisors in {end_time:.0f} s  |  '
                 f'{state.metal:.0f}/{state.metal_cap:.0f} m  '
                 f'{state.energy:.0f}/{state.energy_cap:.0f} e')
    elif mode == 'balanced':
        title = (f'Balanced  --  {state.incisor_count} Incisors  |  {state.metal_rate:.3f} m/s  |  '
                 f'{state.metal:.0f}/{state.metal_cap:.0f} m  '
                 f'{state.energy:.0f}/{state.energy_cap:.0f} e  at {end_time:.0f} s')
    else:
        title = (f'Fastest to {target_rate:.0f} m/s  --  reached at t = {state.time:.2f} s  |  '
                 f'{state.metal:.0f}/{state.metal_cap:.0f} m  '
                 f'{state.energy:.0f}/{state.energy_cap:.0f} e')
    fig.suptitle(title, fontsize=12, fontweight='bold')

    # Panel 0: metal rate
    ax = axes[0]
    ax.step(times, metal_rates, where='post', color='#4CAF50', linewidth=2)
    ax.fill_between(times, metal_rates, step='post', alpha=0.12, color='#4CAF50')
    ax.set_ylabel('Metal Rate (m/s)', fontsize=10)
    ax.grid(True, alpha=0.3)

    # Panel 1: energy rate + energy cap (dashed)
    ax = axes[1]
    ax.step(times, energy_rates, where='post', color='#FFC107', linewidth=2, label='e/s rate')
    ax.fill_between(times, energy_rates, step='post', alpha=0.12, color='#FFC107')
    ax.step(times, energy_caps, where='post', color='#00BCD4', linewidth=1.5,
            linestyle='--', alpha=0.8, label='energy cap')
    ax.set_ylabel('Energy Rate (e/s)\n[dashed = cap]', fontsize=10)
    ax.legend(loc='upper left', fontsize=8, framealpha=0.7)
    ax.grid(True, alpha=0.3)

    # Panel 2: build power
    ax = axes[2]
    ax.step(times, build_powers, where='post', color='#2196F3', linewidth=2)
    ax.fill_between(times, build_powers, step='post', alpha=0.12, color='#2196F3')
    ax.set_ylabel('Build Power (bp)', fontsize=10)
    ax.grid(True, alpha=0.3)

    # Panel 3 (max_units / balanced): incisor count
    if mode in ('max_units', 'balanced'):
        ax = axes[3]
        ax.step(times, incisor_counts, where='post', color='#FF9800', linewidth=2)
        ax.fill_between(times, incisor_counts, step='post', alpha=0.12, color='#FF9800')
        ax.set_ylabel('Incisors Built', fontsize=10)
        ax.yaxis.set_major_locator(plt.MaxNLocator(integer=True))
        ax.grid(True, alpha=0.3)

    for ax in axes:
        ax.set_xlim(0, x_end)

    # Target rate line (time_to_target mode only)
    if mode == 'time_to_target':
        axes[0].axhline(y=target_rate, color='red', linestyle=':', linewidth=1.5,
                        alpha=0.8, label=f'{target_rate:.0f} m/s target')
        axes[0].axvline(x=state.time, color='red', linestyle='-', linewidth=1.5,
                        alpha=0.6)
        axes[0].text(state.time - 1, target_rate * 1.04,
                     f't = {state.time:.1f} s', ha='right', fontsize=9,
                     color='red', fontweight='bold')

    # Vertical action markers
    action_counts: dict[str, int] = {}
    label_positions: list[float] = []

    for entry in h:
        t    = entry['end_time']
        name = entry['action']
        action_counts[name] = action_counts.get(name, 0) + 1
        cnt   = action_counts[name]
        label = ACTION_LABELS[name]
        if name in MULTI_LABEL_ACTIONS or cnt > 1:
            label += f' #{cnt}'
        color = ACTION_COLORS.get(name, 'gray')

        for ax in axes:
            ax.axvline(x=t, color=color, linestyle='--', alpha=0.45, linewidth=0.8)

        nearby = sum(1 for p in label_positions if abs(p - t) < 10)
        y_frac = 0.97 - 0.13 * (nearby % 4)
        label_positions.append(t)

        y_top = axes[0].get_ylim()[1]
        axes[0].text(t + 0.5, y_top * y_frac, label,
                     rotation=90, va='top', ha='left',
                     fontsize=6.5, color=color, alpha=0.9, clip_on=True)

    axes[-1].set_xlabel('Time (seconds)', fontsize=10)

    patches = [mpatches.Patch(color=ACTION_COLORS[n], label=ACTION_LABELS[n])
               for n in ACTION_COLORS]
    axes[0].legend(handles=patches, loc='upper left', fontsize=8, framealpha=0.8)

    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches='tight')
    print(f'Saved chart -> {save_path}')
    plt.show()


# ---------------------------------------------------------------------------
# Save result
# ---------------------------------------------------------------------------

def save_result(state: GameState,
                save_path: str = 'build_order_result.json',
                mode: str = 'max_rate',
                target_rate: float = 80.0,
                end_time: float = SIM_END) -> None:
    if mode == 'max_rate':
        opt_desc = f'max metal_rate (m/s) at {end_time:.0f} s'
    elif mode == 'max_units':
        opt_desc = f'max Incisors built in {end_time:.0f} s'
    elif mode == 'balanced':
        opt_desc = f'max m/s with army_target incisors in {end_time:.0f} s'
    else:
        opt_desc = f'min time to reach {target_rate:.0f} m/s'
    data = {
        'optimization_mode':    mode,
        'optimization_target':  opt_desc,
        'final_metal_rate':     round(state.metal_rate,   3),
        'final_energy_rate':    round(state.energy_rate,  3),
        'final_build_power':    round(state.build_power,  1),
        'final_metal_stored':   round(state.metal,        1),
        'final_metal_cap':      round(state.metal_cap,    0),
        'final_energy_stored':  round(state.energy,       1),
        'final_energy_cap':     round(state.energy_cap,   0),
        'final_incisor_count':  state.incisor_count,
        'final_time':           round(state.time,         2),
        'actions':              state.history,
    }
    with open(save_path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Saved result -> {save_path}')


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='BAR build-order optimizer')
    parser.add_argument(
        '--mode', choices=['max_rate', 'time_to_target', 'max_units', 'balanced'],
        default='max_rate',
        help='max_rate: maximize m/s at end-time; '
             'time_to_target: reach --target m/s as fast as possible; '
             'max_units: maximize Incisors built within end-time; '
             'balanced: maximize m/s while hitting --army-target Incisors')
    parser.add_argument(
        '--target', type=float, default=80.0,
        help='Target metal rate (m/s) for time_to_target mode (default: 80)')
    parser.add_argument(
        '--end-time', type=float, default=SIM_END,
        help=f'Simulation end time in seconds for max_rate/max_units modes (default: {SIM_END:.0f})')
    parser.add_argument(
        '--army-target', type=int, default=35,
        help='Minimum Incisor count for balanced mode (default: 35)')
    parser.add_argument(
        '--em-ratio', type=float, default=10.0,
        help='Target energy:metal rate ratio for balanced mode (default: 10.0). '
             'Penalty is 0 at t=0 and grows quadratically to full strength at end-time. '
             'Set to 0 to disable.')
    parser.add_argument(
        '--beam-width', type=int, default=BEAM_WIDTH,
        help=f'Beam width for search (default: {BEAM_WIDTH})')
    args = parser.parse_args()

    if args.mode == 'max_rate':
        print(f'Mode: max_rate  |  end_time={args.end_time:.0f} s  |  beam_width={args.beam_width}')
    elif args.mode == 'max_units':
        print(f'Mode: max_units  |  end_time={args.end_time:.0f} s  |  beam_width={args.beam_width}')
    elif args.mode == 'balanced':
        print(f'Mode: balanced  |  army_target={args.army_target}  |  em_ratio={args.em_ratio}  |  end_time={args.end_time:.0f} s  |  beam_width={args.beam_width}')
    else:
        print(f'Mode: time_to_target  |  target={args.target:.1f} m/s  |  beam_width={args.beam_width}')

    best = beam_search(
        end_time=args.end_time,
        beam_width=args.beam_width,
        mode=args.mode,
        target_rate=args.target,
        army_target=args.army_target,
        em_ratio=args.em_ratio,
    )
    print_result(best, mode=args.mode, target_rate=args.target,
                 end_time=args.end_time, em_ratio=args.em_ratio)
    visualize_result(best, mode=args.mode, target_rate=args.target, end_time=args.end_time)
    save_result(best, mode=args.mode, target_rate=args.target, end_time=args.end_time)
