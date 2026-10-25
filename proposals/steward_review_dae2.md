# Steward Review - Alkahest Decoction (dae2)

This Keystone Connector bridges the gap in the mid-game progression, specifically within the `bracket_2` band (`198..450m`), addressing tool wear issues while weaving in the lore of the Lithic Choir.

## Audit Observations:
- **Orphan Blocks / Raw Strata:** We connect `blocks/alkahest_quartz_d755` and `blocks/copper` into a multi-ingredient recipe to act as a sink for these strata.
- **Under-Stocked Specialist NPCs:** We assign the recipe to `npcs/mica_salt_vendor_832d`, resolving their low-offer status.
- **Skill Brackets & Stations:** We incorporate `devices/quill_crucible_9ff0` as a permanent skill/station prerequisite, firmly tying the craft to the `skill_school_pewter_cinder` school.
- **Lore Integration:** The capsule's mechanics reflect the `theme_lithic_choir` lore by emitting a harmonious chime when breaking `alkahest_quartz` blocks, simulating the "frozen acoustic music" of the bedrock.

<!-- steward-audit: {"keystone": "consumables/alkahest_decoction_dae2", "vendor": "npcs/mica_salt_vendor_832d", "ore": "blocks/alkahest_quartz_d755", "bracket": "bracket_2"} -->
