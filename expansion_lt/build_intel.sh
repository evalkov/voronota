#!/bin/bash
#
# Build script for Voronota-LT using Intel compilers on HPC
#
# Usage:
#   ./build_intel.sh [module_version] [build_method] [arch_target]
#
# Arguments:
#   module_version  - Intel compiler module version (default: 2023.1.0)
#   build_method    - 'direct' or 'cmake' (default: direct)
#   arch_target     - CPU architecture target (default: multi)
#                     Options: multi, portable, avx2, avx512, native
#
# Examples:
#   ./build_intel.sh                              # Multi-arch dispatch (recommended for mixed clusters)
#   ./build_intel.sh 2023.1.0 direct multi       # Same as above
#   ./build_intel.sh 2023.1.0 direct portable    # Explicit portable build (AVX2)
#   ./build_intel.sh 2023.1.0 direct native      # Optimized for current CPU (not portable!)
#   ./build_intel.sh 2023.1.0 direct avx512      # Requires AVX512 support
#   ./build_intel.sh 2025.2.0 cmake avx2         # CMake build with AVX2
#
# Architecture targets:
#   multi    - Multi-dispatch: Skylake-AVX512 baseline + Cascade Lake + Ice Lake paths
#   portable - AVX2 baseline, works on most modern CPUs (Haswell 2013+)
#   avx2     - Same as portable
#   avx512   - Requires AVX512 (Skylake-X 2017+, may not work on all nodes)
#   native   - Optimized for current CPU (-xHost), NOT portable to other machines
#

set -e  # Exit on error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="${SCRIPT_DIR}/src/voronota_lt.cpp"
OUTPUT="${SCRIPT_DIR}/voronota-lt"
BUILD_DIR="${SCRIPT_DIR}/build_intel"

# Default values
INTEL_VERSION="${1:-2023.1.0}"
BUILD_METHOD="${2:-direct}"
ARCH_TARGET="${3:-multi}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load Intel module
echo_info "Loading Intel compiler module: intel/${INTEL_VERSION}"
if command -v module &> /dev/null; then
    module purge 2>/dev/null || true
    if ! module load "intel/${INTEL_VERSION}" 2>/dev/null; then
        echo_error "Failed to load intel/${INTEL_VERSION}"
        echo_info "Available Intel modules on your system:"
        module avail intel 2>&1 | grep -i intel || true
        exit 1
    fi
else
    echo_warn "Module command not found. Assuming Intel compiler is already in PATH."
fi

# Detect compiler (prefer icpx for newer versions, fall back to icpc)
detect_compiler() {
    if command -v icpx &> /dev/null; then
        CXX_COMPILER="icpx"
        CC_COMPILER="icx"
        COMPILER_TYPE="oneapi"
        echo_info "Using OneAPI compiler: icpx"
    elif command -v icpc &> /dev/null; then
        CXX_COMPILER="icpc"
        CC_COMPILER="icc"
        COMPILER_TYPE="classic"
        echo_info "Using classic Intel compiler: icpc"
    else
        echo_error "No Intel C++ compiler found (icpx or icpc)"
        exit 1
    fi
}

detect_compiler

# Show compiler version
echo_info "Compiler version:"
${CXX_COMPILER} --version | head -1

# Set architecture flags based on target
case "${ARCH_TARGET}" in
    multi)
        # Multi-dispatch: runtime selects best path for Skylake/Cascade Lake/Ice Lake
        ARCH_FLAG="-axICELAKE-SERVER,CASCADELAKE -xSKYLAKE-AVX512"
        echo_info "Architecture: Multi-dispatch (Skylake-AVX512 baseline + Cascade Lake + Ice Lake paths)"
        ;;
    portable|avx2)
        # AVX2: Works on Haswell (2013) and newer - widely compatible
        ARCH_FLAG="-xCORE-AVX2"
        echo_info "Architecture: Portable (AVX2) - compatible with most modern CPUs"
        ;;
    avx512)
        # AVX512: Requires Skylake-X (2017) or newer
        ARCH_FLAG="-xCORE-AVX512"
        echo_warn "Architecture: AVX512 - requires Skylake-X or newer CPUs"
        ;;
    native)
        # Native: Optimized for current CPU, NOT portable
        ARCH_FLAG="-xHost"
        echo_warn "Architecture: Native (-xHost) - optimized for THIS CPU only, NOT portable!"
        ;;
    *)
        echo_error "Unknown architecture target: ${ARCH_TARGET}"
        echo_info "Valid targets: multi, portable, avx2, avx512, native"
        exit 1
        ;;
esac

# Compilation flags
# Using -qopenmp-link=static to avoid runtime dependency on libiomp5.so
# -ipo: interprocedural optimization across translation units
# -fp-model fast=2: aggressive floating-point optimizations
CXX_FLAGS="-std=c++14 -O3 ${ARCH_FLAG} -qopenmp -qopenmp-link=static -ipo -fp-model fast=2"

echo_info "Compilation flags: ${CXX_FLAGS}"

# Build based on method
case "${BUILD_METHOD}" in
    direct)
        echo_info "Building with direct compilation..."

        if [[ ! -f "${SRC_FILE}" ]]; then
            echo_error "Source file not found: ${SRC_FILE}"
            exit 1
        fi

        echo_info "Compiling ${SRC_FILE}..."
        ${CXX_COMPILER} ${CXX_FLAGS} -o "${OUTPUT}" "${SRC_FILE}"

        if [[ -f "${OUTPUT}" ]]; then
            echo_info "Build successful!"
            echo_info "Output: ${OUTPUT}"
        else
            echo_error "Build failed - output not created"
            exit 1
        fi
        ;;

    cmake)
        echo_info "Building with CMake..."

        # Check for CMake
        if ! command -v cmake &> /dev/null; then
            echo_error "CMake not found. Try: module load cmake"
            exit 1
        fi

        # Create and enter build directory
        rm -rf "${BUILD_DIR}"
        mkdir -p "${BUILD_DIR}"
        cd "${BUILD_DIR}"

        # Set compiler environment for CMake
        export CC="${CC_COMPILER}"
        export CXX="${CXX_COMPILER}"

        # Configure with CMake
        echo_info "Running CMake..."
        cmake -DCMAKE_CXX_FLAGS="${CXX_FLAGS}" "${SCRIPT_DIR}"

        # Build
        echo_info "Running make..."
        make -j$(nproc 2>/dev/null || echo 4)

        # Copy output
        if [[ -f "${BUILD_DIR}/voronota-lt" ]]; then
            cp "${BUILD_DIR}/voronota-lt" "${OUTPUT}"
            echo_info "Build successful!"
            echo_info "Output: ${OUTPUT}"
        else
            echo_error "Build failed - output not created"
            exit 1
        fi

        cd "${SCRIPT_DIR}"
        ;;

    *)
        echo_error "Unknown build method: ${BUILD_METHOD}"
        echo_info "Valid methods: direct, cmake"
        exit 1
        ;;
esac

# Test the build
echo_info "Testing build..."
if "${OUTPUT}" --version 2>/dev/null; then
    echo_info "Build verification successful!"
else
    echo_warn "Could not verify build (--version flag may not be supported)"
fi

echo ""
echo_info "Done! You can now use: ${OUTPUT}"
echo_info "Example: ${OUTPUT} --help"

# Print portability warning for native builds
if [[ "${ARCH_TARGET}" == "native" ]]; then
    echo ""
    echo_warn "WARNING: This binary was built with -xHost and may not run on other machines."
    echo_warn "For multi-arch build: $0 ${INTEL_VERSION} ${BUILD_METHOD} multi"
fi
