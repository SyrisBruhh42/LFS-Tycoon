# Steward Review - Alkahest Vitriol Basin

This 1-in-10 Enterprise Steward review addresses the lack of mechanics surrounding overkill damage (`overkill_waste`) and the under-stocked Specialist NPC `npcs/deep_bore_horologist_35a3`.

By introducing the `Alkahest Vitriol Basin` (`upgrades/alkahest_vitriol_basin_ce0c`), we integrate the `theme_alkahest_hydro` lore with the deep-bore horologist. Furthermore, this adds a non-consumed station requirement (`tools/enclave_rivet_sigil_ed7e`) along with `blocks/vitriol_crystal_b488` and `blocks/copper` to effectively tie previously disjointed progression elements from `bracket_3` into a cohesive crafting ecosystem within the `skill_school_pewter_cinder`.

The basin acts as a `place_in_house` upgrade that increases `cleave_pct` by 0.5 whenever the mined block is a `blocks/vitriol_crystal_b488`, alleviating overkill damage waste by ensuring excess energy is transferred efficiently.

<!-- steward-audit: {"mode": "steward_1_in_10", "orphan_ores_connected": ["blocks/vitriol_crystal_b488", "blocks/copper"], "vendor_targeted": "npcs/deep_bore_horologist_35a3", "skill_bracket_linked": "tools/enclave_rivet_sigil_ed7e", "bracket_tier": "bracket_3", "theme": "theme_alkahest_hydro", "keystone": "upgrades/alkahest_vitriol_basin_ce0c"} -->
