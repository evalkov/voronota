#!/bin/bash
#
# Build script for Voronota using Intel compilers on HPC
#
# Usage:
#   ./build_intel.sh [module_version] [arch_target]
#
# Arguments:
#   module_version  - Intel compiler module version (default: 2025.2.0)
#   arch_target     - CPU architecture target (default: native)
#                     Options: native, avx2, avx512
#
# Examples:
#   ./build_intel.sh                          # Max performance for current CPU
#   ./build_intel.sh 2025.2.0 native          # Same as above
#   ./build_intel.sh 2025.2.0 avx2            # Portable (Haswell 2013+)
#   ./build_intel.sh 2025.2.0 avx512          # Requires Skylake-X 2017+
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/voronota"

INTEL_VERSION="${1:-2025.2.0}"
ARCH_TARGET="${2:-native}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load Intel module
echo_info "Loading Intel compiler module: intel/${INTEL_VERSION}"
if command -v module &> /dev/null; then
    module purge 2>/dev/null || true
    if ! module load "intel/${INTEL_VERSION}" 2>/dev/null; then
        echo_error "Failed to load intel/${INTEL_VERSION}"
        echo_info "Available Intel modules:"
        module avail intel 2>&1 | grep -i intel || true
        exit 1
    fi
else
    echo_warn "Module command not found. Assuming Intel compiler is already in PATH."
fi

# Detect compiler
if command -v icpx &> /dev/null; then
    CXX="icpx"
    echo_info "Using OneAPI compiler: icpx"
elif command -v icpc &> /dev/null; then
    CXX="icpc"
    echo_info "Using classic Intel compiler: icpc"
else
    echo_error "No Intel C++ compiler found (icpx or icpc)"
    exit 1
fi

${CXX} --version | head -1

# Architecture flags
case "${ARCH_TARGET}" in
    native)
        ARCH_FLAG="-xHost"
        echo_warn "Architecture: Native (-xHost) - optimized for THIS CPU only"
        ;;
    avx2)
        ARCH_FLAG="-xCORE-AVX2"
        echo_info "Architecture: AVX2 - portable to most modern CPUs"
        ;;
    avx512)
        ARCH_FLAG="-xCORE-AVX512"
        echo_warn "Architecture: AVX512 - requires Skylake-X or newer"
        ;;
    *)
        echo_error "Unknown architecture: ${ARCH_TARGET}"
        echo_info "Valid options: native, avx2, avx512"
        exit 1
        ;;
esac

# Compiler flags for max performance
CXX_FLAGS="-std=c++11 -O3 ${ARCH_FLAG} -qopenmp -qopenmp-link=static -ipo -fp-model fast=2"

echo_info "Compiler flags: ${CXX_FLAGS}"
echo_info "Compiling..."

${CXX} ${CXX_FLAGS} -o "${OUTPUT}" $(find "${SCRIPT_DIR}/src/" -name '*.cpp')

if [[ -f "${OUTPUT}" ]]; then
    echo_info "Build successful: ${OUTPUT}"
    ls -lh "${OUTPUT}"
else
    echo_error "Build failed"
    exit 1
fi

# Test
echo_info "Testing..."
if "${OUTPUT}" --help > /dev/null 2>&1; then
    echo_info "Build verified!"
else
    echo_warn "Could not verify (--help failed)"
fi

if [[ "${ARCH_TARGET}" == "native" ]]; then
    echo ""
    echo_warn "Binary optimized for this CPU - may not run on different nodes."
    echo_warn "For portable build: $0 ${INTEL_VERSION} avx2"
fi
