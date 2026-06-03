# PLAN — SwiftPM build for the core `voronota` binary

Derived from `SPEC.md` (Approach A: SwiftPM drives Clang; core binary only; macOS arm64).
Status: AWAITING APPROVAL — no code changes until approved.

## Guiding constraints (from spec)
- Zero edits to any `src/**` `.cpp`/`.h`. A required source edit is a STOP-and-report finding.
- CMake stays the source of truth; SwiftPM is purely additive.
- One new file (`Package.swift`) + one `.gitignore` line. Nothing else.

## Dependency graph

```
        T1 (Package.swift + build) ─┬─► T2 (smoke)
                                    │
T3 (CMake reference build) ─────────┴─► T4 (functional parity) ─► T5 (hygiene/cleanup)
```

- T1 and T3 are independent and can run in parallel.
- T4 needs both the SwiftPM binary (T1) and the CMake reference (T3).
- Each task is a vertical slice: it ends with something runnable/verifiable.

---

## Phase 1 — The Swift build path produces a binary

### T1 — Add `Package.swift` and build the release binary
- **Do:** Create `Package.swift` at repo root: one `.executableTarget("voronota", path: "src")`,
  `cxxLanguageStandard: .cxx11`. Add `/.build/` to `.gitignore`.
- **Acceptance:**
  - `swift build -c release` exits 0.
  - `.build/release/voronota` exists.
  - `git status` shows **no** modifications under `src/` (only new `Package.swift`, edited `.gitignore`).
  - The target compiled exactly 45 translation units (verify via `swift build -v` /
    object count) — matches `voronota.cpp` + 44 modes.
- **Verify:** `swift build -c release && ls -l .build/release/voronota && git status -s src/`
- **Stop-and-report if:** the build needs any `src/**` edit, or a header isn't found
  (relative-to-file resolution failed) — capture the exact error before changing anything.

### T2 — Smoke test the Swift-built binary
- **Do:** Run the binary's help/listing path.
- **Acceptance:**
  - `.build/release/voronota --help` prints `Voronota version 1.29` and the command list,
    exits without crash.
  - Mode list is non-empty and includes known modes (`calculate-vertices`,
    `calculate-contacts`, `query-balls`, `run-script`).
- **Verify:** `.build/release/voronota --help | head -40`

### ▶ CHECKPOINT A — "It builds and runs"
Binary builds via `swift build` and responds to `--help`. Pause for confirmation
before investing in parity verification.

---

## Phase 2 — Prove behavioral parity with the CMake build

### T3 — Build the CMake reference binary (parity oracle)
- **Do:** `cmake . && make` to produce the reference `./voronota`.
- **Acceptance:** `./voronota` exists and `--help` runs. (No SwiftPM involvement.)
- **Verify:** `cmake . >/dev/null && make >/dev/null && ./voronota --help | head -5`
- **Note:** This writes CMake scaffolding (`CMakeCache.txt`, `Makefile`, …) already in
  `.gitignore`; clean up after with `git status` check in T5.

### T4 — Functional parity via the existing test harness
- **Do:** Place the SwiftPM binary where the harness expects it and run the jobs.
  - `cp .build/release/voronota ./voronota`
  - `./tests/run_all_jobs_scripts.bash`
- **Acceptance (the real bar):**
  - `git status -s ./tests/jobs_output/` is **empty** (zero altered tracked outputs) —
    identical functional output to the committed/CMake baseline. This mirrors the
    check inside `test.bash`.
- **Verify:** `git status -s ./tests/jobs_output/ | wc -l` → `0`
- **Stop-and-report if:** any output differs — diff the offending file; a real numeric/
  format difference between Clang-via-SwiftPM and Clang-via-CMake would be a genuine finding.

### ▶ CHECKPOINT B — "It's equivalent"
Parity proven against the existing test suite. Pause before cleanup/commit decisions.

---

## Phase 3 — Hygiene

### T5 — Cleanup, manifest minimization, no-regression check
- **Do:**
  - Decide whether `Package.swift` needs `headerSearchPath(".")`; remove it if the build
    is green without it (spec: settings must earn their place).
  - Confirm the CMake build still works unchanged.
  - Confirm working tree is clean except intended artifacts (`Package.swift`, `.gitignore`,
    `SPEC.md`, `tasks/`); no stray tracked files from T3.
- **Acceptance:**
  - Both `swift build -c release` and `cmake . && make` succeed.
  - `git status -s` shows only the intended new/changed files.
- **Verify:** re-run T1 + T3 verify lines; `git status -s`.

### ▶ CHECKPOINT C — "Done"
Report results. Committing/PR is a separate, explicitly-authorized step (spec boundary).

---

## Risks / unknowns
- **R1 (most likely):** SwiftPM C-family executable target with `path: "src"` may treat a
  missing `include/` public-headers dir oddly, or warn about the layout. Mitigation: rely on
  file-relative includes; add `headerSearchPath` only if needed (T5 trims it).
- **R2 (low):** A floating-point/formatting difference between toolchain invocations surfaces
  in T4. Mitigation: treat as a finding, diff, report — do not paper over by editing sources.
- **R3 (low):** SwiftPM globs an unexpected `.cpp`. Already checked: 45 `.cpp` under `src/` ==
  CMake set, so glob == intended set.

## Out of scope (re-stated)
Expansions, bash wrappers, Linux verification, Approach B/C, any commit/push/PR.
