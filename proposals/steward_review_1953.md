# 1-in-10 Enterprise Steward Review

## Audit of Past Capsules
The past capsules have successfully built out depth progression down to 1420m, but left several blocks and specialist NPCs orphaned. The Lithic Choir theme has been introduced but under-utilized as a mechanical sink.

## Keystone Connector
The `devices/lithic_choir_sigil_1953` acts as a keystone connector by linking the `upgrades/lithic_choir_routing_e842` skill requirement with orphaned strata (`blocks/quartz_kettle_f043` and `blocks/lithic_tallow_31bc`). This bridges the Assayers skill school (`bracket_3`) with the Hydro Alchemist vendor. The device provides a Skyrim-style tool socket enchantment that uses quartz acoustics to solve grime buildup.

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/quartz_kettle_f043", "blocks/lithic_tallow_31bc"], "vendor_targeted": "npcs/hydro_alchemist_82e8", "skill_bracket_linked": "upgrades/lithic_choir_routing_e842", "bracket_tier": "bracket_3", "theme": "theme_lithic_choir"} -->
<!-- steward-audit: {"keystone": "devices/lithic_choir_sigil_1953", "vendor": "npcs/hydro_alchemist_82e8", "ore": "blocks/quartz_kettle_f043", "bracket": "bracket_3"} -->
