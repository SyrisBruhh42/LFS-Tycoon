#!/usr/bin/env python3
"""LFS-Tycoon Jules factory controller.

One invocation = one "tick" (a systemd user timer fires it every 15 minutes):
  1. Kill switches   : factory/config.json enabled=false, local PAUSE file, or an open GitHub
                       issue labelled `factory:pause` (opened by you from your phone, or by this
                       controller when a circuit breaker trips). Close the issue to resume.
  2. Reconcile       : poll every unfinished session it launched; auto-approve plans, nudge sessions
                       that ask questions, record PRs; close Jules PRs that failed the CI gate and
                       harvest the gate's error lines as "lessons".
  3. Circuit breakers: main red, high failure rate, repeated API errors, key rejected -> pause + issue.
                       Backlogs (too many active sessions / open PRs / daily cap) -> skip this tick.
  4. Dispatch        : launch exactly ONE new session with a fresh, coverage-weighted brief from
                       tools/pick_brief.py plus the most common recent mistakes to avoid.

Never prints or logs the API key. Key file: $JULES_API_KEY_FILE (default ~/.secrets/jules_api_key).
Usage: factory_dispatch.py [--dry-run] [--status] [--no-dispatch]
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = ROOT / "factory" / "config.json"
PROMPT_FILE = ROOT / ".github" / "JULES_PROMPT.md"
API = "https://jules.googleapis.com/v1alpha"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))) / "lfs-tycoon-factory"
STATE_FILE = STATE_DIR / "state.json"
EVENTS_FILE = STATE_DIR / "events.jsonl"
LOCK_FILE = STATE_DIR / "tick.lock"
PAUSE_FILE = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "lfs-tycoon-factory" / "PAUSE"
KEY_FILE = Path(os.environ.get("JULES_API_KEY_FILE", str(Path.home() / ".secrets" / "jules_api_key")))
PAUSE_LABEL = "factory:pause"
FAIL_LABEL = "gate-failed"
GATE_MARKER = "<!-- capsule-gate-report -->"
ACTIVE_STATES = {"QUEUED", "PLANNING", "AWAITING_PLAN_APPROVAL", "AWAITING_USER_FEEDBACK", "IN_PROGRESS", "PAUSED"}
NUDGE = ("Proceed autonomously without asking questions. Make the best reasonable decision yourself, follow "
         "AGENTS.md, keep the scope to one new capsule in its own folder, make tools/preflight.py pass, and "
         "finish by opening the pull request.")


class ApiError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(f"HTTP {status}: {msg}")
        self.status = status


# --------------------------------------------------------------------------- utilities
def now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s: str) -> datetime:
    s = re.sub(r"\.\d+", "", s or "").replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return now()


def log(event: str, **fields) -> None:
    rec = {"ts": iso(now()), "event": event, **fields}
    line = json.dumps(rec, sort_keys=True)
    print(line, flush=True)
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with EVENTS_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"sessions": {}, "lessons": [], "api_fail_streak": 0}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True), encoding="utf-8")
    os.replace(tmp, STATE_FILE)


def gh(*args: str, check: bool = True) -> str:
    res = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
    if check and res.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}... failed: {res.stderr.strip()[:300]}")
    return res.stdout


def api(method: str, path: str, body: dict | None = None, timeout: int = 45) -> dict:
    key = KEY_FILE.read_text(encoding="utf-8").strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = json.loads(e.read() or b"{}").get("error", {}).get("message", "")[:200]
        except Exception:
            pass
        raise ApiError(e.code, detail or e.reason) from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ApiError(0, f"network: {type(e).__name__}") from None


def api_retry(method: str, path: str, body: dict | None = None, attempts: int = 3) -> dict:
    delay = 5
    for i in range(attempts):
        try:
            return api(method, path, body)
        except ApiError as e:
            if e.status in (400, 401, 403, 404) or i == attempts - 1:
                raise
            time.sleep(delay)
            delay *= 4
    return {}


# --------------------------------------------------------------------------- pause / breakers
def pause_issues(cfg: dict) -> list[dict]:
    out = gh("issue", "list", "-R", cfg["repo"], "--label", PAUSE_LABEL, "--state", "open", "--json", "number,title")
    return json.loads(out or "[]")


def ensure_labels(cfg: dict) -> None:
    for name, color, desc in ((PAUSE_LABEL, "B60205", "Open issue = Jules factory paused. Close to resume."),
                              (FAIL_LABEL, "D93F0B", "PR failed the capsule gate.")):
        gh("label", "create", name, "-R", cfg["repo"], "--color", color, "--description", desc, "--force", check=False)


def trip(cfg: dict, reason: str, details: str, dry: bool) -> None:
    log("breaker_tripped", reason=reason)
    if dry:
        return
    ensure_labels(cfg)
    if pause_issues(cfg):
        return
    body = (f"The Jules factory paused itself.\n\n**Reason:** {reason}\n\n{details}\n\n"
            f"Investigate, fix the cause, then **close this issue** to resume dispatching.\n\n"
            f"_Local event log: `~/.local/state/lfs-tycoon-factory/events.jsonl`_")
    gh("issue", "create", "-R", cfg["repo"], "--title", f"Factory paused: {reason}", "--label", PAUSE_LABEL, "--body", body)


def main_is_red(cfg: dict) -> tuple[bool, str]:
    runs = json.loads(gh("run", "list", "-R", cfg["repo"], "--workflow", cfg["gate_workflow"], "--branch", "main",
                         "--limit", "10", "--json", "event,status,conclusion,headSha,url"))
    main_sha = gh("api", f"repos/{cfg['repo']}/commits/main", "--jq", ".sha").strip()
    for r in runs:
        if r["event"] in ("push", "schedule", "workflow_dispatch") and r["status"] == "completed":
            # Only count it if main has not moved on since (e.g. an automatic revert landed).
            return (r["conclusion"] == "failure" and r["headSha"] == main_sha), r.get("url", "")
    return False, ""


# --------------------------------------------------------------------------- reconcile
def first_pr_url(session: dict) -> str | None:
    for o in session.get("outputs", []) or []:
        pr = o.get("pullRequest")
        if pr and pr.get("url"):
            return pr["url"]
    return None


def normalize_error(line: str) -> str:
    line = re.sub(r"\[[a-z0-9_]+/[a-z0-9_]+\]", "[capsule]", line)
    line = re.sub(r"content/capsules/[a-z0-9_/]+", "<capsule path>", line)
    return line.strip()[:220]


def harvest_lessons(cfg: dict, pr_url: str, state: dict) -> None:
    try:
        data = json.loads(gh("pr", "view", pr_url, "--json", "comments"))
    except (RuntimeError, ValueError):
        return
    for c in reversed(data.get("comments", [])):
        if GATE_MARKER in c.get("body", ""):
            errs = [normalize_error(l) for l in c["body"].splitlines()
                    if l.startswith(("ERROR:", "PATH GUARD:", "FAILED:", "  [FAIL]"))]
            state["lessons"] = (state.get("lessons", []) + errs[:8])[-60:]
            return


def reconcile(cfg: dict, state: dict, dry: bool) -> None:
    sessions = state.setdefault("sessions", {})
    for sid, rec in sessions.items():
        if rec.get("outcome"):
            continue
        age_h = (now() - parse_ts(rec["created"])).total_seconds() / 3600
        # ---- session side
        if not rec.get("pr"):
            try:
                s = api_retry("GET", f"/sessions/{sid}")
            except ApiError as e:
                log("session_poll_error", session=sid, error=str(e))
                continue
            st = s.get("state", "UNKNOWN")
            rec["state"] = st
            pr = first_pr_url(s)
            if pr:
                rec["pr"] = pr
                rec["pr_seen"] = iso(now())
                log("pr_opened", session=sid, pr=pr)
            elif st == "AWAITING_PLAN_APPROVAL" and not dry:
                try:
                    api_retry("POST", f"/sessions/{sid}:approvePlan", {})
                    log("plan_approved", session=sid)
                except ApiError as e:
                    log("approve_error", session=sid, error=str(e))
            elif st == "AWAITING_USER_FEEDBACK" and not dry:
                if rec.get("nudges", 0) < cfg["max_feedback_nudges"]:
                    try:
                        api_retry("POST", f"/sessions/{sid}:sendMessage", {"prompt": NUDGE})
                        rec["nudges"] = rec.get("nudges", 0) + 1
                        log("session_nudged", session=sid, nudges=rec["nudges"])
                    except ApiError as e:
                        log("nudge_error", session=sid, error=str(e))
                elif age_h > 2:
                    rec["outcome"] = "failed:stuck_asking"
            elif st == "FAILED":
                rec["outcome"] = "failed:session_failed"
            elif st == "COMPLETED":
                done_min = (now() - parse_ts(s.get("updateTime", rec["created"]))).total_seconds() / 60
                if done_min > cfg["no_pr_grace_minutes"]:
                    rec["outcome"] = "failed:no_pr"
            if not rec.get("outcome") and not rec.get("pr") and age_h > cfg["stale_session_hours"]:
                rec["outcome"] = "failed:stale"
            if rec.get("outcome"):
                rec["finished"] = iso(now())
                log("session_finished", session=sid, outcome=rec["outcome"])
            if not rec.get("pr"):
                continue
        # ---- pull request side
        try:
            pr = json.loads(gh("pr", "view", rec["pr"], "--json", "state,statusCheckRollup,isDraft"))
        except (RuntimeError, ValueError) as e:
            log("pr_poll_error", session=sid, error=str(e)[:200])
            continue
        if pr["state"] == "MERGED":
            rec["outcome"] = "merged"
        elif pr["state"] == "CLOSED":
            rec["outcome"] = "failed:closed"
        else:
            checks = [c for c in pr.get("statusCheckRollup", []) or [] if c.get("name") == cfg["gate_check_name"]]
            concl = (checks[-1].get("conclusion") or "") if checks else ""
            if concl in ("FAILURE", "TIMED_OUT", "STARTUP_FAILURE"):
                harvest_lessons(cfg, rec["pr"], state)
                rec["outcome"] = "failed:gate"
                if not dry:
                    gh("pr", "edit", rec["pr"], "--add-label", FAIL_LABEL, check=False)
                    gh("pr", "close", rec["pr"], "--delete-branch", "--comment",
                       "Closed automatically by the Jules factory: the capsule gate failed. The errors were recorded as "
                       "lessons for future sessions.", check=False)
            elif not checks and (now() - parse_ts(rec.get("pr_seen", rec["created"]))).total_seconds() > cfg["no_gate_hours"] * 3600:
                rec["outcome"] = "failed:no_gate"
        if rec.get("outcome"):
            rec["finished"] = iso(now())
            log("session_finished", session=sid, outcome=rec["outcome"], pr=rec["pr"])

    # Prune finished records older than 14 days to keep state small.
    cutoff = now() - timedelta(days=14)
    for sid in [k for k, v in sessions.items() if v.get("outcome") and parse_ts(v["created"]) < cutoff]:
        del sessions[sid]


def lessons_block(state: dict, n: int) -> str:
    common = [msg for msg, _ in Counter(state.get("lessons", [])).most_common(n)]
    if not common:
        return ""
    return ("\n\n## Recent gate failures to avoid (learned automatically)\n" +
            "\n".join(f"- {m}" for m in common))


# --------------------------------------------------------------------------- dispatch
def dispatch(cfg: dict, state: dict, dry: bool) -> None:
    brief = json.loads(subprocess.run([sys.executable, str(ROOT / "tools" / "pick_brief.py"), "--json"],
                                      capture_output=True, text=True, check=True, cwd=ROOT).stdout)
    prompt = PROMPT_FILE.read_text(encoding="utf-8").strip() + "\n\n" + brief["markdown"] + lessons_block(state, cfg["lesson_count"])
    title = f"capsule {brief['suffix']}: {brief['label']}"[:120]
    body = {
        "prompt": prompt,
        "title": title,
        "sourceContext": {"source": cfg["source"], "githubRepoContext": {"startingBranch": cfg["starting_branch"]}},
        "automationMode": "AUTO_CREATE_PR",
        "requirePlanApproval": False,
    }
    if dry:
        log("dry_run_dispatch", title=title, prompt_chars=len(prompt))
        print("\n----- PROMPT PREVIEW -----\n" + prompt + "\n--------------------------")
        return
    session = None
    for attempt in range(3):
        try:
            session = api("POST", "/sessions", body, timeout=60)
            break
        except ApiError as e:
            if e.status in (400, 401, 403, 404):
                raise
            # Idempotency: the create may have succeeded even though the response was lost.
            time.sleep(10 * (attempt + 1))
            try:
                recent = api("GET", "/sessions?pageSize=10").get("sessions", [])
                session = next((s for s in recent if s.get("title") == title), None)
            except ApiError:
                session = None
            if session:
                break
            if attempt == 2:
                raise
    sid = session.get("id") or session.get("name", "").split("/")[-1]
    state["sessions"][sid] = {"created": iso(now()), "title": title, "suffix": brief["suffix"],
                              "label": brief["label"], "state": session.get("state", "QUEUED")}
    log("dispatched", session=sid, title=title, url=session.get("url", ""))


# --------------------------------------------------------------------------- main
def status(state: dict) -> None:
    sess = state.get("sessions", {})
    outcomes = Counter((v.get("outcome") or "in_flight").split(":")[0] for v in sess.values())
    day = sum(1 for v in sess.values() if now() - parse_ts(v["created"]) < timedelta(hours=24))
    print(json.dumps({"tracked": len(sess), "outcomes": outcomes, "dispatched_24h": day,
                      "api_fail_streak": state.get("api_fail_streak", 0),
                      "top_lessons": [m for m, _ in Counter(state.get("lessons", [])).most_common(5)]}, indent=1))


def tick(args: argparse.Namespace) -> int:
    cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    state = load_state()
    if args.status:
        status(state)
        return 0
    if not KEY_FILE.exists():
        log("no_api_key", path=str(KEY_FILE))
        return 2

    try:
        reconcile(cfg, state, args.dry_run)
    finally:
        save_state(state)

    # ---- kill switches
    if not cfg.get("enabled", True):
        log("skip", reason="config_disabled")
        return 0
    if PAUSE_FILE.exists():
        log("skip", reason="local_pause_file")
        return 0
    try:
        if pause_issues(cfg):
            log("skip", reason="pause_issue_open")
            return 0
        red, url = main_is_red(cfg)
    except RuntimeError as e:
        log("skip", reason="github_unreachable", error=str(e)[:200])  # fail safe: never dispatch blind
        return 0
    if red:
        trip(cfg, "main branch is red", f"Latest gate run on main failed: {url}", args.dry_run)
        return 0

    # ---- rolling failure-rate breaker
    finished = sorted((v for v in state["sessions"].values() if v.get("outcome") and not v.get("breaker_reset")),
                      key=lambda v: v.get("finished", ""))
    window = finished[-cfg["failure_window"]:]
    fails = [v for v in window if v["outcome"].startswith("failed")]
    if len(window) >= cfg["failure_window"] and len(fails) >= cfg["failure_threshold"]:
        reasons = Counter(v["outcome"] for v in fails).most_common()
        trip(cfg, f"{len(fails)}/{len(window)} recent sessions failed",
             "Failure breakdown: " + ", ".join(f"`{k}` x{n}" for k, n in reasons) +
             "\n\nTop recurring gate errors:\n" + lessons_block(state, 5), args.dry_run)
        if not args.dry_run:
            # Exclude this window from future evaluation so resuming starts clean instead of re-tripping.
            for v in window:
                v["breaker_reset"] = True
            save_state(state)
        return 0

    # ---- backpressure (skip, do not pause)
    live = [v for v in state["sessions"].values() if not v.get("outcome")]
    active = [v for v in live if not v.get("pr")]
    open_prs = [v for v in live if v.get("pr")]
    day = [v for v in state["sessions"].values() if now() - parse_ts(v["created"]) < timedelta(hours=24)]
    for cond, reason in ((len(active) >= cfg["max_active_sessions"], "too_many_active_sessions"),
                         (len(open_prs) >= cfg["max_open_prs"], "pr_backlog"),
                         (len(day) >= min(cfg["daily_cap"], 300), "daily_cap")):
        if cond:
            log("skip", reason=reason, active=len(active), open_prs=len(open_prs), last_24h=len(day))
            return 0
    if args.no_dispatch:
        log("skip", reason="no_dispatch_flag")
        return 0

    # ---- dispatch exactly one session
    try:
        dispatch(cfg, state, args.dry_run)
        state["api_fail_streak"] = 0
    except ApiError as e:
        state["api_fail_streak"] = state.get("api_fail_streak", 0) + 1
        log("dispatch_error", error=str(e), streak=state["api_fail_streak"])
        if e.status in (401, 403):
            trip(cfg, "Jules API key rejected", f"Dispatch returned {e}. Replace ~/.secrets/jules_api_key.", args.dry_run)
        elif state["api_fail_streak"] >= cfg["max_api_fail_streak"]:
            trip(cfg, "Jules API failing repeatedly", f"{state['api_fail_streak']} consecutive errors; last: {e}", args.dry_run)
    finally:
        save_state(state)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="LFS-Tycoon Jules factory: reconcile + dispatch one session.")
    ap.add_argument("--dry-run", action="store_true", help="Reconcile read-only and preview the prompt; launch nothing.")
    ap.add_argument("--status", action="store_true", help="Print a summary of tracked sessions and exit.")
    ap.add_argument("--no-dispatch", action="store_true", help="Reconcile and run breakers, but do not launch.")
    args = ap.parse_args()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("skip", reason="previous_tick_still_running")
            return 0
        try:
            return tick(args)
        except Exception as e:  # never crash-loop silently; record and let the next tick retry
            log("tick_crashed", error=f"{type(e).__name__}: {str(e)[:300]}")
            return 1


if __name__ == "__main__":
    sys.exit(main())
