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


def check_prereq_graph(capsules: Dict[str, Dict[str, Any]]) -> List[str]:
    """Law L13: non-block prerequisites (skill brackets, stations, fusion bases) priced in offered_by must be
    obtainable (themselves offered by a vendor), self-/cycle-free, and skill_bracket capsules must be upgrades/* with an offer.
    Prevents Jules from minting dead recipes gated behind an item no player can ever acquire."""
    errors: List[str] = []
    offered = {cid for cid, d in capsules.items() if d.get("offered_by")}
    edges: Dict[str, Set[str]] = {}
    for cid, d in capsules.items():
        tags = d.get("tags", []) if isinstance(d.get("tags"), list) else []
        if "skill_bracket" in tags:
            if not cid.startswith("upgrades/"):
                errors.append(f"[{cid}] Law L13: 'skill_bracket' capsules must live in upgrades/* (books can self-destruct and silently re-lock recipes).")
            if not d.get("offered_by"):
                errors.append(f"[{cid}] Law L13: 'skill_bracket' capsule has no offered_by; it is unobtainable, so every recipe gated on it would be dead.")
        for off in d.get("offered_by", []) or []:
            if not isinstance(off, dict) or not isinstance(off.get("price"), dict):
                continue
            for curr in off["price"]:
                if curr.startswith("blocks/") or curr not in capsules:
                    continue
                if curr == cid:
                    errors.append(f"[{cid}] Law L13: recipe requires itself in price.")
                    continue
                edges.setdefault(cid, set()).add(curr)
                if curr not in offered:
                    errors.append(f"[{cid}] Law L13: prerequisite '{curr}' has no offered_by (unobtainable), recipe would be permanently locked.")
    # Cycle detection (iterative DFS, colors 0=new 1=active 2=done)
    color: Dict[str, int] = {}
    for root in edges:
        if color.get(root):
            continue
        stack = [(root, iter(sorted(edges.get(root, ()))))]
        color[root] = 1
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                color[node] = 2
                stack.pop()
            elif color.get(nxt) == 1:
                errors.append(f"[{node}] Law L13: prerequisite cycle via '{nxt}'.")
            elif not color.get(nxt):
                color[nxt] = 1
                stack.append((nxt, iter(sorted(edges.get(nxt, ())))))
    return errors


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


FALLBACK_BLOCK_ID = "blocks/stone"
SOLID_MASS_BUDGET = 0.90


def check_world_mass_budget(capsules: Dict[str, Dict[str, Any]]) -> List[str]:
    """World-fill sanity: at EVERY depth the summed spawn_prob of non-fallback solid blocks must stay
    <= SOLID_MASS_BUDGET so blocks/stone (the fixed fill) always keeps >= 10% of the world.
    Use a small spawn_prob, a higher z_unlock, or an optional z_max to stay inside the budget."""
    blocks: List[Tuple[str, float, int, int]] = []
    for cid, data in capsules.items():
        if cid == FALLBACK_BLOCK_ID or "mineable_block" not in data.get("affordances", []):
            continue
        st = data.get("stats", {})
        if str(st.get("fluid_type", "NONE")) != "NONE":
            continue
        try:
            p = float(st.get("spawn_prob", 0.05))
            z_lo = int(st.get("z_unlock", 0))
            z_hi = int(st.get("z_max", 2**31 - 1))
        except (TypeError, ValueError):
            continue
        blocks.append((cid, p, z_lo, z_hi))

    breakpoints = {0}
    for _, _, z_lo, z_hi in blocks:
        breakpoints.add(max(0, z_lo))
        if z_hi < 2**31 - 1:
            breakpoints.add(z_hi + 1)

    errors: List[str] = []
    flagged: Set[str] = set()
    for z in sorted(breakpoints):
        active = [(cid, p) for cid, p, z_lo, z_hi in blocks if z_lo <= z <= z_hi]
        total = sum(p for _, p in active)
        if total > SOLID_MASS_BUDGET + 1e-9:
            for cid, _ in active:
                if cid not in flagged:
                    flagged.add(cid)
                    errors.append(
                        f"[{cid}] World Mass Budget exceeded at depth z={z}: solid spawn_prob total {total:.3f} > {SOLID_MASS_BUDGET}. "
                        f"Lower stats.spawn_prob, raise stats.z_unlock, or set stats.z_max."
                    )
    return errors


