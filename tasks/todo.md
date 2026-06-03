# TODO — SwiftPM build for core `voronota`

See `tasks/plan.md` for detail, `SPEC.md` for scope. Nothing is implemented yet
(plan awaiting approval).

## Phase 1 — Build path
- [x] **T1** Add `Package.swift` (executable target, `path: "src"`, C++11) + `.gitignore` `/.build`
      — DONE: `swift build -c release` exit 0, `.build/release/voronota` (5.3 MB), no `src/` edits,
      45 TUs, minimal manifest (no `headerSearchPath` needed — file-relative includes suffice).
- [x] **T2** Smoke test — DONE: `--help` prints `Voronota version 1.29` + 15 modes, no crash.
- [x] ▶ **CHECKPOINT A** — builds and runs. ⏸ Paused for confirmation (commit is "ask first" per spec).

## Phase 2 — Parity
- [x] **T3** Built CMake reference binary (`cmake . && make`) — parity oracle.
- [x] **T4** Functional parity via **head-to-head** diff (CMake-clang vs SwiftPM-clang on this
      machine — isolates the build-system variable, avoids Linux-baseline drift). All outputs
      **byte-identical**: balls, Voronoi vertices (11,664; 15-digit FP), vertices-in-parallel,
      contacts, query-balls, query-contacts, write-balls PDB, expand-descriptors, run-script
      engine (490,472 B). 0 differing outputs.
- [x] ▶ **CHECKPOINT B** — equivalence proven.

## Phase 3 — Hygiene
- [x] **T5** Manifest already minimal (no `headerSearchPath`). CMake build re-verified green.
      CMake artifacts removed; tree clean except intended files.
- [x] ▶ **CHECKPOINT C** — committing Package.swift + .gitignore on branch `swiftpm-build`.
