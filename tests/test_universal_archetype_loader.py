#!/usr/bin/env python3
"""Universal Multi-Engine Archetype & Lore Package Loader Tests (`test_universal_archetype_loader.py`)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
sys.dont_write_bytecode = True

TYCOON_ROOT = Path(__file__).resolve().parents[1]
CAPSULES_ROOT = TYCOON_ROOT.parent
ENCLAVE_GODOT_ROOT = CAPSULES_ROOT / "enclave-digital-twin" / "godot"
ENEMIES_ROOT = CAPSULES_ROOT / "willow-desktop-pet" / "assets" / "source_art" / "enemies"


def resolve_godot_binary() -> Path:
    local_bin = Path.home() / ".local" / "bin" / "godot"
    if local_bin.is_file() and os.access(local_bin, os.X_OK):
        return local_bin
    which_bin = shutil.which("godot")
    if which_bin:
        return Path(which_bin).resolve()
    return local_bin


class UniversalArchetypeLoaderTests(unittest.TestCase):
    def test_gdscript_source_contracts_across_tycoon_and_enclave(self) -> None:
        loader_paths = (
            TYCOON_ROOT / "engine" / "willow_studio_loader.gd",
            ENCLAVE_GODOT_ROOT / "engine" / "willow_studio_loader.gd",
        )
        required_tokens = (
            "class_name WillowStudioLoader",
            'const ROSTER_MASTER_SCHEMA := "lfs-universal-asset-roster-index-v1"',
            'const TIER4_PACKAGE_SCHEMA := "lfs-tier4-game-asset-package-v1"',
            "CANONICAL_PIVOT",
            "func resolve_default_enemies_root(",
            "func load_roster_master_index(",
            "func list_available_archetypes(",
            "func load_archetype_package(",
            "func load_studio_bundle(",
            "func get_view_atlas_texture(",
            "func get_view_metadata(",
        )
        for path in loader_paths:
            self.assertTrue(path.is_file(), f"Missing loader script: {path.name}")
            src = path.read_text(encoding="utf-8")
            for token in required_tokens:
                self.assertIn(token, src, f"{path.name} missing required contract token: {token}")

    def test_headless_godot_universal_archetype_importer_tycoon_and_enclave(self) -> None:
        godot_bin = resolve_godot_binary()
        self.assertTrue(godot_bin.is_file(), "Godot 4.3 binary must be installed")

        harness_code = """extends SceneTree

