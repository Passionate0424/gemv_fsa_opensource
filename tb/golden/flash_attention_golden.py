#!/usr/bin/env python3
"""FlashAttention Golden Model for three-way comparison verification.

Two-layer precision model:
  Layer 1: Ideal fp64 reference (absolute truth)
  Layer 2: Hardware behavior model (fp32 + PWL exp2 + online softmax)

Outputs hex files for RTL testbench consumption.

Usage:
  python flash_attention_golden.py --head_dim 8 --seq_len 8 --num_tiles 1 --out_dir ./vectors
"""

import argparse
import math
import struct
import numpy as np
from pathlib import Path


# ============================================================
# fp32 utility functions
# ============================================================

def to_fp32(x):
    """Round to fp32 precision."""
    return np.float32(x)

def fp32_hex(val):
    """Convert fp32 value to 8-char hex string."""
    return format(struct.unpack('<I', struct.pack('<f', np.float32(val)))[0], '08x')

def hex_to_fp32(h):
    """Convert 8-char hex string to fp32 value."""
    return struct.unpack('<f', struct.pack('<I', int(h, 16)))[0]

def fp32_matmul(A, B):
    """Matrix multiply in fp32 precision (element-wise accumulation)."""
    A = np.array(A, dtype=np.float32)
    B = np.array(B, dtype=np.float32)
    return (A @ B).astype(np.float32)


# ============================================================
# PWL exp2 approximation (matches RTL 8-segment implementation)
# ============================================================

# 8-segment PWL coefficients for exp2(x), x in [-8, 0]
# Extracted from original FSA project (easyfloat pow2_pwl, ew=8, mw=23)
EXP2_SLOPES = np.array([
    0.36203092,  # 0x3EB95C1E
    0.39479753,  # 0x3ECA22E7
    0.43052977,  # 0x3EDC6E66
    0.46949604,  # 0x3EF061C9
    0.51198906,  # 0x3F0311B7
    0.55832803,  # 0x3F0EEE96
    0.60886103,  # 0x3F1BDE51
    0.66396767,  # 0x3F29F9C9
], dtype=np.float32)

EXP2_INTERCEPTS = np.array([
    0.86203092,  # 0x3F5CAE0F
    0.89070171,  # 0x3F640507
    0.91750085,  # 0x3F6AE156
    0.94185477,  # 0x3F711D65
    0.96310133,  # 0x3F768DCF
    0.98047841,  # 0x3F7B00A2
    0.99311167,  # 0x3F7E3C91
    1.00000000,  # 0x3F800000
], dtype=np.float32)


def pwl_exp2_scalar(x):
    """8-segment PWL exp2 approximation for a single value.
    Matches RTL behavior: segment determined by floor(-x), clamped to [0,7].
    Only the matching segment writes back (exp2Done logic).
    """
    x = np.float32(x)
    if x >= 0:
        return np.float32(1.0)
    seg = int(np.clip(np.floor(-x), 0, 7))
    # MAC: reg * slope + intercept, only matching segment updates reg
    result = np.float32(x * EXP2_SLOPES[seg] + EXP2_INTERCEPTS[seg])
    return result


def pwl_exp2(x):
    """Vectorized PWL exp2."""
    x = np.asarray(x, dtype=np.float32)
    result = np.zeros_like(x, dtype=np.float32)
    for idx in np.ndindex(x.shape):
        result[idx] = pwl_exp2_scalar(x[idx])
    return result


# ============================================================
# Constants (matching RTL)
# ============================================================

def compute_attention_scale(head_dim):
    """AttentionScale = log2(e) / sqrt(head_dim)"""
    return np.float32(math.log2(math.e) / math.sqrt(head_dim))


# ============================================================
# Layer 1: Ideal fp64 reference
# ============================================================

