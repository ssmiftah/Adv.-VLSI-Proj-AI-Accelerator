#!/usr/bin/env python3
# =============================================================================
# gen_layer.py  —  Phase 6A workload generator
# =============================================================================
#
# Generates a single 3x3 conv layer (C_in=4, C_out=16, H=W=8, padding=1),
# lowers it to a matmul via im2col, and emits .memh files in the BRAM layout
# expected by accelerator_top / tile_controller.
#
# Outputs (in sim/phase6/):
#   a.memh            A_BRAM contents (S*DATA_W = 64-bit words)
#   b.memh            B_BRAM contents (64-bit words)
#   c_golden.memh     C_BRAM golden  (S*ACC_W = 256-bit words)
#   workload.json     M, N, K and a small metadata block for the TB / Python
#                     comparator
#
# Layout (matches tile_controller.sv:31-37):
#   A_BRAM[k * M_TILES + tile_p]  lane i = A[tile_p*S + i][k]
#   B_BRAM[k * N_TILES + tile_r]  lane j = B[k][tile_r*S + j]
#   C_BRAM[row * N_TILES + tile_r] lane j = C[row][tile_r*S + j]
#
# Lane 0 is the LSBs of the packed word; lane S-1 is the MSBs.
#
# Usage:
#   python scripts/phase6/gen_layer.py [--seed N]
# =============================================================================

import argparse
import json
import sys
from pathlib import Path

import numpy as np


# -----------------------------------------------------------------------------
# Architectural constants — must match accelerator_top.sv defaults
# -----------------------------------------------------------------------------
S       = 8
DATA_W  = 8       # INT8 inputs
ACC_W   = 32      # INT32 accumulators
MAX_M   = 64
MAX_N   = 64
MAX_K   = 64

# Workload (3x3 conv: C_in=4, C_out=16, H=W=8, pad=1)
C_IN    = 4
C_OUT   = 16
H       = 8
W       = 8
KH = KW = 3
PAD     = 1

# Derived matmul dimensions (set after im2col below; asserted against MAX_*)
# M = H_out * W_out, K = C_in*KH*KW, N = C_out


# -----------------------------------------------------------------------------
def im2col(x: np.ndarray, kh: int, kw: int, pad: int) -> np.ndarray:
    """
    x: (C_in, H, W) int8
    returns A: (H_out * W_out, C_in * kh * kw) int8

    Row-major over output positions (oh, ow). Column-major within a patch is
    (c, ki, kj) with c outermost so that one row of A is one full conv input
    patch.
    """
    c_in, h, w = x.shape
    h_out = h + 2 * pad - kh + 1
    w_out = w + 2 * pad - kw + 1

    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)), mode="constant")

    A = np.empty((h_out * w_out, c_in * kh * kw), dtype=np.int8)
    for oh in range(h_out):
        for ow in range(w_out):
            patch = xp[:, oh:oh + kh, ow:ow + kw]   # (c_in, kh, kw)
            A[oh * w_out + ow, :] = patch.reshape(-1)
    return A


# -----------------------------------------------------------------------------
def lane_pack(values: np.ndarray, lane_w: int) -> int:
    """
    Pack S lane values into one big-bit-vector word.
    values[i] occupies bits [(i+1)*lane_w-1 : i*lane_w].
    Negative values are masked into two's complement form first.
    """
    mask = (1 << lane_w) - 1
    word = 0
    for i, v in enumerate(values):
        word |= (int(v) & mask) << (i * lane_w)
    return word


# -----------------------------------------------------------------------------
def write_memh(path: Path, words: list[int], width_bits: int, depth: int) -> None:
    """
    Write a memh file with `depth` lines. Each line is `width_bits/4` hex chars
    (no 0x prefix). Entries past len(words) are zeros — matches BRAM init.
    """
    hex_chars = width_bits // 4
    with path.open("w", newline="\n") as f:
        for addr in range(depth):
            w = words[addr] if addr < len(words) else 0
            f.write(f"{w:0{hex_chars}x}\n")


# -----------------------------------------------------------------------------
def build_a_bram(A: np.ndarray, M: int, K: int) -> list[int]:
    """
    A: (M, K) int8
    Returns a list indexed by A_BRAM address.
    addr = k * M_TILES + tile_p,  lane i = A[tile_p*S + i][k]
    """
    assert M % S == 0 or M < MAX_M, "edge-M tiles need zero-padded A rows"
    M_TILES = (M + S - 1) // S

    depth = (MAX_M * MAX_K) // S
    words = [0] * depth

    for k in range(K):
        for tile_p in range(M_TILES):
            lanes = np.zeros(S, dtype=np.int16)   # int16 to hold signed before mask
            for i in range(S):
                m = tile_p * S + i
                lanes[i] = A[m, k] if m < M else 0
            addr = k * M_TILES + tile_p
            words[addr] = lane_pack(lanes, DATA_W)
    return words


def build_b_bram(B: np.ndarray, N: int, K: int) -> list[int]:
    """
    B: (K, N) int8
    addr = k * N_TILES + tile_r,  lane j = B[k][tile_r*S + j]
    """
    N_TILES = (N + S - 1) // S

    depth = (MAX_K * MAX_N) // S
    words = [0] * depth

    for k in range(K):
        for tile_r in range(N_TILES):
            lanes = np.zeros(S, dtype=np.int16)
            for j in range(S):
                n = tile_r * S + j
                lanes[j] = B[k, n] if n < N else 0
            addr = k * N_TILES + tile_r
            words[addr] = lane_pack(lanes, DATA_W)
    return words


