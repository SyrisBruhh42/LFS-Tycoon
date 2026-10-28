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
import tempfile
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = ROOT / "factory" / "config.json"
PROMPT_FILE = ROOT / ".github" / "JULES_PROMPT.md"
STEWARD_PROMPT_FILE = ROOT / ".github" / "STEWARD_PROMPT.md"
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
CAPSULE_PATH_RE = re.compile(r"^content/capsules/([a-z0-9_]{1,40})/([a-z0-9_]{1,80})/capsule\.json$")
PROPOSAL_PATH_RE = re.compile(r"^proposals/[a-z0-9_]{1,80}\.md$")
ACTIVE_STATES = {"QUEUED", "PLANNING", "AWAITING_PLAN_APPROVAL", "AWAITING_USER_FEEDBACK", "IN_PROGRESS", "PAUSED"}
NUDGE = ("Proceed autonomously without asking questions. Make the best reasonable decision yourself, follow "
         "AGENTS.md, keep the scope to one new capsule in its own folder, make tools/preflight.py pass, and "
         "call your submit tool to finish the session and publish the pull request.")
SUBMIT_NUDGE = (
    "You finished pre-commit steps and sent a chat message without calling the submit tool, "
    "leaving the session Inactive without publishing the branch or pull request. "
    "Ensure your new capsule is committed, `python3 tools/preflight.py` prints PREFLIGHT OK, "
    "and call your `submit` tool now to officially complete the session and create the pull request."
)


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
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("state root must be a dict")
        if not isinstance(data.get("sessions"), dict):
            data["sessions"] = {}
        if not isinstance(data.get("lessons"), list):
            data["lessons"] = []
        if not isinstance(data.get("api_fail_streak"), int):
            data["api_fail_streak"] = 0
        return data
    except (OSError, ValueError):
        if STATE_FILE.exists():
            try:
                STATE_FILE.replace(STATE_FILE.with_suffix(".corrupt.bak"))
            except OSError:
                pass
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
    """Strictly filters Jules v1alpha multi-output arrays (ignoring changeSet objects)."""
    for o in session.get("outputs", []) or []:
        if not isinstance(o, dict):
            continue
        pr = o.get("pullRequest")
        if isinstance(pr, dict) and isinstance(pr.get("url"), str) and pr["url"].strip():
            return pr["url"].strip()
    return None


def extract_latest_changeset(sid: str, session: dict) -> tuple[str, str]:
    """Returns (unidiff_patch, suggested_commit_message) from session.outputs or session/activities."""
    for o in reversed(session.get("outputs", []) or []):
        if isinstance(o, dict):
            gp = (o.get("changeSet") or {}).get("gitPatch") or {}
            patch = gp.get("unidiffPatch", "")
            if isinstance(patch, str) and patch.strip():
                return patch, str(gp.get("suggestedCommitMessage") or "").strip()
    try:
        acts = api_retry("GET", f"/sessions/{sid}/activities?pageSize=50").get("activities", []) or []
    except ApiError:
        return "", ""
    for a in reversed(acts):
        if not isinstance(a, dict):
            continue
        for art in reversed(a.get("artifacts", []) or []):
            if not isinstance(art, dict):
                continue
            gp = (art.get("changeSet") or {}).get("gitPatch") or {}
            patch = gp.get("unidiffPatch", "")
            if isinstance(patch, str) and patch.strip():
                return patch, str(gp.get("suggestedCommitMessage") or "").strip()
    return "", ""


