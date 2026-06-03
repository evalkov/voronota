# Voronota — SwiftPM build handoff

> Handoff document for another agent/pipeline. Describes exactly what was added to
> let the **Swift toolchain (SwiftPM)** compile the core `voronota` binary, how to
> build it, how to consume the binary, and how to re-verify it. Self-contained.

## TL;DR

```bash
# from the repo root, with the Swift toolchain installed
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voronota"
"$BIN" --help        # prints: Voronota version 1.29  + command list
```

`swift build` invokes **Clang** (bundled in the Swift toolchain) to compile the
existing C++11 sources unchanged. The result is a native CLI binary identical in
behavior to the CMake-built one.

## What this is / is not

- **Is:** an *additive* SwiftPM build path for the **core `voronota` CLI binary only**
  (`src/voronota.cpp` + `src/modes/*.cpp`, 45 `.cpp` files, C++ standard library only,
  no external dependencies).
- **Is not:** a rewrite, a Swift-language port, or a C++/Swift interop layer. No C++
  source was modified. **CMake (`CMakeLists.txt`) remains the source of truth**; this is
  a parallel way to build the same binary.
- **Out of scope:** the expansions (`expansion_js`, `expansion_gl`, `expansion_lt`),
  the bash wrapper scripts (`voronota-cadscore`, `voronota-contacts`, …), and any
  non-core target. Those are unaffected and not built by SwiftPM.

## Changes (the entire delta)

Two files. Nothing under `src/` changed.

### 1. `Package.swift` (NEW, repo root)

```swift
// swift-tools-version:5.9
import PackageDescription

// Additive SwiftPM build for the core `voronota` CLI binary.
// SwiftPM drives Clang to compile the existing C++11 sources unchanged;
// CMakeLists.txt remains the source of truth. Scope: src/voronota.cpp + src/modes/*.cpp
// (stdlib-only, no external dependencies).
let package = Package(
    name: "voronota",
    targets: [
        .executableTarget(
            name: "voronota",
            path: "src"
        )
    ],
    cxxLanguageStandard: .cxx11
)
```

Why it is this small:
- `path: "src"` makes SwiftPM glob all `.cpp` under `src/`. That set is **exactly**
  `voronota.cpp` + the 44 `modes/*.cpp` — the same set CMake compiles
  (`file(GLOB ... src/voronota.cpp src/modes/*.cpp)`).
- No header search paths are needed: every `#include` in the modes is **file-relative**
  (e.g. `../apollota/...`, `../auxiliaries/...`, `modescommon/...`), which Clang resolves
  against each source file's own directory.
- `cxxLanguageStandard: .cxx11` matches `set(CMAKE_CXX_STANDARD 11)` in `CMakeLists.txt`.

### 2. `.gitignore` (MODIFIED, +1 line)

Added `/.build` so the SwiftPM build directory is ignored:

```diff
 /voronota
 /build
+/.build
 /tmp
```

## How to build

Prerequisites: a Swift toolchain with C++ support. Verified with **Apple Swift 6.3.2 /
Clang 21 on arm64 macOS**. SwiftPM is cross-platform, so the open-source Swift toolchain
on Linux is expected to work too, but **only macOS arm64 has been verified**.

```bash
swift build -c release                  # release (optimized) build
# or:
swift build                             # debug build
```

Locate the binary (robust, pipeline-friendly — do not hardcode the triple):

```bash
BIN="$(swift build -c release --show-bin-path)/voronota"
# On this machine that resolves to:
#   .build/arm64-apple-macosx/release/voronota
```

## How to consume in a pipeline

`voronota` is a stdin/stdout CLI. Typical core pipeline:

```bash
BIN="$(swift build -c release --show-bin-path)/voronota"

# radii resource (needed by get-balls-from-atoms-file --radii-file)
./voronota-resources radii > /tmp/radii

cat input.pdb \
  | "$BIN" get-balls-from-atoms-file --radii-file /tmp/radii --include-heteroatoms \
  > balls

cat balls | "$BIN" calculate-vertices  > vertices    # Voronoi vertices (quadruples + tangent spheres)
cat balls | "$BIN" calculate-contacts  > contacts    # inter-atom contacts
"$BIN" --help                                         # full command list
```

Run `"$BIN" --help` for all commands and `"$BIN" <command> --help` for per-command options.

## Verification (already done; reproducible)

The SwiftPM-built binary was checked **byte-for-byte against the CMake-built binary** on
the same machine (head-to-head, so the only variable is the build system — not the
platform). The two binaries differ in size (CMake 5,305,592 B vs SwiftPM 5,342,312 B) yet
produced **identical output on every tested path**:

| Path | Result |
|---|---|
| `get-balls-from-atoms-file` (annotated + plain) | identical |
| `calculate-vertices` (core Voronoi: 11,664 vertices, 15-digit FP coords) | identical to last digit |
| `calculate-vertices-in-parallel --method simulated` | identical |
| `calculate-contacts` (959 KB) | identical |
| `query-balls`, `query-contacts` | identical |
| `write-balls-to-atoms-file` (PDB) | identical |
| `expand-descriptors` | identical |
| `run-script` (scripting engine, 490 KB) | identical |

Result: **0 differing outputs.**

To re-verify from scratch:

```bash
# 1. SwiftPM binary
swift build -c release
SW="$(swift build -c release --show-bin-path)/voronota"

# 2. CMake reference binary
cmake . && make            # produces ./voronota at repo root
CM=./voronota

# 3. radii + diff a representative pipeline
./voronota-resources radii > /tmp/radii
for V in "$CM" "$SW"; do
  tag=$(basename $(dirname "$V"))   # crude label; or just run twice into two dirs
  cat tests/input/single/structure.pdb \
    | "$V" get-balls-from-atoms-file --radii-file /tmp/radii --include-heteroatoms \
    | "$V" calculate-vertices
done
# Capture each binary's output to a file and `diff` them — expect no differences.

# 4. cleanup CMake artifacts (all gitignored): 
rm -rf CMakeFiles CMakeCache.txt cmake_install.cmake Makefile ./voronota
```

## Constraints / rules for any downstream agent

- **Do not modify any file under `src/`.** If a build error seems to require a source
  edit, stop and report it — the design goal is zero source changes.
- **Do not remove or alter `CMakeLists.txt`** or the bash wrappers; SwiftPM is additive.
- Keep `Package.swift` minimal. It currently needs **no** `cxxSettings` / header search
  paths; don't add settings that don't earn their place.
- If you extend scope to the expansions, expect real external dependencies (e.g.
  `expansion_js` vendors Duktape under `expansion_js/src/dependencies`; `expansion_gl`
  needs OpenGL/GLFW) and note that the legacy `package.bash` uses `-static`, which does
  **not** link on macOS. That is a separate, larger effort.

## Provenance

- Branch: `swiftpm-build`
- Commit: `647faf07` — "Add SwiftPM build for the core voronota binary" (adds `Package.swift`,
  edits `.gitignore`; 2 files, +18 lines).
- Voronota version: `1.29` (`src/voronota_version.h`).
- Verified on: arm64 macOS, Apple Swift 6.3.2 / Clang 21.
