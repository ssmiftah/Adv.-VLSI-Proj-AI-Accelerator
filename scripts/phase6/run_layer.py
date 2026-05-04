#!/usr/bin/env python3
# =============================================================================
# run_layer.py  —  Phase 6A driver: build + run + compare across MULT variants
# =============================================================================
#
# For each multiplier variant:
#   1. (Re)build a Verilator binary of tb_layer with the variant's parameters.
#      Builds happen inside WSL (verilator is a WSL-side install).
#   2. Run the binary (also under WSL); the TB writes sim/phase6/c_dut.memh.
#   3. Move c_dut.memh to sim/phase6/c_<TAG>.memh.
#
# After all variants are run, compare each c_<TAG>.memh against C_ref.npy
# (the NumPy golden produced by gen_layer.py) and emit a summary table.
#
# Usage (from project root, in PowerShell):
#   .venv/Scripts/python.exe scripts/phase6/run_layer.py
#   .venv/Scripts/python.exe scripts/phase6/run_layer.py --rebuild
#   .venv/Scripts/python.exe scripts/phase6/run_layer.py --only DSP,BAM_B2
# =============================================================================

import argparse
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np


# -----------------------------------------------------------------------------
# Project layout
# -----------------------------------------------------------------------------
PROJ_ROOT = Path(__file__).resolve().parent.parent.parent
SIM_DIR   = PROJ_ROOT / "sim" / "phase6"
OBJ_ROOT  = PROJ_ROOT / "obj_dir"

RTL_FILES = [
    "rtl/multiplier/mult_dsp.sv",
    "rtl/multiplier/mult_lut.sv",
    "rtl/multiplier/mult_truncated.sv",
    "rtl/multiplier/mult_mitchell.sv",
    "rtl/multiplier/mult_bam.sv",
    "rtl/pe_int8.sv",
    "rtl/skew_buffer.sv",
    "rtl/systolic_array.sv",
    "rtl/bram_2p.sv",
    "rtl/tile_controller.sv",
    "rtl/accelerator_top.sv",
    "tb/tb_layer.sv",
]

# Variants under test: (tag, MULT_TYPE, TRUNC_L, BAM_B)
VARIANTS = [
    ("DSP",      "DSP",      0, 0),
    ("BAM_B2",   "BAM",      0, 2),
    ("TRUNC_L2", "TRUNC",    2, 0),
    ("TRUNC_L4", "TRUNC",    4, 0),
    ("MITCHELL", "MITCHELL", 0, 0),
]


# -----------------------------------------------------------------------------
def to_wsl_path(p: Path) -> str:
    """D:\\foo\\bar -> /mnt/d/foo/bar"""
    s = str(p.resolve())
    drive = s[0].lower()
    rest  = s[2:].replace("\\", "/")
    return f"/mnt/{drive}{rest}"


def run_wsl(cmd: str) -> int:
    """Run `bash -c <cmd>` inside WSL; stream output. Return exit code."""
    full = ["wsl", "bash", "-lc", cmd]
    result = subprocess.run(full)
    return result.returncode


# -----------------------------------------------------------------------------
def build_variant(tag: str, mtype: str, trunc_l: int, bam_b: int,
                  wsl_root: str, force: bool) -> bool:
    """Build the Verilator binary for one variant. Returns True on success."""
    mdir_win = OBJ_ROOT / f"tb_layer_{tag}"
    binary   = mdir_win / "Vtb_layer"

    if binary.exists() and not force:
        print(f"[{tag}] binary exists, skipping build (use --rebuild to force)")
        return True

    print(f"[{tag}] building …  MULT_TYPE={mtype}  TRUNC_L={trunc_l}  BAM_B={bam_b}")
    files_str = " ".join(RTL_FILES)
    verilator_cmd = (
        f"cd {wsl_root} && "
        f"verilator --binary --top-module tb_layer "
        f"-GMULT_TYPE='\"{mtype}\"' -GMULT_TRUNC_L={trunc_l} -GMULT_BAM_B={bam_b} "
        f"-Irtl -Irtl/multiplier "
        f"--Mdir obj_dir/tb_layer_{tag} "
        f"-O2 "
        f"-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-INITIALDLY "
        f"{files_str}"
    )
    rc = run_wsl(verilator_cmd)
    if rc != 0:
        print(f"[{tag}] BUILD FAILED (rc={rc})")
        return False
    return True


def run_variant(tag: str, wsl_root: str) -> bool:
    """Run the variant's binary; rename c_dut.memh -> c_<tag>.memh."""
    print(f"[{tag}] running …")
    cmd = f"cd {wsl_root} && ./obj_dir/tb_layer_{tag}/Vtb_layer"
    rc = run_wsl(cmd)
    if rc != 0:
        print(f"[{tag}] RUN FAILED (rc={rc})")
        return False

    src = SIM_DIR / "c_dut.memh"
    dst = SIM_DIR / f"c_{tag}.memh"
    if not src.exists():
        print(f"[{tag}] expected output {src} not found")
        return False
    shutil.move(str(src), str(dst))
    print(f"[{tag}] -> {dst.name}")
    return True


# -----------------------------------------------------------------------------
def parse_c_memh(path: Path, M: int, N: int, S: int, ACC_W: int) -> np.ndarray:
    """Parse c_<tag>.memh into an (M, N) int32 array."""
    N_TILES = (N + S - 1) // S
    used    = M * N_TILES
    mask    = (1 << ACC_W) - 1
    sign    = 1 << (ACC_W - 1)

    out = np.zeros((M, N), dtype=np.int64)
    with path.open() as f:
        for addr in range(used):
            line = f.readline()
            w = int(line.strip(), 16)
            row    = addr // N_TILES
            tile_r = addr %  N_TILES
            for j in range(S):
                v = (w >> (j * ACC_W)) & mask
                if v >= sign:
                    v -= (1 << ACC_W)
                n = tile_r * S + j
                if n < N:
                    out[row, n] = v
    return out.astype(np.int32)


