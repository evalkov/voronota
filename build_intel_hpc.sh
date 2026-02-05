#!/bin/bash
#
# Build script for Voronota using Intel compilers on HPC
# Produces portable static binaries that run on most modern CPUs
#
# Usage:
#   ./build_intel_hpc.sh [options]
#
# Options:
#   -m, --module VERSION    Intel compiler module version (default: 2025.2.0)
#   -a, --arch TARGET       CPU architecture target (default: portable)
#                           Options: portable, avx2, avx512, native
#   -c, --components LIST   Comma-separated list of components to build
#                           Options: all, core, lt, lt-cadscore, js (default: all)
#   -j, --jobs N            Number of parallel jobs (default: auto-detect)
#   -o, --output DIR        Output directory for binaries (default: ./bin_intel)
#   -h, --help              Show this help message
#
# Examples:
#   ./build_intel_hpc.sh                                    # Build all with defaults
#   ./build_intel_hpc.sh -m 2025.2.0 -a portable           # Explicit portable build
#   ./build_intel_hpc.sh -c core,lt                        # Build only core and LT
#   ./build_intel_hpc.sh -a avx512 -j 16                   # AVX512 with 16 cores
#   ./build_intel_hpc.sh -o /path/to/install               # Custom output directory
#
# Architecture targets:
#   portable - AVX2 baseline, works on most modern CPUs (Haswell 2013+) [RECOMMENDED]
#   avx2     - Same as portable
#   avx512   - Requires AVX512 (Skylake-X 2017+, may not work on all nodes)
#   native   - Optimized for current CPU (-xHost), NOT portable to other machines
#
# Components:
#   core       - Main voronota executable (C++11)
#   lt         - voronota-lt fast tessellation tool (C++14, OpenMP)
#   lt-cadscore - cadscore-lt CAD-score tool (C++17, OpenMP)
#   js         - voronota-js JavaScript interface engine (C++14)
#

set -e  # Exit on error

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
INTEL_VERSION="2025.2.0"
ARCH_TARGET="portable"
COMPONENTS="all"
JOBS=""
OUTPUT_DIR="${SCRIPT_DIR}/bin_intel"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
echo_section() { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

show_help() {
    head -45 "$0" | tail -44 | sed 's/^#//' | sed 's/^ //'
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--module)
            INTEL_VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH_TARGET="$2"
            shift 2
            ;;
        -c|--components)
            COMPONENTS="$2"
            shift 2
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo_error "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Auto-detect number of jobs if not specified
if [[ -z "$JOBS" ]]; then
    JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

echo_section "Voronota Intel HPC Build"
echo_info "Intel module: ${INTEL_VERSION}"
echo_info "Architecture: ${ARCH_TARGET}"
echo_info "Components: ${COMPONENTS}"
echo_info "Parallel jobs: ${JOBS}"
echo_info "Output directory: ${OUTPUT_DIR}"

# Load Intel module
echo_section "Loading Intel Compiler"
if command -v module &> /dev/null; then
    module purge 2>/dev/null || true
    if ! module load "intel/${INTEL_VERSION}" 2>/dev/null; then
        echo_error "Failed to load intel/${INTEL_VERSION}"
        echo_info "Available Intel modules on your system:"
        module avail intel 2>&1 | grep -i intel || true
        exit 1
    fi
    echo_info "Loaded intel/${INTEL_VERSION}"
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
    portable|avx2)
        ARCH_FLAG="-xCORE-AVX2"
        echo_info "Architecture target: Portable (AVX2) - compatible with Haswell (2013+)"
        ;;
    avx512)
        ARCH_FLAG="-xCORE-AVX512"
        echo_warn "Architecture target: AVX512 - requires Skylake-X (2017+) or newer"
        ;;
    native)
        ARCH_FLAG="-xHost"
        echo_warn "Architecture target: Native (-xHost) - NOT portable to other machines!"
        ;;
    *)
        echo_error "Unknown architecture target: ${ARCH_TARGET}"
        echo_info "Valid targets: portable, avx2, avx512, native"
        exit 1
        ;;
esac

# Common flags for static linking
# -static: Link all libraries statically (libstdc++, libgcc, libc)
# -static-intel: Link Intel libraries statically
# -qopenmp-link=static: Link OpenMP runtime statically
STATIC_FLAGS="-static -static-intel"
OPENMP_FLAGS="-qopenmp -qopenmp-link=static"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Parse components
if [[ "$COMPONENTS" == "all" ]]; then
    BUILD_CORE=true
    BUILD_LT=true
    BUILD_LT_CADSCORE=true
    BUILD_JS=true
else
    BUILD_CORE=false
    BUILD_LT=false
    BUILD_LT_CADSCORE=false
    BUILD_JS=false

    IFS=',' read -ra COMP_ARRAY <<< "$COMPONENTS"
    for comp in "${COMP_ARRAY[@]}"; do
        case "$comp" in
            core) BUILD_CORE=true ;;
            lt) BUILD_LT=true ;;
            lt-cadscore) BUILD_LT_CADSCORE=true ;;
            js) BUILD_JS=true ;;
            *)
                echo_error "Unknown component: $comp"
                echo_info "Valid components: core, lt, lt-cadscore, js"
                exit 1
                ;;
        esac
    done
fi

# Track build results
BUILT_COMPONENTS=()
FAILED_COMPONENTS=()