def check_engine_vocab_wiring(vocab: Dict[str, Any]) -> List[str]:
    """Ensures every canonical event, action, and modifiable stat in vocab/ is wired in engine/*.gd."""
    errors: List[str] = []
    engine_dir = ROOT / "engine"
    sources = []
    for gd_name in ("grid_manager.gd", "rule_engine.gd", "offline_sim.gd"):
        gd_path = engine_dir / gd_name
        if gd_path.exists():
            sources.append(gd_path.read_text(encoding="utf-8"))
    if not sources:
        return errors
    combined = "\n".join(sources)

    for ev in vocab["events"]["events"]:
        if f'"{ev}"' not in combined:
            errors.append(f"[engine/vocab] Event '{ev}' in vocab/events.json is not wired in engine/*.gd.")
    for act in vocab["actions"]["actions"].keys():
        if f'"{act}"' not in combined:
            errors.append(f"[engine/vocab] Action '{act}' in vocab/actions.json is not wired in engine/*.gd.")
    for st in vocab["affordances"]["modifiable_stats"]:
        if f'"{st}"' not in combined:
            errors.append(f"[engine/vocab] Modifiable stat '{st}' in vocab/affordances.json is not wired in engine/*.gd.")
    return errors


def validate_semantic_quality(cap_id: str, data: Dict[str, Any]) -> List[str]:
    """Forward-only semantic & physics lints enforced on newly added capsules."""
    errors: List[str] = []
    ns = cap_id.split("/", 1)[0] if "/" in cap_id else ""
    affordances = set(data.get("affordances", []) if isinstance(data.get("affordances"), list) else [])
    tags = set(data.get("tags", []) if isinstance(data.get("tags"), list) else [])
    stats = data.get("stats", {}) if isinstance(data.get("stats"), dict) else {}
    modifiers = data.get("modifiers", []) if isinstance(data.get("modifiers"), list) else []
    reactions = data.get("reactions", []) if isinstance(data.get("reactions"), list) else []
    offered_by = data.get("offered_by", []) if isinstance(data.get("offered_by"), list) else []

    # 1. World archetypes (npcs, biomes, natural blocks) must not declare offered_by
    if ns in ("npcs", "biomes") and offered_by:
        errors.append(
            f"[{cap_id}] Semantic error: '{ns}/*' world capsules must not declare 'offered_by' "
            f"(Hint: remove 'offered_by'; items point to NPCs via 'offered_by', never inside '{ns}/*')."
        )
    elif ns == "blocks" and offered_by and not (affordances & {"catalyst", "backfill_material"}):
        errors.append(
            f"[{cap_id}] Semantic error: natural 'blocks/*' strata must not declare 'offered_by' "
            f"(Hint: remove 'offered_by' from natural blocks)."
        )

    # 2. Every offered_by vendor must be an npcs/* capsule
    for o_idx, offer in enumerate(offered_by):
        if isinstance(offer, dict):
            vendor = str(offer.get("vendor", ""))
            if vendor and not vendor.startswith("npcs/"):
                errors.append(
                    f"[{cap_id}] Semantic error: offered_by[{o_idx}].vendor '{vendor}' is not an NPC vendor "
                    f"(Hint: use an 'npcs/*' vendor such as 'npcs/peddler_vayne')."
                )

    # 3. Per-block spawn_prob cap for new blocks so a single block cannot consume the world mass budget
    if ns == "blocks" and str(stats.get("fluid_type", "NONE")) == "NONE":
        try:
            sp = float(stats.get("spawn_prob", 0.02))
            if sp > 0.03:
                errors.append(
                    f"[{cap_id}] Semantic error: new block stats.spawn_prob ({sp}) exceeds 0.03 cap "
                    f"(Hint: set 'stats.spawn_prob' <= 0.03 so the world mass budget stays balanced)."
                )
        except (TypeError, ValueError):
            pass

    # 4. Reject yield_mult <= 0 unless paired with a non-dirt/stone spawn_item reaction
    has_real_spawn = False
    for rx in reactions:
        if isinstance(rx, dict):
            for act in rx.get("do", []) if isinstance(rx.get("do"), list) else []:
                if isinstance(act, dict) and act.get("act") == "spawn_item":
                    if str(act.get("item", "")) not in ("blocks/dirt", "blocks/stone", ""):
                        has_real_spawn = True
    for m_idx, mod in enumerate(modifiers):
        if not isinstance(mod, dict):
            continue
        st_name = str(mod.get("stat", ""))
        ph_name = str(mod.get("phase", ""))
        val_str = str(mod.get("value", "")).strip()
        try:
            num_val = float(val_str)
        except ValueError:
            num_val = None
        if st_name == "yield_mult" and ph_name in ("base", "mul", "clamp") and num_val is not None and num_val <= 0.0 and not has_real_spawn:
            errors.append(
                f"[{cap_id}] Semantic error: modifiers[{m_idx}] sets 'yield_mult' to {val_str} without a non-dirt 'spawn_item' reaction, "
                f"destroying all mined ore drops (Hint: use 'yield_mult' > 0, or add a 'spawn_item' reaction that grants a real ore/item)."
            )
        if st_name.endswith("_mult") and ph_name == "mul" and num_val is not None and num_val < 0.0:
            errors.append(
                f"[{cap_id}] Semantic error: modifiers[{m_idx}] applies a negative multiplier ({val_str}) to '{st_name}' "
                f"(Hint: use a positive multiplier like '0.75' for a 25% reduction or '1.25' for a 25% boost)."
            )

    # 5. Reject unreachable tile.fluid_level > 0 conditions inside on_block_break
    for r_idx, rx in enumerate(reactions):
        if not isinstance(rx, dict):
            continue
        if rx.get("on") == "on_block_break":
            conds = [str(rx.get("if", ""))] + [
                str(a.get("if", "")) for a in (rx.get("do", []) if isinstance(rx.get("do"), list) else []) if isinstance(a, dict)
            ]
            for c_str in conds:
                if "tile.fluid_level" in c_str and not any(tok in c_str for tok in ("== 0", "<= 0", "< 1")):
                    errors.append(
                        f"[{cap_id}] Semantic error: reactions[{r_idx}] ('on_block_break') checks 'tile.fluid_level > 0', which is unreachable "
                        f"because fluid strict-locks solid blocks from breaking (Hint: trigger on 'on_zero_damage_stall', 'on_fluid_contact', or 'on_second_tick' instead)."
                    )
                    break

    # 6. Non-world capsules must have at least one active gameplay effect (not just self-decay)
    if ns not in ("blocks", "biomes", "npcs") and not ("equip_tool" in affordances and "base_dps" in stats):
        has_effect = len(modifiers) > 0
        if not has_effect:
            for rx in reactions:
                if not isinstance(rx, dict):
                    continue
                for act in rx.get("do", []) if isinstance(rx.get("do"), list) else []:
                    if not isinstance(act, dict):
                        continue
                    act_name = str(act.get("act", ""))
                    var_name = str(act.get("var", ""))
                    if act_name == "destroy_self":
                        continue
                    if act_name in ("var_add", "var_set") and var_name in ("self.charge_left", "self.durability_left"):
                        continue
                    has_effect = True
                    break
        if not has_effect:
            errors.append(
                f"[{cap_id}] Semantic error: item has no active gameplay modifier or non-decay reaction "
                f"(Hint: add at least one 'modifiers' entry or a gameplay action in 'reactions' that eases the target friction)."
            )

    # 7. Required brief coverage tags
    has_solution_tags = any(t.startswith("solves_") for t in tags) and any(t.startswith("path_") for t in tags)
    has_world_tag = any(t.startswith("world_") for t in tags)
    if not (has_solution_tags or has_world_tag):
        errors.append(
            f"[{cap_id}] Semantic error: missing required brief coverage tags in 'tags' "
            f"(Hint: include both 'solves_<friction>' and 'path_<path_type>' for solution capsules, or 'world_<kind>' for world-building capsules)."
        )

    return errors


