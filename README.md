# pk_wordloot

RedM / VORP resource to search the static and networked containers found around the world: crates, drawers, chests, cabinets, wardrobes and desks. The target system is configurable (`v-lib`, `ox_target` or your own), the progress bar and notifications use `pk_library`, and cooldowns, loot rolls and rewards are handled entirely on the server.

## Features

- Search world props with a target option, or with the game's original ransack prompt on furniture (drawers, chests, cabinets, wardrobes, desks).
- Loot table per model: every entry rolls separately with its own chance and min/max amount.
- Persistent global cooldown per container (default 8 hours), stored in the database.
- No reroll: if the reward does not fit in the inventory it is saved and handed out on the next attempt.
- Server-side validation of models, distance, timing, one-time tokens, locks and inventory capacity.
- Optional strict mode that only accepts container positions listed in the config.

## Requirements

- `oxmysql`
- `vorp_core`
- `vorp_inventory`
- `vorp_lib` (game events for the native furniture interaction)
- `pk_library` (progress bar and notifications)
- A target system: `v-lib`, `ox_target` or a custom one
- OneSync enabled

## Installation

1. Put the `pk_wordloot` folder in your resources.
2. The database table is created automatically with `Config.Database.AutoCreateTable = true`. Otherwise set it to `false` and import `sql/install.sql`.
3. Make sure the example items in `config.lua` exist in the VORP `items` table, or replace them with your own.
4. Start the resources in this order:

```cfg
ensure oxmysql
ensure vorp_core
ensure vorp_inventory
ensure vorp_lib
ensure v-lib        # or ox_target / your target
ensure pk_library
ensure pk_wordloot
```

## Target system

Containers with `nativeInteraction = true` use the game's original prompt and do not need any target. For all the others, choose the system in `config.lua`:

```lua
Config.Target.System = 'v-lib'     -- exports['v-lib']:addLocalEntity
Config.Target.System = 'ox_target' -- exports.ox_target:addLocalEntity (also uses Config.Target.Icon)
Config.Target.System = 'custom'    -- fill in the custom provider in target.lua
```

To use your own target, open `target.lua` and fill in `add` / `remove` of the `custom` provider. Each call receives the option name, label, icon, distance, `canInteract(entity)` and `onSelect()`. If your target is a resource, put its name in `resource`, so props are only registered while it is running and are registered again when it restarts.

Props are attached with `addLocalEntity` instead of a global model target, so each model can use its own interaction distance. Nearby props are found in the local object pool and attached/removed dynamically.

## Loot rolls

Every entry of a model's `loot` table is rolled separately against its `chance` (0 to 100). On success a random whole amount between `min` and `max` is given. A single search can therefore return several items, one item or nothing.

```lua
loot = {
    { item = 'wood', label = 'Wood', min = 1, max = 3, chance = 65.0 },
    { item = 'coal', label = 'Coal', min = 1, max = 2, chance = 20.0 }
}
```

A completed search with no items still starts the cooldown. The default is `Config.DefaultCooldown = 28800` (8 hours); each model can override it with `cooldown`.

The roll happens on the server. If the result does not fully fit in the inventory, it is saved as `pending_loot`: nothing is given, the cooldown does not start, and the next attempt on the same container reuses exactly that result. Players cannot free some space and reroll for a better reward.

## Container options

Each entry in `Config.Containers` (key = model name) supports:

| Field | Description |
| --- | --- |
| `loot` | Loot table (see above) |
| `distance` | Interaction distance |
| `searchDuration` | Search duration in ms |
| `animation` | `dict`, `clip`, `flag`, `blendIn`, `blendOut` |
| `cooldown` | Cooldown in seconds for this model |
| `nativeInteraction` | `true` to use the game's ransack prompt instead of the target |
| `locations` | Allowed positions (`vector3`), used by strict mode |

## Identity and persistence

A container is identified by its model name and its coordinates, rounded with `Config.Security.PositionPrecision`. Two containers of the same model in different places have separate records and cooldowns. The cooldown is global for all players.

The table stores the expiry as a Unix timestamp plus any pending loot. Expired records without pending loot are removed on start and periodically, every `Config.Database.CleanupInterval` seconds.

## Static prop security

For networked objects the server resolves the network ID and checks model, coordinates and routing bucket. Ordinary static props built into the map, however, often exist only in the client's local pool and have no network ID the server can resolve.

In the default mode the server still validates the allowed model, finite/canonical coordinates, the real distance of the ped, search duration, one-time token, lock and cooldown. A modified client could still claim a non-existent static prop near its own position: this is a limit of model-only targeting on non-networked objects.

For strict validation, add the real coordinates under `locations` for each model and set:

```lua
Config.Security.RequireConfiguredLocations = true
```

Example:

```lua
['p_crate08x'] = {
    -- other options...
    locations = {
        vector3(1234.56, -456.78, 80.12),
        vector3(987.65, 321.00, 72.40)
    }
}
```

In this mode every request must match an allowed position within `ConfiguredLocationTolerance`, and the configured position is also used to build the stable identifier.

## Protections

- Server-side model allowlist; no item, amount or chance is ever accepted from the client.
- Player distance checked when the search starts and when it completes.
- Full validation of networked objects and optional allowlist for static props.
- One global lock per container and one session per player.
- One-time server tokens, rate limit and minimum search time.
- Locks released on cancel, distance, death, timeout or disconnect.
- Cumulative check of weight, item limits and capacity before handing out rewards.
- Rollback of items already added if a later inventory export fails.
- Persistent pending loot to prevent rerolls after a full inventory.
- Persistent global cooldown and automatic cleanup of expired records.

## Messages

All texts can be edited in `Config.Messages`, with the `{loot}` and `{time}` placeholders where available. Labels and messages ship in Italian: translate them in `config.lua` for your server.
