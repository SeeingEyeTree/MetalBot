#!/usr/bin/env python3
"""
remote_testing.py  -  Run bot-vs-bot tests on remote Pis via Tailscale SSH.

Extends bot_testing.py with:
  - Remote execution over Tailscale (no local BAR data required)
  - Guaranteed archival to the USB flash drive plugged into iamtree (Pi 2) --
    regardless of which Pi actually ran the match. Pi 1 (dme43) has no USB
    drive attached, so results from a Pi-1 run are fetched back to this
    machine and relayed on to iamtree rather than left stranded on Pi 1.
  - Automatic result + replay collection

Usage:
    python remote_testing.py --bot1 PATH --bot2 PATH [--pi-host TAILSCALE_IP] [options]

Arguments:
    --bot1 PATH           Folder with team-0 bot .lua widgets
    --bot2 PATH           Folder with team-1 bot .lua widgets
    --pi-host IP/HOST     Tailscale IP or hostname (e.g., 100.86.20.115 or 100.68.112.80).
                          Omit this to auto-pick: tries pi1 then pi2, using whichever is
                          reachable and not already mid-match (see pick_available_pi()).
                          Basic load balancing only -- no queue, no locking.

Options:
    --pi-user USER        SSH username (default: dme43 for Pi 1, iamtree for Pi 2)
    --pi-key PATH         SSH private key (default: ~/.ssh/id_ed25519_nopass)
    --duration SECS       Run for this many real seconds then kill (default: 300)
    --save-replay         Keep the .sdfz replay file and archive it to iamtree's USB
    --usb-mount MOUNT     USB mount path on iamtree (default: /mnt/usb)
    --result-dir DIR      Save results under this relative path on iamtree's USB
    --remote-repo PATH    Path to MetalBot repo on the Pi running the match (default: ~/MetalBot)
    --skip-deploy         Don't re-sync bot files to the Pi
    --no-archive          Don't copy results/replay to iamtree's USB flash drive
    --map NAME            Map name (default: Full Metal Plate 1.7)

NOTE: this machine (the one running this script) must itself be joined to the
same Tailscale network as the Pis. Installing Tailscale only on the Pis is not
enough -- direct-IP SSH to a 100.x.x.x address only resolves from a device
that is itself on the tailnet.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

# Windows consoles often default to a legacy codepage (cp1252) that can't
# encode the checkmark/warning glyphs used in status messages below, which
# would otherwise crash mid-archive with a raw UnicodeEncodeError. Force
# UTF-8 with a safe fallback so status output never takes down the run.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

# Confirmed 2026-09-15 by direct SSH test -- an earlier version of this file
# had these two swapped, which caused persistent "Permission denied" errors
# (each key was being tried against the wrong Pi's user account).
TAILSCALE_IPS = {
    "pi1": "100.68.112.80",    # dme43@192.168.1.170  (repo + bar_data present)
    "pi2": "100.86.20.115",    # iamtree@192.168.1.172 (has the USB drive + repo + bar_data)
}

PI_USERS = {
    "100.68.112.80": "dme43",
    "100.86.20.115": "iamtree",
}

# Preference order for auto-pick load balancing: try pi1 first, then pi2.
PI_HOSTS = [TAILSCALE_IPS["pi1"], TAILSCALE_IPS["pi2"]]

# Pi 2 (iamtree) is the only Pi with a USB flash drive attached. All archival
# -- regardless of which Pi actually ran the match -- targets this Pi.
# Both Pis can run matches (iamtree provisioned 2026-09-15 by streaming a
# tar of dme43's ~/bar_data + ~/MetalBot directly Pi-to-Pi over Tailscale;
# both are aarch64 Debian 12, so the engine binaries needed no changes).
IAMTREE_HOST = "100.86.20.115"
IAMTREE_USER = "iamtree"
# /mnt/usb is the conventional mount point, but as of 2026-09-15 the drive is
# actually auto-mounted at /media/iamtree/<label> instead. _resolve_usb_mount()
# checks both so this keeps working if it's ever remounted at /mnt/usb later.
DEFAULT_USB_MOUNT = "/mnt/usb"
DEFAULT_PI_KEY = os.path.expanduser("~/.ssh/id_ed25519_nopass")


@dataclass
class RemoteTestConfig:
    """Configuration for a remote test run."""
    pi_host: str              # Tailscale IP or hostname of the Pi running the match
    pi_user: str              # SSH username for pi_host
    pi_key: str               # Path to SSH private key (used for pi_host AND iamtree)
    bot1_dir: Path            # Local path to bot 1
    bot2_dir: Path            # Local path to bot 2
    duration: int             # Test duration in seconds
    save_replay: bool         # Keep + archive replay file
    usb_mount: str            # USB mount path on iamtree
    result_dir: str           # Relative path on iamtree's USB for results
    remote_repo: str          # Path to repo on pi_host
    skip_deploy: bool         # Skip syncing bot files
    map_name: str             # Game map name
    bar_data_dir: str         # BAR data dir on pi_host


def _ssh_reachable(host: str, user: str, pi_key: str, timeout: int = 6) -> bool:
    """Quick reachability check so a missing/disconnected Tailscale client fails
    fast with a clear message instead of hanging on every subsequent command."""
    cmd = (
        f'ssh -i "{pi_key}" -o ConnectTimeout={timeout} -o BatchMode=yes '
        f'-o StrictHostKeyChecking=accept-new {user}@{host} "echo ok"'
    )
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                timeout=timeout + 4)
        return result.returncode == 0 and "ok" in result.stdout
    except subprocess.TimeoutExpired:
        return False


def _pi_busy(host: str, user: str, pi_key: str, timeout: int = 8) -> bool:
    """Is this Pi already mid-match? Looks for the orchestrating bot_testing.py
    process or either engine binary it launches. Just a presence check, no
    queueing/locking -- good enough for "pick whichever Pi is free right now"."""
    cmd = (
        f'ssh -i "{pi_key}" -o ConnectTimeout={timeout} -o BatchMode=yes '
        f'-o StrictHostKeyChecking=accept-new {user}@{host} '
        f'"pgrep -f \'bot_testing.py|spring-headless|spring-dedicated\' '
        f'>/dev/null 2>&1 && echo BUSY || echo FREE"'
    )
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                timeout=timeout + 4)
        return "BUSY" in result.stdout
    except subprocess.TimeoutExpired:
        # Unknown is treated as free -- if the Pi is actually unreachable,
        # the separate _ssh_reachable() check will catch that instead.
        return False


def pick_available_pi(pi_key: str) -> "tuple[str, str] | None":
    """Very basic load balancing: try pi1 then pi2, use whichever is reachable
    AND not already running a match. If both are reachable but busy, queue on
    the first one rather than giving up. Returns None only if neither Pi
    answers SSH at all, so the caller can fall back to running locally."""
    order = [(host, PI_USERS[host]) for host in PI_HOSTS]
    reachable = []
    for host, user in order:
        if not _ssh_reachable(host, user, pi_key):
            print(f"⊘ {user}@{host} not reachable over Tailscale, skipping")
            continue
        reachable.append((host, user))
        if not _pi_busy(host, user, pi_key):
            print(f"✓ {user}@{host} is free -- using it")
            return (host, user)
        print(f"⏳ {user}@{host} is busy running a match, trying next")

    if reachable:
        host, user = reachable[0]
        print(f"⚠ All reachable Pis are busy -- queuing on {user}@{host} anyway")
        return (host, user)

    return None


def sync_bots_to_pi(config: RemoteTestConfig) -> bool:
    """
    Copy bot files to the Pi via scp. Only syncs if --skip-deploy not set.

    Uses scp rather than rsync -- rsync isn't available on a stock Windows
    install (confirmed 2026-09-15: absent from both the Windows PATH and Git
    Bash's bundled tools). Each bot dir is removed and recreated remotely
    before the copy so a stale file from a previously-synced bot can't
    linger (the closest practical equivalent to `rsync --delete` for these
    small, flat 3-4 file bot folders).
    """
    if config.skip_deploy:
        print("⊘ Skipping bot sync (--skip-deploy)")
        return True

    print(f"Syncing bots to {config.pi_user}@{config.pi_host}:{config.remote_repo}...")

    for local_dir, remote_name in [(config.bot1_dir, "bot1"), (config.bot2_dir, "bot2")]:
        remote_path = f"{config.remote_repo}/{remote_name}"
        # remote_path must NOT exist before the scp -r below: when the
        # destination is absent, scp creates it populated with local_dir's
        # *contents*; when it already exists, scp nests local_dir itself
        # inside it instead. Removing first guarantees the former.
        clear_cmd = (
            f'ssh -i "{config.pi_key}" -o StrictHostKeyChecking=accept-new '
            f'{config.pi_user}@{config.pi_host} '
            f'"mkdir -p {config.remote_repo} && rm -rf {remote_path}"'
        )
        try:
            r = subprocess.run(clear_cmd, shell=True, timeout=20)
            if r.returncode != 0:
                print(f"✗ Failed to prep remote dir {remote_path}")
                return False
        except subprocess.TimeoutExpired:
            print(f"✗ Timeout preparing remote dir {remote_path}")
            return False

        scp_cmd = (
            f'scp -r -o StrictHostKeyChecking=accept-new -i "{config.pi_key}" '
            f'"{local_dir}" {config.pi_user}@{config.pi_host}:{remote_path}'
        )
        try:
            r = subprocess.run(scp_cmd, shell=True, timeout=60)
            if r.returncode != 0:
                print(f"✗ Failed to copy {local_dir} -> {remote_path}")
                return False
        except subprocess.TimeoutExpired:
            print(f"✗ scp timeout copying {local_dir}")
            return False

    print("✓ Bots synced successfully")
    return True


def run_remote_test(config: RemoteTestConfig) -> dict:
    """Execute bot_testing.py on the remote Pi and collect the result JSON."""
    result_file = "/tmp/metalbot_result.json"

    test_cmd = (
        f"cd {config.remote_repo} && "
        f"BAR_DATA_DIR={config.bar_data_dir} "
        f"python3 bot_testing.py "
        f"--bot1 bot1 --bot2 bot2 "
        f"--duration {config.duration} "
        f"{'--save-replay ' if config.save_replay else ''}"
        f"--map '{config.map_name}' "
        f"--save-result {result_file}"
    )

    ssh_cmd = (
        f'ssh -i "{config.pi_key}" -o StrictHostKeyChecking=accept-new '
        f'{config.pi_user}@{config.pi_host} '
        f'"{test_cmd}"'
    )

    print(f"\n{'='*60}")
    print(f"Running test on {config.pi_host}...")
    print(f"Bot 1: {config.bot1_dir.name}")
    print(f"Bot 2: {config.bot2_dir.name}")
    print(f"Duration: {config.duration}s")
    print(f"{'='*60}\n")

    try:
        result = subprocess.run(ssh_cmd, shell=True, timeout=config.duration + 120)
        if result.returncode != 0:
            print(f"✗ Test failed with exit code {result.returncode}")
            return {}
    except subprocess.TimeoutExpired:
        print("✗ Test timed out")
        return {}

    print("\nFetching results from Pi...")
    local_result = Path(tempfile.gettempdir()) / "metalbot_result_temp.json"
    fetch_cmd = (
        f'scp -i "{config.pi_key}" -o StrictHostKeyChecking=accept-new '
        f'{config.pi_user}@{config.pi_host}:{result_file} '
        f'"{local_result}"'
    )

    try:
        result = subprocess.run(fetch_cmd, shell=True, timeout=30)
        if result.returncode == 0 and local_result.exists():
            data = json.loads(local_result.read_text())
            print("✓ Results retrieved successfully")
            local_result.unlink()
            return data
    except subprocess.TimeoutExpired:
        print("✗ scp timeout when fetching results")
    except json.JSONDecodeError:
        print("✗ Failed to parse result.json")

    return {}


def fetch_latest_replay(config: RemoteTestConfig) -> "Path | None":
    """Find and download the most recently created .sdfz replay from the Pi
    that actually ran the match (which may not be iamtree).

    BAR replay filenames embed the map name (e.g. "...Full Metal Plate
    1.7...sdfz"), which breaks naive shell-string scp commands run through
    Windows cmd.exe -- the space gets word-split somewhere across the
    local-shell/ssh/remote-shell boundary. Using list-form subprocess calls
    (no shell=True locally) plus shlex.quote() for the remote-side path
    avoids that: argv list elements aren't re-split by cmd.exe. shlex.quote()
    is used ONLY for the `ssh ... "shell command"` argument below (a real
    remote shell parses that string). It must NOT be used on scp's remote
    PATH argument: modern OpenSSH scp (9.0+) defaults to the SFTP protocol,
    which has no remote shell in the loop for the transfer itself and takes
    the path completely literally -- shell-quote characters there become
    part of the (nonexistent) filename SFTP looks for, producing a
    misleading "No such file or directory". List-form subprocess already
    keeps the raw path intact as one argv element, which is all either
    scp backend needs.
    """
    demos_dir = f"{config.bar_data_dir}/demos"
    find_cmd = [
        "ssh", "-i", config.pi_key, "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        f"{config.pi_user}@{config.pi_host}",
        f"ls -t {shlex.quote(demos_dir)}/*.sdfz 2>/dev/null | head -1",
    ]
    try:
        result = subprocess.run(find_cmd, capture_output=True, text=True, timeout=15)
        remote_path = result.stdout.strip()
        if not remote_path:
            print("⚠ No replay file found on Pi")
            return None
        local_path = Path(tempfile.gettempdir()) / Path(remote_path).name
        fetch_cmd = [
            "scp", "-i", config.pi_key, "-o", "StrictHostKeyChecking=accept-new",
            f"{config.pi_user}@{config.pi_host}:{remote_path}",
            str(local_path),
        ]
        r2 = subprocess.run(fetch_cmd, timeout=90)
        if r2.returncode == 0 and local_path.exists():
            return local_path
    except subprocess.TimeoutExpired:
        print("✗ Timeout fetching replay from Pi")
    return None


def _resolve_usb_mount(pi_key: str, preferred: str = DEFAULT_USB_MOUNT) -> str:
    """
    Find where the USB flash drive is actually mounted on iamtree.

    Prefers the conventional `preferred` path (/mnt/usb), but as of 2026-09-15
    the drive is auto-mounted by udisks2 at /media/iamtree/<label> instead
    (a plain `mkdir -p /mnt/usb` there would silently create a folder on the
    SD card rather than the flash drive). Falls back to `preferred` if neither
    is found, so callers still get a sensible path to try.
    """
    check_cmd = (
        f'ssh -i "{pi_key}" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new '
        f'{IAMTREE_USER}@{IAMTREE_HOST} '
        f'"mountpoint -q {preferred} 2>/dev/null && echo {preferred} || '
        f'ls -d /media/{IAMTREE_USER}/*/ 2>/dev/null | head -1"'
    )
    try:
        result = subprocess.run(check_cmd, shell=True, capture_output=True, text=True, timeout=12)
        found = result.stdout.strip().rstrip("/")
        if found:
            return found
    except subprocess.TimeoutExpired:
        pass
    return preferred


def archive_to_iamtree(pi_key: str, files: list, result_dir: str,
                       subdir: str = "", usb_mount: str = DEFAULT_USB_MOUNT) -> bool:
    """
    Copy local files (result JSON, .sdfz replay, etc.) to the USB flash drive
    plugged into iamtree (Pi 2). This is the single guaranteed archive location
    for all test and tournament results, regardless of which Pi actually ran
    the match or whether it ran locally -- Pi 1 (dme43) has no USB attached.

    Fails soft: if iamtree isn't reachable (e.g. this machine isn't on the
    tailnet), prints a warning and returns False rather than raising.
    """
    files = [Path(f) for f in files if f]
    if not files:
        return False

    if not _ssh_reachable(IAMTREE_HOST, IAMTREE_USER, pi_key):
        print(f"⚠ iamtree ({IAMTREE_HOST}) not reachable over Tailscale -- skipping USB archive.")
        print("  (This machine must itself be joined to the tailnet, not just the Pis.)")
        return False

    usb_mount = _resolve_usb_mount(pi_key, usb_mount)
    remote_dir = f"{usb_mount}/{result_dir}"
    if subdir:
        remote_dir = f"{remote_dir}/{subdir}"

    mkdir_cmd = [
        "ssh", "-i", pi_key, "-o", "StrictHostKeyChecking=accept-new",
        f"{IAMTREE_USER}@{IAMTREE_HOST}", f"mkdir -p {shlex.quote(remote_dir)}",
    ]
    subprocess.run(mkdir_cmd, timeout=15)

    ok = True
    for f in files:
        # Replay filenames embed the map name and contain spaces (e.g.
        # "...Full Metal Plate 1.7...sdfz"). List-form subprocess (no
        # shell=True) keeps this intact as one argv element for both the
        # local and remote side -- do NOT shlex.quote() the remote path:
        # modern scp defaults to the SFTP protocol, which takes it
        # literally with no remote shell involved (see fetch_latest_replay).
        remote_path = f"{remote_dir}/{f.name}"
        scp_cmd = [
            "scp", "-i", pi_key, "-o", "StrictHostKeyChecking=accept-new",
            str(f), f"{IAMTREE_USER}@{IAMTREE_HOST}:{remote_path}",
        ]
        r = subprocess.run(scp_cmd, timeout=90)
        if r.returncode == 0:
            print(f"✓ Archived to iamtree USB: {remote_path}")
        else:
            print(f"✗ Failed to archive {f.name} to iamtree USB")
            ok = False
    return ok


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bot1", required=True, metavar="PATH", help="Team-0 bot folder")
    p.add_argument("--bot2", required=True, metavar="PATH", help="Team-1 bot folder")
    p.add_argument("--pi-host", help="Tailscale IP or hostname (e.g., 100.86.20.115). "
                   "Omit to auto-pick whichever Pi is reachable and free (basic load balancing).")
    p.add_argument("--pi-user", help="SSH username (auto-detected from --pi-host if not set)")
    p.add_argument("--pi-key", default=DEFAULT_PI_KEY, help="SSH private key path")
    p.add_argument("--duration", type=int, default=400, help="Test duration in seconds")
    p.add_argument("--save-replay", action="store_true",
                   help="Keep the replay and archive it to iamtree's USB")
    p.add_argument("--usb-mount", default=DEFAULT_USB_MOUNT, help="USB mount path on iamtree")
    p.add_argument("--result-dir", default="metalbot_results",
                   help="Relative path on iamtree's USB for storing results")
    p.add_argument("--remote-repo", default="~/MetalBot",
                   help="Path to MetalBot repo on the Pi running the match")
    p.add_argument("--skip-deploy", action="store_true",
                   help="Don't re-sync bot files to the Pi")
    p.add_argument("--no-archive", action="store_true",
                   help="Don't copy results/replay to iamtree's USB flash drive")
    p.add_argument("--map", default="Full Metal Plate 1.7", dest="map_name")
    p.add_argument("--bar-data-dir", default="/home/{user}/bar_data",
                   help="BAR data directory on the Pi running the match (use {user} placeholder)")

    args = p.parse_args()

    bot1_dir = Path(args.bot1).resolve()
    bot2_dir = Path(args.bot2).resolve()
    for d, label in [(bot1_dir, "--bot1"), (bot2_dir, "--bot2")]:
        if not d.is_dir():
            sys.exit(f"{label}: folder not found: {d}")

    if args.pi_host:
        pi_host = args.pi_host
        pi_user = args.pi_user or PI_USERS.get(args.pi_host, "iamtree")
        print("\n" + "="*60)
        print(f"STEP 1: Checking {pi_host} is reachable")
        print("="*60)
        if not _ssh_reachable(pi_host, pi_user, args.pi_key):
            sys.exit(
                f"✗ Cannot reach {pi_user}@{pi_host} over Tailscale.\n"
                f"  Check that (a) this machine is joined to the same tailnet as the Pis,\n"
                f"  (b) the Pi is powered on and tailscaled up, and (c) the SSH key at\n"
                f"  {args.pi_key} is authorized on that Pi."
            )
        print(f"✓ {pi_host} reachable")
    else:
        print("\n" + "="*60)
        print("STEP 1: Picking an available Pi (basic load balancing)")
        print("="*60)
        picked = pick_available_pi(args.pi_key)
        if not picked:
            sys.exit(
                "✗ Neither Pi is reachable over Tailscale.\n"
                "  Check that this machine is joined to the tailnet and both Pis are\n"
                "  powered on and tailscaled up."
            )
        pi_host, pi_user = picked
        if args.pi_user:
            pi_user = args.pi_user

    bar_data_dir = args.bar_data_dir.format(user=pi_user)

    config = RemoteTestConfig(
        pi_host=pi_host,
        pi_user=pi_user,
        pi_key=args.pi_key,
        bot1_dir=bot1_dir,
        bot2_dir=bot2_dir,
        duration=args.duration,
        save_replay=args.save_replay,
        usb_mount=args.usb_mount,
        result_dir=args.result_dir,
        remote_repo=args.remote_repo,
        skip_deploy=args.skip_deploy,
        map_name=args.map_name,
        bar_data_dir=bar_data_dir,
    )

    print("\n" + "="*60)
    print("STEP 2: Syncing bot files to Pi")
    print("="*60)
    if not sync_bots_to_pi(config):
        sys.exit("Failed to sync bot files")

    print("\n" + "="*60)
    print("STEP 3: Running test on Pi")
    print("="*60)
    result = run_remote_test(config)
    if not result:
        sys.exit("Test failed or produced no results")

    replay_local = None
    if config.save_replay:
        print("\n" + "="*60)
        print("STEP 4: Fetching replay from Pi")
        print("="*60)
        replay_local = fetch_latest_replay(config)

    if not args.no_archive:
        print("\n" + "="*60)
        print("STEP 5: Archiving to iamtree's USB flash drive")
        print("="*60)
        timestamp = result.get("timestamp", datetime.now().isoformat()).replace(":", "-")
        bot0 = result.get("bot0_name", "bot0")
        bot1 = result.get("bot1_name", "bot1")
        result_json_path = Path(tempfile.gettempdir()) / f"result_{bot0}_vs_{bot1}_{timestamp}.json"
        result_json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        archive_to_iamtree(
            config.pi_key,
            [result_json_path, replay_local],
            config.result_dir,
            usb_mount=config.usb_mount,
        )

    print("\n" + "="*60)
    print("TEST COMPLETE")
    print("="*60)
    print(f"Winner: Team {result.get('winner')}")
    print(f"Bot 0 units: {result.get('units_built', {}).get('0', '?')}")
    print(f"Bot 1 units: {result.get('units_built', {}).get('1', '?')}")


if __name__ == "__main__":
    main()