def check_frontier_bound(capsules: Dict[str, Dict[str, Any]], check_ids: Set[str]) -> List[str]:
    """Law L14: Monotone Frontier Step Bound. Prevents unreachable depth jumps > F_base + max_step."""
    errors: List[str] = []
    if not check_ids:
        return errors

    max_step = 150.0
    pacing_path = ROOT / "design" / "pacing.json"
    if pacing_path.exists():
        try:
            pacing = strict_json_loads(pacing_path.read_text(encoding="utf-8"))
            max_step = float(
                pacing.get("frontier_growth", {}).get(
                    "hard_law_l14_max_step", pacing.get("hard_law_l14_max_step", 150.0)
                )
            )
        except Exception:
            max_step = 150.0

    f_base = max(
        (
            float(c.get("stats", {}).get("z_unlock", 0.0))
            for cid, c in capsules.items()
            if cid.startswith("blocks/") and cid not in check_ids and isinstance(c.get("stats"), dict)
        ),
        default=150.0,
    )

    for cid in sorted(check_ids):
        data = capsules.get(cid)
        if not isinstance(data, dict):
            continue
        stats = data.get("stats", {}) if isinstance(data.get("stats"), dict) else {}
        affordances = data.get("affordances", []) if isinstance(data.get("affordances"), list) else []
        tags = data.get("tags", []) if isinstance(data.get("tags"), list) else []

        if "mineable_block" in affordances or cid.startswith("blocks/") or "world_block" in tags:
            try:
                z_u = float(stats.get("z_unlock", 0.0))
            except (TypeError, ValueError):
                z_u = 0.0
            if z_u > f_base + max_step:
                errors.append(
                    f"[{cid}] Law L14 Frontier Jump: block stats.z_unlock ({z_u}) exceeds current obtainable frontier ({f_base}) + {max_step}. Grow depth in rolling steps [F+40, F+120]."
                )

        if data.get("offered_by"):
            try:
                u_depth = float(stats.get("unlock_depth", 0.0))
            except (TypeError, ValueError):
                u_depth = 0.0
            if u_depth > f_base + max_step:
                errors.append(
                    f"[{cid}] Law L14 Frontier Jump: stats.unlock_depth ({u_depth}) exceeds current obtainable frontier ({f_base}) + {max_step}."
                )
            for offer in data.get("offered_by", []) or []:
                if not isinstance(offer, dict):
                    continue
                vendor_id = str(offer.get("vendor", ""))
                v_stats = capsules.get(vendor_id, {}).get("stats", {})
                if isinstance(v_stats, dict):
                    try:
                        v_z = float(v_stats.get("unlock_depth", v_stats.get("z_unlock", 0.0)))
                    except (TypeError, ValueError):
                        v_z = 0.0
                    if v_z > f_base + max_step:
                        errors.append(
                            f"[{cid}] Law L14 Frontier Jump: vendor '{vendor_id}' unlock_depth ({v_z}) exceeds current obtainable frontier ({f_base}) + {max_step}."
                        )
                price = offer.get("price", {})
                if isinstance(price, dict):
                    for curr_id in price:
                        c_stats = capsules.get(curr_id, {}).get("stats", {})
                        if isinstance(c_stats, dict):
                            try:
                                c_z = float(c_stats.get("z_unlock", 0.0))
                            except (TypeError, ValueError):
                                c_z = 0.0
                            if c_z > f_base + max_step:
                                errors.append(
                                    f"[{cid}] Law L14 Frontier Jump: price currency '{curr_id}' z_unlock ({c_z}) exceeds current obtainable frontier ({f_base}) + {max_step}."
                                )

    return errors


