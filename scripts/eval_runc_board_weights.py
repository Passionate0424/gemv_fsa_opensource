#!/usr/bin/env python3
"""
eval_runc_board_weights.py - 评估 runc_board 嵌入式权重的模型输出质量

从 stories_data.h 提取原始二进制模型数据，加载并推理评估。

依赖：karpathy/llama2.c 仓库里的 model.py / tokenizer.py（PyTorch 参考实现），
用 --llama2-ref-dir 指向该仓库的路径。
"""
import argparse
import struct
import sys
import os


def _import_llama2_ref(llama2_ref_dir):
    sys.path.insert(0, llama2_ref_dir)
    global ModelArgs, Transformer, Tokenizer
    from model import ModelArgs, Transformer
    from tokenizer import Tokenizer


import torch


def parse_stories_data_h(filepath):
    """从 xxd -i 生成的 C 头文件中提取二进制数据"""
    with open(filepath, "r") as f:
        text = f.read()

    # 找到 stories_bin[] 数组的内容
    start = text.find("{")
    end = text.find("};")
    if start == -1 or end == -1:
        raise ValueError("找不到 stories_bin[] 数组")

    hex_content = text[start+1:end]
    # 解析十六进制字节
    bytes_list = []
    for token in hex_content.split(","):
        token = token.strip()
        if token.startswith("0x") or token.startswith("0X"):
            bytes_list.append(int(token, 16))
    return bytes(bytes_list)