def salvage_changeset_to_pr(cfg: dict, sid: str, rec: dict, state: dict, session: dict, dry: bool) -> bool:
    """Antifragile fallback: if a session completed work inside its VM (producing a valid changeSet in
    outputs or activities) but never opened a GitHub PR even after submit nudges, validates the patch
    in an isolated git worktree against path_guard.py + check_capsules.py --strict. If valid, pushes a
    salvage branch and opens the PR; if invalid, harvests the exact validation errors into state['lessons']."""
    if rec.get("salvage_attempted"):
        return False
    rec["salvage_attempted"] = True
    patch, commit_msg = extract_latest_changeset(sid, session)
    if not patch.strip():
        return False

    touched_paths: list[str] = []
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            parts = line.split(" b/", 1)
            if len(parts) == 2:
                touched_paths.append(parts[1].strip())
    if not touched_paths:
        return False

    capsule_paths = [p for p in touched_paths if CAPSULE_PATH_RE.match(p)]
    bad_paths = [
        p for p in touched_paths
        if not (CAPSULE_PATH_RE.match(p) or PROPOSAL_PATH_RE.match(p))
    ]
    if bad_paths and not capsule_paths:
        errs = [
            normalize_error(f"PATH GUARD: {p}: outside the allowed paths (content/capsules/<ns>/<slug>/capsule.json, proposals/<name>.md).")
            for p in bad_paths[:4]
        ]
        state["lessons"] = (state.get("lessons", []) + errs)[-60:]
        log("salvage_rejected_path_guard", session=sid, bad_paths=bad_paths[:4])
        return False

    if not capsule_paths:
        return False

    if dry:
        log("dry_run_salvage", session=sid, paths=capsule_paths)
        return True

    title = (commit_msg.splitlines()[0].strip() if commit_msg else "") or f"content: add {capsule_paths[0].split('/')[2]}/{capsule_paths[0].split('/')[3]}"
    title = title[:120]
    branch = f"salvage/jules-{sid}"

    with tempfile.TemporaryDirectory(prefix=f"tycoon-salvage-{sid[:8]}-") as tmp_dir:
        wt = Path(tmp_dir) / "wt"
        try:
            subprocess.run(["gh", "repo", "clone", cfg["repo"], str(wt), "--", "--depth=50", "--branch", cfg["starting_branch"]],
                           capture_output=True, text=True, check=True, timeout=90)
            apply_res = subprocess.run(["git", "-C", str(wt), "apply", "--index"],
                                       input=patch, capture_output=True, text=True, timeout=30)
            if apply_res.returncode != 0:
                log("salvage_apply_failed", session=sid, error=apply_res.stderr.strip()[:200])
                return False
            for tp in touched_paths:
                if not (CAPSULE_PATH_RE.match(tp) or PROPOSAL_PATH_RE.match(tp)):
                    subprocess.run(["git", "-C", str(wt), "rm", "-rf", "--ignore-unmatch", tp],
                                   capture_output=True, text=True, check=False, timeout=15)
                    scratch_fp = wt / tp
                    if scratch_fp.exists():
                        scratch_fp.unlink(missing_ok=True)
            subprocess.run(["git", "-C", str(wt), "-c", "user.name=lfs-tycoon-factory",
                            "-c", "user.email=lfs-tycoon-factory@users.noreply.github.com",
                            "commit", "-m", commit_msg or title],
                           capture_output=True, text=True, check=True, timeout=30)

            pg = subprocess.run([sys.executable, "tools/path_guard.py", "--base", f"origin/{cfg['starting_branch']}", "--head", "HEAD"],
                                cwd=wt, capture_output=True, text=True, timeout=30)
            new_cap_args: list[str] = []
            for cp in capsule_paths:
                new_cap_args.extend(["--new-capsule", cp])
            cc = subprocess.run([sys.executable, "tools/check_capsules.py", "--strict", *new_cap_args],
                                cwd=wt, capture_output=True, text=True, timeout=60)

            if pg.returncode != 0 or cc.returncode != 0:
                combined = (pg.stdout + "\n" + pg.stderr + "\n" + cc.stdout + "\n" + cc.stderr).splitlines()
                errs = [
                    normalize_error(l) for l in combined
                    if l.startswith(("ERROR:", "PATH GUARD:", "FAILED:", "  [FAIL]"))
                ]
                if errs:
                    state["lessons"] = (state.get("lessons", []) + errs[:8])[-60:]
                log("salvage_validation_failed", session=sid, errors=errs[:4])
                return False

            subprocess.run(["git", "-C", str(wt), "push", "-f", "origin", f"HEAD:refs/heads/{branch}"],
                           capture_output=True, text=True, check=True, timeout=60)
            pr_body = (
                f"{commit_msg or title}\n\n---\n"
                f"*Salvaged automatically by `factory_dispatch.py` from verified changeSet in Jules session `{sid}`.*"
            )
            out = gh("pr", "create", "-R", cfg["repo"], "--base", cfg["starting_branch"],
                     "--head", branch, "--title", title, "--body", pr_body).strip()
            pr_url = next((l.strip() for l in reversed(out.splitlines()) if l.strip().startswith("https://")), "")
            if pr_url:
                rec["pr"] = pr_url
                rec["pr_seen"] = iso(now())
                rec["salvaged"] = True
                log("salvaged_pr_opened", session=sid, pr=pr_url, paths=capsule_paths)
                subprocess.run(["gh", "pr", "merge", pr_url, "--squash", "--delete-branch", "--auto"],
                               capture_output=True, text=True, check=False, timeout=30)
                return True
        except Exception as e:
            log("salvage_error", session=sid, error=f"{type(e).__name__}: {str(e)[:200]}")
    return False