def check_dps_pacing_budget(capsules: Dict[str, Dict[str, Any]], check_ids: Set[str]) -> List[str]:
    """Law L15: Bracket Tool DPS Pacing Budget from design/pacing.json."""
    errors: List[str] = []
    if not check_ids:
        return errors

    budgets: Dict[str, Dict[str, float]] = {
        "bracket_1": {"min_dps": 2.0, "max_dps": 120.0},
        "bracket_2": {"min_dps": 18.0, "max_dps": 180.0},
        "bracket_3": {"min_dps": 35.0, "max_dps": 280.0},
        "bracket_4": {"min_dps": 65.0, "max_dps": 420.0},
        "bracket_5": {"min_dps": 110.0, "max_dps": 650.0},
    }
    pacing_path = ROOT / "design" / "pacing.json"
    if pacing_path.exists():
        try:
            pacing = strict_json_loads(pacing_path.read_text(encoding="utf-8"))
            if isinstance(pacing.get("bracket_dps_budgets"), dict):
                budgets = pacing["bracket_dps_budgets"]
        except Exception:
            pass

    for cid in sorted(check_ids):
        data = capsules.get(cid)
        if not isinstance(data, dict):
            continue
        affordances = data.get("affordances", []) if isinstance(data.get("affordances"), list) else []
        stats = data.get("stats", {}) if isinstance(data.get("stats"), dict) else {}
        tags = data.get("tags", []) if isinstance(data.get("tags"), list) else []

        if "equip_tool" in affordances or ("base_dps" in stats and cid.startswith("tools/")):
            bracket = "bracket_1"
            for t in tags:
                if t in budgets:
                    bracket = t
                    break
            b_spec = budgets.get(bracket, budgets.get("bracket_1", {"min_dps": 2.0, "max_dps": 120.0}))
            min_dps = float(b_spec.get("min_dps", 2.0))
            max_dps = float(b_spec.get("max_dps", 120.0))
            try:
                dps = float(stats.get("base_dps", 0.0))
            except (TypeError, ValueError):
                dps = 0.0
            if dps < min_dps or dps > max_dps:
                errors.append(
                    f"[{cid}] Law L15 Pacing Budget: tool stats.base_dps ({dps}) is outside {bracket} DPS budget [{min_dps}, {max_dps}] in design/pacing.json."
                )

    return errors