def load_model_from_binary(binary_data, device="cpu"):
    """从原始二进制数据加载 Transformer 模型"""
    # 前 sizeof(Config) 字节是配置头
    # Config: dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len
    # 每个字段是 4 字节 int32 (little-endian)
    config_size = 7 * 4  # 28 bytes
    header = struct.unpack("<7i", binary_data[:config_size])

    dim = header[0]
    hidden_dim = header[1]
    n_layers = header[2]
    n_heads = header[3]
    n_kv_heads = header[4]
    vocab_size = header[5]
    seq_len = header[6]

    print(f"模型配置:")
    print(f"  dim={dim}, hidden_dim={hidden_dim}, n_layers={n_layers}")
    print(f"  n_heads={n_heads}, n_kv_heads={n_kv_heads}")
    print(f"  vocab_size={vocab_size}, seq_len={seq_len}")

    # vocab_size 负数表示 unshared weights
    shared_weights = vocab_size > 0
    vocab_size = abs(vocab_size)

    # 创建 ModelArgs
    gptconf = ModelArgs(
        dim=dim,
        hidden_dim=hidden_dim,
        n_layers=n_layers,
        n_heads=n_heads,
        n_kv_heads=n_kv_heads,
        vocab_size=vocab_size,
        multiple_of=4,
        max_seq_len=seq_len,
        dropout=0.0,
    )

    model = Transformer(gptconf)

    # 从二进制数据中加载权重
    # 布局: [token_embedding_table] [rms_att_weight] [wq] [wk] [wv] [wo]
    #        [rms_ffn_weight] [w1] [w2] [w3] [rms_final_weight]
    #        [freq_cis_real] [freq_cis_imag] [wcls (if unshared)]
    head_size = dim // n_heads
    kv_dim = (dim * n_kv_heads) // n_heads

    ptr = config_size  # 跳过 Config 头

    # token_embedding_table: (vocab_size, dim)
    emb_size = vocab_size * dim * 4
    token_embedding = torch.frombuffer(
        binary_data[ptr:ptr+emb_size], dtype=torch.float32
    ).view(vocab_size, dim).clone()
    ptr += emb_size

    # rms_att_weight: (n_layers, dim)
    rms_att_size = n_layers * dim * 4
    rms_att = torch.frombuffer(
        binary_data[ptr:ptr+rms_att_size], dtype=torch.float32
    ).view(n_layers, dim).clone()
    ptr += rms_att_size

    # wq: (n_layers, dim, n_heads * head_size)
    wq_size = n_layers * dim * (n_heads * head_size) * 4
    wq = torch.frombuffer(
        binary_data[ptr:ptr+wq_size], dtype=torch.float32
    ).view(n_layers, dim, n_heads * head_size).clone()
    ptr += wq_size

    # wk: (n_layers, dim, kv_dim)
    wk_size = n_layers * dim * kv_dim * 4
    wk = torch.frombuffer(
        binary_data[ptr:ptr+wk_size], dtype=torch.float32
    ).view(n_layers, dim, kv_dim).clone()
    ptr += wk_size

    # wv: (n_layers, dim, kv_dim)
    wv_size = n_layers * dim * kv_dim * 4
    wv = torch.frombuffer(
        binary_data[ptr:ptr+wv_size], dtype=torch.float32
    ).view(n_layers, dim, kv_dim).clone()
    ptr += wv_size

    # wo: (n_layers, n_heads * head_size, dim)
    wo_size = n_layers * (n_heads * head_size) * dim * 4
    wo = torch.frombuffer(
        binary_data[ptr:ptr+wo_size], dtype=torch.float32
    ).view(n_layers, n_heads * head_size, dim).clone()
    ptr += wo_size

    # rms_ffn_weight: (n_layers, dim)
    rms_ffn_size = n_layers * dim * 4
    rms_ffn = torch.frombuffer(
        binary_data[ptr:ptr+rms_ffn_size], dtype=torch.float32
    ).view(n_layers, dim).clone()
    ptr += rms_ffn_size

    # w1: (n_layers, hidden_dim, dim)
    w1_size = n_layers * hidden_dim * dim * 4
    w1 = torch.frombuffer(
        binary_data[ptr:ptr+w1_size], dtype=torch.float32
    ).view(n_layers, hidden_dim, dim).clone()
    ptr += w1_size

    # w2: (n_layers, dim, hidden_dim)
    w2_size = n_layers * dim * hidden_dim * 4
    w2 = torch.frombuffer(
        binary_data[ptr:ptr+w2_size], dtype=torch.float32
    ).view(n_layers, dim, hidden_dim).clone()
    ptr += w2_size

    # w3: (n_layers, hidden_dim, dim)
    w3_size = n_layers * hidden_dim * dim * 4
    w3 = torch.frombuffer(
        binary_data[ptr:ptr+w3_size], dtype=torch.float32
    ).view(n_layers, hidden_dim, dim).clone()
    ptr += w3_size

    # rms_final_weight: (dim,)
    rms_final = torch.frombuffer(
        binary_data[ptr:ptr+dim*4], dtype=torch.float32
    ).view(dim).clone()
    ptr += dim * 4

    # freq_cis_real: (seq_len, head_size/2)
    freq_real_size = seq_len * (head_size // 2) * 4
    ptr += freq_real_size  # skip

    # freq_cis_imag: (seq_len, head_size/2)
    freq_imag_size = seq_len * (head_size // 2) * 4
    ptr += freq_imag_size  # skip

    # wcls (if unshared)
    if not shared_weights:
        wcls_size = vocab_size * dim * 4
        wcls = torch.frombuffer(
            binary_data[ptr:ptr+wcls_size], dtype=torch.float32
        ).view(vocab_size, dim).clone()
        ptr += wcls_size
    else:
        wcls = token_embedding  # shared weights

    # 加载到模型
    state_dict = model.state_dict()
    state_dict["tok_emb.weight"] = token_embedding
    state_dict["norm.weight"] = rms_final

    for l in range(n_layers):
        state_dict[f"layers.{l}.attention_norm.weight"] = rms_att[l]
        state_dict[f"layers.{l}.attention.wq.weight"] = wq[l]
        state_dict[f"layers.{l}.attention.wk.weight"] = wk[l]
        state_dict[f"layers.{l}.attention.wv.weight"] = wv[l]
        state_dict[f"layers.{l}.attention.wo.weight"] = wo[l]
        state_dict[f"layers.{l}.ffn_norm.weight"] = rms_ffn[l]
        state_dict[f"layers.{l}.feed_forward.w1.weight"] = w1[l]
        state_dict[f"layers.{l}.feed_forward.w2.weight"] = w2[l]
        state_dict[f"layers.{l}.feed_forward.w3.weight"] = w3[l]

    state_dict["output.weight"] = wcls

    model.load_state_dict(state_dict, strict=False)
    model.eval().to(device)
    return model


@torch.no_grad()
def generate(model, tokenizer, prompt, max_new_tokens=120, temperature=0.93, top_p=0.9, top_k=40):
    """Top-p + top-k 采样生成"""
    ids = tokenizer.encode(prompt, bos=True, eos=False)
    x = torch.tensor(ids, dtype=torch.long)[None, ...]

    for _ in range(max_new_tokens):
        idx_cond = x if x.size(1) <= model.params.max_seq_len else x[:, -model.params.max_seq_len:]
        logits = model(idx_cond)
        logits = logits[:, -1, :] / max(temperature, 1e-6)
        probs = torch.nn.functional.softmax(logits, dim=-1)

        if top_k > 0:
            v, _ = torch.topk(probs, min(top_k, probs.size(-1)))
            probs = probs.masked_fill(probs < v[:, [-1]], 0.0)

        sorted_probs, sorted_idx = torch.sort(probs, dim=-1, descending=True)
        cdf = torch.cumsum(sorted_probs, dim=-1)
        cutoff = cdf > top_p
        cutoff[..., 1:] = cutoff[..., :-1].clone()
        cutoff[..., 0] = False
        sorted_probs = sorted_probs.masked_fill(cutoff, 0.0)
        sorted_probs = sorted_probs / sorted_probs.sum(dim=-1, keepdim=True).clamp(min=1e-8)
        next_sorted = torch.multinomial(sorted_probs, num_samples=1)
        next_token = torch.gather(sorted_idx, -1, next_sorted)
        x = torch.cat((x, next_token), dim=1)

    return x[0].tolist()


def distinct_stats(ids):
    if not ids:
        return {}
    unigrams = set(ids)
    bigrams = set(zip(ids, ids[1:])) if len(ids) > 1 else set()
    trigrams = set(zip(ids, ids[1:], ids[2:])) if len(ids) > 2 else set()
    max_run = 1
    cur = 1
    for i in range(1, len(ids)):
        if ids[i] == ids[i-1]:
            cur += 1
            max_run = max(max_run, cur)
        else:
            cur = 1
    bigram_total = max(0, len(ids) - 1)
    trigram_total = max(0, len(ids) - 2)
    return {
        "distinct1": len(unigrams) / max(1, len(ids)),
        "distinct2": len(bigrams) / max(1, bigram_total),
        "distinct3": len(trigrams) / max(1, trigram_total),
        "max_repeat_run": max_run,
        "repeat_trigram_ratio": 1.0 - (len(trigrams) / max(1, trigram_total)),
    }


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_stories_h = os.path.join(
        repo_root, "soc", "sdk", "software", "apps", "runc_board", "stories_data.h"
    )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--llama2-ref-dir", required=True,
        help="karpathy/llama2.c 仓库路径（提供 model.py / tokenizer.py）",
    )
    parser.add_argument(
        "--stories-h", default=default_stories_h,
        help="待评估的 stories_data.h 路径（默认：仓库内 runc_board 固件）",
    )
    parser.add_argument(
        "--tok-model", required=True,
        help="分词器模型文件路径（如 tok512.model）",
    )
    args = parser.parse_args()

    _import_llama2_ref(args.llama2_ref_dir)

    print("=== 解析 runc_board/stories_data.h ===")
    binary_data = parse_stories_data_h(args.stories_h)
    print(f"二进制大小: {len(binary_data)} bytes ({len(binary_data)/1024:.1f} KB)")

    print("\n=== 加载模型 ===")
    model = load_model_from_binary(binary_data, device="cpu")
    tokenizer = Tokenizer(tokenizer_model=args.tok_model)

    prompts = [
        "",
        "Once upon a time",
        "Lily was sad because",
        "The little boy found a",
    ]

    print("\n=== 采样评估 (temp=0.93, top_p=0.9, top_k=40, rep_penalty=1.05) ===")
    all_ids = []
    for prompt in prompts:
        ids = generate(model, tokenizer, prompt, max_new_tokens=120,
                       temperature=0.93, top_p=0.9, top_k=40)
        text = tokenizer.decode(ids)
        stats = distinct_stats(ids)
        all_ids.extend(ids)
        print(f"\nPrompt: '{prompt}'")
        print(f"  Output: {text[:300]}")
        print(f"  distinct2={stats.get('distinct2',0):.4f}, repeat_trigram={stats.get('repeat_trigram_ratio',0):.4f}, max_run={stats.get('max_repeat_run',0)}")

    overall = distinct_stats(all_ids)
    print(f"\n=== 汇总 ===")
    print(f"  distinct1={overall.get('distinct1',0):.4f}")
    print(f"  distinct2={overall.get('distinct2',0):.4f}")
    print(f"  distinct3={overall.get('distinct3',0):.4f}")
    print(f"  repeat_trigram={overall.get('repeat_trigram_ratio',0):.4f}")


if __name__ == "__main__":
    main()
