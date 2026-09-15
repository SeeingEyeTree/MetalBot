"""
tournament.py  —  ELO-based tournament pool for MetalBot candidates.

Pool lives in pool/.  Persistent across sessions via pool/pool_state.json.
Candidates are admitted by running a gauntlet against all current pool members.

Usage:
    python tournament.py gauntlet --candidate <bot_dir>
    python tournament.py rankings
    python tournament.py admit --candidate <bot_dir> --id <name> [--parent <name>] [--notes "..."]
"""

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR   = Path(__file__).parent
POOL_DIR   = REPO_DIR / "pool"
BOTS_DIR   = POOL_DIR / "bots"
STATE_FILE = POOL_DIR / "pool_state.json"

ELO_K = 32


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _expected(rating_a: float, rating_b: float) -> float:
    return 1.0 / (1.0 + 10 ** ((rating_b - rating_a) / 400.0))


def _new_elo(rating: float, expected: float, actual: float) -> float:
    return rating + ELO_K * (actual - expected)


# ── TournamentPool ────────────────────────────────────────────────────────────

class TournamentPool:
    def __init__(self, pool_dir: Path = POOL_DIR):
        self.pool_dir  = pool_dir
        self.bots_dir  = pool_dir / "bots"
        self.state_file = pool_dir / "pool_state.json"
        self.pool_dir.mkdir(parents=True, exist_ok=True)
        self.bots_dir.mkdir(parents=True, exist_ok=True)
        self._load()

    def _load(self):
        if self.state_file.exists():
            with open(self.state_file) as f:
                self._state = json.load(f)
        else:
            self._state = {"max_pool_size": 10, "bots": {}, "match_history": []}

    def _save(self):
        with open(self.state_file, "w") as f:
            json.dump(self._state, f, indent=2)

    @property
    def max_pool_size(self) -> int:
        return self._state.get("max_pool_size", 10)

    @property
    def bots(self) -> dict:
        return self._state["bots"]

    def get_ranked_bots(self) -> list:
        """Return bot IDs sorted by ELO descending."""
        return sorted(self.bots.keys(), key=lambda b: self.bots[b]["elo"], reverse=True)

    def bot_dir(self, bot_id: str) -> Path:
        return self.bots_dir / bot_id

    def top_elo(self) -> float:
        if not self.bots:
            return 1200.0
        return max(v["elo"] for v in self.bots.values())

    def record_match(self, bot0_id: str, bot1_id: str, winner: "int | None") -> dict:
        """
        Record a match result and update ELO.

        winner: 0 → bot0 won, 1 → bot1 won, None → draw.
        Returns a dict with old/new ELO values.
        """
        b0 = self.bots.get(bot0_id)
        b1 = self.bots.get(bot1_id)
        if b0 is None or b1 is None:
            return {}

        e0 = _expected(b0["elo"], b1["elo"])
        e1 = 1.0 - e0

        if winner == 0:
            s0, s1 = 1.0, 0.0
        elif winner == 1:
            s0, s1 = 0.0, 1.0
        else:
            s0, s1 = 0.5, 0.5

        old_elo0 = b0["elo"]
        old_elo1 = b1["elo"]
        b0["elo"]            = round(_new_elo(b0["elo"], e0, s0), 2)
        b1["elo"]            = round(_new_elo(b1["elo"], e1, s1), 2)
        b0["matches_played"] = b0.get("matches_played", 0) + 1
        b1["matches_played"] = b1.get("matches_played", 0) + 1

        if winner == 0:
            b0["wins"]   = b0.get("wins", 0) + 1
            b1["losses"] = b1.get("losses", 0) + 1
        elif winner == 1:
            b1["wins"]   = b1.get("wins", 0) + 1
            b0["losses"] = b0.get("losses", 0) + 1
        else:
            b0["draws"] = b0.get("draws", 0) + 1
            b1["draws"] = b1.get("draws", 0) + 1

        record = {
            "timestamp": _now(),
            "bot0": bot0_id, "bot1": bot1_id,
            "winner": winner,
            "elo_before": {bot0_id: old_elo0, bot1_id: old_elo1},
            "elo_after":  {bot0_id: b0["elo"], bot1_id: b1["elo"]},
        }
        self._state["match_history"].append(record)
        self._save()
        return record

    def admit_bot(self, src_dir: Path, bot_id: str, parent_id: str = None, notes: str = "") -> bool:
        """Copy src_dir into pool/bots/<bot_id> and register it with starting ELO 1200."""
        dst = self.bots_dir / bot_id
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src_dir, dst)
        self.bots[bot_id] = {
            "elo": 1200.0,
            "wins": 0, "losses": 0, "draws": 0,
            "matches_played": 0,
            "created_at": _now(),
            "parent_id": parent_id,
            "notes": notes,
        }
        self._save()
        return True

    def evict_weakest(self):
        """Remove the lowest-ELO bot when pool is over capacity."""
        if len(self.bots) <= self.max_pool_size:
            return
        weakest = min(self.bots.keys(), key=lambda b: self.bots[b]["elo"])
        # Never evict baseline_001
        if weakest == "baseline_001" and len(self.bots) > 1:
            ranked = self.get_ranked_bots()
            weakest = ranked[-1] if ranked[-1] != "baseline_001" else ranked[-2]
        bot_path = self.bots_dir / weakest
        if bot_path.exists():
            shutil.rmtree(bot_path)
        del self.bots[weakest]
        self._save()
        print(f"[pool] Evicted {weakest} (pool over capacity).")

    def admit_candidate(self, candidate_dir: Path, bot_id: str,
                        parent_id: str = None, task_desc: str = "",
                        match_results: list = None) -> bool:
        """
        Evaluate a candidate against the pool and admit if strong enough.

        match_results: list of MatchResult.to_dict() from gauntlet vs pool members.
        Admission criteria: win_rate > 0.5 OR beats the current top-ELO bot.
        """
        if match_results is None or len(match_results) == 0:
            print("[pool] No match results — cannot evaluate candidate.")
            return False

        wins = sum(1 for r in match_results if r.get("winner") == 0)
        draws = sum(1 for r in match_results if r.get("winner") is None)
        total = len(match_results)
        win_rate = (wins + 0.5 * draws) / total

        top_bot_match = next(
            (r for r in match_results if r.get("bot1_name") == self.get_ranked_bots()[0]),
            None
        )
        beats_top = top_bot_match is not None and top_bot_match.get("winner") == 0

        admitted = win_rate > 0.5 or beats_top
        print(f"[pool] Candidate {bot_id}: win_rate={win_rate:.2f} beats_top={beats_top} → {'ADMIT' if admitted else 'REJECT'}")

        if admitted:
            self.admit_bot(candidate_dir, bot_id, parent_id, task_desc)
            self.evict_weakest()

        return admitted

    def print_rankings(self):
        print(f"\n{'Rank':<5} {'Bot ID':<30} {'ELO':>7} {'W':>5} {'L':>5} {'D':>5} {'GP':>5}")
        print("-" * 70)
        for i, bot_id in enumerate(self.get_ranked_bots(), 1):
            b = self.bots[bot_id]
            print(f"{i:<5} {bot_id:<30} {b['elo']:>7.1f} {b.get('wins',0):>5} "
                  f"{b.get('losses',0):>5} {b.get('draws',0):>5} {b.get('matches_played',0):>5}")
        print()