# Function to build a component
build_component() {
    local name="$1"
    local std="$2"
    local src_files="$3"
    local output="$4"
    local extra_flags="$5"
    local include_dirs="$6"

    echo_section "Building ${name}"

    local flags="-std=c++${std} -O3 ${ARCH_FLAG} ${STATIC_FLAGS} ${extra_flags}"
    local includes=""

    if [[ -n "$include_dirs" ]]; then
        IFS=':' read -ra INC_ARRAY <<< "$include_dirs"
        for inc in "${INC_ARRAY[@]}"; do
            includes="${includes} -I${inc}"
        done
    fi

    echo_info "C++ standard: C++${std}"
    echo_info "Flags: ${flags}"
    [[ -n "$includes" ]] && echo_info "Includes: ${includes}"
    echo_info "Source: ${src_files}"
    echo_info "Output: ${output}"

    # Compile
    if ${CXX_COMPILER} ${flags} ${includes} -o "${output}" ${src_files}; then
        echo_info "Build successful: ${output}"
        BUILT_COMPONENTS+=("$name")
        return 0
    else
        echo_error "Build failed: ${name}"
        FAILED_COMPONENTS+=("$name")
        return 1
    fi
}

# Build core voronota (C++11)
if [[ "$BUILD_CORE" == true ]]; then
    CORE_SRC="${SCRIPT_DIR}/src/voronota.cpp"
    CORE_MODE_SRC=$(find "${SCRIPT_DIR}/src/modes" -name "*.cpp" 2>/dev/null | tr '\n' ' ')
    CORE_OUTPUT="${OUTPUT_DIR}/voronota"

    build_component "voronota (core)" "11" "${CORE_SRC} ${CORE_MODE_SRC}" "${CORE_OUTPUT}" "" "" || true
fi

# Build voronota-lt (C++14, OpenMP)
if [[ "$BUILD_LT" == true ]]; then
    LT_SRC="${SCRIPT_DIR}/expansion_lt/src/voronota_lt.cpp"
    LT_OUTPUT="${OUTPUT_DIR}/voronota-lt"

    build_component "voronota-lt" "14" "${LT_SRC}" "${LT_OUTPUT}" "${OPENMP_FLAGS}" "" || true
fi

# Build cadscore-lt (C++17, OpenMP)
if [[ "$BUILD_LT_CADSCORE" == true ]]; then
    LT_CADSCORE_SRC="${SCRIPT_DIR}/expansion_lt_cadscore/src/cadscore_lt.cpp"
    LT_CADSCORE_OUTPUT="${OUTPUT_DIR}/cadscore-lt"
    LT_CADSCORE_INCLUDES="${SCRIPT_DIR}/expansion_lt/src"

    build_component "cadscore-lt" "17" "${LT_CADSCORE_SRC}" "${LT_CADSCORE_OUTPUT}" "${OPENMP_FLAGS}" "${LT_CADSCORE_INCLUDES}" || true
fi

# Build voronota-js (C++14)
if [[ "$BUILD_JS" == true ]]; then
    JS_SRC="${SCRIPT_DIR}/expansion_js/src/voronota_js.cpp"
    JS_OUTPUT="${OUTPUT_DIR}/voronota-js"
    JS_INCLUDES="${SCRIPT_DIR}/expansion_js/src/dependencies"

    build_component "voronota-js" "14" "${JS_SRC}" "${JS_OUTPUT}" "" "${JS_INCLUDES}" || true
fi

# Summary
echo_section "Build Summary"

if [[ ${#BUILT_COMPONENTS[@]} -gt 0 ]]; then
    echo_info "Successfully built:"
    for comp in "${BUILT_COMPONENTS[@]}"; do
        echo "  - ${comp}"
    done
fi

if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
    echo_error "Failed to build:"
    for comp in "${FAILED_COMPONENTS[@]}"; do
        echo "  - ${comp}"
    done
fi

echo ""
echo_info "Output directory: ${OUTPUT_DIR}"
ls -lh "${OUTPUT_DIR}"/ 2>/dev/null || true

# Test built binaries
echo_section "Testing Binaries"
for binary in "${OUTPUT_DIR}"/*; do
    if [[ -x "$binary" ]]; then
        name=$(basename "$binary")
        echo -n "Testing ${name}... "
        if "${binary}" --help &>/dev/null || "${binary}" --version &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}(no --help/--version)${NC}"
        fi
    fi
done

# Verify static linking
echo_section "Verifying Static Linking"
echo_info "Checking library dependencies (should show minimal dynamic libraries):"
for binary in "${OUTPUT_DIR}"/*; do
    if [[ -x "$binary" ]]; then
        name=$(basename "$binary")
        echo ""
        echo "=== ${name} ==="
        if command -v ldd &>/dev/null; then
            ldd "$binary" 2>/dev/null | grep -v "linux-vdso\|ld-linux" | head -10 || echo "(no dynamic libs or ldd failed)"
        else
            echo "(ldd not available - run on Linux to verify)"
        fi
    fi
done

# Print portability warning for native builds
if [[ "${ARCH_TARGET}" == "native" ]]; then
    echo ""
    echo_warn "=========================================="
    echo_warn "WARNING: These binaries were built with -xHost"
    echo_warn "and may NOT run on other machines!"
    echo_warn ""
    echo_warn "For portable binaries, rebuild with:"
    echo_warn "  $0 -a portable"
    echo_warn "=========================================="
fi

echo ""
echo_section "Done"
echo_info "Binaries are in: ${OUTPUT_DIR}"
echo_info "Copy this directory to any HPC node with compatible CPU architecture."

# Exit with error if any builds failed
if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
    exit 1
fi

exit 0