def cut_loss_session(cfg: dict, sid: str, rec: dict, state: dict, reason: str, dry: bool) -> None:
    """Gracefully closes stalled/failed sessions, deletes abandoned PR branches, and records a bounded Second-Pass Lesson."""
    rec["outcome"] = f"failed:{reason}"
    rec["finished"] = iso(now())
    if reason == "no_pr":
        lesson = (
            "[Second-Pass Failure Lesson] Session finished without opening a PR (no_pr): "
            "after tools/preflight.py prints PREFLIGHT OK and pre-commit steps finish, "
            "you MUST invoke the submit tool (never stop after sending a chat message)."
        )
    else:
        lesson = f"[Second-Pass Failure Lesson] Session stalled/failed ({reason}) on {rec.get('label', 'capsule')}: keep scope to 1 valid capsule, respect 2-Item Self-Mix Budget, and run tools/preflight.py."
    state["lessons"] = (state.get("lessons", []) + [lesson[:220]])[-60:]
    pr_url = rec.get("pr")
    if pr_url and not dry:
        gh("pr", "edit", pr_url, "--add-label", FAIL_LABEL, check=False)
        gh("pr", "close", pr_url, "--delete-branch", "--comment",
           f"Closed automatically by `cut_loss_session` ({reason}). Recorded Second-Pass Failure Lesson.", check=False)
    log("cut_loss_session", session=sid, reason=reason, pr=pr_url or "")


def enclave_dispatched_24h() -> int:
    """Reads peer factories' (PA-15 Enclave, PF-08 Trash Arcade, PA-14 Willow Guild) rolling-24h Jules dispatches for sympathetic 4-fleet quota sharing."""
    cutoff = now() - timedelta(hours=24)
    total_peer_24h = 0
    xdg_state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))

    # 1. PA-15 Enclave Digital Twin runtime budget (with repo fallback)
    for eb in (xdg_state / "lfs-enclave-factory" / "budget.json", ROOT.parent / "enclave-digital-twin" / "ops" / "budget.json"):
        if eb.exists():
            try:
                data = json.loads(eb.read_text(encoding="utf-8"))
                ledger = data.get("session_ledger_24h", [])
                if isinstance(ledger, list) and ledger:
                    total_peer_24h += sum(
                        1 for e in ledger
                        if isinstance(e, dict) and not e.get("dry_run", False)
                        and isinstance(e.get("timestamp_utc"), str) and parse_ts(e["timestamp_utc"]) >= cutoff
                    )
                    break
                ts_list = data.get("dispatches_utc", []) or data.get("recent_dispatches", [])
                if isinstance(ts_list, list) and ts_list:
                    total_peer_24h += sum(1 for t in ts_list if isinstance(t, str) and parse_ts(t) >= cutoff)
                    break
            except Exception:
                pass

    # 2. PF-08 Trash Arcade & PA-14 Willow Guild state files
    for peer_state_file in (
        xdg_state / "lfs-trasharcade-factory" / "state.json",
        xdg_state / "lfs-willow-guild-factory" / "state.json",
    ):
        if peer_state_file.exists():
            try:
                pdata = json.loads(peer_state_file.read_text(encoding="utf-8"))
                psess = pdata.get("sessions", {})
                if isinstance(psess, dict):
                    total_peer_24h += sum(
                        1 for rec in psess.values()
                        if isinstance(rec, dict)
                        and isinstance(rec.get("created_at") or rec.get("created"), str)
                        and parse_ts(str(rec.get("created_at") or rec.get("created"))) >= cutoff
                    )
            except Exception:
                pass
    return total_peer_24h


def normalize_error(line: str) -> str:
    line = re.sub(r"\[[a-z0-9_]+/[a-z0-9_]+\]", "[capsule]", line)
    line = re.sub(r"content/capsules/[a-z0-9_/]+", "<capsule path>", line)
    return line.strip()[:220]


def harvest_lessons(cfg: dict, pr_url: str, state: dict) -> bool:
    """Records the gate's content errors as lessons. Returns True if the failure was infrastructure, not content."""
    try:
        data = json.loads(gh("pr", "view", pr_url, "--json", "comments"))
    except (RuntimeError, ValueError):
        return False
    for c in reversed(data.get("comments", [])):
        body = c.get("body", "")
        if GATE_MARKER in body:
            if "INFRA:" in body:
                return True
            errs = [normalize_error(l) for l in body.splitlines()
                    if l.startswith(("ERROR:", "PATH GUARD:", "FAILED:", "  [FAIL]"))]
            state["lessons"] = (state.get("lessons", []) + errs[:8])[-60:]
            return False
    return False