# -----------------------------------------------------------------------------
def compute_metrics(C_ref: np.ndarray, C_dut: np.ndarray) -> dict:
    diff = C_dut.astype(np.int64) - C_ref.astype(np.int64)
    sq_err = (diff ** 2).sum()
    sq_sig = (C_ref.astype(np.int64) ** 2).sum()
    if sq_err == 0:
        sqnr_db = math.inf
    else:
        sqnr_db = 10.0 * math.log10(sq_sig / sq_err)

    return {
        "max_abs_err":  int(np.abs(diff).max()),
        "mse":          float((diff ** 2).mean()),
        "sqnr_db":      sqnr_db,
        "exact_pct":    100.0 * float((diff == 0).mean()),
        "n_outputs":    int(C_ref.size),
    }


# -----------------------------------------------------------------------------
def emit_results(results: dict, out_csv: Path, out_md: Path) -> None:
    # CSV
    with out_csv.open("w", newline="\n") as f:
        f.write("variant,max_abs_err,mse,sqnr_db,exact_pct,n_outputs\n")
        for tag, m in results.items():
            sqnr = "inf" if math.isinf(m["sqnr_db"]) else f"{m['sqnr_db']:.2f}"
            f.write(f"{tag},{m['max_abs_err']},{m['mse']:.4f},{sqnr},"
                    f"{m['exact_pct']:.2f},{m['n_outputs']}\n")

    # Markdown
    with out_md.open("w", newline="\n") as f:
        f.write("# Phase 6A — Layer-level results\n\n")
        f.write("Workload: 3x3 conv, C_in=4, C_out=16, H=W=8, pad=1 -> "
                "matmul (M, N, K) = (64, 16, 36).\n")
        f.write("All metrics computed against the DSP variant's NumPy golden "
                "(`C_ref.npy`).\n\n")
        f.write("| Variant   | max abs err | MSE         | SQNR (dB)  | "
                "Exact % | N outputs |\n")
        f.write("|-----------|------------:|------------:|-----------:|"
                "--------:|----------:|\n")
        for tag, m in results.items():
            sqnr = " inf " if math.isinf(m["sqnr_db"]) else f"{m['sqnr_db']:7.2f}"
            f.write(f"| {tag:<9} | {m['max_abs_err']:>11d} | "
                    f"{m['mse']:>11.4f} | {sqnr} | "
                    f"{m['exact_pct']:>6.2f}% | {m['n_outputs']:>9d} |\n")

    print(f"\nWrote {out_csv}")
    print(f"Wrote {out_md}")


# -----------------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--rebuild", action="store_true",
                    help="force rebuild even if binary exists")
    ap.add_argument("--only", default="",
                    help="comma-separated tags to run (default: all)")
    ap.add_argument("--skip-build", action="store_true",
                    help="don't (re)build, only run + compare")
    ap.add_argument("--skip-run", action="store_true",
                    help="don't run, only compare existing c_<tag>.memh")
    args = ap.parse_args(argv)

    wsl_root = to_wsl_path(PROJ_ROOT)

    # Pick variants
    if args.only:
        wanted = set(s.strip() for s in args.only.split(",") if s.strip())
        variants = [v for v in VARIANTS if v[0] in wanted]
        if not variants:
            print(f"no variants match --only={args.only}; "
                  f"choices: {[v[0] for v in VARIANTS]}")
            return 2
    else:
        variants = VARIANTS

    print(f"Project root  : {PROJ_ROOT}")
    print(f"WSL root      : {wsl_root}")
    print(f"Variants      : {[v[0] for v in variants]}")
    print()

    # Sanity: workload metadata + ref
    meta_path = SIM_DIR / "workload.json"
    if not meta_path.exists():
        print(f"ERROR: {meta_path} not found — run gen_layer.py first")
        return 2
    meta = json.loads(meta_path.read_text())
    M, N, K, S, ACC_W = meta["M"], meta["N"], meta["K"], meta["S"], meta["ACC_W"]
    C_ref = np.load(SIM_DIR / "C_ref.npy")
    assert C_ref.shape == (M, N)

    # Build + run
    if not args.skip_run:
        for tag, mtype, trunc_l, bam_b in variants:
            if not args.skip_build:
                if not build_variant(tag, mtype, trunc_l, bam_b,
                                     wsl_root, args.rebuild):
                    return 1
            if not run_variant(tag, wsl_root):
                return 1

    # Compare
    print()
    print("=" * 78)
    print("Comparing against NumPy golden (DSP-equivalent reference)…")
    print("=" * 78)
    results = {}
    for tag, *_ in variants:
        memh = SIM_DIR / f"c_{tag}.memh"
        if not memh.exists():
            print(f"[{tag}] {memh} missing — did the run fail?")
            continue
        C_dut = parse_c_memh(memh, M, N, S, ACC_W)
        m = compute_metrics(C_ref, C_dut)
        results[tag] = m
        sqnr = "inf" if math.isinf(m["sqnr_db"]) else f"{m['sqnr_db']:.2f}"
        print(f"  {tag:<10s}  max_abs_err={m['max_abs_err']:>7d}  "
              f"MSE={m['mse']:>12.4f}  SQNR={sqnr:>8s} dB  "
              f"exact={m['exact_pct']:>6.2f}%")

    if not results:
        return 1

    emit_results(results,
                 SIM_DIR / "results_6A.csv",
                 SIM_DIR / "results_6A.md")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
