"""
agent_harness.py  —  Claude API agent runner for MetalBot bot generation.

The agent is given a specific sub-task (tune parameters, improve a component,
invent a new algorithm, etc.) and tools to write Lua files, check syntax, and
read existing code.  It works on a candidate copy of a baseline bot so the
original is never modified.

Usage:
    python agent_harness.py --task tune_parameters --component lab_controller.lua --baseline baseline_001
    python agent_harness.py --task improve_component --component macro_controller.lua --baseline baseline_001
    python agent_harness.py --task post_match_analysis --result-file results/last.json --baseline baseline_001

Environment:
    ANTHROPIC_API_KEY  — required
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path

import anthropic

REPO_DIR       = Path(__file__).parent
POOL_DIR       = REPO_DIR / "pool"
BOTS_DIR       = POOL_DIR / "bots"
CANDIDATES_DIR = REPO_DIR / "candidates"
KNOWLEDGE_DIR  = REPO_DIR / "knowledge"
FRAMEWORK_DIR  = REPO_DIR / "bar_framework"
STRATEGY_LOG   = KNOWLEDGE_DIR / "strategy_log.jsonl"

MODEL          = "claude-opus-4-7"
MAX_TOKENS     = 8192
MAX_ITERATIONS = 10  # agent loop cap


class TaskType(str, Enum):
    TUNE_PARAMETERS    = "tune_parameters"
    IMPROVE_COMPONENT  = "improve_component"
    NEW_ALGORITHM      = "new_algorithm"
    POST_MATCH_ANALYSIS = "post_match_analysis"
    FRAMEWORK_FUNCTION = "framework_function"


# ── Knowledge loading ─────────────────────────────────────────────────────────

def _read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def _recent_strategy_log(n: int = 20) -> str:
    if not STRATEGY_LOG.exists():
        return "(no entries yet)"
    lines = STRATEGY_LOG.read_text(encoding="utf-8").strip().splitlines()
    recent = lines[-n:] if len(lines) > n else lines
    return "\n".join(recent) if recent else "(no entries yet)"


def _build_system_prompt(task_type: TaskType, component: str,
                         candidate_dir: Path, match_result_json: str = "") -> str:
    game_mechanics = _read_file(KNOWLEDGE_DIR / "game_mechanics.md")
    framework_api  = _read_file(KNOWLEDGE_DIR / "framework_api.md")
    lessons        = _read_file(KNOWLEDGE_DIR / "lessons_learned.md")
    component_src  = _read_file(candidate_dir / component)
    strategy_log   = _recent_strategy_log(20)

    task_instructions = {
        TaskType.TUNE_PARAMETERS: """\
Your task is TUNE_PARAMETERS.
Adjust numeric constants and thresholds in the target component to improve performance.
Do NOT restructure the logic — only change values.
Examples: build ratios, timing thresholds, resource stall fractions, unit counts.""",

        TaskType.IMPROVE_COMPONENT: """\
Your task is IMPROVE_COMPONENT.
Rewrite or substantially improve ONE controller file (the target component).
You may restructure logic, add new behaviors, or remove broken ones.
Keep the overall widget API contract (widget:GameFrame, widget:UnitCreated, etc.).""",

        TaskType.NEW_ALGORITHM: """\
