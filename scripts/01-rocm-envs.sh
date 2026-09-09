#!/usr/bin/env bash
# Detect and export ROCm toolchain paths from the _rocm_sdk_core package

# Enable AOTriton for torch
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1

# Ensure ROCm uses recent PRs for hipblaslt performance improvement on gfx1151/gfx1101
# Refs: ROCm/rocm-libraries#3913, ROCm/rocm-libraries#3879
export TORCH_BLAS_PREFER_HIPBLASLT=1

# MIOpen ships no tuning data for gfx1151 -- share/miopen/db covers
# gfx908/90a/942/950 only, verified in both the per-arch
# _rocm_sdk_libraries_gfx1151 wheel (7.14.0a20260608) and the multi-arch
# rocm-sdk-device-gfx1151 wheel (10.1.0a20260822). With no
# system find-db, MIOpen's default (exhaustive) search benchmarks every
# candidate solver against the real tensor on each unseen conv config,
# including ConvDirectNaiveConv. On MiniMax-H3's 3D convs that solver measures
# ~5.6 s where the GEMM solver it then picks takes 0.55 ms, so a first run
# stalls for tens of minutes before the sampler ever starts.
# FAST skips the search and uses heuristics: cold cost drops from 57-116 s to
# ~1 s per new shape, warm throughput is within ~4%.
export MIOPEN_FIND_MODE=2
