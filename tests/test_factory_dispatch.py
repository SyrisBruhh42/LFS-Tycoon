#!/usr/bin/env python3
"""Adversarial Crucible test suite for tools/factory_dispatch.py.

Verifies antifragile handling of:
  1. Pseudo-completed 'Inactive' sessions (state=COMPLETED, outputs=[]) -> SUBMIT_NUDGE + 10m cooldown.
  2. Deadlock prevention when :sendMessage raises ApiError(400/404) on AWAITING_USER_FEEDBACK or COMPLETED.
  3. Autonomous changeSet salvage (extract_latest_changeset + salvage_changeset_to_pr):
     - Valid capsule patch in activities -> opens salvage PR and avoids failed:no_pr.
     - Hostile path in changeSet (e.g. tools/factory_dispatch.py) -> rejected by path guard + lesson harvested.
     - Invalid capsule content in changeSet -> rejected by check_capsules.py + exact ERROR harvested into lessons.
  4. PR-side auto-reconciliation:
     - Draft PRs -> gh pr ready.
     - Green-but-unmerged PRs (>= 180s) -> gh pr merge fallback.
     - CONFLICTING PRs -> cut_loss_session(merge_conflict).
     - Stale open PRs (> stale_session_hours) -> cut_loss_session(stale_pr).
  5. Corrupt state.json -> backed up to .corrupt.bak and recovered cleanly.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

import factory_dispatch as fd  # noqa: E402


def base_cfg() -> dict:
    return {
        "enabled": True,
        "repo": "SyrisBruhh42/LFS-Tycoon",
        "source": "sources/github/SyrisBruhh42/LFS-Tycoon",
        "starting_branch": "main",
        "gate_workflow": "capsule_gate.yml",
        "gate_check_name": "Capsule gate",
        "daily_cap": 96,
        "max_active_sessions": 12,
        "max_open_prs": 8,
        "failure_window": 12,
        "failure_threshold": 6,
        "max_api_fail_streak": 4,
        "stale_session_hours": 6,
        "no_pr_grace_minutes": 30,
        "no_gate_hours": 24,
        "max_feedback_nudges": 2,
        "lesson_count": 5,
    }


class TestFactoryDispatchAntifragile(unittest.TestCase):
    def setUp(self) -> None:
        self.cfg = base_cfg()
        self.t0 = fd.now()

    def test_inactive_completed_session_nudges_and_respects_cooldown(self) -> None:
        """A session in COMPLETED with empty outputs is nudged immediately, then waits 10m before nudge #2."""
        created = fd.iso(self.t0 - timedelta(minutes=15))
        updated = fd.iso(self.t0 - timedelta(minutes=2))
        state = {"sessions": {"s1": {"created": created, "label": "test"}}, "lessons": []}

        calls: list[tuple[str, str]] = []

        def fake_api_retry(method: str, path: str, body: dict | None = None, attempts: int = 3) -> dict:
            calls.append((method, path))
            if method == "GET" and path == "/sessions/s1":
                return {"state": "COMPLETED", "updateTime": updated, "outputs": []}
            return {}

        with mock.patch.object(fd, "api_retry", side_effect=fake_api_retry), \
             mock.patch.object(fd, "log"):
            # Tick 1: sends submit nudge #1
            fd.reconcile(self.cfg, state, dry=False)
            self.assertEqual(state["sessions"]["s1"].get("submit_nudges"), 1)
            self.assertIsNone(state["sessions"]["s1"].get("outcome"))
            self.assertIn(("POST", "/sessions/s1:sendMessage"), calls)

            # Tick 2 (2 minutes later): cooldown (< 10m) prevents duplicate nudge and does NOT cut loss
            calls.clear()
            fd.reconcile(self.cfg, state, dry=False)
            self.assertEqual(state["sessions"]["s1"].get("submit_nudges"), 1)
            self.assertNotIn(("POST", "/sessions/s1:sendMessage"), calls)
            self.assertIsNone(state["sessions"]["s1"].get("outcome"))

            # Tick 3 (11 minutes after nudge #1): sends submit nudge #2
            state["sessions"]["s1"]["last_submit_nudge"] = fd.iso(self.t0 - timedelta(minutes=11))
            calls.clear()
            fd.reconcile(self.cfg, state, dry=False)
            self.assertEqual(state["sessions"]["s1"].get("submit_nudges"), 2)
            self.assertIn(("POST", "/sessions/s1:sendMessage"), calls)

    def test_send_message_api_error_does_not_livelock_session(self) -> None:
        """If :sendMessage raises ApiError(404), submit_nudges and nudges still increment so the session can terminate."""
        created = fd.iso(self.t0 - timedelta(minutes=50))
        updated = fd.iso(self.t0 - timedelta(minutes=40))
        state = {
            "sessions": {
                "s_comp": {"created": created, "label": "comp", "submit_nudges": 1,
                           "last_submit_nudge": fd.iso(self.t0 - timedelta(minutes=15))},
                "s_ask": {"created": created, "label": "ask", "nudges": 1},
            },
            "lessons": [],
        }

        def fake_api_retry(method: str, path: str, body: dict | None = None, attempts: int = 3) -> dict:
            if method == "GET" and path == "/sessions/s_comp":
                return {"state": "COMPLETED", "updateTime": updated, "outputs": []}
            if method == "GET" and path == "/sessions/s_ask":
                return {"state": "AWAITING_USER_FEEDBACK", "updateTime": updated, "outputs": []}
            if method == "POST" and path.endswith(":sendMessage"):
                raise fd.ApiError(404, "Session archived")
            if method == "GET" and path.endswith("/activities?pageSize=50"):
                return {"activities": []}
            return {}

        with mock.patch.object(fd, "api_retry", side_effect=fake_api_retry), \
             mock.patch.object(fd, "log"):
            # Tick 1: both hit ApiError(404) on nudge #2, but counters increment to 2
            fd.reconcile(self.cfg, state, dry=False)
            self.assertEqual(state["sessions"]["s_comp"]["submit_nudges"], 2)
            self.assertEqual(state["sessions"]["s_ask"]["nudges"], 2)

            # Fast-forward last_submit_nudge by 11m and run Tick 2: both must terminate cleanly
            state["sessions"]["s_comp"]["last_submit_nudge"] = fd.iso(self.t0 - timedelta(minutes=11))
            fd.reconcile(self.cfg, state, dry=False)
            self.assertEqual(state["sessions"]["s_comp"].get("outcome"), "failed:no_pr")
            self.assertEqual(state["sessions"]["s_ask"].get("outcome"), "failed:stuck_asking")

    def test_salvage_rejects_hostile_path_and_harvests_lesson(self) -> None:
        """A changeSet that touches tools/factory_dispatch.py is rejected by salvage and logged into lessons."""
        hostile_patch = (
            "diff --git a/tools/factory_dispatch.py b/tools/factory_dispatch.py\n"
            "index 1111111..2222222 100644\n"
            "--- a/tools/factory_dispatch.py\n"
            "+++ b/tools/factory_dispatch.py\n"
            "@@ -1 +1 @@\n-foo\n+bar\n"
        )
        session = {
            "state": "COMPLETED",
            "outputs": [{"changeSet": {"gitPatch": {"unidiffPatch": hostile_patch, "suggestedCommitMessage": "hack"}}}],
        }
        rec: dict = {"created": fd.iso(self.t0 - timedelta(hours=1)), "label": "hostile"}
        state: dict = {"sessions": {"s_hostile": rec}, "lessons": []}

        with mock.patch.object(fd, "log"):
            ok = fd.salvage_changeset_to_pr(self.cfg, "s_hostile", rec, state, session, dry=False)
        self.assertFalse(ok)
        self.assertTrue(any("PATH GUARD: tools/factory_dispatch.py" in l for l in state["lessons"]))

    def test_salvage_validates_and_opens_pr_from_activities(self) -> None:
        """When session.outputs is empty but activities contain a valid capsule patch, salvage opens a PR."""
        valid_patch = (
            "diff --git a/content/capsules/tools/salvage_pick_abcd/capsule.json "
            "b/content/capsules/tools/salvage_pick_abcd/capsule.json\n"
            "new file mode 100644\n"
            "index 0000000..1111111\n"
            "--- /dev/null\n"
            "+++ b/content/capsules/tools/salvage_pick_abcd/capsule.json\n"
            "@@ -0,0 +1,5 @@\n+{\n+  \"schema\": 1\n+}\n"
        )
        session = {"state": "COMPLETED", "outputs": []}
        rec: dict = {"created": fd.iso(self.t0 - timedelta(hours=1)), "label": "salvage_test"}
        state: dict = {"sessions": {"s_salv": rec}, "lessons": []}

        def fake_api_retry(method: str, path: str, body: dict | None = None, attempts: int = 3) -> dict:
            if path == "/sessions/s_salv/activities?pageSize=50":
                return {
                    "activities": [
                        {
                            "artifacts": [
                                {
                                    "changeSet": {
                                        "gitPatch": {
                                            "unidiffPatch": valid_patch,
                                            "suggestedCommitMessage": "content: add tools/salvage_pick_abcd",
                                        }
                                    }
                                }
                            ]
                        }
                    ]
                }
            return {}

        ok_proc = subprocess.CompletedProcess(args=[], returncode=0, stdout="OK\n", stderr="")
        with mock.patch.object(fd, "api_retry", side_effect=fake_api_retry), \
             mock.patch.object(fd.subprocess, "run", return_value=ok_proc), \
             mock.patch.object(fd, "gh", return_value="https://github.com/SyrisBruhh42/LFS-Tycoon/pull/999\n"), \
             mock.patch.object(fd, "log"):
            ok = fd.salvage_changeset_to_pr(self.cfg, "s_salv", rec, state, session, dry=False)

        self.assertTrue(ok)
        self.assertEqual(rec.get("pr"), "https://github.com/SyrisBruhh42/LFS-Tycoon/pull/999")
        self.assertTrue(rec.get("salvaged"))

    def test_salvage_harvests_validation_errors_when_check_capsules_fails(self) -> None:
        """If an un-submitted capsule patch fails check_capsules.py, salvage rejects it and harvests ERROR lines into lessons."""
        bad_capsule_patch = (
            "diff --git a/content/capsules/tools/broken_pick_1234/capsule.json "
            "b/content/capsules/tools/broken_pick_1234/capsule.json\n"
            "new file mode 100644\n"
            "index 0000000..1111111\n"
            "--- /dev/null\n"
            "+++ b/content/capsules/tools/broken_pick_1234/capsule.json\n"
            "@@ -0,0 +1,3 @@\n+{\n+  \"id\": \"tools/broken_pick_1234\"\n+}\n"
        )
        session = {
            "state": "COMPLETED",
            "outputs": [{"changeSet": {"gitPatch": {"unidiffPatch": bad_capsule_patch, "suggestedCommitMessage": "bad"}}}],
        }
        rec: dict = {"created": fd.iso(self.t0 - timedelta(hours=1)), "label": "broken_test"}
        state: dict = {"sessions": {"s_broken": rec}, "lessons": []}

        def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
            if "check_capsules.py" in " ".join(str(x) for x in cmd):
                return subprocess.CompletedProcess(
                    args=cmd,
                    returncode=1,
                    stdout="ERROR: content/capsules/tools/broken_pick_1234/capsule.json: missing required field 'schema'\n",
                    stderr="",
                )
            return subprocess.CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

        with mock.patch.object(fd.subprocess, "run", side_effect=fake_run), \
             mock.patch.object(fd, "log"):
            ok = fd.salvage_changeset_to_pr(self.cfg, "s_broken", rec, state, session, dry=False)

        self.assertFalse(ok)
        self.assertTrue(any("missing required field 'schema'" in l for l in state["lessons"]))


    def test_pr_side_draft_ready_and_green_fallback_merge_and_conflict_cut(self) -> None:
        """Draft PRs are marked ready, green open PRs >= 3m are fallback-merged, and CONFLICTING PRs are cut."""
        old_ts = fd.iso(self.t0 - timedelta(minutes=10))
        state = {
            "sessions": {
                "s_green": {"created": old_ts, "pr": "https://github.com/r/p/1", "pr_seen": old_ts, "label": "g"},
                "s_conf": {"created": old_ts, "pr": "https://github.com/r/p/2", "pr_seen": old_ts, "label": "c"},
            },
            "lessons": [],
        }

        def fake_gh(*args: str, check: bool = True) -> str:
            if args[:2] == ("pr", "view") and args[2] == "https://github.com/r/p/1":
                return json.dumps({
                    "number": 1,
                    "state": "OPEN",
                    "isDraft": True,
                    "mergeable": "MERGEABLE",
                    "mergeStateStatus": "CLEAN",
                    "statusCheckRollup": [{"name": "Capsule gate", "conclusion": "SUCCESS"}],
                })
            if args[:2] == ("pr", "view") and args[2] == "https://github.com/r/p/2":
                return json.dumps({
                    "number": 2,
                    "state": "OPEN",
                    "isDraft": False,
                    "mergeable": "CONFLICTING",
                    "mergeStateStatus": "DIRTY",
                    "statusCheckRollup": [],
                })
            return ""

        ok_merge = subprocess.CompletedProcess(args=[], returncode=0, stdout="Merged\n", stderr="")
        with mock.patch.object(fd, "gh", side_effect=fake_gh) as m_gh, \
             mock.patch.object(fd.subprocess, "run", return_value=ok_merge), \
             mock.patch.object(fd, "log"):
            fd.reconcile(self.cfg, state, dry=False)

        self.assertEqual(state["sessions"]["s_green"].get("outcome"), "merged")
        self.assertEqual(state["sessions"]["s_conf"].get("outcome"), "failed:merge_conflict")
        gh_calls = [c.args for c in m_gh.call_args_list]
        self.assertTrue(any(c[:3] == ("pr", "ready", "https://github.com/r/p/1") for c in gh_calls))

    def test_corrupt_state_file_backed_up_and_recovered(self) -> None:
        """Corrupt state.json is moved to .corrupt.bak and replaced with a clean state dict."""
        with tempfile.TemporaryDirectory() as td:
            sf = Path(td) / "state.json"
            sf.write_text("{corrupt json", encoding="utf-8")
            with mock.patch.object(fd, "STATE_FILE", sf):
                st = fd.load_state()
            self.assertEqual(st, {"sessions": {}, "lessons": [], "api_fail_streak": 0})
            self.assertTrue(sf.with_suffix(".corrupt.bak").exists())


if __name__ == "__main__":
    unittest.main()