Your task is NEW_ALGORITHM.
Invent a new strategic behavior and implement it in the target component.
Look at what the current bot is missing (see game_mechanics.md §10 and lessons_learned.md)
and pick ONE gap to fill. Be concrete — vague "improvements" don't help.""",

        TaskType.POST_MATCH_ANALYSIS: """\
Your task is POST_MATCH_ANALYSIS.
You have a match result JSON below. Diagnose why the bot performed poorly and propose
a concrete fix. Then implement the fix in the target component.""",

        TaskType.FRAMEWORK_FUNCTION: """\
Your task is FRAMEWORK_FUNCTION.
Add a new reusable utility function to bar_framework/. It should be genuinely useful
across multiple bot components (not just this one). Write the function, explain its
interface, and update the component to use it.""",
    }

    post_match_section = ""
    if match_result_json:
        post_match_section = f"""
## Match result to analyse

```json
{match_result_json}
```
"""

    return f"""You are an expert Beyond All Reason (BAR) bot developer working in Lua 5.1.

Your goal is to improve a BAR bot that plays the Cortex faction on Full Metal Plate 1.7.
You will modify ONE bot component file. The bot is a Spring engine Lua widget.

## Task

{task_instructions.get(task_type, task_instructions[TaskType.TUNE_PARAMETERS])}

## Critical Lua / Spring constraints

- Lua 5.1 only.  Max **60 upvalues per function** — split large functions if you approach the limit.
- Always start team-ID access with:
    `local spGetMyTeamID = Spring.GetMyTeamID`
  Never call `Spring.GetMyTeamID()` directly — the test harness patches the alias pattern.
- Widget callbacks: `widget:GameStart()`, `widget:GameFrame(n)`, `widget:UnitCreated(...)`,
  `widget:UnitDestroyed(...)`, `widget:UnitFinished(...)`.
- Throttle work in `GameFrame` — don't run every frame. Use `if n % 30 ~= 0 then return end`.
- `Spring.GetTeamUnits(teamID)` respects visibility. Player 0 (fullview=1) can query both teams.
- Use `VFS.Include("LuaUI/Widgets/bar_framework/resource_utils.lua")` etc. to load framework modules.
  Do NOT reinvent helpers that already exist in bar_framework/.

## Game mechanics reference

{game_mechanics}

## bar_framework API

{framework_api}

## Lessons learned from previous agent runs

{lessons}

## Recent strategy log (last 20 entries)

{strategy_log}
{post_match_section}
## Target component: `{component}`

```lua
{component_src}
```

## Instructions

1. Analyse the current code and the task.
2. Use `read_file` if you need to look at other files (other controllers, framework source, blueprints).
3. When ready, use `write_lua_file` to write your improved version. You MUST call this tool.
4. Use `run_syntax_check` after writing to verify the file has no syntax errors.
5. Explain your reasoning in the `reason` parameter of `write_lua_file`.
6. If syntax check fails, fix the errors and write the file again.

The match will be run automatically after you call `write_lua_file` for the final time.
"""


# ── Agent tools ───────────────────────────────────────────────────────────────

TOOLS = [
    {
        "name": "write_lua_file",
        "description": (
            "Write a Lua file to the candidate bot directory. "
            "Call this when you have a complete, improved version of the component ready. "
            "You MUST call this at least once — the match won't run otherwise."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "filename": {
                    "type": "string",
                    "description": "File name relative to the bot directory, e.g. 'lab_controller.lua'",
                },
                "content": {
                    "type": "string",
                    "description": "Complete Lua file content.",
                },
                "reason": {
                    "type": "string",
                    "description": "One paragraph explaining what changed and why.",
                },
            },
            "required": ["filename", "content", "reason"],
        },
    },
    {
        "name": "run_syntax_check",
        "description": "Run luac syntax check on a file in the candidate bot directory.",
        "input_schema": {
            "type": "object",
            "properties": {
                "filename": {
                    "type": "string",
                    "description": "File name relative to bot directory, e.g. 'lab_controller.lua'",
                },
            },
            "required": ["filename"],
        },
    },
    {
        "name": "read_file",
        "description": (
            "Read any file in the MetalBot repo. "
            "Use this to inspect other controllers, bar_framework source, blueprints, etc."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path relative to the MetalBot repo root, e.g. 'bar_framework/unit_query.lua'",
                },
            },
            "required": ["path"],
        },
    },
]


# ── Tool handlers ─────────────────────────────────────────────────────────────

def _handle_write_lua_file(inputs: dict, candidate_dir: Path, written_files: list) -> str:
    filename = inputs["filename"]
    content  = inputs["content"]
    reason   = inputs.get("reason", "")
    dest = candidate_dir / filename
    dest.write_text(content, encoding="utf-8")
    written_files.append({"filename": filename, "reason": reason})
    return f"Written {filename} ({len(content)} chars). Use run_syntax_check to verify."


