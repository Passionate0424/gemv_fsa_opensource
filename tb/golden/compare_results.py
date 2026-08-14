#!/usr/bin/env python3
"""Three-way comparison script for FlashAttention verification.

Compares outputs from:
  A: Python golden model (ideal fp64 + hardware fp32 model)
  B: Original Chisel FSA RTL (reference)
  C: Our gemv_fsa DUT

Usage:
  python compare_results.py --golden_dir ./vectors_1tile --dut_dir ./dut_output --ref_dir ./ref_output
"""

import argparse
import json
import math
import struct
import sys
from pathlib import Path
import numpy as np


# ============================================================
# Utility
# ============================================================

def hex_to_fp32(h):
    """Convert 8-char hex string to fp32."""
    return struct.unpack('<f', struct.pack('<I', int(h.strip(), 16)))[0]

def load_hex_matrix(filepath, rows, cols):
    """Load hex file into numpy matrix."""
    filepath = Path(filepath)
    if not filepath.exists():
        return None
    values = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                values.append(hex_to_fp32(line))
    arr = np.array(values, dtype=np.float32)
    if arr.size == rows * cols:
        return arr.reshape(rows, cols)
    return arr

def load_hex_vector(filepath):
    """Load hex file into numpy vector."""
    filepath = Path(filepath)
    if not filepath.exists():
        return None
    values = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                values.append(hex_to_fp32(line))
    return np.array(values, dtype=np.float32)

def ulp_diff(a, b):
    """Compute ULP difference between two fp32 values."""
    if np.isnan(a) or np.isnan(b):
        return float('inf')
    if a == b:
        return 0
    a_bits = struct.unpack('<I', struct.pack('<f', np.float32(a)))[0]
    b_bits = struct.unpack('<I', struct.pack('<f', np.float32(b)))[0]
    # 处理符号不同的情况
    if (a_bits >> 31) != (b_bits >> 31):
        return abs(int(a_bits) + int(b_bits))
    return abs(int(a_bits) - int(b_bits))

def ulp_diff_matrix(A, B):
    """Compute element-wise ULP differences."""
    A = np.asarray(A, dtype=np.float32).flat
    B = np.asarray(B, dtype=np.float32).flat
    diffs = [ulp_diff(a, b) for a, b in zip(A, B)]
    return np.array(diffs)


# ============================================================
# Comparison functions
# ============================================================

def compare_matrices(name, A, B, abs_tol=1e-3, rel_tol=1e-3, ulp_tol=2):
    """Compare two matrices with multiple criteria.

    Returns dict with comparison results.
    """
    if A is None or B is None:
        return {'name': name, 'status': 'SKIP', 'reason': 'data not available'}

    if A.shape != B.shape:
        return {'name': name, 'status': 'FAIL', 'reason': f'shape mismatch: {A.shape} vs {B.shape}'}

    A_flat = A.flatten().astype(np.float64)
    B_flat = B.flatten().astype(np.float64)

    abs_err = np.abs(A_flat - B_flat)
    max_abs = float(np.max(abs_err))
    mean_abs = float(np.mean(abs_err))

    denom = np.maximum(np.abs(A_flat), 1e-12)
    rel_err = abs_err / denom
    max_rel = float(np.max(rel_err))
    mean_rel = float(np.mean(rel_err))

    ulp_diffs = ulp_diff_matrix(A, B)
    max_ulp = int(np.max(ulp_diffs))
    mean_ulp = float(np.mean(ulp_diffs))

    # 判定
    pass_abs = max_abs <= abs_tol
    pass_rel = max_rel <= rel_tol
    pass_ulp = max_ulp <= ulp_tol

    status = 'PASS' if (pass_abs or pass_rel or pass_ulp) else 'FAIL'

    return {
        'name': name,
        'status': status,
        'max_abs_err': max_abs,
        'mean_abs_err': mean_abs,
        'max_rel_err': max_rel,
        'mean_rel_err': mean_rel,
        'max_ulp': max_ulp,
        'mean_ulp': mean_ulp,
        'pass_abs': pass_abs,
        'pass_rel': pass_rel,
        'pass_ulp': pass_ulp,
        'shape': list(A.shape),
    }