# ── CLI ───────────────────────────────────────────────────────────────────────

def _gauntlet_cmd(args):
    """Run candidate vs all pool members and report admission decision."""
    from bot_testing import run_match

    pool = TournamentPool()
    candidate_dir = Path(args.candidate).resolve()
    if not candidate_dir.exists():
        print(f"[error] Candidate directory not found: {candidate_dir}")
        sys.exit(1)

    bot_id = args.id or candidate_dir.name
    results = []
    for pool_bot_id in pool.get_ranked_bots():
        pool_bot_dir = pool.bot_dir(pool_bot_id)
        print(f"[gauntlet] {bot_id} vs {pool_bot_id} ...", end=" ", flush=True)
        result = run_match(candidate_dir, pool_bot_dir, duration=args.duration)
        print(f"winner={result.winner} ({result.winner_method})")
        results.append(result.to_dict())

    admitted = pool.admit_candidate(
        candidate_dir, bot_id, parent_id=args.parent,
        task_desc=args.notes or "", match_results=results
    )
    if admitted:
        pool.print_rankings()
    return admitted


def _rankings_cmd(_args):
    TournamentPool().print_rankings()


def _admit_cmd(args):
    pool = TournamentPool()
    src = Path(args.candidate).resolve()
    bot_id = args.id or src.name
    pool.admit_bot(src, bot_id, parent_id=args.parent, notes=args.notes or "")
    print(f"[pool] Admitted {bot_id}.")
    pool.print_rankings()


def main():
    p = argparse.ArgumentParser(description="MetalBot tournament pool manager")
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gauntlet", help="Run candidate vs pool and decide admission")
    g.add_argument("--candidate", required=True, help="Path to candidate bot directory")
    g.add_argument("--id",        default=None,  help="Bot ID to register under (default: dir name)")
    g.add_argument("--parent",    default=None,  help="Parent bot ID this was derived from")
    g.add_argument("--notes",     default="",    help="Short description of changes")
    g.add_argument("--duration",  type=int, default=300, help="Match duration seconds")
    g.set_defaults(func=_gauntlet_cmd)

    r = sub.add_parser("rankings", help="Print current ELO rankings")
    r.set_defaults(func=_rankings_cmd)

    a = sub.add_parser("admit", help="Admit a bot directly without gauntlet")
    a.add_argument("--candidate", required=True)
    a.add_argument("--id",        default=None)
    a.add_argument("--parent",    default=None)
    a.add_argument("--notes",     default="")
    a.set_defaults(func=_admit_cmd)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