def _handle_syntax_check(inputs: dict, candidate_dir: Path) -> str:
    filename = inputs["filename"]
    target = candidate_dir / filename
    if not target.exists():
        return f"ERROR: {filename} does not exist in candidate dir."

    # Try luac5.1 first, fall back to luac
    for luac in ("luac5.1", "luac"):
        try:
            result = subprocess.run(
                [luac, "-p", str(target)],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return f"PASS: {filename} — no syntax errors."
            return f"FAIL: {filename}\n{result.stderr or result.stdout}"
        except FileNotFoundError:
            continue
        except subprocess.TimeoutExpired:
            return f"ERROR: syntax check timed out for {filename}"

    return (
        f"WARNING: luac not found — could not syntax-check {filename}. "
        "Proceeding anyway; the match runner will catch runtime errors."
    )


def _handle_read_file(inputs: dict) -> str:
    rel_path = inputs["path"].replace("\\", "/")
    target = REPO_DIR / rel_path
    if not target.exists():
        return f"ERROR: File not found: {rel_path}"
    try:
        content = target.read_text(encoding="utf-8")
        if len(content) > 8000:
            content = content[:8000] + "\n... [truncated]"
        return content
    except Exception as e:
        return f"ERROR reading {rel_path}: {e}"


def _dispatch_tool(tool_name: str, tool_input: dict,
                   candidate_dir: Path, written_files: list) -> str:
    if tool_name == "write_lua_file":
        return _handle_write_lua_file(tool_input, candidate_dir, written_files)
    elif tool_name == "run_syntax_check":
        return _handle_syntax_check(tool_input, candidate_dir)
    elif tool_name == "read_file":
        return _handle_read_file(tool_input)
    return f"ERROR: unknown tool {tool_name}"


# ── Agent loop ────────────────────────────────────────────────────────────────

def run_agent(task_type: TaskType, component: str,
              candidate_dir: Path, match_result_json: str = "",
              verbose: bool = True) -> dict:
    """
    Run the Claude agent loop.  Returns a dict with:
        files_modified: list of {filename, reason}
        agent_reasoning: str (last reason from write_lua_file)
        syntax_valid: bool
        iterations: int
    """
    client = anthropic.Anthropic()
    system = _build_system_prompt(task_type, component, candidate_dir, match_result_json)
    messages = []
    written_files: list = []

    for iteration in range(MAX_ITERATIONS):
        if verbose:
            print(f"  [agent] iteration {iteration + 1}/{MAX_ITERATIONS} ...", flush=True)

        # First turn: just the task prompt; subsequent: tool results
        if iteration == 0:
            messages = [{"role": "user", "content": f"Please improve `{component}` for the task: {task_type.value}"}]

        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=system,
            tools=TOOLS,
            messages=messages,
        )

        # Append assistant message
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            if verbose:
                print("  [agent] done (end_turn).")
            break

        if response.stop_reason != "tool_use":
            if verbose:
                print(f"  [agent] unexpected stop_reason={response.stop_reason}, stopping.")
            break

        # Process tool calls
        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            if verbose:
                print(f"  [agent] tool: {block.name}({list(block.input.keys())})")
            result_text = _dispatch_tool(block.name, block.input, candidate_dir, written_files)
            if verbose and len(result_text) < 300:
                print(f"    → {result_text}")
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": result_text,
            })

        messages.append({"role": "user", "content": tool_results})

    syntax_valid = True
    if written_files:
        last_file = written_files[-1]["filename"]
        check = _handle_syntax_check({"filename": last_file}, candidate_dir)
        syntax_valid = check.startswith("PASS") or check.startswith("WARNING")
        if verbose:
            print(f"  [agent] final syntax check: {check}")

    reasoning = written_files[-1]["reason"] if written_files else ""
    return {
        "files_modified": [f["filename"] for f in written_files],
        "agent_reasoning": reasoning,
        "syntax_valid": syntax_valid,
        "iterations": iteration + 1,
    }


# ── Strategy log ──────────────────────────────────────────────────────────────