def build_c_bram(C: np.ndarray, M: int, N: int) -> list[int]:
    """
    C: (M, N) int32
    addr = row * N_TILES + tile_r,  lane j = C[row][tile_r*S + j]
    """
    N_TILES = (N + S - 1) // S

    depth = (MAX_M * MAX_N) // S
    words = [0] * depth

    for row in range(M):
        for tile_r in range(N_TILES):
            lanes = np.zeros(S, dtype=np.int64)   # int64 to hold ACC_W
            for j in range(S):
                n = tile_r * S + j
                lanes[j] = int(C[row, n]) if n < N else 0
            addr = row * N_TILES + tile_r
            words[addr] = lane_pack(lanes, ACC_W)
    return words


# -----------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out-dir", default="sim/phase6")
    args = ap.parse_args(argv)

    rng = np.random.default_rng(args.seed)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # -------------------------------------------------------------------------
    # 1) Generate INT8 input + weights
    # -------------------------------------------------------------------------
    x = rng.integers(-128, 128, size=(C_IN, H, W),       dtype=np.int8)
    Wt = rng.integers(-128, 128, size=(C_OUT, C_IN, KH, KW), dtype=np.int8)

    # -------------------------------------------------------------------------
    # 2) im2col -> A, weight-flatten -> B, golden matmul -> C
    # -------------------------------------------------------------------------
    A = im2col(x, KH, KW, PAD)                      # (M, K)
    # B is (K, N) where rows are (c, ki, kj) flattened — same order im2col uses
    B = Wt.reshape(C_OUT, C_IN * KH * KW).T.copy()   # (K, N)

    M, K = A.shape
    K2, N = B.shape
    assert K == K2

    # Reference matmul in INT32 (matches the accelerator's accumulator width)
    C_ref = (A.astype(np.int32) @ B.astype(np.int32))

    # Saturate to ACC_W just in case (won't fire for these magnitudes, but be
    # safe for the comparison contract)
    acc_max = (1 << (ACC_W - 1)) - 1
    acc_min = -(1 << (ACC_W - 1))
    if C_ref.max() > acc_max or C_ref.min() < acc_min:
        print(f"WARN: C overflows INT{ACC_W}: range [{C_ref.min()}, {C_ref.max()}]",
              file=sys.stderr)

    print(f"Workload: conv {C_IN}x{C_OUT}, {H}x{W}, k={KH}x{KW}, pad={PAD}")
    print(f"  M = H*W           = {M}")
    print(f"  N = C_out         = {N}")
    print(f"  K = C_in*KH*KW    = {K}")
    assert M <= MAX_M and N <= MAX_N and K <= MAX_K, \
        "workload exceeds MAX_*; would need host-side tiling (not in scope)"

    # -------------------------------------------------------------------------
    # 3) Pack into BRAM layouts and emit
    # -------------------------------------------------------------------------
    a_words = build_a_bram(A, M, K)
    b_words = build_b_bram(B, N, K)
    c_words = build_c_bram(C_ref, M, N)

    write_memh(out / "a.memh",        a_words, S * DATA_W, (MAX_M * MAX_K) // S)
    write_memh(out / "b.memh",        b_words, S * DATA_W, (MAX_K * MAX_N) // S)
    write_memh(out / "c_golden.memh", c_words, S * ACC_W,  (MAX_M * MAX_N) // S)

    # Also save raw A, B, C as .npy for the Python comparator
    np.save(out / "A.npy", A)
    np.save(out / "B.npy", B)
    np.save(out / "C_ref.npy", C_ref)

    meta = {
        "M": int(M), "N": int(N), "K": int(K),
        "S": S, "DATA_W": DATA_W, "ACC_W": ACC_W,
        "MAX_M": MAX_M, "MAX_N": MAX_N, "MAX_K": MAX_K,
        "M_TILES": (M + S - 1) // S,
        "N_TILES": (N + S - 1) // S,
        "K_BLOCKS": (K + S - 1) // S,
        "seed": args.seed,
        "layer": {
            "type": "conv2d",
            "C_in": C_IN, "C_out": C_OUT,
            "H": H, "W": W,
            "kH": KH, "kW": KW, "pad": PAD,
        },
        "files": {
            "a_memh": "a.memh",
            "b_memh": "b.memh",
            "c_golden_memh": "c_golden.memh",
            "A_npy": "A.npy",
            "B_npy": "B.npy",
            "C_ref_npy": "C_ref.npy",
        },
        "c_used_addrs": int(M * ((N + S - 1) // S)),
    }
    (out / "workload.json").write_text(json.dumps(meta, indent=2))

    print(f"Wrote {out / 'a.memh'}        ({(MAX_M*MAX_K)//S} lines, {S*DATA_W//4} hex/line)")
    print(f"Wrote {out / 'b.memh'}        ({(MAX_K*MAX_N)//S} lines, {S*DATA_W//4} hex/line)")
    print(f"Wrote {out / 'c_golden.memh'} ({(MAX_M*MAX_N)//S} lines, {S*ACC_W//4} hex/line)")
    print(f"Wrote {out / 'workload.json'}")
    print(f"C range: [{C_ref.min()}, {C_ref.max()}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
