#!/usr/bin/env python3
"""
Gate G1 & Static G3 Validator for LFS-Tycoon (Codename: StrataPaper).
Zero external dependencies (Python 3.10+ stdlib only).

Enforces Foundation Laws L1-L12:
  - Strict JSON parsing: rejects duplicate keys, trailing commas, NaN/Inf, >2^53 ints.
  - Law L1: Closed verbs (events, actions, affordances, stats) with build-time fuzzy suggestions.
  - Law L2: Path-derived identity (<namespace>/<slug>).
  - Law L3: Backward edges (offered_by, biome_weights, item refs point to valid capsules).
  - Law L5: Namespaced state (self.<var> declared locally; shared.<var> in vocab/shared_vars.json).
  - Law L7: Deterministic & safe expressions via Python AST allow-list (bans randf, OS, FileAccess, etc.).
  - Law L11: Static economy containment (detects positive-gain conversion cycles and invalid numeric bounds).
"""
import argparse
import ast
import difflib
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Set, Tuple

ROOT = Path(__file__).resolve().parent.parent
VOCAB_DIR = ROOT / "vocab"
DEFAULT_CAPSULES_DIR = ROOT / "content" / "capsules"

MAX_SAFE_INT = (1 << 53) - 1
TRAILING_COMMA_RE = re.compile(r",\s*([\]}])")


class DuplicateKeyError(ValueError):
    pass


