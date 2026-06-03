// swift-tools-version:5.9
import PackageDescription

// Additive SwiftPM build for the core `voronota` CLI binary.
// SwiftPM drives Clang to compile the existing C++11 sources unchanged;
// CMakeLists.txt remains the source of truth. Scope: src/voronota.cpp + src/modes/*.cpp
// (stdlib-only, no external dependencies). See SPEC.md.
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
