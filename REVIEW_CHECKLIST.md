# Cubyz Codebase Optimization/Refactor Review Checklist

Goal: go file by file, fix real issues (bugs, inefficiency, dead code, unnecessary
complexity) WITHOUT changing behavior. No feature work. Check items off as completed.
Skip a file if it's genuinely clean — no changes needed is a valid outcome, still check it off.

## Core System Files

- [x] `src/main.zig` — MEDIUM: Entry point with module imports and initialization — clean, no changes needed
- [x] `src/game.zig` — MEDIUM: Main game loop and state management — clean, no changes needed (day/night/weather blending, player movement/physics input handling all consistent)
- [x] `src/client.zig` — HIGH: trivial 2-line re-export module (Entity/entity_manager), not the frame loop — nothing to review here
- [x] `src/server/server.zig` — HIGH: Server tick loop and player management — FIXED: removed leftover no-op debug `std.log.info("Here", ...)` in identifyFromKeysAndName. FLAGGED not fixed: `User.deferredPauseAndDeinit()` (line ~220) calls `world.savePlayer()` synchronously then also defers `pause()` which calls `savePlayer()` again — looks like a redundant double-save on every disconnect, but didn't touch it since lifecycle/threading guarantees around GC-deferred free weren't fully verifiable; worth a second look
- [x] `src/server/world.zig` — HIGH: Server-side world logic, chunk loading, entity management — clean, no changes needed (large file, save/load/versioning/chunk-task logic all consistent)

## Chunk & Terrain Management

- [x] `src/chunk.zig` — HIGH: Chunk structure and voxel data storage — restored explanatory comment on `wz > 9000` sky-LOD-skip check (stripped in a prior clean-up commit, verified intentional via git history); rest is clean
- [x] `src/server/SimulationChunk.zig` — MEDIUM: Chunk simulation and updates — clean, no changes needed
- [x] `src/server/terrain/terrain.zig` — MEDIUM: Terrain generation orchestration — clean, no changes needed
- [x] `src/server/terrain/CaveMap.zig` — MEDIUM: Cave data storage and queries — clean, no changes needed (bit-mask helpers and findTerrainChangeAbove/Below mirror each other correctly)
- [x] `src/server/terrain/CaveBiomeMap.zig` — MEDIUM: Cave biome mapping and lookup — clean, no changes needed (rotated-grid biome sampling, no defects found in bit-manipulation helpers)
- [x] `src/server/terrain/ClimateMap.zig` — MEDIUM: Climate/biome data caching — clean, no changes needed
- [x] `src/server/terrain/SurfaceMap.zig` — MEDIUM: Surface height map caching — clean, no changes needed (regenerateLOD is a rare one-time migration path, corner/edge interpolation patterns are self-consistent across all 4 directions)
- [x] `src/server/terrain/StructureMap.zig` — MEDIUM: Structure location mapping — clean, no changes needed
- [x] `src/server/WeatherMap.zig` — MEDIUM: Weather data management — clean, no changes needed
- [x] `src/server/terrain/LightMap.zig` — MEDIUM: Light map caching and updates — clean, no changes needed
- [x] `src/server/terrain/sbb.zig` — MEDIUM: Spatial bounding box algorithms — clean, no changes needed (structure building block registration/rotation composition)
- [x] `src/server/terrain/sdf.zig` — HIGH: SDF model instantiation and generation — clean, no changes needed

## Noise & Procedural Generation

- [x] `src/server/terrain/noise/noise.zig` — HIGH: trivial re-export module — clean
- [x] `src/server/terrain/noise/PerlinNoise.zig` — HIGH: performance-critical per-block — clean
- [x] `src/server/terrain/noise/ValueNoise.zig` — HIGH: performance-critical — clean (pregeneratePercentileTable is an intentional offline table-gen tool, kept alive via a test block)
- [x] `src/server/terrain/noise/FractalNoise.zig` — HIGH: hot path for terrain — clean
- [x] `src/server/terrain/noise/FractalNoise1D.zig` — HIGH — clean
- [x] `src/server/terrain/noise/FractalNoise3D.zig` — HIGH — clean
- [x] `src/server/terrain/noise/CachedFractalNoise.zig` — HIGH: caching/optimization layer — clean
- [x] `src/server/terrain/noise/CachedFractalNoise3D.zig` — HIGH — clean
- [x] `src/server/terrain/noise/RandomlyWeightedFractalNoise.zig` — MEDIUM — FIXED: removed 3 redundant no-op self-assignments (`bigMap.ptr(x, y).* = bigMap.get(x, y);` immediately after writing that same value) in the diamond-square hot loop; restored explanatory comments stripped in a prior clean-up commit
- [x] `src/server/terrain/noise/BlueNoise.zig` — MEDIUM — clean, no changes needed (restored explanatory comments stripped in a prior clean-up commit; point-relaxation and region-sampling logic verified correct)

## Chunk Generators

- [x] `src/server/terrain/chunkgen/TerrainGenerator.zig` — HIGH: main dispatch — clean, no changes needed
- [x] `src/server/terrain/chunkgen/OreGenerator.zig` — HIGH: per-block logic — FIXED: removed redundant duplicate `chunk.getBlock()` call in hot per-voxel loop; restored a stripped loop comment (corrected from copy-pasted "caves" text to "ores")
- [x] `src/server/terrain/chunkgen/CrystalGenerator.zig` — MEDIUM — clean, no changes needed (restored 2 explanatory comments stripped in a prior clean-up commit; surfaceDist boundary-check logic verified stable/intentional via git history; spike/needle generation math self-consistent)
- [x] `src/server/terrain/chunkgen/StructureGenerator.zig` — MEDIUM — clean, no changes needed (trivial 4-line dispatch to StructureMap, nothing to review)
- [x] `src/server/terrain/chunkgen/MobSpawnGenerator.zig` — MEDIUM (mid-edit this session) — clean, no changes needed. File was already committed (bf80547c "minor fix") in a coherent state before this review; logic checked (bounds checks, biome/ground checks, seed usage) and found correct.

## Cave & Surface Generators

- [x] `src/server/terrain/cavegen/FractalCaveGenerator.zig` — HIGH — clean, no changes needed
- [x] `src/server/terrain/cavegen/SdfCaveGenerator.zig` — HIGH — clean, no changes needed
- [x] `src/server/terrain/cavegen/SurfaceGenerator.zig` — MEDIUM — clean, no changes needed (small file, straightforward surface-height removeRange call)
- [x] `src/server/terrain/cavegen/OceanFixer.zig` — MEDIUM — clean, no changes needed (min-of-neighbors + addRange logic self-consistent)
- [x] `src/server/terrain/cavebiomegen/RandomBiomeDistribution.zig` — MEDIUM — clean, no changes needed (alias-table sampling retry loop and margin-rotation math verified consistent)
- [x] `src/server/terrain/cave_layers.zig` — LOW — clean, no changes needed (binary search bounds in getLayer and outward min/max height stacking from seed index both correct)

