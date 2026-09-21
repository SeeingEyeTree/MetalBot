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
import tempfile
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

def _archive_tournament_match(result_dict: dict, bot0_id: str, bot1_id: str, match_start: float) -> None:
    """
    Save this gauntlet match's result JSON + replay to the USB flash drive
    plugged into iamtree (Pi 2). Tournament games are kept regardless of
    whether the match ran locally or on a Pi -- iamtree's USB is the single
    archive location (see remote_testing.archive_to_iamtree).

    Fails soft: a missing Tailscale connection on this machine prints a
    warning (via archive_to_iamtree) but never blocks the gauntlet.
    """
    from remote_testing import archive_to_iamtree, DEFAULT_PI_KEY
    from bot_testing import BAR_DATA_DIR

    timestamp = result_dict.get("timestamp", datetime.now(timezone.utc).isoformat()).replace(":", "-")
    result_json_path = Path(tempfile.gettempdir()) / f"tourney_{bot0_id}_vs_{bot1_id}_{timestamp}.json"
    result_json_path.write_text(json.dumps(result_dict, indent=2), encoding="utf-8")

    replay_path = None
    demos_dir = BAR_DATA_DIR / "demos"
    if demos_dir.is_dir():
        fresh = [p for p in demos_dir.glob("*.sdfz") if p.stat().st_mtime >= match_start]
        if fresh:
            replay_path = max(fresh, key=lambda p: p.stat().st_mtime)

    archive_to_iamtree(DEFAULT_PI_KEY, [result_json_path, replay_path],
                       "metalbot_results", subdir="tournament")


def _gauntlet_cmd(args):
    """Run candidate vs all pool members and report admission decision."""
    import time
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
        match_start = time.time()
        result = run_match(candidate_dir, pool_bot_dir, duration=args.duration,
                           save_replay=not args.no_archive)
        print(f"winner={result.winner} ({result.winner_method})")
        results.append(result.to_dict())

        if not args.no_archive:
            _archive_tournament_match(result.to_dict(), bot_id, pool_bot_id, match_start)

    admitted = pool.admit_candidate(
        candidate_dir, bot_id, parent_id=args.parent,
        task_desc=args.notes or "", match_results=results
    )
    if admitted:
        pool.print_rankings()
    return admitted


def _reachable_pis(pi_key: str) -> list:
    """Return [(host, user), ...] for every Pi that answers SSH right now."""
    from remote_testing import _ssh_reachable, PI_HOSTS, PI_USERS

    pis = []
    for host in PI_HOSTS:
        user = PI_USERS[host]
        if _ssh_reachable(host, user, pi_key):
            pis.append((host, user))
        else:
            print(f"[gauntlet-all] {user}@{host} not reachable over Tailscale, skipping")
    return pis


def _run_remote_match(bot0_dir: Path, bot1_dir: Path, pi_host: str, pi_user: str,
                       pi_key: str, duration: int, save_replay: bool) -> dict:
    """Run one bot-vs-bot match on a remote Pi and return a MatchResult-shaped dict.

    Mirrors remote_testing.main()'s single-match flow (sync -> run -> fetch
    replay -> archive to iamtree's USB) but returns the result dict instead of
    printing a summary, so the caller can feed it into pool admission logic.
    """
    from remote_testing import RemoteTestConfig, sync_bots_to_pi, run_remote_test, \
        fetch_latest_replay, archive_to_iamtree, DEFAULT_USB_MOUNT

    config = RemoteTestConfig(
        pi_host=pi_host, pi_user=pi_user, pi_key=pi_key,
        bot1_dir=bot0_dir, bot2_dir=bot1_dir,
        duration=duration, save_replay=save_replay,
        usb_mount=DEFAULT_USB_MOUNT, result_dir="metalbot_results",
        remote_repo="~/MetalBot", skip_deploy=False,
        map_name="Full Metal Plate 1.7",
        bar_data_dir=f"/home/{pi_user}/bar_data",
    )

    if not sync_bots_to_pi(config):
        raise RuntimeError(f"Failed to sync bots to {pi_user}@{pi_host}")

    result = run_remote_test(config)
    if not result:
        raise RuntimeError(f"Match on {pi_user}@{pi_host} produced no result")

    if save_replay:
        replay_local = fetch_latest_replay(config)
        timestamp = result.get("timestamp", _now()).replace(":", "-")
        bot0_name = result.get("bot0_name", "bot0")
        bot1_name = result.get("bot1_name", "bot1")
        result_json_path = Path(tempfile.gettempdir()) / f"tourney_{bot0_name}_vs_{bot1_name}_{timestamp}.json"
        result_json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        archive_to_iamtree(pi_key, [result_json_path, replay_local],
                           "metalbot_results", subdir="tournament")

    return result