def compare_vectors(name, A, B, abs_tol=1e-3, ulp_tol=2):
    """Compare two vectors."""
    if A is None or B is None:
        return {'name': name, 'status': 'SKIP', 'reason': 'data not available'}
    return compare_matrices(name, A.reshape(1, -1), B.reshape(1, -1), abs_tol=abs_tol, ulp_tol=ulp_tol)


# ============================================================
# Three-way comparison
# ============================================================

def run_comparison(golden_dir, dut_dir=None, ref_dir=None, head_dim=8, seq_tile_len=8, num_tiles=1):
    """Run three-way comparison.

    Args:
        golden_dir: Python golden output directory
        dut_dir: gemv_fsa DUT output directory (optional)
        ref_dir: Chisel FSA reference output directory (optional)
    """
    golden_dir = Path(golden_dir)
    dut_dir = Path(dut_dir) if dut_dir else None
    ref_dir = Path(ref_dir) if ref_dir else None

    results = []
    seq_q = seq_tile_len  # Q rows = tile_size

    print("=" * 60)
    print("FlashAttention Three-Way Comparison Report")
    print("=" * 60)
    print(f"  head_dim={head_dim}, seq_tile_len={seq_tile_len}, num_tiles={num_tiles}")
    print()

    # --- Load golden data ---
    golden_ideal_O = load_hex_matrix(golden_dir / 'golden_ideal_O.hex', seq_q, head_dim)
    golden_hw_O = load_hex_matrix(golden_dir / 'golden_hw_O.hex', seq_q, head_dim)

    # --- Load DUT data (if available) ---
    dut_O = load_hex_matrix(dut_dir / 'dut_final_O.hex', seq_q, head_dim) if dut_dir else None

    # --- Load reference data (if available) ---
    ref_O = load_hex_matrix(ref_dir / 'ref_final_O.hex', seq_q, head_dim) if ref_dir else None

    # ============================================================
    # Comparison A vs C: DUT vs Ideal Golden (端到端精度)
    # ============================================================
    print("--- A(ideal) vs C(DUT): End-to-end precision ---")
    if dut_O is not None and golden_ideal_O is not None:
        r = compare_matrices('A_vs_C_final_O', golden_ideal_O, dut_O, abs_tol=1e-3, rel_tol=1e-3)
        results.append(r)
        print(f"  [{r['status']}] max_abs={r['max_abs_err']:.2e} max_rel={r['max_rel_err']:.2e}")
    else:
        print("  [SKIP] DUT output not available")

    # ============================================================
    # Comparison A(hw) vs C: DUT vs HW Golden (算法一致性)
    # ============================================================
    print("\n--- A(hw_model) vs C(DUT): Algorithm consistency ---")
    if dut_O is not None and golden_hw_O is not None:
        r = compare_matrices('Ahw_vs_C_final_O', golden_hw_O, dut_O, abs_tol=1e-6, ulp_tol=1)
        results.append(r)
        print(f"  [{r['status']}] max_abs={r['max_abs_err']:.2e} max_ulp={r['max_ulp']}")
    else:
        print("  [SKIP] DUT output not available")

    # ============================================================
    # Comparison B vs C: DUT vs Chisel FSA (数据流等价性)
    # ============================================================
    print("\n--- B(Chisel) vs C(DUT): Dataflow equivalence ---")
    if dut_O is not None and ref_O is not None:
        r = compare_matrices('B_vs_C_final_O', ref_O, dut_O, abs_tol=1e-5, ulp_tol=2)
        results.append(r)
        print(f"  [{r['status']}] max_abs={r['max_abs_err']:.2e} max_ulp={r['max_ulp']}")
    else:
        print("  [SKIP] Reference output not available")

    # ============================================================
    # Comparison A vs B: Chisel FSA vs Ideal (原版精度baseline)
    # ============================================================
    print("\n--- A(ideal) vs B(Chisel): Reference precision baseline ---")
    if ref_O is not None and golden_ideal_O is not None:
        r = compare_matrices('A_vs_B_final_O', golden_ideal_O, ref_O, abs_tol=1e-3, rel_tol=1e-3)
        results.append(r)
        print(f"  [{r['status']}] max_abs={r['max_abs_err']:.2e} max_rel={r['max_rel_err']:.2e}")
    else:
        print("  [SKIP] Reference output not available")

    # ============================================================
    # Per-tile intermediate comparison (golden hw vs DUT)
    # ============================================================
    print("\n--- Per-tile intermediate comparison ---")
    for t in range(num_tiles):
        golden_scores = load_hex_matrix(golden_dir / f'golden_qk_scores_tile{t}.hex', seq_q, seq_tile_len)
        golden_P = load_hex_matrix(golden_dir / f'golden_P_tile{t}.hex', seq_q, seq_tile_len)
        golden_PV = load_hex_matrix(golden_dir / f'golden_pv_tile{t}.hex', seq_q, head_dim)

        # DUT per-tile data (if available)
        dut_scores = load_hex_matrix(dut_dir / f'dut_qk_scores_tile{t}.hex', seq_q, seq_tile_len) if dut_dir else None
        dut_P = load_hex_matrix(dut_dir / f'dut_P_tile{t}.hex', seq_q, seq_tile_len) if dut_dir else None
        dut_PV = load_hex_matrix(dut_dir / f'dut_pv_tile{t}.hex', seq_q, head_dim) if dut_dir else None

        print(f"\n  Tile {t}:")
        if dut_scores is not None:
            r = compare_matrices(f'tile{t}_qk_scores', golden_scores, dut_scores, ulp_tol=1)
            results.append(r)
            print(f"    QK scores: [{r['status']}] max_ulp={r.get('max_ulp','N/A')}")
        if dut_P is not None:
            r = compare_matrices(f'tile{t}_P', golden_P, dut_P, ulp_tol=2)
            results.append(r)
            print(f"    Softmax P:  [{r['status']}] max_ulp={r.get('max_ulp','N/A')}")
        if dut_PV is not None:
            r = compare_matrices(f'tile{t}_PV', golden_PV, dut_PV, ulp_tol=2)
            results.append(r)
            print(f"    PV output:  [{r['status']}] max_ulp={r.get('max_ulp','N/A')}")

        if dut_scores is None and dut_P is None:
            print(f"    [SKIP] DUT tile data not available")

    # ============================================================
    # Summary
    # ============================================================
    print("\n" + "=" * 60)
    total = len(results)
    passed = sum(1 for r in results if r['status'] == 'PASS')
    failed = sum(1 for r in results if r['status'] == 'FAIL')
    skipped = sum(1 for r in results if r['status'] == 'SKIP')

    print(f"SUMMARY: {passed}/{total} PASS, {failed} FAIL, {skipped} SKIP")

    if failed > 0:
        print("\nFailed comparisons:")
        for r in results:
            if r['status'] == 'FAIL':
                print(f"  - {r['name']}: max_abs={r.get('max_abs_err','?'):.2e} max_ulp={r.get('max_ulp','?')}")

    print("=" * 60)

    # Save detailed report
    report_path = golden_dir / 'comparison_report.json'
    with open(report_path, 'w') as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nDetailed report saved to: {report_path}")

    return failed == 0


# ============================================================
# Main
# ============================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Three-way FlashAttention comparison')
    parser.add_argument('--golden_dir', type=str, required=True, help='Python golden output dir')
    parser.add_argument('--dut_dir', type=str, default=None, help='gemv_fsa DUT output dir')
    parser.add_argument('--ref_dir', type=str, default=None, help='Chisel FSA reference output dir')
    parser.add_argument('--head_dim', type=int, default=8)
    parser.add_argument('--seq_tile_len', type=int, default=8)
    parser.add_argument('--num_tiles', type=int, default=1)
    args = parser.parse_args()

    success = run_comparison(
        golden_dir=args.golden_dir,
        dut_dir=args.dut_dir,
        ref_dir=args.ref_dir,
        head_dim=args.head_dim,
        seq_tile_len=args.seq_tile_len,
        num_tiles=args.num_tiles,
    )

    sys.exit(0 if success else 1)