def _append_strategy_log(entry: dict):
    STRATEGY_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(STRATEGY_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


# ── Main task runner ──────────────────────────────────────────────────────────

def run_task(task_type: TaskType, component: str, baseline_id: str,
             match_result_json: str = "", duration: int = 400,
             verbose: bool = True) -> dict:
    """
    Full pipeline:
      1. Copy baseline bot → candidates/<run_id>/
      2. Run agent loop to modify component
      3. Run a test match (candidate vs baseline)
      4. Log to strategy_log.jsonl
      5. Return result dict
    """
    from bot_testing import run_match

    run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
    baseline_dir  = BOTS_DIR / baseline_id
    candidate_dir = CANDIDATES_DIR / run_id

    if not baseline_dir.exists():
        raise ValueError(f"Baseline bot not found: {baseline_dir}")

    CANDIDATES_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copytree(baseline_dir, candidate_dir)

    if verbose:
        print(f"\n[harness] Run {run_id}")
        print(f"[harness] Task: {task_type.value} — component: {component}")
        print(f"[harness] Candidate: {candidate_dir}")

    agent_result = run_agent(task_type, component, candidate_dir, match_result_json, verbose)

    if not agent_result["files_modified"]:
        print("[harness] Agent wrote no files — skipping match.")
        return {
            "run_id": run_id, "task_type": task_type.value,
            "component": component, "baseline_id": baseline_id,
            "agent_result": agent_result, "match_result": None,
            "admitted": False,
        }

    if verbose:
        print(f"[harness] Running match: candidate vs {baseline_id} ...")

    match = run_match(candidate_dir, baseline_dir, duration=duration, verbose=False)

    if verbose:
        print(f"[harness] Match winner={match.winner} ({match.winner_method}) "
              f"units={match.units_built}")

    log_entry = {
        "run_id":          run_id,
        "timestamp":       match.timestamp,
        "task_type":       task_type.value,
        "component":       component,
        "baseline_id":     baseline_id,
        "files_modified":  agent_result["files_modified"],
        "syntax_valid":    agent_result["syntax_valid"],
        "iterations":      agent_result["iterations"],
        "winner":          match.winner,
        "winner_method":   match.winner_method,
        "units_built":     match.units_built,
        "sanity_pass":     match.sanity_pass,
        "lua_errors":      match.lua_errors,
        "agent_reasoning": agent_result["agent_reasoning"],
        "outcome_tag":     "WIN" if match.winner == 0 else ("DRAW" if match.winner is None else "LOSS"),
    }
    _append_strategy_log(log_entry)

    if verbose:
        print(f"[harness] Outcome: {log_entry['outcome_tag']} — logged to strategy_log.jsonl")

    return {
        "run_id":        run_id,
        "task_type":     task_type.value,
        "component":     component,
        "baseline_id":   baseline_id,
        "candidate_dir": str(candidate_dir),
        "agent_result":  agent_result,
        "match_result":  match.to_dict(),
        "outcome_tag":   log_entry["outcome_tag"],
        "admitted":      False,  # caller decides admission via tournament.py
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="MetalBot agent harness (Claude API)")
    p.add_argument("--task",        required=True,
                   choices=[t.value for t in TaskType],
                   help="Task type to assign the agent")
    p.add_argument("--component",   required=True,
                   help="Lua file to modify, e.g. lab_controller.lua")
    p.add_argument("--baseline",    default="baseline_001",
                   help="Pool bot ID to base the candidate on (default: baseline_001)")
    p.add_argument("--duration",    type=int, default=400,
                   help="Match duration in real seconds (default: 400)")
    p.add_argument("--result-file", default="",
                   help="Path to a match result JSON for post_match_analysis tasks")
    p.add_argument("--admit",       action="store_true",
                   help="Run gauntlet and admit to pool if the candidate wins")
    p.add_argument("--quiet",       action="store_true")
    args = p.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ERROR: ANTHROPIC_API_KEY environment variable is not set.")
        sys.exit(1)

    match_result_json = ""
    if args.result_file:
        try:
            match_result_json = Path(args.result_file).read_text(encoding="utf-8")
        except Exception as e:
            print(f"WARNING: could not read result file: {e}")

    result = run_task(
        task_type=TaskType(args.task),
        component=args.component,
        baseline_id=args.baseline,
        match_result_json=match_result_json,
        duration=args.duration,
        verbose=not args.quiet,
    )

    if args.admit and result.get("outcome_tag") == "WIN":
        from tournament import TournamentPool
        pool = TournamentPool()
        candidate_dir = Path(result["candidate_dir"])
        bot_id = f"bot_{result['run_id']}"
        pool.admit_candidate(
            candidate_dir, bot_id,
            parent_id=args.baseline,
            task_desc=result.get("agent_result", {}).get("agent_reasoning", ""),
            match_results=[result["match_result"]] if result["match_result"] else [],
        )

    print(f"\n[harness] Done. Outcome: {result.get('outcome_tag', 'N/A')}")
    if result.get("candidate_dir"):
        print(f"[harness] Candidate: {result['candidate_dir']}")


if __name__ == "__main__":
    main()
