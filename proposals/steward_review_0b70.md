# Enterprise Steward Audit: Keystone Connector devices/tectonic_quarry_rig_0b70

## Synthesis of the Past 9 Capsules
Over the past review window, the baseline capsules have expanded the **bracket_2** tier and **theme_tectonic_crucible** lore. However, an audit revealed that several key stratum ores (like Magma Anvilstone and Copper) and specialist NPCs (like Ignis the Cinder-Horologist) were under-utilized.

## Keystone Connector Contribution
To bridge these gaps, the **Tectonic Quarry Rig** (`devices/tectonic_quarry_rig_0b70`) has been forged.
- **Lore & Theme**: Strengthens the `theme_tectonic_crucible` and `skill_school_assayers` path, linking deep subterranean lore.
- **Orphan Ores**: Provides a much-needed sink for `blocks/magma_anvilstone_6384` and `blocks/copper` via multi-ingredient crafting and mechanical reactions.
- **Specialist NPCs**: Integrates directly with `npcs/clockwork_horologist_c7b1` to ensure the vendor is well-stocked and offers robust modular skill bracket progression (requiring `devices/clockwork_automaton_c50a`).

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/magma_anvilstone_6384", "blocks/copper"], "vendor_targeted": "npcs/clockwork_horologist_c7b1", "skill_bracket_linked": "devices/clockwork_automaton_c50a", "bracket_tier": "bracket_2", "theme": "theme_tectonic_crucible"} -->
<!-- steward-audit: {"keystone": "devices/tectonic_quarry_rig_0b70", "vendor": "npcs/clockwork_horologist_c7b1", "ore": "blocks/magma_anvilstone_6384", "bracket": "bracket_2"} -->