def reconcile(cfg: dict, state: dict, dry: bool) -> None:
    sessions = state.setdefault("sessions", {})
    behind_updates_this_tick = 0
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
                since_nudge_min = (
                    (now() - parse_ts(rec["last_nudge_at"])).total_seconds() / 60
                    if rec.get("last_nudge_at") else 999.0
                )
                if rec.get("nudges", 0) < cfg["max_feedback_nudges"]:
                    if since_nudge_min >= 10.0:
                        rec["nudges"] = rec.get("nudges", 0) + 1
                        rec["last_nudge_at"] = iso(now())
                        try:
                            api_retry("POST", f"/sessions/{sid}:sendMessage", {"prompt": NUDGE})
                            log("session_nudged", session=sid, nudges=rec["nudges"])
                        except ApiError as e:
                            log("nudge_error", session=sid, error=str(e), nudges=rec["nudges"])
                elif age_h > 0.5 and since_nudge_min >= 10.0:
                    if not salvage_changeset_to_pr(cfg, sid, rec, state, s, dry):
                        cut_loss_session(cfg, sid, rec, state, "stuck_asking", dry)
            elif st == "FAILED":
                if not salvage_changeset_to_pr(cfg, sid, rec, state, s, dry):
                    cut_loss_session(cfg, sid, rec, state, "session_failed", dry)
            elif st == "COMPLETED":
                done_min = (now() - parse_ts(s.get("updateTime", rec["created"]))).total_seconds() / 60
                since_last_nudge_min = (
                    (now() - parse_ts(rec["last_submit_nudge"])).total_seconds() / 60
                    if rec.get("last_submit_nudge") else 999.0
                )
                nudges_used = rec.get("submit_nudges", 0)
                # Jules v1alpha reports "COMPLETED" with empty outputs when an agent ends its turn via
                # agentMessaged without calling the submit tool (shown as "Inactive" in Jules UI/CLI).
                # 1. Nudge the session to call `submit` (with deadlock-safe attempt tracking).
                # 2. If nudges are exhausted and grace elapsed, attempt autonomous local changeSet salvage
                #    before ever cutting loss as `no_pr`.
                if (not s.get("outputs") or done_min >= 5.0) and nudges_used < cfg["max_feedback_nudges"] and since_last_nudge_min >= 10.0 and not dry:
                    rec["submit_nudges"] = nudges_used + 1
                    rec["last_submit_nudge"] = iso(now())
                    try:
                        api_retry("POST", f"/sessions/{sid}:sendMessage", {"prompt": SUBMIT_NUDGE})
                        log("session_submit_nudged", session=sid, submit_nudges=rec["submit_nudges"])
                    except ApiError as e:
                        log("nudge_error", session=sid, error=str(e), submit_nudges=rec["submit_nudges"])
                elif done_min > cfg["no_pr_grace_minutes"] and (nudges_used >= cfg["max_feedback_nudges"] or since_last_nudge_min >= 10.0):
                    if not salvage_changeset_to_pr(cfg, sid, rec, state, s, dry):
                        cut_loss_session(cfg, sid, rec, state, "no_pr", dry)
            since_any_nudge_min = min(
                (now() - parse_ts(rec["last_nudge_at"])).total_seconds() / 60 if rec.get("last_nudge_at") else 999.0,
                (now() - parse_ts(rec["last_submit_nudge"])).total_seconds() / 60 if rec.get("last_submit_nudge") else 999.0,
            )
            if not rec.get("outcome") and not rec.get("pr") and age_h > cfg["stale_session_hours"] and since_any_nudge_min >= 10.0:
                if not salvage_changeset_to_pr(cfg, sid, rec, state, s, dry):
                    cut_loss_session(cfg, sid, rec, state, "stale", dry)
            if not rec.get("pr"):
                continue
        # ---- pull request side
        try:
            pr = json.loads(gh("pr", "view", rec["pr"], "--json", "number,state,statusCheckRollup,isDraft,mergeable,mergeStateStatus"))
        except (RuntimeError, ValueError) as e:
            log("pr_poll_error", session=sid, error=str(e)[:200])
            continue
        if pr["state"] == "MERGED":
            rec["outcome"] = "merged"
        elif pr["state"] == "CLOSED":
            rec["outcome"] = "failed:closed"
        else:
            if pr.get("isDraft") and not dry:
                gh("pr", "ready", rec["pr"], check=False)
                log("pr_marked_ready", session=sid, pr=rec["pr"])
            if pr.get("mergeable") == "CONFLICTING":
                cut_loss_session(cfg, sid, rec, state, "merge_conflict", dry)
                continue
            # Auto-reconcile stale-base PRs (MERGEABLE + BEHIND, bounded to <= 2 per tick)
            if (pr.get("mergeable") == "MERGEABLE" and pr.get("mergeStateStatus") == "BEHIND"
                    and behind_updates_this_tick < 2 and not dry and pr.get("number")):
                gh("api", "-X", "PUT", f"repos/{cfg['repo']}/pulls/{pr['number']}/update-branch", check=False)
                behind_updates_this_tick += 1
                log("pr_branch_updated", session=sid, pr=rec["pr"], number=pr["number"])
            checks = [c for c in pr.get("statusCheckRollup", []) or [] if c.get("name") == cfg["gate_check_name"]]
            concl = (checks[-1].get("conclusion") or "") if checks else ""
            pr_age_sec = (now() - parse_ts(rec.get("pr_seen", rec["created"]))).total_seconds()
            if concl in ("FAILURE", "TIMED_OUT", "STARTUP_FAILURE"):
                if harvest_lessons(cfg, rec["pr"], state):
                    # Gate infrastructure broke, not the capsule: keep the PR open for a re-run after the fix.
                    # These still count toward the failure breaker, so a systemic CI outage pauses the factory.
                    rec["outcome"] = "failed:gate_infra"
                    rec["finished"] = iso(now())
                    log("session_finished", session=sid, outcome=rec["outcome"], pr=rec["pr"])
                    continue
                cut_loss_session(cfg, sid, rec, state, "gate", dry)
                continue
            elif concl == "SUCCESS" and pr.get("mergeable") == "MERGEABLE" and pr_age_sec >= 180 and not dry:
                # Fallback auto-merge if capsule_gate.yml passed but its merge step hit a transient race.
                merge_res = subprocess.run(["gh", "pr", "merge", rec["pr"], "--squash", "--delete-branch"],
                                           capture_output=True, text=True, timeout=60)
                if merge_res.returncode == 0:
                    rec["outcome"] = "merged"
                    log("pr_fallback_merged", session=sid, pr=rec["pr"])
            elif not checks and pr_age_sec > cfg["no_gate_hours"] * 3600:
                cut_loss_session(cfg, sid, rec, state, "no_gate", dry)
                continue
            elif age_h > cfg["stale_session_hours"]:
                cut_loss_session(cfg, sid, rec, state, "stale_pr", dry)
                continue
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
    next_seq = int(state.get("dispatch_seq", 0)) + 1
    is_steward = (next_seq % 10 == 0)
    cmd = [sys.executable, str(ROOT / "tools" / "pick_brief.py"), "--json"]
    if is_steward:
        cmd.append("--force-steward")
    brief = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True, cwd=ROOT).stdout)
    base_prompt_file = STEWARD_PROMPT_FILE if (is_steward and STEWARD_PROMPT_FILE.exists()) else PROMPT_FILE
    prompt = base_prompt_file.read_text(encoding="utf-8").strip() + "\n\n" + brief["markdown"] + lessons_block(state, cfg["lesson_count"])
    title = f"capsule {brief['suffix']}: {brief['label']}"[:120]
    body = {
        "prompt": prompt,
        "title": title,
        "sourceContext": {"source": cfg["source"], "githubRepoContext": {"startingBranch": cfg["starting_branch"]}},
        "automationMode": "AUTO_CREATE_PR",
        "requirePlanApproval": False,
    }
    if dry:
        log("dry_run_dispatch", title=title, prompt_chars=len(prompt), seq=next_seq)
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
    state["dispatch_seq"] = next_seq
    state["sessions"][sid] = {"created": iso(now()), "title": title, "suffix": brief["suffix"],
                              "label": brief["label"], "anchors": brief.get("anchors", []),
                              "state": session.get("state", "QUEUED")}
    log("dispatched", session=sid, title=title, seq=next_seq, url=session.get("url", ""))


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
    fleet_24h = len(day) + enclave_dispatched_24h()
    for cond, reason in ((len(active) >= cfg["max_active_sessions"], "too_many_active_sessions"),
                         (len(open_prs) >= cfg["max_open_prs"], "pr_backlog"),
                         (len(day) >= min(cfg["daily_cap"], 300), "daily_cap"),
                         (fleet_24h >= 270, "fleet_ultra_budget_cap")):
        if cond:
            log("skip", reason=reason, active=len(active), open_prs=len(open_prs), last_24h=len(day), fleet_24h=fleet_24h)
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