func _init() -> void:
	var script_res: Script = load("res://engine/willow_studio_loader.gd")
	if script_res == null:
		print("HARNESS_ERROR: failed to load willow_studio_loader.gd")
		quit(1)
		return
	var loader: RefCounted = script_res.new()
	var roster_idx: Dictionary = loader.load_roster_master_index()
	if not bool(roster_idx.get("ok", false)):
		print("HARNESS_ERROR: load_roster_master_index failed: ", roster_idx)
		quit(1)
		return
	var available: Array = loader.list_available_archetypes()
	if available.size() < 13:
		print("HARNESS_ERROR: expected >= 13 archetypes, got ", available.size())
		quit(1)
		return
	var hound_pkg: Dictionary = loader.load_archetype_package("crucible_slag_hound")
	if not bool(hound_pkg.get("ok", false)):
		print("HARNESS_ERROR: crucible_slag_hound package load failed: ", hound_pkg)
		quit(1)
		return

	var loaded_count: int = 0
	for arch_id in available:
		var pkg: Dictionary = loader.load_archetype_package(str(arch_id))
		if not bool(pkg.get("ok", false)):
			print("HARNESS_ERROR: failed loading archetype ", arch_id)
			quit(1)
			return
		var ctex: CanvasTexture = pkg.get("canvas_texture", null) as CanvasTexture
		var lore: Dictionary = pkg.get("lore_profile", {})
		var rig: Dictionary = pkg.get("rig_bones", {})
		var pbr: Dictionary = pkg.get("pbr_textures", {})
		if ctex == null or ctex.diffuse_texture == null:
			print("HARNESS_ERROR: missing CanvasTexture for ", arch_id)
			quit(1)
			return
		if lore.is_empty() or rig.is_empty() or pbr.size() < 5:
			print("HARNESS_ERROR: incomplete metadata or PBR passes for ", arch_id)
			quit(1)
			return
		loaded_count += 1

	var frames: Array = hound_pkg.get("spritesheet_frames", [])
	var first_frame: Dictionary = frames[0] if frames.size() > 0 else {}
	var summary := {
		"ok": true,
		"archetype_count": available.size(),
		"loaded_count": loaded_count,
		"hound_display_name": str(hound_pkg.get("display_name", "")),
		"hound_has_canvas_texture": hound_pkg.get("canvas_texture", null) is CanvasTexture,
		"hound_has_depth_texture": hound_pkg.get("depth_texture", null) != null,
		"hound_has_emissive_texture": hound_pkg.get("emissive_texture", null) != null,
		"hound_frame_count": frames.size(),
		"hound_has_hurtbox": (first_frame.get("combatBoxes", {}) as Dictionary).has("hurtbox"),
		"hound_has_melee_hitbox": (first_frame.get("combatBoxes", {}) as Dictionary).has("meleeHitbox"),
		"hound_socket_count": (first_frame.get("socketAnchors", {}) as Dictionary).size(),
		"hound_bone_count": (hound_pkg.get("rig_bones", {}).get("bones", []) as Array).size(),
		"foot_pivot_x": float((hound_pkg.get("foot_pivot", Vector2.ZERO) as Vector2).x),
		"foot_pivot_y": float((hound_pkg.get("foot_pivot", Vector2.ZERO) as Vector2).y),
	}
	print("HARNESS_JSON:" + JSON.stringify(summary))
	quit(0)
"""
        with tempfile.TemporaryDirectory(prefix="archetype-loader-test-") as tmp:
            harness_path = Path(tmp) / "verify_universal_loader.gd"
            harness_path.write_text(harness_code, encoding="utf-8")

            for project_dir in (TYCOON_ROOT, ENCLAVE_GODOT_ROOT):
                proc = subprocess.run(
                    [
                        str(godot_bin),
                        "--headless",
                        "--path",
                        str(project_dir),
                        "-s",
                        str(harness_path),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=60,
                    check=False,
                )
                combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
                self.assertEqual(
                    proc.returncode,
                    0,
                    f"Headless Godot failed for {project_dir.name}:\n{combined}",
                )
                json_line = next(
                    (
                        line.split("HARNESS_JSON:", 1)[1].strip()
                        for line in combined.splitlines()
                        if "HARNESS_JSON:" in line
                    ),
                    "",
                )
                self.assertTrue(bool(json_line), f"Missing HARNESS_JSON output:\n{combined}")
                payload = json.loads(json_line)
                self.assertTrue(payload["ok"])
                self.assertGreaterEqual(payload["archetype_count"], 13)
                self.assertEqual(payload["loaded_count"], payload["archetype_count"])
                self.assertTrue(payload["hound_has_canvas_texture"])
                self.assertTrue(payload["hound_has_depth_texture"])
                self.assertTrue(payload["hound_has_emissive_texture"])
                self.assertGreaterEqual(payload["hound_frame_count"], 8)
                self.assertTrue(payload["hound_has_hurtbox"])
                self.assertTrue(payload["hound_has_melee_hitbox"])
                self.assertGreaterEqual(payload["hound_socket_count"], 1)
                self.assertGreaterEqual(payload["hound_bone_count"], 24)
                self.assertAlmostEqual(payload["foot_pivot_x"], 0.5, places=3)
                self.assertAlmostEqual(payload["foot_pivot_y"], 0.9, places=3)


def tearDownModule() -> None:
    shutil.rmtree(TYCOON_ROOT / "tests" / "__pycache__", ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
