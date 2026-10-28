# Enterprise Steward & Synergy Connector Audit

## Overarching Progress (Past 9 Capsules)
The recent progression window has focused on early-game ore hunting and depth awareness, setting up foundational blocks like Alkahest Quartz and key progression steps in the `skill_school_assayers`. The `bracket_1` node `clockwork_hearth_ledger_7364` provided initial tracking capabilities, but players venturing deeper into `bracket_2` (198-450m) were facing market saturation from accumulating abundant ores.

## Keystone Integration (`upgrades/lithic_choir_assayer_6c59`)
To solve this friction while anchoring the orphaned lore of the Lithic Choir and the Deep-Bore Horologist NPC, this new capsule expands the Guild Assayer bracket into `bracket_2`.

*   **Friction Eased:** Resolves `market_saturation` via a permanent +35% multiplier to market value (`market_value_mult`).
*   **Orphan Connection:** Links the previously under-utilized `blocks/alkahest_quartz_d755` via a mechanical transformation reaction: turning Alkahest Quartz directly into `blocks/copper` during combat or block-breaking stalls (`on_damage_dealt`) when battery is low. This provides an active late-game sink for the quartz beyond simply selling it.
*   **Bracket Expansion:** Enforces progression by requiring the non-consumed `upgrades/clockwork_hearth_ledger_7364` inside its `price` list, establishing a clear modular skill tree line for the `skill_school_assayers` path.
*   **Lore Anchoring:** Integrates the `theme_lithic_choir` lore into the Assayer guild's mechanical framework, framing the market manipulation as the result of exploiting acoustic harmonics.

<!-- steward-audit: {"keystone": "upgrades/lithic_choir_assayer_6c59", "vendor": "npcs/deep_bore_horologist_35a3", "ore": "blocks/alkahest_quartz_d755", "bracket": "bracket_2"} -->