def strict_json_loads(raw_text: str) -> Any:
    if not raw_text or not raw_text.strip():
        raise ValueError("Empty JSON file.")
    m = TRAILING_COMMA_RE.search(raw_text)
    if m:
        raise ValueError(f"Trailing comma before '{m.group(1)}' is forbidden (Law L9).")

    def no_dup_pairs(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
        out: Dict[str, Any] = {}
        for k, v in pairs:
            if k in out:
                raise DuplicateKeyError(f"Duplicate JSON key '{k}' is forbidden (Law L9).")
            out[k] = v
        return out

    def reject_nan_inf(constant: str) -> Any:
        raise ValueError(f"Non-finite JSON constant '{constant}' is forbidden.")

    def check_int(num_str: str) -> int:
        val = int(num_str)
        if abs(val) > MAX_SAFE_INT:
            raise ValueError(f"Integer {num_str} exceeds IEEE-754 53-bit exact precision required by Godot JSON.")
        return val

    return json.loads(
        raw_text,
        object_pairs_hook=no_dup_pairs,
        parse_constant=reject_nan_inf,
        parse_int=check_int,
    )


def suggest(bad_token: str, valid_options: Set[str], aliases: Dict[str, str] | None = None) -> str:
    if aliases and bad_token in aliases:
        return f" (Hint: '{bad_token}' is an alias for '{aliases[bad_token]}'; use canonical '{aliases[bad_token]}'.)"
    matches = difflib.get_close_matches(bad_token, sorted(valid_options), n=2, cutoff=0.55)
    if matches:
        return f" (Did you mean: {', '.join(repr(m) for m in matches)}?)"
    return f" (Valid options: {', '.join(sorted(list(valid_options))[:8])}...)"


class ExpressionAllowListLinter:
    """Validates expression strings against Law L1, L5, and L7 using Python's AST."""

    ALLOWED_TILE_FIELDS = {
        "depth",
        "max_depth_reached",
        "tier",
        "hp",
        "max_hp",
        "fluid_level",
        "is_hazard",
        "is_strict_locked",
        "covered_by_self",
    }
    ALLOWED_PLAYER_FIELDS = {"max_depth", "grime", "is_rested", "drunk_seconds"}
    ALLOWED_TOOL_FIELDS = {"tier", "dps", "charge_left", "durability_left", "overkill_damage"}
    ALLOWED_CTX_FIELDS = {"dt", "now", "is_direct_tap", "is_secondary_damage"}
    FORBIDDEN_CALLS = {
        "randf",
        "randi",
        "randfn",
        "randf_range",
        "randi_range",
        "seed",
        "randomize",
        "print",
        "load",
        "preload",
        "instance_from_id",
        "eval",
        "exec",
    }
    FORBIDDEN_ROOTS = {
        "OS",
        "Engine",
        "FileAccess",
        "DirAccess",
        "ClassDB",
        "ProjectSettings",
        "DisplayServer",
        "RenderingServer",
        "ResourceLoader",
        "ResourceSaver",
        "Time",
        "Input",
    }

    def __init__(self, allowed_funcs: Set[str], allowed_roots: Set[str], shared_vars: Set[str]) -> None:
        self.allowed_funcs = allowed_funcs
        self.allowed_roots = allowed_roots
        self.shared_vars = shared_vars

    def validate_expr(
        self,
        expr_str: str,
        local_stats: Set[str],
        local_vars: Set[str],
        context_label: str,
    ) -> List[str]:
        errors: List[str] = []
        if not isinstance(expr_str, str) or not expr_str.strip():
            return [f"{context_label}: Expression must be a non-empty string."]

        if "__" in expr_str:
            errors.append(f"{context_label}: Double-underscore attribute access forbidden in '{expr_str}'.")
            return errors

        # Normalize GDScript '&&', '||', '!' if present into Python AST equivalents, though contract prefers 'and'/'or'/'not'
        py_expr = expr_str.replace("&&", " and ").replace("||", " or ")
        try:
            tree = ast.parse(py_expr, mode="eval")
        except SyntaxError as exc:
            return [f"{context_label}: Syntax error in expression '{expr_str}': {exc.msg}"]

        for node in ast.walk(tree):
            if isinstance(node, (ast.Lambda, ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp, ast.Await, ast.Yield)):
                errors.append(f"{context_label}: Forbidden construct {type(node).__name__} in '{expr_str}'.")
            elif isinstance(node, ast.Subscript):
                errors.append(f"{context_label}: Subscript/indexing '[]' forbidden in '{expr_str}'.")
            elif isinstance(node, (ast.BinOp,)) and isinstance(node.op, (ast.Div, ast.FloorDiv, ast.Mod)):
                # Catch literal divide by zero or obvious (x - x) denominator
                if isinstance(node.right, ast.Constant) and node.right.value == 0:
                    errors.append(f"{context_label}: Literal division by zero in '{expr_str}'.")
                elif isinstance(node.right, ast.BinOp) and isinstance(node.right.op, ast.Sub):
                    if ast.dump(node.right.left) == ast.dump(node.right.right):
                        errors.append(f"{context_label}: Self-canceling zero denominator in '{expr_str}'.")
            elif isinstance(node, ast.Call):
                if not isinstance(node.func, ast.Name):
                    errors.append(
                        f"{context_label}: Method calls on objects ('{ast.unparse(node.func)}(...)') are forbidden in '{expr_str}' (Law L7)."
                    )
                else:
                    fn_name = node.func.id
                    if fn_name in self.FORBIDDEN_CALLS:
                        errors.append(
                            f"{context_label}: Forbidden nondeterministic/unsafe function '{fn_name}()' in '{expr_str}' (use 'roll(prob)' instead)."
                        )
                    elif fn_name not in self.allowed_funcs:
                        errors.append(
                            f"{context_label}: Unknown function '{fn_name}()' in '{expr_str}'{suggest(fn_name, self.allowed_funcs)}"
                        )
            elif isinstance(node, ast.Name):
                # Standalone name that is not the function name in a Call
                name = node.id
                if name in ("true", "false"):
                    continue
                if name in self.FORBIDDEN_ROOTS:
                    errors.append(f"{context_label}: Forbidden engine singleton '{name}' in '{expr_str}'.")
                elif name not in self.allowed_roots and name not in self.allowed_funcs and name not in self.FORBIDDEN_CALLS:
                    errors.append(
                        f"{context_label}: Bare identifier '{name}' in '{expr_str}' must be scoped (e.g. 'self.{name}', 'tile.{name}', 'shared.{name}')."
                    )
            elif isinstance(node, ast.Attribute):
                chain = self._extract_attr_chain(node)
                if chain is not None and len(chain) >= 2:
                    root = chain[0]
                    if root in self.FORBIDDEN_ROOTS:
                        errors.append(f"{context_label}: Forbidden singleton '{root}' in '{expr_str}'.")
                    elif root == "self":
                        if len(chain) == 3 and chain[1] == "stats":
                            if chain[2] not in local_stats:
                                errors.append(
                                    f"{context_label}: 'self.stats.{chain[2]}' is not declared in capsule 'stats'{suggest(chain[2], local_stats)}"
                                )
                        elif len(chain) == 2 and chain[1] != "stats":
                            if chain[1] not in local_vars and chain[1] not in local_stats:
                                errors.append(
                                    f"{context_label}: 'self.{chain[1]}' is not declared in capsule 'vars' or 'stats'{suggest(chain[1], local_vars | local_stats)}"
                                )
                    elif root == "shared":
                        if len(chain) != 2 or chain[1] not in self.shared_vars:
                            bad_key = chain[1] if len(chain) >= 2 else ""
                            errors.append(
                                f"{context_label}: 'shared.{bad_key}' is not declared in vocab/shared_vars.json (Law L5){suggest(bad_key, self.shared_vars)}"
                            )
                    elif root == "tile":
                        if len(chain) != 2 or chain[1] not in self.ALLOWED_TILE_FIELDS:
                            bad_key = chain[1] if len(chain) >= 2 else ""
                            errors.append(
                                f"{context_label}: Unknown tile property 'tile.{bad_key}'{suggest(bad_key, self.ALLOWED_TILE_FIELDS)}"
                            )
                    elif root == "player":
                        if len(chain) != 2 or chain[1] not in self.ALLOWED_PLAYER_FIELDS:
                            bad_key = chain[1] if len(chain) >= 2 else ""
                            errors.append(
                                f"{context_label}: Unknown player property 'player.{bad_key}'{suggest(bad_key, self.ALLOWED_PLAYER_FIELDS)}"
                            )
                    elif root == "tool":
                        if len(chain) != 2 or chain[1] not in self.ALLOWED_TOOL_FIELDS:
                            bad_key = chain[1] if len(chain) >= 2 else ""
                            errors.append(
                                f"{context_label}: Unknown tool property 'tool.{bad_key}'{suggest(bad_key, self.ALLOWED_TOOL_FIELDS)}"
                            )
                    elif root == "ctx":
                        if len(chain) != 2 or chain[1] not in self.ALLOWED_CTX_FIELDS:
                            bad_key = chain[1] if len(chain) >= 2 else ""
                            errors.append(
                                f"{context_label}: Unknown ctx property 'ctx.{bad_key}'{suggest(bad_key, self.ALLOWED_CTX_FIELDS)}"
                            )

        return errors

    @staticmethod
    def _extract_attr_chain(node: ast.Attribute) -> List[str] | None:
        parts: List[str] = []
        cur: ast.AST = node
        while isinstance(cur, ast.Attribute):
            parts.append(cur.attr)
            cur = cur.value
        if isinstance(cur, ast.Name):
            parts.append(cur.id)
            parts.reverse()
            return parts
        return None


def load_vocab() -> Dict[str, Any]:
    return {
        "gmst": strict_json_loads((VOCAB_DIR / "gmst.json").read_text(encoding="utf-8")),
        "events": strict_json_loads((VOCAB_DIR / "events.json").read_text(encoding="utf-8")),
        "actions": strict_json_loads((VOCAB_DIR / "actions.json").read_text(encoding="utf-8")),
        "affordances": strict_json_loads((VOCAB_DIR / "affordances.json").read_text(encoding="utf-8")),
        "shared_vars": strict_json_loads((VOCAB_DIR / "shared_vars.json").read_text(encoding="utf-8")),
    }


def validate_single_capsule(
    cap_id: str,
    cap_path: Path,
    vocab: Dict[str, Any],
    known_ids: Set[str],
    expr_linter: ExpressionAllowListLinter,
) -> Tuple[List[str], Dict[str, Any] | None]:
    errors: List[str] = []
    try:
        raw = cap_path.read_text(encoding="utf-8")
        data = strict_json_loads(raw)
    except Exception as exc:
        return [f"[{cap_id}] JSON parse failure: {exc}"], None

    if not isinstance(data, dict):
        return [f"[{cap_id}] Root JSON value must be an object."], None

    # Law L2: Path-derived identity
    if "id" in data and data["id"] != cap_id:
        errors.append(f"[{cap_id}] Law L2 violation: explicit 'id' field '{data['id']}' disagrees with folder path '{cap_id}'. Omit 'id' or match path.")

    if data.get("schema") != 1:
        errors.append(f"[{cap_id}] Missing or unsupported 'schema': {data.get('schema')} (expected 1).")

    meta = data.get("meta")
    if not isinstance(meta, dict) or not isinstance(meta.get("name"), str) or not meta["name"].strip():
        errors.append(f"[{cap_id}] Missing required non-empty 'meta.name'.")

    valid_affordances = set(vocab["affordances"]["affordances"])
    affordances = data.get("affordances")
    if not isinstance(affordances, list) or not affordances:
        errors.append(f"[{cap_id}] 'affordances' must be a non-empty list.")
    else:
        for aff in affordances:
            if aff not in valid_affordances:
                errors.append(f"[{cap_id}] Unknown affordance '{aff}'{suggest(str(aff), valid_affordances)}")

    tags = data.get("tags")
    if not isinstance(tags, list) or not all(isinstance(t, str) and t.strip() for t in tags):
        errors.append(f"[{cap_id}] 'tags' must be a list of non-empty strings.")

    stats = data.get("stats", {})
    if not isinstance(stats, dict):
        errors.append(f"[{cap_id}] 'stats' must be an object.")
        stats = {}

    # Check mathematical bounds in stats (Law L9 & Ingestion safety)
    if "base_hp" in stats and (not isinstance(stats["base_hp"], (int, float)) or stats["base_hp"] <= 0):
        errors.append(f"[{cap_id}] 'stats.base_hp' must be > 0 (got {stats['base_hp']}).")
    if "l_step" in stats and (not isinstance(stats["l_step"], (int, float)) or stats["l_step"] <= 0):
        errors.append(f"[{cap_id}] 'stats.l_step' must be > 0 to avoid tier divide-by-zero (got {stats['l_step']}).")
    if "clump_xy" in stats and (not isinstance(stats["clump_xy"], (int, float)) or stats["clump_xy"] <= 0):
        errors.append(f"[{cap_id}] 'stats.clump_xy' must be > 0 (got {stats['clump_xy']}).")
    if "pipe_z" in stats and (not isinstance(stats["pipe_z"], (int, float)) or stats["pipe_z"] <= 0):
        errors.append(f"[{cap_id}] 'stats.pipe_z' must be > 0 (got {stats['pipe_z']}).")
    if "spawn_prob" in stats and (not isinstance(stats["spawn_prob"], (int, float)) or not (0.0 <= stats["spawn_prob"] <= 1.0)):
        errors.append(f"[{cap_id}] 'stats.spawn_prob' must be in [0.0, 1.0] (got {stats['spawn_prob']}).")
    if "base_value" in stats and (not isinstance(stats["base_value"], (int, float)) or stats["base_value"] < 0):
        errors.append(f"[{cap_id}] 'stats.base_value' must be >= 0 (got {stats['base_value']}).")

    valid_tool_types = set(vocab["affordances"]["tool_types"])
    for tk in ("tool_type", "ideal_tool"):
        if tk in stats and stats[tk] not in valid_tool_types:
            errors.append(f"[{cap_id}] Invalid stats.{tk} '{stats[tk]}'{suggest(str(stats[tk]), valid_tool_types)}")

    vars_dict = data.get("vars", {})
    if not isinstance(vars_dict, dict) or not all(isinstance(v, (int, float)) for v in vars_dict.values()):
        errors.append(f"[{cap_id}] 'vars' must be an object mapping register names to numbers.")
        vars_dict = {}

    local_stats = set(stats.keys())
    local_vars = set(vars_dict.keys())
    shared_vars = set(vocab["shared_vars"]["shared_vars"].keys())

    # Validate modifiers (Law L6)
    valid_mod_stats = set(vocab["affordances"]["modifiable_stats"])
    valid_phases = set(vocab["affordances"]["modifier_phases"])
    modifiers = data.get("modifiers", [])
    if not isinstance(modifiers, list):
        errors.append(f"[{cap_id}] 'modifiers' must be a list.")
        modifiers = []
    for idx, mod in enumerate(modifiers):
        if not isinstance(mod, dict):
            errors.append(f"[{cap_id}] modifiers[{idx}] must be an object.")
            continue
        st = mod.get("stat")
        ph = mod.get("phase")
        val = mod.get("value")
        if st not in valid_mod_stats:
            errors.append(f"[{cap_id}] modifiers[{idx}].stat '{st}' invalid{suggest(str(st), valid_mod_stats)}")
        if ph not in valid_phases:
            errors.append(f"[{cap_id}] modifiers[{idx}].phase '{ph}' invalid{suggest(str(ph), valid_phases)}")
        errors.extend(expr_linter.validate_expr(str(val), local_stats, local_vars, f"[{cap_id}] modifiers[{idx}].value"))
        if "if" in mod:
            errors.extend(expr_linter.validate_expr(str(mod["if"]), local_stats, local_vars, f"[{cap_id}] modifiers[{idx}].if"))

    # Validate reactions (Law L1, L7, L8)
    valid_events = set(vocab["events"]["events"])
    event_aliases = vocab["events"].get("aliases", {})
    valid_actions = vocab["actions"]["actions"]
    reactions = data.get("reactions", [])
    if not isinstance(reactions, list):
        errors.append(f"[{cap_id}] 'reactions' must be a list.")
        reactions = []

    for r_idx, rx in enumerate(reactions):
        if not isinstance(rx, dict):
            errors.append(f"[{cap_id}] reactions[{r_idx}] must be an object.")
            continue
        ev = rx.get("on")
        if ev not in valid_events:
            errors.append(f"[{cap_id}] reactions[{r_idx}].on '{ev}' invalid{suggest(str(ev), valid_events, event_aliases)}")
        if "if" in rx:
            errors.extend(expr_linter.validate_expr(str(rx["if"]), local_stats, local_vars, f"[{cap_id}] reactions[{r_idx}].if"))

        do_list = rx.get("do", [])
        if not isinstance(do_list, list) or not do_list:
            errors.append(f"[{cap_id}] reactions[{r_idx}].do must be a non-empty list of actions.")
            continue
        if len(do_list) > 8:
            errors.append(f"[{cap_id}] reactions[{r_idx}].do exceeds Law L8 max 8 actions per hook.")

        for a_idx, act_obj in enumerate(do_list):
            if not isinstance(act_obj, dict):
                errors.append(f"[{cap_id}] reactions[{r_idx}].do[{a_idx}] must be an object.")
                continue
            act_name = act_obj.get("act")
            if act_name not in valid_actions:
                errors.append(
                    f"[{cap_id}] reactions[{r_idx}].do[{a_idx}].act '{act_name}' invalid{suggest(str(act_name), set(valid_actions.keys()))}"
                )
                continue
            spec = valid_actions[act_name]
            for req_k in spec["required"]:
                if req_k not in act_obj:
                    errors.append(f"[{cap_id}] reactions[{r_idx}].do[{a_idx}] ('{act_name}') missing required key '{req_k}'.")
            if "if" in act_obj:
                errors.extend(
                    expr_linter.validate_expr(
                        str(act_obj["if"]), local_stats, local_vars, f"[{cap_id}] reactions[{r_idx}].do[{a_idx}].if"
                    )
                )

            # Action-specific checks
            if act_name == "deal_damage":
                tgt = act_obj.get("target")
                if tgt not in spec["targets"]:
                    errors.append(f"[{cap_id}] deal_damage invalid target '{tgt}'{suggest(str(tgt), set(spec['targets']))}")
                if "amount" in act_obj:
                    errors.extend(
                        expr_linter.validate_expr(
                            str(act_obj["amount"]), local_stats, local_vars, f"[{cap_id}] deal_damage.amount"
                        )
                    )
                # Law L8: Reject direct unguarded infinite damage self-recursion
                if ev == "on_damage_dealt" and "ctx.is_secondary_damage" not in str(rx.get("if", "")):
                    errors.append(
                        f"[{cap_id}] Law L8 violation: 'deal_damage' inside 'on_damage_dealt' must guard with 'ctx.is_secondary_damage == 0' to prevent infinite damage recursion."
                    )
            elif act_name in ("var_set", "var_add"):
                v_target = str(act_obj.get("var", ""))
                if v_target.startswith("self."):
                    v_key = v_target.split(".", 1)[1]
                    if v_key not in local_vars:
                        errors.append(
                            f"[{cap_id}] {act_name} target '{v_target}' is not declared in 'vars'{suggest(v_key, local_vars)}"
                        )
                elif v_target.startswith("shared."):
                    v_key = v_target.split(".", 1)[1]
                    if v_key not in shared_vars:
                        errors.append(
                            f"[{cap_id}] {act_name} target '{v_target}' is not declared in vocab/shared_vars.json{suggest(v_key, shared_vars)}"
                        )
                else:
                    errors.append(f"[{cap_id}] {act_name} target '{v_target}' must start with 'self.' or 'shared.' (Law L5).")
                expr_k = "value" if act_name == "var_set" else "by"
                if expr_k in act_obj:
                    errors.extend(
                        expr_linter.validate_expr(
                            str(act_obj[expr_k]), local_stats, local_vars, f"[{cap_id}] {act_name}.{expr_k}"
                        )
                    )
            elif act_name in ("spawn_item", "consume_item"):
                item_ref = act_obj.get("item")
                if item_ref not in known_ids:
                    errors.append(f"[{cap_id}] {act_name} references unknown capsule '{item_ref}'{suggest(str(item_ref), known_ids)}")
                if "qty" in act_obj:
                    errors.extend(
                        expr_linter.validate_expr(str(act_obj["qty"]), local_stats, local_vars, f"[{cap_id}] {act_name}.qty")
                    )
            elif act_name == "transform_tile":
                blk_ref = act_obj.get("block")
                if blk_ref not in known_ids:
                    errors.append(f"[{cap_id}] transform_tile references unknown block '{blk_ref}'{suggest(str(blk_ref), known_ids)}")
            elif act_name == "transmute_self":
                into_ref = act_obj.get("into")
                if into_ref not in known_ids:
                    errors.append(f"[{cap_id}] transmute_self references unknown capsule '{into_ref}'{suggest(str(into_ref), known_ids)}")

    # Law L3: Backward edges in offered_by and biome_weights
    for o_idx, offer in enumerate(data.get("offered_by", [])):
        if not isinstance(offer, dict):
            errors.append(f"[{cap_id}] offered_by[{o_idx}] must be an object.")
            continue
        vendor = offer.get("vendor")
        if vendor not in known_ids:
            errors.append(f"[{cap_id}] offered_by[{o_idx}].vendor '{vendor}' unknown{suggest(str(vendor), known_ids)}")
        price = offer.get("price", {})
        if not isinstance(price, dict) or not price:
            errors.append(f"[{cap_id}] offered_by[{o_idx}].price must be a non-empty map of capsule_id -> quantity.")
        else:
            for curr_id, qty in price.items():
                if curr_id not in known_ids:
                    errors.append(f"[{cap_id}] offered_by[{o_idx}].price currency '{curr_id}' unknown{suggest(str(curr_id), known_ids)}")
                if not isinstance(qty, (int, float)) or qty <= 0:
                    errors.append(f"[{cap_id}] offered_by[{o_idx}].price['{curr_id}'] must be > 0.")

    for b_target, b_weight in data.get("biome_weights", {}).items():
        if b_target not in known_ids:
            errors.append(f"[{cap_id}] biome_weights target '{b_target}' unknown{suggest(str(b_target), known_ids)}")
        if not isinstance(b_weight, (int, float)) or b_weight < 0:
            errors.append(f"[{cap_id}] biome_weights['{b_target}'] must be >= 0.")

    offline = data.get("offline", "none")
    valid_offline = set(vocab["affordances"]["offline_modes"])
    if offline not in valid_offline:
        errors.append(f"[{cap_id}] invalid offline mode '{offline}'{suggest(str(offline), valid_offline)}")

    return errors, data


def check_economy_containment(capsules: Dict[str, Dict[str, Any]]) -> List[str]:
    """Law L11: Static economy containment (checks for positive-gain purchase/consume value explosions)."""
    errors: List[str] = []
    base_values: Dict[str, float] = {}
    for cid, data in capsules.items():
        base_values[cid] = float(data.get("stats", {}).get("base_value", 1.0))

    for cid, data in capsules.items():
        item_val = base_values.get(cid, 1.0)
        # Check if on_consume spawns items worth strictly more than the item itself or its purchase cost
        spawned_val_on_consume = 0.0
        for rx in data.get("reactions", []):
            if rx.get("on") == "on_consume":
                for act in rx.get("do", []):
                    if act.get("act") == "spawn_item":
                        target_id = act.get("item", "")
                        try:
                            qty = float(act.get("qty", "1"))
                        except ValueError:
                            qty = 1.0
                        spawned_val_on_consume += qty * base_values.get(target_id, 1.0)

        for offer in data.get("offered_by", []):
            cost_val = 0.0
            for curr_id, qty in offer.get("price", {}).items():
                if isinstance(qty, (int, float)):
                    cost_val += float(qty) * base_values.get(curr_id, 1.0)
            if cost_val > 0:
                if item_val > cost_val * 10.0:
                    errors.append(
                        f"[{cid}] Law L11 Economy Outlier: base_value ({item_val}) exceeds >10x purchase cost value ({cost_val}) at vendor '{offer.get('vendor')}'."
                    )
                if spawned_val_on_consume > cost_val:
                    errors.append(
                        f"[{cid}] Law L11 Positive-Gain Arbitrage Loop: buying '{cid}' (cost value {cost_val}) and consuming it spawns resources worth {spawned_val_on_consume}."
                    )
    return errors


def discover_capsules(base_dir: Path) -> Dict[str, Path]:
    found: Dict[str, Path] = {}
    if not base_dir.exists():
        return found
    for p in sorted(base_dir.glob("*/*/capsule.json")):
        rel = p.relative_to(base_dir)
        cap_id = f"{rel.parts[0]}/{rel.parts[1]}"
        found[cap_id] = p
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate LFS-Tycoon capsules (Gate G1 & Static G3).")
    parser.add_argument("--dir", type=Path, default=DEFAULT_CAPSULES_DIR, help="Capsules root directory")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on any error")
    args = parser.parse_args()

    vocab = load_vocab()
    expr_linter = ExpressionAllowListLinter(
        allowed_funcs=set(vocab["affordances"]["expression_functions"]),
        allowed_roots=set(vocab["affordances"]["expression_roots"]),
        shared_vars=set(vocab["shared_vars"]["shared_vars"].keys()),
    )

    # Always include canonical content/capsules IDs as known targets even when validating a test dir
    canonical_map = discover_capsules(DEFAULT_CAPSULES_DIR)
    target_map = discover_capsules(args.dir)
    known_ids = set(canonical_map.keys()) | set(target_map.keys())

    all_errors: List[str] = []
    parsed_capsules: Dict[str, Dict[str, Any]] = {}

    for cap_id, cap_path in target_map.items():
        errs, data = validate_single_capsule(cap_id, cap_path, vocab, known_ids, expr_linter)
        if data is not None:
            parsed_capsules[cap_id] = data
        all_errors.extend(errs)

    # Load canonical capsules too for cross-capsule economy checks
    full_economy_pool = dict(parsed_capsules)
    if args.dir != DEFAULT_CAPSULES_DIR:
        for cid, cpath in canonical_map.items():
            if cid not in full_economy_pool:
                try:
                    full_economy_pool[cid] = strict_json_loads(cpath.read_text(encoding="utf-8"))
                except Exception:
                    pass

    econ_errors = check_economy_containment(full_economy_pool)
    # Filter economy errors to capsules in target_map
    for e in econ_errors:
        if any(e.startswith(f"[{cid}]") for cid in target_map):
            all_errors.append(e)

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}")
        print(f"\nFAILED: {len(all_errors)} validation error(s) across {len(target_map)} capsules.")
        return 1

    print(f"ALL CAPSULES VALID ({len(target_map)} capsules verified against Laws L1-L12).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