def flash_attention_ideal(Q, K, V, head_dim):
    """Standard attention in fp64 precision.

    Args:
        Q: [seq_q, head_dim] query matrix
        K: [seq_kv, head_dim] key matrix
        V: [seq_kv, head_dim] value matrix
        head_dim: dimension for scaling

    Returns:
        O: [seq_q, head_dim] output
        intermediates: dict of intermediate values for comparison
    """
    Q = np.array(Q, dtype=np.float64)
    K = np.array(K, dtype=np.float64)
    V = np.array(V, dtype=np.float64)

    scale = 1.0 / math.sqrt(head_dim)

    # S = Q @ K^T
    S = Q @ K.T  # [seq_q, seq_kv]

    # Scaled scores
    S_scaled = S * scale

    # Softmax
    m = np.max(S_scaled, axis=-1, keepdims=True)
    P = np.exp(S_scaled - m)
    l = np.sum(P, axis=-1, keepdims=True)
    P_norm = P / l

    # Output
    O = P_norm @ V

    intermediates = {
        'scores': S,
        'scores_scaled': S_scaled,
        'rowmax': m,
        'P_unnorm': P,
        'rowsum': l,
        'P_norm': P_norm,
    }

    return O, intermediates


# ============================================================
# Layer 2: Hardware behavior model (online softmax, tiled)
# ============================================================

def flash_attention_hw_model(Q, K, V, head_dim, tile_size):
    """Hardware-accurate FlashAttention with online softmax.

    Simulates the exact RTL dataflow:
    - Tiled K/V processing
    - fp32 precision throughout
    - PWL exp2 approximation
    - Online softmax with cross-tile correction

    Args:
        Q: [seq_q, head_dim]
        K: [seq_kv, head_dim]
        V: [seq_kv, head_dim]
        head_dim: int
        tile_size: int (seq_tile_len)

    Returns:
        O: [seq_q, head_dim] final output
        trace: dict of per-tile intermediate values
    """
    Q = np.array(Q, dtype=np.float32)
    K = np.array(K, dtype=np.float32)
    V = np.array(V, dtype=np.float32)

    seq_q = Q.shape[0]
    seq_kv = K.shape[0]
    num_tiles = (seq_kv + tile_size - 1) // tile_size

    attention_scale = compute_attention_scale(head_dim)

    # Accumulator state (per query position)
    O_acc = np.zeros((seq_q, head_dim), dtype=np.float32)
    l_acc = np.zeros(seq_q, dtype=np.float32)
    m_acc = np.full(seq_q, -np.inf, dtype=np.float32)

    trace = {
        'tiles': [],
        'attention_scale': float(attention_scale),
    }

    for tile_idx in range(num_tiles):
        tile_start = tile_idx * tile_size
        tile_end = min(tile_start + tile_size, seq_kv)
        actual_tile_len = tile_end - tile_start

        K_tile = K[tile_start:tile_end]  # [tile_len, head_dim]
        V_tile = V[tile_start:tile_end]

        tile_trace = {}

        # === QK MAC (flow_up) ===
        # S = Q @ K_tile^T, computed as sum of Q[k]*K[j][k] over k
        S = fp32_matmul(Q, K_tile.T)  # [seq_q, tile_len]
        tile_trace['qk_scores'] = S.copy()

        # === SCORE_RESTREAM + CMP UPDATE ===
        # CMP tracks rowmax across scores
        new_m = np.max(S, axis=-1).astype(np.float32)
        # Update running max
        new_m = np.maximum(m_acc, new_m)
        tile_trace['newMax'] = new_m.copy()

        # === LOAD_REG_UI: PE.reg ← score ===
        # (scores are loaded into PE registers)

        # === SUBTRACT: S - newMax ===
        # CMP PROP_MAX outputs -newMax
        S_minus_m = np.zeros_like(S, dtype=np.float32)
        for i in range(seq_q):
            S_minus_m[i] = np.float32(S[i] - new_m[i])
        tile_trace['S_minus_m'] = S_minus_m.copy()

        # === SCALE: (S-m) * AttentionScale ===
        S_scaled = np.zeros_like(S_minus_m, dtype=np.float32)
        for i in range(seq_q):
            for j in range(actual_tile_len):
                S_scaled[i, j] = np.float32(S_minus_m[i, j] * attention_scale)
        tile_trace['S_scaled'] = S_scaled.copy()

        # === EXP2: P = exp2(S_scaled) ===
        P = pwl_exp2(S_scaled)
        tile_trace['P'] = P.copy()

        # === ROWSUM: sum(P) ===
        new_exp_sum = np.sum(P, axis=-1).astype(np.float32)
        tile_trace['exp_sum'] = new_exp_sum.copy()

        # === delta_m and cross-tile correction ===
        # delta_m = oldMax - newMax (from CMP PROP_MAX_DIFF)
        delta_m = np.float32(m_acc - new_m)
        tile_trace['delta_m'] = delta_m.copy()

        # === PV MAC (flow_down) ===
        # new_PV = P @ V_tile
        new_PV = fp32_matmul(P, V_tile)  # [seq_q, head_dim]
        tile_trace['PV'] = new_PV.copy()

        # === ACC_CORRECT ===
        if tile_idx == 0:
            # First tile: bypass correction, scale=1
            scale = np.ones(seq_q, dtype=np.float32)
            O_acc = new_PV
            l_acc = new_exp_sum
        else:
            # EXP_S1: delta_m * log2e
            log2e = np.float32(math.log2(math.e))
            scale_exp = np.float32(delta_m * log2e)
            # EXP_S2: exp2(scale_exp)
            scale = np.array([pwl_exp2_scalar(s) for s in scale_exp], dtype=np.float32)
            tile_trace['correction_scale'] = scale.copy()

            # ACC_SA: new_O = scale * old_O + new_PV
            for i in range(seq_q):
                O_acc[i] = np.float32(scale[i] * O_acc[i] + new_PV[i])
                l_acc[i] = np.float32(scale[i] * l_acc[i] + new_exp_sum[i])

        m_acc = new_m
        tile_trace['O_acc'] = O_acc.copy()
        tile_trace['l_acc'] = l_acc.copy()
        trace['tiles'].append(tile_trace)

    # === RECIPROCAL + NORM ===
    # O_final = O_acc / l_acc
    O_final = np.zeros_like(O_acc, dtype=np.float32)
    for i in range(seq_q):
        inv_l = np.float32(1.0 / l_acc[i])
        O_final[i] = np.float32(O_acc[i] * inv_l)

    trace['O_final'] = O_final.copy()
    trace['l_final'] = l_acc.copy()

    return O_final, trace


