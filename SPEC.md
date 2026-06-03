# SPEC — Build the core `voronota` binary with the Swift toolchain (SwiftPM)

Status: DRAFT (awaiting approval)
Date: 2026-06-03
Owner: Eugene Valkov

## 1. Objective

Make the core `voronota` command-line binary buildable with the **Swift toolchain**
via a `Package.swift` manifest, where **SwiftPM drives Clang** to compile the
existing C++ sources unchanged.

This is **Approach A** ("compile with the Swift toolchain"), explicitly chosen over:
- **B** — a Swift `main.swift` over a C++ core via C++ interop (more glue, deferred).
- **C** — porting ~70k LOC of C++ to native Swift (rejected: months of effort, no gain,
  diverges from upstream).

The produced binary must be **behaviorally identical** to the one CMake produces.
SwiftPM is a *second, additive* build path — CMake remains the source of truth.

### Target users
- Developers on macOS who want `swift build` / `swift run` ergonomics and SwiftPM
  tooling instead of (or alongside) CMake.

### Non-goals
- No source rewrite, no Swift application code, no C++ interop layer.
- No change to CMake, the bash wrappers, or any existing build script.
- Expansions (`expansion_js`, `expansion_gl`, `expansion_lt`) are **out of scope**.
- Cross-platform/Linux verification is **out of scope** for this iteration
  (macOS arm64 only). The manifest should not gratuitously block Linux, but Linux
  is not a verified deliverable here.

## 2. Scope (confirmed)

- **In:** the monolithic core binary only — `src/voronota.cpp` + `src/modes/*.cpp`
  (45 `.cpp` total) plus the header-only code under `src/{apollota,auxiliaries,common,scripting}`.
- **Dependencies:** C++ standard library only. No external libraries. No Boost.
- **Platform:** macOS arm64, Apple Swift 6.3.2 / Clang 21 (already installed).
- **C++ standard:** C++11 (matches `CMakeLists.txt`).

## 3. Key facts that make this clean

- All `modes/*.cpp` includes are **file-relative** (`../apollota/...`,
  `../auxiliaries/...`, `modescommon/...`), so Clang resolves them relative to each
  source file with no special search-path configuration.
- The 45 `.cpp` files under `src/` are **exactly** the CMake target set
  (`voronota.cpp` + 44 modes). A single SwiftPM target with `path: "src"` globs the
  identical set — no per-file enumeration, no accidental inclusion.
- `main(int, const char**)` in `src/voronota.cpp` is a normal C++ entry point;
  exceptions and `std::pointer_to_unary_function` mode dispatch stay entirely within
  C++ (never cross any Swift boundary).

## 4. Commands

| Command | Purpose |
|---|---|
| `swift build -c release` | Compile the core binary via Clang under SwiftPM. |
| `swift run -c release voronota --help` | Run the built binary (lists modes). |
| `swift build && swift build -c release` | Debug + release sanity. |
| `cmake . && make` | Unchanged reference build (parity oracle). |

Build artifact: `.build/release/voronota`.

## 5. Project structure (delta)

```
voronota/
├── Package.swift          # NEW — SwiftPM manifest, one C++ executable target
├── CMakeLists.txt         # UNCHANGED — remains source of truth
├── SPEC.md                # this file
├── src/                   # UNCHANGED sources
│   ├── voronota.cpp       #   → globbed as the executable target's main
│   ├── modes/*.cpp        #   → globbed
│   └── {apollota,auxiliaries,common,scripting}/*.h
└── .build/                # NEW (gitignored) — SwiftPM output
```

Proposed `Package.swift` (illustrative, to be finalized in implementation):

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "voronota",
    targets: [
        .executableTarget(
            name: "voronota",
            path: "src",
            cxxSettings: [
                .headerSearchPath(".")   // -I src; relative-to-file already covers includes
            ]
        )
    ],
    cxxLanguageStandard: .cxx11
)
```

Open implementation question to resolve during build, not now:
- Whether `.headerSearchPath(".")` is needed at all (relative-to-file may suffice).
  Keep only if it earns its place.

## 6. Code style

- **Do not modify any `.cpp`/`.h` under `src/`.** If SwiftPM cannot build without a
  source change, STOP and surface it — that is a finding, not a license to edit.
- `Package.swift` follows standard SwiftPM manifest conventions; minimal, no clever
  abstractions, no unused settings.

## 7. Testing strategy (acceptance criteria)

The binary is accepted only when **all** hold:

1. **Builds:** `swift build -c release` exits 0 with no source modifications.
2. **Same source set:** the target compiles exactly 45 translation units
   (`voronota.cpp` + 44 modes) — verified from build output / source globbing.
3. **Smoke:** `.build/release/voronota --help` prints the version and the mode list
   without crashing.
4. **Parity vs CMake (the real bar):**
   - Build the reference binary: `cmake . && make` → `./voronota`.
   - Copy the SwiftPM binary over the expected path:
     `cp .build/release/voronota ./voronota`.
   - Run the existing harness: `./tests/run_all_jobs_scripts.bash`.
   - **Pass = zero altered tracked files** under `tests/jobs_output/`
     (`git status -s ./tests/jobs_output/` is empty), matching what `test.bash`
     checks. This proves byte-identical functional output to the CMake build.
5. **No regression to existing builds:** CMake build still works unchanged.

## 8. Boundaries

**Always:**
- Keep CMake as the source of truth; SwiftPM is purely additive.
- Keep all C++ sources byte-for-byte unchanged.
- Add `.build/` to `.gitignore`.

**Ask first:**
- Any change to a file under `src/`.
- Adding a `Package.swift` that pulls in dependencies or extra targets.
- Expanding scope to wrappers, expansions, or Linux verification.
- Committing/pushing or opening a PR.

**Never:**
- Rewrite C++ in Swift, or add a C++ interop/Swift-code layer (that's Approach B/C,
  out of scope for this spec).
- Modify, replace, or delete `CMakeLists.txt` or the bash wrapper scripts.
- Touch the expansions.

## 9. Effort estimate

~30–60 minutes. The dominant risk is a SwiftPM layout/manifest detail (e.g.,
public-headers handling for a C-family executable target), not the C++ itself.
