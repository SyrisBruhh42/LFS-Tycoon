# 1-in-10 Enterprise Steward Review

## Audit of Past Capsules
The past 9 baseline capsules successfully built out depth progression into the active bracket_3 band (700..1399m) but left several blocks and specialist NPCs orphaned, including `blocks/lithic_choir_zinc_e80e` and `blocks/syndicate_brass_801b`. The Alkahest Hydro theme was introduced but lacked a functional skill sink.

## Keystone Connector
The `books/alkahest_hydro_grimoire_c9c1` acts as a keystone connector by linking the `upgrades/alkahest_salt_tuning_charm_f862` skill requirement with the orphaned strata. This bridges the Alkahest Salt skill school with the Lithic Archivist vendor. The arcane grimoire teaches a geomancy spell that leverages the hydro-alchemists' methods, transmuting stubborn Lithic Choir Zinc into Syndicate Brass and granting deep-bore vendor discounts, easing the `vendor_access` friction.

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/lithic_choir_zinc_e80e", "blocks/syndicate_brass_801b"], "vendor_targeted": "npcs/lithic_archivist_9c38", "skill_bracket_linked": "upgrades/alkahest_salt_tuning_charm_f862", "bracket_tier": "bracket_3", "theme": "theme_alkahest_hydro"} -->
<!-- steward-audit: {"keystone": "books/alkahest_hydro_grimoire_c9c1", "vendor": "npcs/lithic_archivist_9c38", "ore": "blocks/lithic_choir_zinc_e80e", "bracket": "bracket_3"} -->