def _gauntlet_all_cmd(args):
    """Run gauntlet for every candidate dir in order, running each candidate's
    matches concurrently -- one per reachable Pi at a time -- so total wall
    time scales down as more Pis become available. Refuses to fall back to
    running locally.

    Candidates are still processed one at a time, in order: a candidate's
    admission decision depends on all of its own matches finishing first, and
    later candidates' opponent lists depend on who got admitted before them.
    Only the matches *within* one candidate's gauntlet (vs each current pool
    bot) are independent of each other, so those are what run in parallel.
    """
    import queue
    import concurrent.futures
    from remote_testing import DEFAULT_PI_KEY

    pi_key = args.pi_key or DEFAULT_PI_KEY
    candidates_dir = Path(args.candidates_dir).resolve()
    candidate_dirs = sorted(p for p in candidates_dir.iterdir() if p.is_dir())
    if args.only:
        wanted = {name.strip() for name in args.only.split(",") if name.strip()}
        candidate_dirs = [p for p in candidate_dirs if p.name in wanted]
        missing = wanted - {p.name for p in candidate_dirs}
        if missing:
            print(f"[error] --only named candidates not found in {candidates_dir}: {', '.join(sorted(missing))}")
            sys.exit(1)
    if not candidate_dirs:
        print(f"[error] No candidate directories found in {candidates_dir}")
        sys.exit(1)

    pis = _reachable_pis(pi_key)
    if args.pi_host:
        pis = [(host, user) for host, user in pis if host == args.pi_host]
        if not pis:
            sys.exit(f"[error] {args.pi_host} is not reachable over Tailscale.")
    if not pis:
        sys.exit("[error] Neither Pi is reachable over Tailscale -- refusing to run locally.")
    if len(pis) == 1:
        host, user = pis[0]
        print(f"[gauntlet-all] Only {user}@{host} is reachable -- matches will run there one at a time.")
    else:
        print(f"[gauntlet-all] Running up to {len(pis)} matches at once across: " +
              ", ".join(f"{u}@{h}" for h, u in pis))

    # A queue of free Pis doubles as the concurrency limiter: a worker blocks
    # on get() until a Pi is free, and only returns it with put() when its
    # match (sync + run + fetch + archive) is fully done -- so a given Pi
    # never runs two matches at once, and adding more Pis to this queue is
    # the entire scale-up path.
    free_pis = queue.Queue()
    for pi in pis:
        free_pis.put(pi)

    def run_one(candidate_dir, bot_id, pool_bot_id, pool_bot_dir):
        host, user = free_pis.get()
        try:
            print(f"[gauntlet-all] {bot_id} vs {pool_bot_id} on {user}@{host} ...")
            result = _run_remote_match(candidate_dir, pool_bot_dir, host, user, pi_key,
                                       args.duration, not args.no_archive)
            print(f"  [{bot_id} vs {pool_bot_id}] winner={result.get('winner')} ({result.get('winner_method')})")
            return result
        finally:
            free_pis.put((host, user))

    pool = TournamentPool()
    for candidate_dir in candidate_dirs:
        bot_id = candidate_dir.name
        print(f"\n=== Gauntlet: {bot_id} ===")
        opponents = pool.get_ranked_bots()
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(pis)) as ex:
            futures = [
                ex.submit(run_one, candidate_dir, bot_id, pool_bot_id, pool.bot_dir(pool_bot_id))
                for pool_bot_id in opponents
            ]
            results = [f.result() for f in concurrent.futures.as_completed(futures)]

        admitted = pool.admit_candidate(
            candidate_dir, bot_id, parent_id=args.parent,
            task_desc=args.notes or "", match_results=results
        )
        if admitted:
            pool.print_rankings()


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
    g.add_argument("--duration",  type=int, default=400, help="Match duration seconds")
    g.add_argument("--no-archive", action="store_true",
                   help="Don't save replays/results to iamtree's USB flash drive")
    g.set_defaults(func=_gauntlet_cmd)

    ga = sub.add_parser("gauntlet-all",
                        help="Run gauntlet for every candidate dir, distributing matches across all reachable Pis")
    ga.add_argument("--candidates-dir", default="candidates", help="Directory containing candidate bot folders")
    ga.add_argument("--only", default=None,
                    help="Comma-separated candidate dir names to test, skipping the rest (default: all)")
    ga.add_argument("--duration",  type=int, default=400, help="Match duration seconds")
    ga.add_argument("--pi-host",   default=None, help="Restrict to a single Pi's Tailscale IP (e.g. to avoid an unhealthy Pi)")
    ga.add_argument("--pi-key",    default=None, help="SSH private key path (default: ~/.ssh/id_ed25519_nopass)")
    ga.add_argument("--parent",    default=None, help="Parent bot ID recorded for all admitted candidates")
    ga.add_argument("--notes",     default="",   help="Short description recorded for all admitted candidates")
    ga.add_argument("--no-archive", action="store_true",
                    help="Don't save replays/results to iamtree's USB flash drive")
    ga.set_defaults(func=_gauntlet_all_cmd)

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