# ============================================================
# Hex file export
# ============================================================

def export_matrix_hex(matrix, filepath):
    """Export a matrix to hex file (one value per line)."""
    matrix = np.asarray(matrix, dtype=np.float32)
    with open(filepath, 'w') as f:
        for val in matrix.flat:
            f.write(fp32_hex(val) + '\n')


def export_vector_hex(vector, filepath):
    """Export a vector to hex file."""
    vector = np.asarray(vector, dtype=np.float32)
    with open(filepath, 'w') as f:
        for val in vector.flat:
            f.write(fp32_hex(val) + '\n')


def generate_test_vectors(head_dim, seq_len, num_tiles, out_dir, seed=42):
    """Generate complete test vector set for three-way comparison.

    Outputs:
        input_Q.hex, input_K.hex, input_V.hex - input matrices
        golden_ideal_O.hex - fp64 ideal output
        golden_hw_O.hex - hardware model output
        golden_qk_scores_tile{N}.hex - per-tile QK scores
        golden_P_tile{N}.hex - per-tile softmax P
        golden_pv_tile{N}.hex - per-tile PV result
        golden_final_O.hex - final normalized output
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    np.random.seed(seed)
    tile_size = seq_len // num_tiles if num_tiles > 1 else seq_len

    # 生成随机输入（小范围避免溢出）
    Q = np.random.randn(tile_size, head_dim).astype(np.float32) * 0.5
    K = np.random.randn(seq_len, head_dim).astype(np.float32) * 0.5
    V = np.random.randn(seq_len, head_dim).astype(np.float32) * 0.5

    # 导出输入
    export_matrix_hex(Q, out_dir / 'input_Q.hex')
    export_matrix_hex(K, out_dir / 'input_K.hex')
    export_matrix_hex(V, out_dir / 'input_V.hex')

    # Layer 1: Ideal reference
    O_ideal, ideal_inter = flash_attention_ideal(Q, K, V, head_dim)
    export_matrix_hex(O_ideal.astype(np.float32), out_dir / 'golden_ideal_O.hex')

    # Layer 2: Hardware model
    O_hw, hw_trace = flash_attention_hw_model(Q, K, V, head_dim, tile_size)
    export_matrix_hex(O_hw, out_dir / 'golden_hw_O.hex')

    # Per-tile intermediates
    for t_idx, tile in enumerate(hw_trace['tiles']):
        export_matrix_hex(tile['qk_scores'], out_dir / f'golden_qk_scores_tile{t_idx}.hex')
        export_matrix_hex(tile['P'], out_dir / f'golden_P_tile{t_idx}.hex')
        export_matrix_hex(tile['PV'], out_dir / f'golden_pv_tile{t_idx}.hex')
        export_vector_hex(tile['newMax'], out_dir / f'golden_newMax_tile{t_idx}.hex')
        export_vector_hex(tile['exp_sum'], out_dir / f'golden_expsum_tile{t_idx}.hex')
        if 'delta_m' in tile:
            export_vector_hex(tile['delta_m'], out_dir / f'golden_delta_m_tile{t_idx}.hex')
        if 'correction_scale' in tile:
            export_vector_hex(tile['correction_scale'], out_dir / f'golden_scale_tile{t_idx}.hex')

    export_matrix_hex(O_hw, out_dir / 'golden_final_O.hex')

    # 精度报告
    max_err = np.max(np.abs(O_hw.astype(np.float64) - O_ideal))
    rel_err = np.max(np.abs((O_hw.astype(np.float64) - O_ideal) /
                            np.maximum(np.abs(O_ideal), 1e-12)))

    report = {
        'head_dim': head_dim,
        'seq_len': seq_len,
        'num_tiles': num_tiles,
        'tile_size': tile_size,
        'attention_scale': float(hw_trace['attention_scale']),
        'max_abs_error': float(max_err),
        'max_rel_error': float(rel_err),
        'ideal_O_sample': O_ideal[0, :4].tolist(),
        'hw_O_sample': O_hw[0, :4].tolist(),
    }

    import json
    with open(out_dir / 'golden_report.json', 'w') as f:
        json.dump(report, f, indent=2)

    print(f"Generated test vectors in {out_dir}")
    print(f"  Q: [{Q.shape[0]}×{Q.shape[1]}], K: [{K.shape[0]}×{K.shape[1]}], V: [{V.shape[0]}×{V.shape[1]}]")
    print(f"  Tiles: {num_tiles}, tile_size: {tile_size}")
    print(f"  AttentionScale: {hw_trace['attention_scale']:.6f}")
    print(f"  Max abs error (hw vs ideal): {max_err:.2e}")
    print(f"  Max rel error (hw vs ideal): {rel_err:.2e}")

    return Q, K, V, O_ideal, O_hw, hw_trace


# ============================================================
# Main
# ============================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='FlashAttention Golden Model')
    parser.add_argument('--head_dim', type=int, default=8)
    parser.add_argument('--seq_len', type=int, default=8)
    parser.add_argument('--num_tiles', type=int, default=1)
    parser.add_argument('--out_dir', type=str, default='./vectors')
    parser.add_argument('--seed', type=int, default=42)
    args = parser.parse_args()

    generate_test_vectors(
        head_dim=args.head_dim,
        seq_len=args.seq_len,
        num_tiles=args.num_tiles,
        out_dir=args.out_dir,
        seed=args.seed
    )
