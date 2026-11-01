# Upstream source and adaptations

Upstream: https://github.com/nicedoctors/wukong-steve

Pinned version: 0.11.0, commit `9f213556519dca4498fd46f02af6236ae121ecae`.
The original PolyForm Noncommercial 1.0.0 LICENSE and required NOTICE are retained.

The four source files in this directory are from that commit. The local resource
converter uses `ExtractMinecraft.py`, `MinecraftInventory.cs`, `AdventureItems.cs`
and `MinecraftWeapons.cs` as its extraction recipe and item definitions. They are
mod source, not decompiled game code. No upstream game assets are included.

PBZMC also adapts the upstream placement geometry, item identifiers, combat timing,
Steve part proportions, third-person animation, item display transforms, status HUD,
activation-frame recipe and enchantment presentation. These derived rules and
presentation code retain the upstream noncommercial license and required notices.

The PBZ host adapter, fixed 27+9 inventory, native equipment references, native
checkpoint transactions, input ownership and version guards are project-specific
adaptations. Their existence does not imply complete parity with every upstream
feature. See the project README for the features included in this release.

Minecraft textures, models, fonts and sounds have separate ownership. They are
prepared locally from pinned original sources and are excluded from the public
source repository and release archive. The upstream software license does not
relicense those resources.
