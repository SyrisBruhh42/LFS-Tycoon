# Enterprise Steward & Synergy Connector Audit

## Past 9 Capsules Review
The baseline progression band `bracket_2` (spanning 198..450m depth) heavily features mechanical and alchemical themes but faced a fluid flooding challenge (where lava/water blocks excavation). Furthermore, `blocks/stormbreaker_geode_5e99` and `blocks/copper` needed stronger reagent sinks for late-bracket manual mining build paths, and the `npcs/deep_bore_horologist_35a3` had fewer specialist unlocks.

## Keystone Connector
I forged the `consumables/clockwork_stormbreaker_decoction_5d16` capsule to act as the bridging piece for these systems.
- **Lore Theme**: The Perpetual Clockwork Deep-Bore Syndicate (`theme_clockwork_syndicate`).
- **Mechanical Synergy**: Brews a potent 5-minute timed buff. During the buff's duration, breaking blocks will instantly modify the fluid level to drain floods (using `modify_fluid` with delta `-1.0`), preventing water/lava stagnation. Moreover, direct taps and overkill generate raw `stormbreaker_geode_5e99` as a mechanical loop interaction.
- **Multi-Reagent Sink**: The deep-bore horologist offers this recipe combining raw copper, raw stormbreaker geodes, and the non-consumed permanent node `upgrades/iron_stormbreaker_charm_a589` as the station prerequisite, tightly integrating the skill school nodes with raw strata.

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/stormbreaker_geode_5e99", "blocks/copper"], "vendor_targeted": "npcs/deep_bore_horologist_35a3", "skill_bracket_linked": "upgrades/iron_stormbreaker_charm_a589", "bracket_tier": "bracket_2", "theme": "theme_clockwork_syndicate", "keystone": "consumables/clockwork_stormbreaker_decoction_5d16"} -->