def check_recursive_value_flow(capsules: Dict[str, Dict[str, Any]], check_ids: Set[str]) -> List[str]:
    """Law L11v2: Recursive copper-equivalent value-flow & multi-step arbitrage / power-to-cost outlier check."""
    errors: List[str] = []

    cost_map: Dict[str, float] = {}
    for cid, data in capsules.items():
        if not isinstance(data, dict):
            continue
        stats = data.get("stats", {}) if isinstance(data.get("stats"), dict) else {}
        try:
            bv = max(1.0, float(stats.get("base_value", 1.0)))
        except (TypeError, ValueError):
            bv = 1.0
        if cid.startswith("blocks/"):
            try:
                zu = max(0.0, float(stats.get("z_unlock", 0.0)))
            except (TypeError, ValueError):
                zu = 0.0
            cost_map[cid] = bv * (1.0 + zu / 250.0)
        else:
            cost_map[cid] = bv

    for _ in range(8):
        for cid, data in capsules.items():
            if cid.startswith("blocks/") or not isinstance(data, dict):
                continue
            offers = data.get("offered_by", [])
            if not isinstance(offers, list) or not offers:
                continue
            best_cost: float | None = None
            for off in offers:
                if not isinstance(off, dict) or not isinstance(off.get("price"), dict) or not off["price"]:
                    continue
                offer_cost = 0.0
                for curr_id, qty in off["price"].items():
                    if not isinstance(qty, (int, float)):
                        continue
                    curr_data = capsules.get(curr_id, {})
                    curr_tags = curr_data.get("tags", []) if isinstance(curr_data, dict) and isinstance(curr_data.get("tags"), list) else []
                    w = 0.25 if (str(curr_id).startswith("upgrades/") or "skill_bracket" in curr_tags or "station" in curr_tags) else 1.0
                    offer_cost += float(qty) * w * cost_map.get(curr_id, 1.0)
                if offer_cost > 0.0 and (best_cost is None or offer_cost < best_cost):
                    best_cost = offer_cost
            if best_cost is not None:
                cost_map[cid] = best_cost

    # Multi-step recursive arbitrage check on check_ids (and repeatable consumables)
    inspect_ids = set(check_ids)
    for cid, data in capsules.items():
        if isinstance(data, dict) and "consume" in (data.get("affordances") or []) and not cid.startswith("upgrades/"):
            inspect_ids.add(cid)

    for cid in sorted(inspect_ids):
        data = capsules.get(cid)
        if not isinstance(data, dict):
            continue
        spawned_cost = 0.0
        for rx in data.get("reactions", []) if isinstance(data.get("reactions"), list) else []:
            if isinstance(rx, dict) and rx.get("on") == "on_consume":
                for act in rx.get("do", []) if isinstance(rx.get("do"), list) else []:
                    if isinstance(act, dict) and act.get("act") == "spawn_item":
                        target_id = str(act.get("item", ""))
                        try:
                            qty = float(act.get("qty", "1"))
                        except (TypeError, ValueError):
                            qty = 1.0
                        spawned_cost += qty * cost_map.get(target_id, 1.0)
        c_self = cost_map.get(cid, 1.0)
        if spawned_cost > c_self * 1.05:
            errors.append(
                f"[{cid}] Law L11v2 Recursive Arbitrage Loop: consuming '{cid}' (recursive cost {c_self:.2f}) spawns items with recursive cost {spawned_cost:.2f} (> 1.05x)."
            )

    def _power_score(data: Dict[str, Any]) -> float:
        stats = data.get("stats", {}) if isinstance(data.get("stats"), dict) else {}
        try:
            dps = max(0.0, float(stats.get("base_dps", 0.0)))
        except (TypeError, ValueError):
            dps = 0.0
        mod_score = 0.0
        for mod in data.get("modifiers", []) if isinstance(data.get("modifiers"), list) else []:
            if isinstance(mod, dict):
                try:
                    mod_score += abs(float(mod.get("value", 0.0))) * 10.0
                except (TypeError, ValueError):
                    mod_score += 10.0
        rx_list = data.get("reactions", []) if isinstance(data.get("reactions"), list) else []
        return max(0.01, dps + mod_score + len(rx_list) * 15.0)

    baseline_ratios: List[float] = []
    for cid, data in capsules.items():
        if cid in check_ids or not isinstance(data, dict) or not data.get("offered_by"):
            continue
        s_val = _power_score(data)
        c_val = max(1.0, cost_map.get(cid, 1.0))
        baseline_ratios.append(math.log(max(0.01, s_val) / c_val))

    if len(baseline_ratios) >= 10:
        mu = sum(baseline_ratios) / len(baseline_ratios)
        var = sum((x - mu) ** 2 for x in baseline_ratios) / len(baseline_ratios)
        sigma = max(0.5, math.sqrt(var))
        for cid in sorted(check_ids):
            data = capsules.get(cid)
            if not isinstance(data, dict) or not data.get("offered_by"):
                continue
            s_val = _power_score(data)
            c_val = max(1.0, cost_map.get(cid, 1.0))
            log_r = math.log(max(0.01, s_val) / c_val)
            if log_r > mu + 4.5 * sigma and (s_val / c_val) > 25.0:
                errors.append(
                    f"[{cid}] Law L11v2 Value-Flow Outlier: power-to-cost ratio ({s_val / c_val:.2f}, log={log_r:.2f}) exceeds corpus mean+4.5*sigma ({mu + 4.5 * sigma:.2f})."
                )

    return errors


