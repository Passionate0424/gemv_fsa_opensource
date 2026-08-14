#!/usr/bin/env python3
"""
parse_board_dump.py
解析板上dump文件 (board_dump_pos154.txt)，生成TB可用的hex文件。

输出文件（放在 tb/board_data/ 目录下）：
  - q.hex:  32个值 (4 heads × 8 dim)，每行一个32位hex
  - k.hex:  DDR布局，tile-major: tile × head × row × col
            20 tiles × 4 heads × 8 rows × 8 cols = 5120 值
            最后一个tile只有3行有效数据，其余补0
  - v.hex:  同k.hex布局
  - o_expected.hex: 32个值，板上实际输出（含Inf，用于参考）

K/V DDR布局说明：
  地址 = BASE + tile * kv_stride + (head * d*d + row_in_tile * d + col) * 4
  kv_stride = NUM_HEADS * HEAD_DIM * HEAD_DIM * 4 = 4 * 8 * 8 * 4 = 1024 bytes
  hex文件按word地址递增排列，即：
    tile0_head0_row0_col0, tile0_head0_row0_col1, ..., tile0_head0_row7_col7,
    tile0_head1_row0_col0, ..., tile19_head3_row7_col7
"""

import os
import re
import sys

# 参数
NUM_HEADS = 4
HEAD_DIM = 8
SEQ_LEN = 155
NUM_TILES = (SEQ_LEN + HEAD_DIM - 1) // HEAD_DIM  # = 20
LAST_TILE_ROWS = SEQ_LEN - (NUM_TILES - 1) * HEAD_DIM  # = 3

def parse_dump(filepath):
    """解析dump文件，返回 q_data, k_data, v_data, o_data"""
    q_data = []       # 32个hex字符串
    o_data = []       # 32个hex字符串
    # k_data[tile][head][row] = [8个hex字符串]
    k_data = {}
    v_data = {}

    with open(filepath, 'r') as f:
        lines = f.readlines()

    for line in lines:
        line = line.strip()

        # 解析 FSA_O_ALL
        if line.startswith('[FSA_O_ALL]'):
            tokens = line.split()[1:]  # 跳过tag
            o_data = tokens
            assert len(o_data) == NUM_HEADS * HEAD_DIM, \
                f"O data count mismatch: got {len(o_data)}, expected {NUM_HEADS * HEAD_DIM}"

        # 解析 FSA_Q_ALL
        elif line.startswith('[FSA_Q_ALL]'):
            tokens = line.split()[1:]
            q_data = tokens
            assert len(q_data) == NUM_HEADS * HEAD_DIM, \
                f"Q data count mismatch: got {len(q_data)}, expected {NUM_HEADS * HEAD_DIM}"

        # 解析 K 行: [K] tN hN rN: val0 val1 ... val7
        elif line.startswith('[K] t'):
            m = re.match(r'\[K\] t(\d+) h(\d+) r(\d+): (.+)', line)
            if m:
                tile = int(m.group(1))
                head = int(m.group(2))
                row = int(m.group(3))
                vals = m.group(4).split()
                assert len(vals) == HEAD_DIM, \
                    f"K row data count mismatch at t{tile} h{head} r{row}: got {len(vals)}"
                k_data[(tile, head, row)] = vals

        # 解析 V 行: [V] tN hN rN: val0 val1 ... val7
        elif line.startswith('[V] t'):
            m = re.match(r'\[V\] t(\d+) h(\d+) r(\d+): (.+)', line)
            if m:
                tile = int(m.group(1))
                head = int(m.group(2))
                row = int(m.group(3))
                vals = m.group(4).split()
                assert len(vals) == HEAD_DIM, \
                    f"V row data count mismatch at t{tile} h{head} r{row}: got {len(vals)}"
                v_data[(tile, head, row)] = vals

    # 验证数据完整性
    total_k_rows = 0
    for tile in range(NUM_TILES):
        rows_in_tile = LAST_TILE_ROWS if tile == NUM_TILES - 1 else HEAD_DIM
        for head in range(NUM_HEADS):
            for row in range(rows_in_tile):
                key = (tile, head, row)
                assert key in k_data, f"Missing K data for t{tile} h{head} r{row}"
                assert key in v_data, f"Missing V data for t{tile} h{head} r{row}"
                total_k_rows += 1

    print(f"[INFO] 解析完成: Q={len(q_data)} vals, K={total_k_rows} rows, V={total_k_rows} rows")
    print(f"[INFO] seq_len={SEQ_LEN}, num_tiles={NUM_TILES}, last_tile_rows={LAST_TILE_ROWS}")

    return q_data, k_data, v_data, o_data


def write_hex_file(filepath, values):
    """写入hex文件，每行一个32位hex值（无前缀）"""
    with open(filepath, 'w') as f:
        for v in values:
            f.write(v + '\n')
    print(f"[INFO] 写入 {filepath}: {len(values)} 个值")


def generate_kv_ddr_layout(kv_data):
    """
    将K或V数据按DDR tile-major布局展开为flat列表。
    布局: tile × head × row_in_tile × col
    最后一个tile不足8行的部分补0。
    """
    flat = []
    for tile in range(NUM_TILES):
        for head in range(NUM_HEADS):
            for row in range(HEAD_DIM):
                key = (tile, head, row)
                if key in kv_data:
                    flat.extend(kv_data[key])
                else:
                    # 最后一个tile的padding行，补0
                    flat.extend(['00000000'] * HEAD_DIM)
    return flat


def main():
    # 确定路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    dump_file = os.path.join(project_dir, 'reports', 'board_dump_pos154.txt')
    output_dir = os.path.join(project_dir, 'tb', 'board_data')

    # 支持命令行指定dump文件
    if len(sys.argv) > 1:
        dump_file = sys.argv[1]

    if not os.path.exists(dump_file):
        print(f"[ERROR] Dump文件不存在: {dump_file}")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    # 解析
    q_data, k_data, v_data, o_data = parse_dump(dump_file)

    # 生成Q hex文件
    write_hex_file(os.path.join(output_dir, 'q.hex'), q_data)

    # 生成K hex文件（DDR布局，含padding）
    k_flat = generate_kv_ddr_layout(k_data)
    write_hex_file(os.path.join(output_dir, 'k.hex'), k_flat)

    # 生成V hex文件（DDR布局，含padding）
    v_flat = generate_kv_ddr_layout(v_data)
    write_hex_file(os.path.join(output_dir, 'v.hex'), v_flat)

    # 生成期望输出（参考用）
    write_hex_file(os.path.join(output_dir, 'o_expected.hex'), o_data)

    # 打印摘要
    print(f"\n[SUMMARY]")
    print(f"  Q: {len(q_data)} values")
    print(f"  K: {len(k_flat)} values ({NUM_TILES} tiles × {NUM_HEADS} heads × {HEAD_DIM} rows × {HEAD_DIM} cols)")
    print(f"  V: {len(v_flat)} values (same layout)")
    print(f"  O_expected: {len(o_data)} values")
    print(f"  输出目录: {output_dir}")


if __name__ == '__main__':
    main()
