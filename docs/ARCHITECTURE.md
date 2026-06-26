# Build system architecture

This document defines **layer boundaries** for the Sims-like build mode. It guides refactors and new code so responsibilities stay separated and the core stays testable.

## Layers

| Layer | Responsibility | Allowed dependencies | Examples |
| ----- | -------------- | -------------------- | -------- |
| **Domain** | Pure rules, value types, queries on in-memory data | Standard library / Godot value types only (`Vector2i`, `Dictionary`, etc.). No `Node`, no autoloads, no filesystem. | [`GridMath`](../domain/building/GridMath.gd), [`BuildCatalogQueries`](../domain/catalog/BuildCatalogQueries.gd), [`WallKey`](../domain/building/WallKey.gd) |
| **Application** | Use-case orchestration, stable façade over session capabilities | Domain + references to services (injected or via session). No scene tree walks, no UI nodes. | [`BuildContext`](../application/BuildContext.gd) |
| **Presentation** | Input, 3D placement UX, UI scenes | Application façade, signals, `Node`/`Node3D`. Calls into services for side effects. | `Main`, `FurniturePlacer`, `BuildModeUI` |
| **Infrastructure** | I/O, persistence, loading external data | Domain helpers + engine APIs (`FileAccess`, JSON). | [`BuildCatalogService`](../services/BuildCatalogService.gd), [`BuildPersistenceService`](../services/BuildPersistenceService.gd), [`GameDatabase`](../autoload/GameDatabase.gd) |

## Data flow (target)

```text
UI / tools (presentation)
    → intents (e.g. place furniture, undo)
    → BuildContext or coordinator (application)
    → Services + domain helpers (state changes, validation)
    → Signals / state read models back to UI
```

## Naming conventions

- `*Service` — coordinates side effects, talks to state or scene (Node).
- `*State` / `*Model` — holds data; prefer a **single writer** path (e.g. commands) where possible.
- `*Placer` / `*Painter` — presentation adapters (input + visuals).
- `GridMath`, `BuildCatalogQueries` — domain: static or `RefCounted`, **no** `App.` access.

## Session and composition root

[`GameSession`](../session/GameSession.gd) is the per-save **composition root**: it creates services and states. [`App`](../autoload/App.gd) owns the active session and may expose a narrow façade.

[`BuildContext`](../application/BuildContext.gd) is the first **strangler** API: furniture catalog resolution plus undo/redo in one place so presentation does not grow new `App.get_*` call chains for that slice.

## Catalog

Furniture definitions live in **[`data/build_catalog.json`](../data/build_catalog.json)**. [`BuildCatalogService`](../services/BuildCatalogService.gd) loads and caches via `GameDatabase`. Parsing and lookup rules live in **`BuildCatalogQueries`** so they can be unit tested without the scene tree.

## Running tests

Headless test runner (no editor UI):

```bash
godot --path . -s res://tests/run_all.gd
```

Exit code `0` means all assertions passed.

## Migration notes

- Prefer **vertical slices** (e.g. furniture + catalog + undo) behind `BuildContext` before rewriting unrelated tools.
- Avoid duplicating catalog entries in scene scripts; use `BuildCatalogService` / queries instead.