def check_health_ratchet(capsules: Dict[str, Dict[str, Any]]) -> List[str]:
    """Monotone Corpus Health Ratchet against design/health_baseline.json."""
    errors: List[str] = []
    baseline_path = ROOT / "design" / "health_baseline.json"
    if not baseline_path.exists():
        return errors
    try:
        baseline = strict_json_loads(baseline_path.read_text(encoding="utf-8"))
    except Exception:
        return errors

    tol = float(baseline.get("single_capsule_tolerance", 0.005))
    metrics = baseline.get("metrics", baseline)

    vendor_counts: Dict[str, int] = {}
    curr_counts: Dict[str, int] = {}
    total_offers = 0

    for data in capsules.values():
        if not isinstance(data, dict):
            continue
        for offer in data.get("offered_by", []) or []:
            if not isinstance(offer, dict):
                continue
            total_offers += 1
            vendor = str(offer.get("vendor", ""))
            if vendor:
                vendor_counts[vendor] = vendor_counts.get(vendor, 0) + 1
            price = offer.get("price", {})
            if isinstance(price, dict):
                for curr_id in price:
                    curr_counts[curr_id] = curr_counts.get(curr_id, 0) + 1

    if total_offers > 0 and vendor_counts:
        top_vendor, top_v_cnt = max(vendor_counts.items(), key=lambda kv: kv[1])
        live_max_vendor_share = top_v_cnt / float(total_offers)
        base_max_vendor = float(metrics.get("max_vendor_offer_share", 1.0))
        if live_max_vendor_share > base_max_vendor + tol:
            errors.append(
                f"[health_ratchet] Monotone Health Ratchet failed: max_vendor_offer_share ({live_max_vendor_share:.6f} on '{top_vendor}') "
                f"exceeds baseline ({base_max_vendor:.6f}) + tolerance ({tol}). Diversify vendor offers."
            )

    total_curr_mentions = sum(curr_counts.values())
    if total_curr_mentions > 0 and curr_counts:
        top3 = sorted(curr_counts.items(), key=lambda kv: kv[1], reverse=True)[:3]
        live_top3_curr_share = sum(cnt for _, cnt in top3) / float(total_curr_mentions)
        base_top3_curr = float(metrics.get("top3_currency_share", 1.0))
        if live_top3_curr_share > base_top3_curr + tol:
            top3_names = ", ".join(k for k, _ in top3)
            errors.append(
                f"[health_ratchet] Monotone Health Ratchet failed: top3_currency_share ({live_top3_curr_share:.6f} for [{top3_names}]) "
                f"exceeds baseline ({base_top3_curr:.6f}) + tolerance ({tol}). Diversify recipe currencies."
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


def _extract_cap_id_from_relpath(rel_or_id: str) -> str:
    s = rel_or_id.strip().replace("\\", "/")
    if s.startswith("content/capsules/"):
        parts = s.split("/")
        if len(parts) >= 4:
            return f"{parts[2]}/{parts[3]}"
    return s


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate LFS-Tycoon capsules (Gate G1 & Static G3).")
    parser.add_argument("--dir", type=Path, default=DEFAULT_CAPSULES_DIR, help="Capsules root directory")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on any error")
    parser.add_argument(
        "--new-capsule",
        action="append",
        default=[],
        help="Capsule id or relative path of a newly added capsule to run forward-only semantic quality lints on.",
    )
    args = parser.parse_args()
    is_default_dir = args.dir.resolve() == DEFAULT_CAPSULES_DIR.resolve()

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

    new_cap_ids: Set[str] = {_extract_cap_id_from_relpath(x) for x in args.new_capsule if x.strip()}
    added_txt = ROOT / "added.txt"
    if is_default_dir and added_txt.exists():
        for ln in added_txt.read_text(encoding="utf-8").splitlines():
            if ln.strip().startswith("content/capsules/") and ln.strip().endswith("capsule.json"):
                new_cap_ids.add(_extract_cap_id_from_relpath(ln))

    all_errors: List[str] = []
    if is_default_dir:
        all_errors.extend(check_engine_vocab_wiring(vocab))

    parsed_capsules: Dict[str, Dict[str, Any]] = {}

    for cap_id, cap_path in target_map.items():
        errs, data = validate_single_capsule(cap_id, cap_path, vocab, known_ids, expr_linter)
        if data is not None:
            parsed_capsules[cap_id] = data
            if cap_id in new_cap_ids:
                errs.extend(validate_semantic_quality(cap_id, data))
        all_errors.extend(errs)

    # Load canonical capsules too for cross-capsule economy checks
    full_economy_pool = dict(parsed_capsules)
    if not is_default_dir:
        for cid, cpath in canonical_map.items():
            if cid not in full_economy_pool:
                try:
                    full_economy_pool[cid] = strict_json_loads(cpath.read_text(encoding="utf-8"))
                except Exception:
                    pass

    check_ids: Set[str] = set(new_cap_ids) if is_default_dir else set(target_map.keys())
    econ_errors = (
        check_economy_containment(full_economy_pool)
        + check_world_mass_budget(full_economy_pool)
        + check_prereq_graph(full_economy_pool)
        + check_frontier_bound(full_economy_pool, check_ids)
        + check_dps_pacing_budget(full_economy_pool, check_ids)
        + check_recursive_value_flow(full_economy_pool, check_ids)
    )
    # Filter economy errors to capsules in target_map
    for e in econ_errors:
        if any(e.startswith(f"[{cid}]") for cid in target_map):
            all_errors.append(e)

    if is_default_dir and len(parsed_capsules) >= 400:
        all_errors.extend(check_health_ratchet(parsed_capsules))

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}")
        print(f"\nFAILED: {len(all_errors)} validation error(s) across {len(target_map)} capsules.")
        return 1

    print(f"ALL CAPSULES VALID ({len(target_map)} capsules verified against Laws L1-L15).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

