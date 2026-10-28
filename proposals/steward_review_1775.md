# Enterprise Steward Audit Note (1-in-10 Review)

**Keystone Connector ID:** `upgrades/stormbreaker_calipers_bench_1775`

This review bridges the current Quarry Depth Frontier of 330m by introducing a new Homestead Workshop Bench for `bracket_3`.
The `stormbreaker_calipers_bench_1775` serves as a permanent architectural fixture (using `place_in_house`) that mitigates zero-damage stalls, easing the friction of burning charge/durability on indestructible blocks. It requires the `devices/clockwork_siphon_rig_2410` (a non-consumed station requirement) and sinks orphan strata like `blocks/stormbreaker_geode_5e99` alongside `blocks/copper`.

By assigning this recipe to the `npcs/deep_bore_horologist_35a3` vendor, we resolve an under-stocked specialist NPC while extending the `skill_school_manual` tree and enriching the `theme_clockwork_syndicate` lore.

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/stormbreaker_geode_5e99", "blocks/copper"], "vendor_targeted": "npcs/deep_bore_horologist_35a3", "skill_bracket_linked": "devices/clockwork_siphon_rig_2410", "bracket_tier": "bracket_3", "theme": "theme_clockwork_syndicate", "keystone": "upgrades/stormbreaker_calipers_bench_1775", "vendor": "npcs/deep_bore_horologist_35a3", "ore": "blocks/stormbreaker_geode_5e99", "bracket": "bracket_3"} -->