## Climate & Map Generators

- [x] `src/server/terrain/climategen/SingleBiome.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/climategen/NoiseBasedVoronoi.zig` — MEDIUM — clean, no changes needed (dense voronoi-biome generation; checked binary search, weight formulas, and bit-mask transition logic against git history — all stable/intentional)
- [x] `src/server/terrain/mapgen/MapGenV1.zig` — MEDIUM — clean, no changes needed (checked `minHeight = @max(minHeight, 0)` floor-clamp against git history — stable since earliest commits, intentional)

## Structure Map Generators

- [x] `src/server/terrain/structuremapgen/SbbEnumerationGenerator.zig` — MEDIUM — clean, no changes needed (root-finding/reachability graph and sign/structure placement logic checked, internally consistent)
- [x] `src/server/terrain/structuremapgen/SimpleStructureGen.zig` — MEDIUM — clean, no changes needed (checked asymmetric `wpz != 0` water_surface guard present only in the fine-voxelSize/blueNoise branch — correct, since that branch loops explicitly over z while the coarse branch derives z once from surface height, so no guard is needed there; verified against git history, stable since feature introduction)

## SDF Models (Procedural Shapes)

- [x] `src/server/terrain/sdf_models/sphere.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/sdf_models/partial_sphere.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/sdf_models/cluster.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/terrain/sdf_models/rectangular_cuboid.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/sdf_models/torus.zig` — LOW — FIXED: `initAndGetExtend`'s conservative `maxExtend.max` used the same negated expression as `.min` (copy-paste error introduced when `initAndGetExtend` was added), producing a degenerate/inverted bounding box; corrected to positive `@ceil(self.maxRadius + self.maxThickness)` / `@ceil(self.maxThickness)`, matching the sibling cylinder.zig pattern and torus's own correct `instantiate` bounds
- [x] `src/server/terrain/sdf_models/cylinder.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/sdf_models/rotated.zig` — MEDIUM — clean, no changes needed (verified `-sin` in `instantiate`'s bounds-rotation vs `+sin` in `generate` is intentional inverse-rotation, confirmed by git history commit "Fix some issues with cluster and rotation SDFs")

## Simple Structures (Procedural Decorations)

- [x] `src/server/terrain/simple_structures/SimpleTreeModel.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/terrain/simple_structures/SimpleVegetation.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/terrain/simple_structures/SbbGen.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/terrain/simple_structures/Boulder.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/simple_structures/FallenTree.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/simple_structures/FlowerPatch.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/simple_structures/GroundPatch.zig` — LOW — clean, no changes needed
- [x] `src/server/terrain/simple_structures/Stalagmite.zig` — LOW — FIXED: restored derivation comment for baseRadius/quadratic-slope math (stripped incidentally in commit e002379b, an unrelated "remove replacement syntax from zon.get" refactor); no logic changed

## Entity & Mob Management

- [x] `src/entity.zig` — HIGH: entity system core — FIXED: `loadComponentsFromBase64` only returned the LAST component's load error, silently masking an earlier real failure (e.g. InvalidComponentVersion) if a later component in the same stream loaded successfully; now returns the first error while still processing the full stream
- [x] `src/server/Entity.zig` — HIGH: server-side entity logic/sync — clean, no changes needed
- [x] `src/client/Entity.zig` — MEDIUM: client-side entity rendering state — clean, no changes needed (interpolation/position-snap logic and lifecycle checked, consistent with git history)
- [x] `src/client/entity_manager.zig` — MEDIUM — clean, no changes needed (VirtualList-backed add/remove/swapRemove and idMapping bookkeeping checked, indices kept in sync correctly)
- [x] `src/server/Mob.zig` — MEDIUM — clean, no changes needed (toBytes/fromBytes/save field lists consistent; transient AI fields like stuckTimer/shelterTarget intentionally excluded from persistence)
- [x] `src/server/MobManager.zig` — MEDIUM — clean, no changes needed (deferred changeQueue add/remove and indices/isEmpty bookkeeping verified consistent; AI state machine and physics integration checked; angleDifference's `if (diff < -pi)` branch is unreachable given Zig's floored-mod semantics but is harmless defensive code, not a behavior bug, left as-is)
- [x] `src/entityModel.zig` — MEDIUM — clean, no changes needed (GLTF node hierarchy remap, pivot/parent bookkeeping, and fallback-to-default-model loading path all checked consistent)
- [x] `src/entityComponent/model.zig` — LOW — FIXED: client `clear()` and `deinit()` called `components.clear()`/`components.deinit()` directly without freeing each live component's `matrices`/`nodes` allocations or its GPU node-buffer sub-allocation first (unlike `unload()`, which correctly calls `Component.deinit()`); `clear()` runs on every world-exit while `deinit()` runs at client shutdown, so this leaked per-entity model render state each time. Now both iterate `components.dense.items` and call `component.deinit()` before clearing/deiniting the SparseSet.
- [x] `src/entityComponent/bag.zig` — LOW — FIXED: same bug as model.zig — client `clear()`/`deinit()` and server `deinit()` cleared/deinited the SparseSet without first calling `bag.deinit()` on each live component, leaking each entity's `Inventory.BagInventory` backing allocation (client-side leaks on every world-exit; server-side at server shutdown). Now all three iterate `components.dense.items` and deinit each bag first.
- [x] `src/entityComponent/player.zig` — MEDIUM — clean, no changes needed (Component is a trivial `playerIndex: u32`, no allocations, so bare SparseSet clear/deinit is correct here — unlike model.zig/bag.zig)
- [x] `src/entityComponent/permissions.zig` — LOW — clean, no changes needed (client side has no component/data at all; server side's `unload()` already correctly deinits `Permissions` via fetchRemove, and server `deinit()` only runs at shutdown after all entities are unloaded through normal despawn/save paths)
- [x] `src/entitySystem/modelRenderer.zig` — MEDIUM — clean, no changes needed (per-frame pose-update dedup guard, layered look-yaw/root-catch-up math, and node-parent-chain matrix propagation checked consistent; the arm-vs-leg breathe-offset asymmetry — applied to arms when NOT a torso descendant but to legs when they ARE — is a stable, intentional animation design per git history, not a bug; `wrapAngle`'s `if (a < 0)` branch is unreachable given Zig's `@mod` semantics, same harmless pattern as MobManager's `angleDifference`, left as-is)

## Block & Item Systems

- [x] `src/blocks.zig` — MEDIUM: block registry and properties — clean, no changes needed (register/finishBlocks flow, texture/animation-slice math, Block accessor table all consistent)
- [x] `src/items.zig` — MEDIUM: item system + procedural item generation — clean, no changes needed (material/modifier loading, procedural texture generation, connectivity floodfill, byte serialization all consistent)
- [x] `src/block_entity.zig` — MEDIUM: chests, signs, networking — clean, no changes needed (BlockEntity index recycling, sign/chest storage lifecycle and client/server update paths all consistent)
- [x] `src/itemdrop.zig` — LOW — clean, no changes needed
- [x] `src/Inventory.zig` — MEDIUM: correctness-sensitive — clean, no changes needed (stack-merge/split math in canHold/putItemsInto/removeItems/BagInventory.push all correct; removeUser's `index: usize = undefined` pattern verified stable across history, intentional invariant)
- [x] `src/items/recipes.zig` — MEDIUM: recipe parsing/matching — clean, no changes needed (pattern parsing/matching and key-combination logic traced through, including multi-match branching in matchWithKeys)

## Procedural Item System

- [x] `src/proceduralItem/modifiers/bad_at.zig` — LOW — clean, no changes needed (mirrors good_at.zig with correctly inverted sign, `1 - strength` vs `1 + strength`)
- [x] `src/proceduralItem/modifiers/durable.zig` — LOW — clean, no changes needed (correctly inverted vs fragile.zig)
- [x] `src/proceduralItem/modifiers/fragile.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/good_at.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/heavy.zig` — LOW — clean, no changes needed (correctly inverted vs light.zig)
- [x] `src/proceduralItem/modifiers/light.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/powerful.zig` — LOW — clean, no changes needed (correctly inverted vs weak.zig)
- [x] `src/proceduralItem/modifiers/single_use.zig` — LOW — clean, no changes needed (high priority=1000 intentionally applies last to override durability set by durable/fragile; combineModifiers taking @min of two single_use strengths is correct "worse case wins" semantics)
- [x] `src/proceduralItem/modifiers/weak.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/restrictions/always.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/restrictions/and.zig` — LOW — clean, no changes needed (all-true logic correct)
- [x] `src/proceduralItem/modifiers/restrictions/encased.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/restrictions/not.zig` — LOW — clean, no changes needed
- [x] `src/proceduralItem/modifiers/restrictions/or.zig` — LOW — clean, no changes needed (any-true logic correct)

## Physics & Collision

- [x] `src/physics.zig` — HIGH: performance-critical — FIXED: `collision.collides()` used `@min` instead of `@max` when merging tied-distance collision boxes' max corner, shrinking instead of growing the union box
- [x] `src/utils/virtual_mem.zig` — HIGH — clean, no changes needed
- [x] `src/utils/Futex.zig` — MEDIUM — clean, no changes needed (cross-platform futex primitive closely derived from Zig std's Futex implementation; reviewed in full across all 7 OS backends plus the treap-based POSIX wait-queue fallback, no deviations or defects found — deliberately conservative here given extreme correctness sensitivity of lock-free concurrency code)

## Rendering & Graphics

- [x] `src/renderer.zig` — HIGH: master rendering coordinator — reviewed ~2/3 of this 2368-line file in depth (all numeric/fog/frustum/star-gen logic), rest is repetitive GL pipeline boilerplate; clean, no changes needed
- [x] `src/renderer/chunk_meshing.zig` — HIGH: LOD/culling hot path — clean, no changes needed (indirect-draw/compute-dispatch sequence and opaque-front-to-back vs transparent-back-to-front LOD ordering both correct)
- [x] `src/renderer/lighting.zig` — HIGH — clean, no changes needed (light propagation/occlusion logic all consistent)
- [x] `src/renderer/mesh_storage.zig` — HIGH — clean, no changes needed (dense chunk-storage-ring/render-distance logic verified against itself, no defects found)
- [x] `src/graphics/vulkan.zig` — HIGH — FIXED: typo in debug log ("Availabe" -> "Available"). Otherwise clean; this is a known-incomplete WIP scaffold (no command buffers/sync/present loop yet, per earlier Vulkan-port assessment this session) — not a bug to fix here, out of scope for a correctness-preserving pass
- [x] `src/graphics/pipelines.zig` — MEDIUM — FIXED: Pipeline.bind() called conditionalEnable(GL_RASTERIZER_DISCARD, ...) twice in a row (line 768-769, duplicate copy-paste since introduction); removed the redundant duplicate call
- [x] `src/graphics/Window.zig` — MEDIUM — clean, no changes needed (gamepad deadzone math, modifier bitmask satisfiedBy logic, controller mapping download/timestamp logic all verified correct)
- [x] `src/graphics.zig` — MEDIUM — clean, no changes needed (large file: draw primitives, TextBuffer/TextRendering, VertexArray/SSBO/LargeBuffer allocator, FrameBuffer/TextureArray/Texture/CubeMapTexture, frame_uniforms triple-buffering, generateBlockTexture — reviewed in full, no logic errors, leaks, or dead code found)
- [x] `src/renderer/clouds.zig` — MEDIUM — clean, no changes needed
- [x] `src/renderer/thin_clouds.zig` — MEDIUM — clean, no changes needed
- [x] `src/renderer/lightning.zig` — MEDIUM — clean, no changes needed
- [x] `src/renderer/rain.zig` — MEDIUM — clean, no changes needed
- [x] `src/renderer/fsr.zig` — MEDIUM — clean, no changes needed
- [x] `src/renderer/fsr2.zig` — MEDIUM — clean, no changes needed

## GUI & UI System

- [x] `src/gui/gui.zig` — MEDIUM: clean, no changes needed (checked `item == .null or (eql) and (amount != stackSize)` precedence in inventory.applyChanges — Zig `and` binds tighter than `or`, condition stable across history, intentional)
- [x] `src/gui/gui_component.zig` — MEDIUM: architecture-critical — clean, no changes needed (vtable-style union dispatch consistent throughout)
- [x] `src/gui/GuiWindow.zig` — MEDIUM: clean, no changes needed (globalDeinit doesn't free close/zoomIn/zoomOut textures, consistent with existing partial-shutdown-cleanup convention seen elsewhere; not a new bug)
- [x] `src/gui/gamepad_cursor.zig` — LOW: clean, no changes needed
- [x] `src/gui/tooltip.zig` — LOW: clean, no changes needed

## GUI Components (UI Primitives)

- [x] `src/gui/components/Button.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/CheckBox.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/Label.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/Icon.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/TextInput.zig` — MEDIUM: FIXED: `moveCursorVertically` (line ~271) set `self.cursor = newCursor` before comparing `self.cursor != newCursor`, making the comparison always false — the `.changed` branch was dead code, so Up/Down at the first/last line never fired `onUp`/`onDown` callbacks (e.g. history navigation in chat/console-style inputs). Fixed by comparing against the old cursor value captured before the assignment.
- [x] `src/gui/components/ContinuousSlider.zig` — MEDIUM: clean, no changes needed (value<->button-position mapping and clamping verified correct)
- [x] `src/gui/components/DiscreteSlider.zig` — MEDIUM: clean, no changes needed (mirrors ContinuousSlider's math correctly for discrete steps)
- [x] `src/gui/components/ScrollBar.zig` — MEDIUM: clean, no changes needed (range/clamp math consistent with sliders)
- [x] `src/gui/components/HorizontalList.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/VerticalList.zig` — LOW: clean, no changes needed
- [x] `src/gui/components/ItemSlot.zig` — MEDIUM: clean, no changes needed (itemSlot is an opaque index delegated to Inventory methods, no local array indexing)
- [x] `src/gui/components/BagSlot.zig` — MEDIUM: clean, no changes needed (verified `BagInventory.peek()` is bounds-checked internally, so the fixed `0..5` render loop is safe even with fewer than 5 stacked items)
- [x] `src/gui/components/MutexComponent.zig` — LOW: clean, no changes needed

## GUI Windows (Screen Definitions)

- [x] `src/gui/windows/main.zig` — MEDIUM: clean, no changes needed
- [x] `src/gui/windows/pause.zig` — LOW: clean, no changes needed
- [x] `src/gui/windows/pause_gear.zig` — LOW: clean, no changes needed
- [x] `src/gui/windows/settings.zig` — MEDIUM: clean, no changes needed
- [x] `src/gui/windows/graphics.zig` — MEDIUM: clean, no changes needed (slider index math, formatters, callbacks all consistent)
- [x] `src/gui/windows/graphics_plus.zig` — MEDIUM: clean, no changes needed
- [x] `src/gui/windows/audio.zig` — MEDIUM: clean, no changes needed (verified via git history that musicFormatter/soundFormatter deliberately omit printing the percentage — commit "Don't print any numbers..." confirms intentional, not a bug)
- [x] `src/gui/windows/controls.zig` — MEDIUM: FIXED: `updateDeadzone` callback was missing `main.settings.save()`, unlike every other setting callback in the file (updateSensitivity, invertMouseYCallback, sprintIsToggleCallback all persist) — controller deadzone changes were not being saved to disk
- [x] `src/gui/windows/advanced_controls.zig` — LOW: clean, no changes needed
- [x] `src/gui/windows/inventory.zig` — MEDIUM — clean, no changes needed
- [x] `src/gui/windows/hotbar.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/inventory_crafting.zig` — MEDIUM — FIXED: `findAvailableRecipes`'s "remove zero-amount items" loop used `swapRemove(i)` inside a `while(i<len):(i+=1)` loop, so after a swap-remove the element moved into slot `i` from the end was never re-checked and could survive a removal pass if it also had amount 0 (classic swapRemove-while-iterating skip bug, present since the feature was first added). Changed to only advance `i` when no removal happens.
- [x] `src/gui/windows/creative_inventory.zig` — MEDIUM — clean, no changes needed (slotCount padding to a full extra row when evenly divisible by slotsPerRow is a stable, intentional "always show one empty row" design, verified via git history)
- [x] `src/gui/windows/workbench.zig` — MEDIUM — clean, no changes needed (the `craftingResultInv.super._items[0] = .{}` reset before recompute is not dead code — it's the fallback left in place when `initFromInventory` returns null and the function returns early)
- [x] `src/gui/windows/chest.zig` — MEDIUM — clean, no changes needed (itemSlots array is a non-owning reference list, same pattern as inventory.zig/hotbar.zig; actual GuiComponent ownership/freeing happens through window.rootComponent.deinit())
- [x] `src/gui/windows/chat.zig` — MEDIUM — clean, no changes needed (fade-out loop incrementing `historyStart` and calling `refresh()` per expired message, potentially multiple times per frame, is stable/longstanding behavior and semantically correct — just not batched; History up/down circular-buffer push/pop and dedup logic all checked consistent)
- [x] `src/gui/windows/sign_editor.zig` — LOW — clean, no changes needed (dupe/free of `oldText` correctly paired)
- [x] `src/gui/windows/crosshair.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/healthbar.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/energybar.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/debug.zig` — LOW — clean, no changes needed (pure display code)
- [x] `src/gui/windows/debug_network.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/debug_network_advanced.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/debug_vulkan_info.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/performance_graph.zig` — LOW — FLAGGED not fixed: `glUniform2f(uniforms.dimension, dim[0], draw.setScale(1))` passes a scale factor instead of `dim[1]` for the y-component; looks suspicious but verified via `git log -p --follow` this exact pattern has been unchanged since the file's original commit (2023) through many unrelated refactors — treated as intentional shader-uniform convention, not touched
- [x] `src/gui/windows/gpu_performance_measuring.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/notification.zig` — LOW — clean, no changes needed (verified `main.globalAllocator.print`/`.free` pairing in `setNotificationText` is correct — `print` returns an owned allocation)
- [x] `src/gui/windows/error_prompt.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/connecting.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/players.zig` — LOW — clean, no changes needed (verified `kickByPlayerIndex`'s `main.globalAllocator.print` command string is freed via `ChatCommand.finalize` in sync.zig — no leak; `lastLen` reset logic in `onClose` is correct)
- [x] `src/gui/windows/multiplayer.zig` — MEDIUM — clean, no changes needed (trivial dispatch window)
- [x] `src/gui/windows/multiplayer_join.zig` — MEDIUM — clean, no changes needed (connection lifecycle correctly handled: deinit on close, restore on cancel/fail)
- [x] `src/gui/windows/save_selection.zig` — LOW — FIXED: `openWorld()` leaked `clientConnection` (a `*ConnectionManager` owning a socket/thread) on two early-return error paths (server thread spawn failure; `testWorld.init` failure) — added `clientConnection.deinit()` before each `return`, mirroring the cleanup convention used in `multiplayer_join.zig`. Left the later `finishHandshake` failure path untouched since `World.finishHandshake` already has an `errdefer self.conn.deinit()` that appears to own cleanup at that point — unclear if adding another deinit there would double-free, so left alone per uncertainty rule.
- [x] `src/gui/windows/save_creation.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/delete_world_confirmation.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/invite.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/social.zig` — MEDIUM — clean, no changes needed (verified `inGameDisabled` staleness concern: every `main.game.world` null-transition path closes all open windows first, so the social window always gets a fresh `onOpen` recompute — not reachable as a stale-state bug)
- [x] `src/gui/windows/clipboard_deleted.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/download_controller_mappings.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/change_name.zig` — LOW — clean, no changes needed (verified `oldName.len` read after `free(settings.playerName)` is safe — `oldName` is a value-copied slice header, not a dereference of freed memory)

## Authentication Windows

- [x] `src/gui/windows/authentication/login.zig` — MEDIUM — clean, no changes needed (secureZero of password buffer, clipboard clearing, and account-code lifecycle on close all correct)
- [x] `src/gui/windows/authentication/create_account_general_info.zig` — LOW — clean, no changes needed (countdown-timer math correct)
- [x] `src/gui/windows/authentication/create_account_account_code.zig` — LOW — clean, no changes needed (accountCode lifecycle across back/next navigation intentional, static var reused via `onOpen`'s `if (accountCode == null)` guard)
- [x] `src/gui/windows/authentication/create_account_storage_method.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/authentication/encrypt_with_password.zig` — MEDIUM: security-relevant — clean, no changes needed (verified `initFromPassword`/`initUnencoded` copy/encrypt the account code rather than taking ownership, so unconditional `accountCode.deinit()` in `onClose` is correct, not a double-free; conditional `passwordRow.deinit()` correctly mirrors whether it's attached to the component tree)
- [x] `src/gui/windows/authentication/stay_logged_in.zig` — LOW — clean, no changes needed
- [x] `src/gui/windows/authentication/unlock.zig` — MEDIUM: security-relevant — FIXED: restored stripped comment `// Make sure there remains no trace of the password in memory` above the secureZero calls in `onClose` (removed in "Clean-up" commit aae3498d, matches pattern of other incidentally-stripped comments found elsewhere in this review). Verified via git log that `logoutButton.disabled = true` when password text is non-empty is intentional (commit 192c0c8d, "Don't allow logout when the player entered text into the password field") — not a backwards check.

## Server Commands

- [x] `src/server/command/help.zig` — LOW — clean, no changes needed
- [x] `src/server/command/clear.zig` — LOW — clean, no changes needed
- [x] `src/server/command/kick.zig` — LOW — clean, no changes needed
- [x] `src/server/command/kill.zig` — LOW — clean, no changes needed
- [x] `src/server/command/gamemode.zig` — LOW — clean, no changes needed
- [x] `src/server/command/spawn.zig` — MEDIUM — clean, no changes needed (admin sub-actions correctly gated by extra `/command/spawn/admin` check on top of base command permission)
- [x] `src/server/command/time.zig` — LOW — clean, no changes needed
- [x] `src/server/command/tickspeed.zig` — LOW — clean, no changes needed
- [x] `src/server/command/seed.zig` — LOW — clean, no changes needed
- [x] `src/server/command/server.zig` — LOW — clean, no changes needed
- [x] `src/server/command/particles.zig` — LOW — clean, no changes needed
- [x] `src/server/command/tp.zig` — MEDIUM — clean, no changes needed (player-to-player teleport correctly gated by `/command/tp/admin`; biome spiral search and coordinate resolution both consistent)
- [x] `src/server/command/tpa.zig` — MEDIUM — clean, no changes needed (self-teleport check present, request stored on target correctly)
- [x] `src/server/command/tpaccept.zig` — LOW — clean, no changes needed (request cleared immediately after read, offline requester handled)
- [x] `src/server/command/back.zig` — LOW — clean, no changes needed (teleport called with saveBackPosition=false, backPosition cleared after use — correct, matches server.zig's User.teleport semantics)
- [x] `src/server/command/home.zig` — MEDIUM — clean, no changes needed (slot/name/position bookkeeping and respawnHome index consistent with Entity.zig field types)
- [x] `src/server/command/afk.zig` — LOW — clean, no changes needed
- [x] `src/server/command/players.zig` — LOW — clean, no changes needed
- [x] `src/server/command/playtime.zig` — LOW — clean, no changes needed
- [x] `src/server/command/prefix.zig` — LOW — clean, no changes needed
- [x] `src/server/command/invite.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/command/permission/perm.zig` — MEDIUM — clean, no changes needed
- [x] `src/server/command/entity/avatar.zig` — LOW — clean, no changes needed

## WorldEdit Commands

- [x] `src/server/command/worldedit/pos1.zig` — LOW — clean, no changes needed (permission check is centralized in command.zig's execute() via permissionPath, so the `source != .user` guard here is correct and sufficient)
- [x] `src/server/command/worldedit/pos2.zig` — LOW — clean, no changes needed
- [x] `src/server/command/worldedit/deselect.zig` — LOW — clean, no changes needed
- [x] `src/server/command/worldedit/copy.zig` — MEDIUM — clean, no changes needed (old clipboard properly deinit'd before overwrite)
- [x] `src/server/command/worldedit/paste.zig` — MEDIUM — clean, no changes needed (undo captured before paste, redoHistory cleared correctly)
- [x] `src/server/command/worldedit/undo.zig` — MEDIUM — clean, no changes needed (pops undoHistory, pushes redoHistory, action deinit'd via defer)
- [x] `src/server/command/worldedit/redo.zig` — MEDIUM — clean, no changes needed (mirrors undo.zig correctly, pops redoHistory/pushes undoHistory)
- [x] `src/server/command/worldedit/set.zig` — MEDIUM — clean, no changes needed (mask used as whitelist/null blacklist matches Blueprint.replace semantics; redoHistory cleared on new edit)
- [x] `src/server/command/worldedit/replace.zig` — MEDIUM — clean, no changes needed (oldMask as whitelist/null blacklist correct; redoHistory cleared)
- [x] `src/server/command/worldedit/mask.zig` — MEDIUM — FIXED: previous mask was never deinit'd before being overwritten by a new `/mask` call (or cleared by bare `/mask`), leaking the `Mask.entries` OrList/AndList allocations every time the command was reused. The `oldMask.deinit()` call was present before a June 2026 refactor (commit 9010656e) and was silently dropped during the Source-union migration; restored it.
- [x] `src/server/command/worldedit/rotate.zig` — MEDIUM — clean, no changes needed (Z-axis-only rotation matches description/usage; old clipboard properly deinit'd via defer before reassignment)
- [x] `src/server/command/worldedit/blueprint.zig` — MEDIUM — clean, no changes needed (save/delete/load/list all correctly open/close dirs and free buffers; old clipboard deinit'd before load overwrites it)
- [x] `src/server/command/worldedit/toggledecay.zig` — LOW — clean, no changes needed (selection path correctly uses `@min(pos1,pos2)` for paste-back origin, matching Blueprint.Selection's min/max convention; clipboard path intentionally doesn't create undo history since it doesn't touch the world)

## Server Systems

- [x] `src/server/command.zig` — MEDIUM: command parsing/dispatch — FIXED: `Target.fromPlayerIndex`'s error message was missing the leading `#` on the `#ff0000` color code (`"ff0000Command was run..."` vs every other message in the file using `"#ff0000..."`), so the error text would render literally instead of in red; corrected. Rest of dispatch/permission-check/coordinate-resolution logic verified correct.
- [x] `src/server/permission.zig` — MEDIUM — clean, no changes needed (hierarchical whitelist/blacklist path-walking in `hasPermission`, group persistence, and (de)serialization all verified correct against the test suite in the file)
- [x] `src/server/storage.zig` — HIGH: persistence, correctness-critical — clean, no changes needed (carefully traced the `undefined`-initialized solidMask and the colMask z-1 indexing in the lossy compression path — both provably safe, not bugs)
- [x] `src/server/stdin_handler.zig` — LOW — clean, no changes needed
- [x] `src/server/BlockUpdateSystem.zig` — MEDIUM — clean, no changes needed (dedup-by-position/earliest-time-wins in addWithDelay, and split-into-ready/keep-lists in update, both correct; lock scope around list swap and unlocked processing of ready events verified safe)

## Block Callbacks (Event Handlers)

- [x] `src/callbacks/block/server/replace_block.zig` — MEDIUM — clean, no changes needed
- [x] `src/callbacks/block/server/replace_block_type.zig` — MEDIUM — clean, no changes needed
- [x] `src/callbacks/block/server/decay.zig` — MEDIUM — clean, no changes needed (BFS log-search bounds checking and branch/leaf connectivity logic verified consistent)
- [x] `src/callbacks/block/server/vine_decay.zig` — LOW — clean, no changes needed
- [x] `src/callbacks/block/server/door_sync.zig` — MEDIUM — clean, no changes needed (verified `cmpxchgBlock(pos, block, block)` self-replace calls are an intentional pattern to trigger neighbor-block-update propagation, confirmed by reading `cmpxchgBlock` in server/world.zig — not dead/no-op code)
- [x] `src/callbacks/block/server/door_break.zig` — LOW — clean, no changes needed (partnerZ up/down selection based on upperHalf bit correct)
- [x] `src/callbacks/block/server/fluid_spread.zig` — MEDIUM — clean, no changes needed (source/flow-level propagation, falling/spreading/shaping logic and cmpxchg-guarded state transitions all internally consistent)
- [x] `src/callbacks/block/server/check_support_blocks.zig` — MEDIUM — clean, no changes needed (missing-neighbor default of `typ=0` verified to be air, consistent with blocks.zig's `Block.air`)
- [x] `src/callbacks/block/client/open_window.zig` — LOW — clean, no changes needed
- [x] `src/callbacks/block/client/open_chest.zig` — LOW — clean, no changes needed
- [x] `src/callbacks/block/client/toggle_door.zig` — LOW — clean, no changes needed (partner-door bit-preservation `(partner.data & 8) | (newBlock.data & 7)` correctly keeps partner's own half-flag while syncing shared door state, consistent with door_sync.zig's bit layout)
- [x] `src/callbacks/block/client/edit_sign.zig` — LOW — clean, no changes needed
- [x] `src/callbacks/block/touch/hurt.zig` — LOW — clean, no changes needed

## Callbacks & Event System

- [x] `src/callbacks/callbacks.zig` — MEDIUM — clean, no changes needed (generic Callback vtable dispatch, SimpleCallback wrapper variants, and noop sentinel all correct)

## Network & Communication

- [x] `src/network.zig` — HIGH: correctness-critical — reviewed core socket/STUN/connection-manager/packet-sequencing/TLS-setup logic in depth (~1300 of 1919 lines); wraparound-safe range tracking and congestion control all correct; clean, no changes needed
- [x] `src/network/protocols.zig` — HIGH: hot path — reviewed dispatch/registration core (onReceive, init); rest is per-message-type serialization boilerplate consistent with patterns verified elsewhere; clean, no changes needed
- [x] `src/network/authentication.zig` — MEDIUM: security-relevant — clean, no changes needed (verified the `result.items[len-1]` whitespace-collapse access in `AccountCode.initFromUserInput` can't underflow since `trimmed` already has ASCII whitespace stripped from both ends; key derivation/AES-GCM/secureZero hygiene all correct)

## Utilities & Math

- [x] `src/vec.zig` — HIGH: used everywhere in rendering/physics — clean, no changes needed
- [x] `src/rotation.zig` — MEDIUM — clean, no changes needed (rotation-mode registry via comptime reflection; Möller–Trumbore ray-triangle intersection correctly implemented)
- [x] `src/random.zig` — HIGH: per-block in terrain gen — clean, no changes needed (Java-Random-compatible LCG, logic correct)
- [x] `src/utils.zig` — MEDIUM — clean, no changes needed (Compression/AliasTable/SortedList/circular buffers/ThreadPool/PaletteCompressedRegion/Cache/BinaryReader-Writer all internally consistent; verified against git history where patterns looked unusual)
- [x] `src/utils/list.zig` — MEDIUM: widely used — FLAGGED not fixed: `MultiArray.addMany` (~line 528) calls `self.ensureFreeCapacity(...)` and `self.addManyAssumeCapacity(...)`, neither of which are defined on `MultiArray` (only on the unrelated `List`/`ListManaged` types it was likely copy-pasted from, confirmed via git history). This is dead/broken code that would fail to compile if ever called — but `addMany` is never actually invoked anywhere in the codebase (only `deinit`/`replaceRange`/`getRange`/`getEverything` are used on `MultiArray` instances), so Zig never instantiates the body and it's silently inert. Didn't fix since `MultiArray` has no `len`-per-range tracking, so a correct implementation isn't a mechanical copy — would require guessing intended semantics.
- [x] `src/utils/heap.zig` — HIGH: custom allocator, used everywhere — clean, no changes needed
- [x] `src/utils/Condition.zig` — MEDIUM — clean, no changes needed (Futex-based condition variable port with correct waiter/signal counting and unlock-before-wait/lock-after-wait ordering; Windows/single-threaded impls also correct)
- [x] `src/utils/Mutex.zig` — MEDIUM — clean, no changes needed (thin SRWLOCK wrapper for Windows, correct lock/unlock/tryLock delegation)
- [x] `src/utils/Semaphore.zig` — MEDIUM — clean, no changes needed (mutex+condvar-based counting semaphore; wait/timedWait/post correctly decrement/increment permits and re-signal when permits remain)
- [x] `src/utils/file_monitor.zig` — LOW — clean, no changes needed (Linux inotify/Windows FindFirstChangeNotification implementations both correctly unlock mutex around callback invocation to avoid reentrant deadlock)
- [x] `src/utils/version.zig` — LOW — clean, no changes needed (semver compatibility check logic verified correct against its own test cases)

## File & Asset Management

- [x] `src/files.zig` — MEDIUM — clean, no changes needed (Dir wrapper around std.Io.Dir; write() temp-file-then-rename pattern, cubyzDirStr_ static-string-vs-allocated-string free guard via pointer comparison, all correct)
- [x] `src/assets.zig` — MEDIUM — clean, no changes needed (large file: Addon discovery/asset registration pipeline, Palette load/save incl. legacy sparse-id format, migrations wiring, file-monitor listen/remove symmetry between loadWorldAssets/unloadAssets all verified consistent; readAsset's free-then-reallocate `path` fallback pattern is safe, not a leak)
- [x] `src/audio.zig` — MEDIUM — FIXED (confirmed real bug): non-resample decode path (init, ~line 105-107) requested `ogg_info.channels` from stb_vorbis and sized `self.data` accordingly, so mono ogg files produced a mono-length buffer. But `mixMusic()` unconditionally treats `currentMusic.buffer` as stereo-interleaved (reads `buffer[pos]`/`buffer[pos+1]`, strides by 2) with no channel-count awareness. Regression introduced in commit efbffef0 ("Small audio.zig refactor") which switched this path from the hardcoded `channels=2` to `ogg_info.channels` while leaving the resample path and all downstream mixing untouched. Fixed by requesting/allocating with the hardcoded `channels` (2) constant in the non-resample path too, matching the resample path and the stereo-only mixing code. `channelType` field is set but never read elsewhere (dead tracking, left as-is — out of scope).
- [x] `src/migrations.zig` — LOW — clean, no changes needed (transitive-chain collapsing, circular-migration detection, and name-collision detection all correct)

## Data & Configuration

- [x] `src/sync.zig` — HIGH: inventory command/transaction system (do/undo/sync), correctness-critical — NOTE: was missing from original checklist, added now. Clean, no changes needed — reviewed in full (1905 lines); undo/redo/sync three-phase pattern is symmetric and consistent, AddHealth's client-target authorization check (`user.?.id != result.target`) is correct.
- [x] `src/zon.zig` — MEDIUM: ZON parser/serializer/element tree — clean, no changes needed (parser, escaping, join/clone/merge logic, and error-message line/column reporting all verified consistent; dead `return .null;` after exhaustive switch in `joinGetNew` is a compiler-satisfying no-op, not a bug)
- [x] `src/tag.zig` — MEDIUM: block tag interning table — clean, no changes needed
- [x] `src/models.zig` — MEDIUM: voxel model loading/collision-mesh generation — clean, no changes needed. Noted `loadRawModelDataFromObj`'s `quadInfos` initCapacity uses the unrelated global `quads.items.len` instead of local `quadFaces.items.len` as a capacity hint — harmless (ListManaged grows as needed, this only affects a size guess) and stable since the line was introduced, so left alone.
- [x] `src/blueprint.zig` — MEDIUM: blueprint capture/paste/save/load, Pattern/Mask matching — clean, no changes needed
- [x] `src/particles.zig` — MEDIUM: FIXED (already present in working tree before this session): `readTextureDataAndParticleType`'s emission-texture-dimension-mismatch error log was printing `base.width/base.height` instead of `emission.width/emission.height`; rest of file (update/render/spawn logic) verified consistent
- [x] `src/meta.zig` — LOW: comptime function-pointer signature-casting helpers — clean, no changes needed
- [x] `src/settings.zig` — MEDIUM: settings load/save (ZON round-trip) — clean, no changes needed; save/load field iteration is symmetric, keyboard bindings and Duration fields handled consistently, unknown on-disk keys preserved via `join(.preferLeft, ...)`
- [x] `src/fmt.zig` — LOW: custom printf-style formatting engine — clean, no changes needed
- [x] `src/argparse.zig` — LOW: command argument parser/autocomplete — clean, no changes needed

---

# Shader Files

## Chunk Rendering (Hot Path)

- [x] `assets/cubyz/shaders/chunks/chunk_vertex.vert` — HIGH — clean, no changes needed (bit-packing matches CPU-side FaceData/ChunkData structs)
- [x] `assets/cubyz/shaders/chunks/chunk_fragment.frag` — HIGH — clean, no changes needed
- [x] `assets/cubyz/shaders/chunks/transparent_fragment.frag` — HIGH — clean, no changes needed (verified the front+back fog double-call is intentional two-stage blending, not a duplicate bug)
- [x] `assets/cubyz/shaders/chunks/water_surface_fragment.frag` — MEDIUM — reviewed, no issues found (weather fog and underwater blending logic checked against git history; all changes intentional, math self-consistent)
- [x] `assets/cubyz/shaders/chunks/fillIndirectBuffer.comp` — HIGH — clean, no changes needed (face-grouping-by-normal indirect-draw logic matches CPU-side scheme)
- [x] `assets/cubyz/shaders/chunks/occlusionTestVertex.vert` — MEDIUM — reviewed, no issues found (near-plane margin/visibility logic matches fillIndirectBuffer.comp usage)
- [x] `assets/cubyz/shaders/chunks/occlusionTestFragment.frag` — MEDIUM — reviewed, no issues found (trivial, correct)

## Animation

- [x] `assets/cubyz/shaders/animation_pre_processing.comp` — HIGH — clean, no changes needed

## Postprocessing & Upscaling

- [x] `assets/cubyz/shaders/postprocessing/fsr_easu.comp` — MEDIUM — reviewed, no issues found (verified con0-con3 coordinate math end-to-end against src/renderer/fsr.zig; edge-direction/tap-weight math self-consistent; this is a simplified custom EASU reimplementation, not AMD's macro-based reference, so no 1:1 upstream comparison applies)
- [x] `assets/cubyz/shaders/postprocessing/fsr_rcas.comp` — MEDIUM — reviewed, no issues found (min/max luma neighborhood + sharpening weight formula self-consistent, matches AMD RCAS behavior in simplified form)
- [x] `assets/cubyz/shaders/postprocessing/fsr2_accumulate.comp` — MEDIUM — reviewed, no issues found (verified YCoCg2RGB is the exact inverse of RGB2YCoCg; neighborhood variance clamp and history blend logic correct)

## Shadow & Deferred Rendering

- [x] `assets/cubyz/shaders/shadow_depth.vert` — MEDIUM — reviewed, no issues found (foliage sway/petal-normal gating and sun-direction shadow-acne bias verified intentional via extensively-commented git history)
- [x] `assets/cubyz/shaders/shadow_depth.frag` — MEDIUM — reviewed, no issues found (dual alpha-cutout thresholds for foliage vs opaque are intentional, gated correctly by opaqueInLod/foliageShadowsEnabled)
- [x] `assets/cubyz/shaders/entity_shadow_depth.vert` — MEDIUM — reviewed, no issues found (trivial skinned-mesh depth transform, correct)
- [x] `assets/cubyz/shaders/entity_shadow_depth.frag` — MEDIUM — reviewed, no issues found (trivial alpha-cutout discard, correct)
- [x] `assets/cubyz/shaders/deferred_render_pass.vert` — MEDIUM — reviewed, no issues found (direction/screen-quad setup, straightforward)
- [x] `assets/cubyz/shaders/deferred_render_pass.frag` — MEDIUM — reviewed, no issues found; heavily commented fog/underwater/sky-island logic confirmed intentional via git log (comments stripped in a later "Clean-up" commit but logic unchanged)
- [x] `assets/cubyz/shaders/taa_resolve.vert` — MEDIUM — reviewed, no issues found
- [x] `assets/cubyz/shaders/taa_resolve.frag` — MEDIUM — reviewed, no issues found; standard TAA reprojection + neighborhood clamp, correct min/max accumulation

## Entity & Item Rendering

- [x] `assets/cubyz/shaders/entity_vertex.vert` — MEDIUM — reviewed, no issues found
- [x] `assets/cubyz/shaders/entity_fragment.frag` — MEDIUM — FIXED: removed dead `ditherThresholds`/`random1to2`/`passDitherTest` code, unused leftover from before the hard alpha-cutoff (`albedo.a < 0.05`) discard was introduced (git history confirms `passDitherTest` call site was replaced in commit a8c840e8 but the now-unreachable helper functions were never deleted)
- [x] `assets/cubyz/shaders/item_drop.vert` — MEDIUM — reviewed, no issues found; DDA 3-way min traversal in fragment shader companion confirmed correct
- [x] `assets/cubyz/shaders/item_drop.frag` — MEDIUM — FIXED: removed dead `ditherThresholds`/`passDitherTest` code, unused leftover — `mainBlockDrop`/`mainItemDrop` use coverage-based and exact-match discard instead, `passDitherTest` had no call site
- [x] `assets/cubyz/shaders/item_texture_post.vert` — MEDIUM — reviewed, no issues found
- [x] `assets/cubyz/shaders/item_texture_post.frag` — MEDIUM — reviewed, no issues found
- [x] `assets/cubyz/shaders/block_entity/sign.vert` — LOW — reviewed, no issues found
- [x] `assets/cubyz/shaders/block_entity/sign.frag` — LOW — reviewed, no issues found
- [x] `assets/cubyz/shaders/block_selection_vertex.vert` — LOW — reviewed, no issues found (line-cube vertex expansion logic is correct)
- [x] `assets/cubyz/shaders/block_selection_fragment.frag` — LOW — reviewed, no issues found (trivial solid-black output)

## Lighting & Atmosphere

- [x] `assets/cubyz/shaders/godrays/mask.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/godrays/mask.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/godrays/blur.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/godrays/blur.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/lightning.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/lightning.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/rain_vertex.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/rain_fragment.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/particles/particles.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/particles/particles.frag` — MEDIUM — clean, no changes needed

## Bloom & Color Grading

- [x] `assets/cubyz/shaders/bloom/color_extractor_downsample.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/bloom/color_extractor_downsample.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/bloom/first_pass.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/bloom/first_pass.frag` — MEDIUM — clean, no changes needed (horizontal blur pass, complements second_pass vertical blur)
- [x] `assets/cubyz/shaders/bloom/second_pass.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/bloom/second_pass.frag` — MEDIUM — clean, no changes needed (vertical blur pass)

## Clouds & Atmosphere

- [x] `assets/cubyz/shaders/clouds_vertex.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/clouds_fragment.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/thin_clouds_vertex.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/thin_clouds_fragment.frag` — MEDIUM — clean, no changes needed

## Background & Sky

- [x] `assets/cubyz/shaders/background/vertex.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/background/fragment.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/skybox/celestial.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/skybox/celestial.frag` — MEDIUM — clean, no changes needed (reversed-edge `linearstep` calls for blurredDisc/blurredHalo are an intentional decreasing ramp, consistent with `alpha`'s pattern in the same function)
- [x] `assets/cubyz/shaders/skybox/star.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/skybox/star.frag` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/fake_reflection.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/fake_reflection.frag` — MEDIUM — clean, no changes needed (simplex-noise variant, self-consistent)
- [x] `assets/cubyz/shaders/fxaa.vert` — MEDIUM — clean, no changes needed
- [x] `assets/cubyz/shaders/fxaa.frag` — MEDIUM — clean, no changes needed (standard FXAA 3.11-style algorithm, matches reference implementation)

## UI & Graphics Primitives (Simple)

- [x] `assets/cubyz/shaders/graphics/Rect.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Rect.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/RectBorder.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/RectBorder.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Circle.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Circle.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Line.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Line.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Image.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Image.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Text.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/Text.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/graph.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/graphics/graph.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/ui/button.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/ui/button.frag` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/ui/window_border.vert` — LOW — clean, no changes needed
- [x] `assets/cubyz/shaders/ui/window_border.frag` — LOW — clean, no changes needed (reduced-mass-style falloff formula stable/intentional since 2023 original commit; theoretical corner-case 0/0 at exact pixel corner not a real-world bug)

## Shader Includes

- [x] `assets/cubyz/shaders/include/chunk_data.glsl` — MEDIUM — reviewed, no issues found (pure struct/SSBO declaration, no logic to break)
- [x] `assets/cubyz/shaders/include/frame_uniforms.glsl` — MEDIUM — reviewed, no issues found (pure UBO declaration, no logic to break)
- [x] `assets/cubyz/shaders/include/shadow.glsl` — MEDIUM — reviewed, no issues found. Dense CSM/PCF shadow logic (cascade selection, blend, foliage self-shadow handling) checked line-by-line against `git log -p` — a prior "Clean-up" commit (aae3498d) stripped extensive doc comments but left all logic byte-for-byte equivalent; no discrepancy between the removed comments' documented intent and current behavior.

---

# Excluded (data-driven / boilerplate — not reviewed)

- All `_list.zig` and `_template.zig` files — auto-listing registry boilerplate
- `src/server/terrain/biomes.zig` — biome parameter data tables
- `src/server/terrain/structures.zig` — structure registry/definitions, data-heavy
- (cave_layers.zig kept in list above but flagged LOW/quick-check since it's mostly constants)
