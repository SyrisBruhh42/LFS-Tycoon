# Enterprise Steward & Synergy Connector Audit

## Overarching Themes & Graph Connections
The recent block capsules (e.g. `blocks/living_atlas_galena_0725` and `blocks/umber_catalyst_ore_fff0`) and the expansion of Modular Skill Brackets (such as `skill_school_assayers` at `bracket_2`) presented orphan nodes in the progression tree. The specialist NPCs, notably `npcs/lithic_archivist_1aa4`, lacked offerings that integrated these recent strata.

## The Keystone Connector Capsule
The newly forged **Arcane Grimoire: Quarry Geomancy** (`books/arcane_grimoire_quarry_17f3`) weaves these loose threads together by acting as a skill-tome that provides an explicit sink for the otherwise orphaned ores and provides mechanical depth for the assayers skill school within the thematic framework of *The Living Atlas*.

### Key Bridges Built
1. **Orphan Sinks**: Integrates `blocks/living_atlas_galena_0725` and `blocks/umber_catalyst_ore_fff0` within its acquisition cost (`offered_by.price`) and `consume_item` logic.
2. **NPC Connection**: Specifically targets `npcs/lithic_archivist_1aa4` as the provider, adding value to this vendor.
3. **Modular Skill Alignment**: Incorporates `devices/clockwork_automaton_c50a` as an essential requirement, tying this consumable grimoire strictly to advanced progression nodes within `bracket_2`.

<!-- steward-audit: {"keystone": "books/arcane_grimoire_quarry_17f3", "vendor": "npcs/lithic_archivist_1aa4", "ore": "blocks/living_atlas_galena_0725", "bracket": "bracket_2"} -->
