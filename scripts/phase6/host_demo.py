#!/usr/bin/env python3
# =============================================================================
# host_demo.py  —  Phase 6B host driver: talk to the FPGA over UART
# =============================================================================
#
# Loads the same A and B that gen_layer.py produced for Phase 6A, sends them
# to the FPGA over UART, fires RUN, reads C back, compares against the
# pre-computed NumPy reference. Emits PASS/FAIL.
#
# Usage:
#   python scripts/phase6/host_demo.py --port COM5
#   python scripts/phase6/host_demo.py --port /dev/ttyUSB0
#   python scripts/phase6/host_demo.py --port COM5 --baud 115200
#
# The bitstream this talks to is built by tcl/synth_top.tcl; the protocol is
# specified in docs/phase6/02_design_decisions_6B.md.
# =============================================================================

import argparse
import json
import math
import struct
import sys
import time
from pathlib import Path

import numpy as np
import serial


# Mirror gen_layer.py's helpers so the protocol-side packing matches.
PROJ_ROOT = Path(__file__).resolve().parent.parent.parent
SIM_DIR   = PROJ_ROOT / "sim" / "phase6"

# Protocol constants (must match docs/phase6/02_design_decisions_6B.md)
SYNC_HOST  = 0xA5
SYNC_FPGA  = 0x5A
OP_LOAD_A  = 0x01
OP_LOAD_B  = 0x02
OP_RUN     = 0x03
OP_READ_C  = 0x04
OP_PING    = 0x7F
RESP_ACK   = 0x00
RESP_DATA  = 0x01
RESP_DONE  = 0x02
RESP_PONG  = 0x7F


# -----------------------------------------------------------------------------
def lane_pack_bytes(values, lane_w_bits: int) -> bytes:
    """Pack S lane values into bytes, lane 0 = byte 0 = LSB-first."""
    lane_bytes = lane_w_bits // 8
    out = bytearray()
    for v in values:
        v_int = int(v) & ((1 << lane_w_bits) - 1)
        for i in range(lane_bytes):
            out.append((v_int >> (i * 8)) & 0xFF)
    return bytes(out)


def build_a_bram_bytes(A: np.ndarray, M_TILES: int, K: int, S: int) -> list[bytes]:
    """Return list of 8-byte words, one per A_BRAM address."""
    M, _ = A.shape
    words = []
    for k in range(K):
        for tile_p in range(M_TILES):
            lanes = [A[tile_p*S + i, k] if (tile_p*S + i) < M else 0
                     for i in range(S)]
            words.append(lane_pack_bytes(lanes, 8))
    return words


def build_b_bram_bytes(B: np.ndarray, N_TILES: int, K: int, S: int) -> list[bytes]:
    _, N = B.shape
    words = []
    for k in range(K):
        for tile_r in range(N_TILES):
            lanes = [B[k, tile_r*S + j] if (tile_r*S + j) < N else 0
                     for j in range(S)]
            words.append(lane_pack_bytes(lanes, 8))
    return words


def parse_c_bytes(buf: bytes, M: int, N: int, S: int, ACC_W: int) -> np.ndarray:
    """Parse the bytes returned by READ_C into an (M, N) int32 array."""
    N_TILES = (N + S - 1) // S
    bytes_per_lane = ACC_W // 8
    bytes_per_word = bytes_per_lane * S
    used = M * N_TILES
    assert len(buf) >= used * bytes_per_word, \
        f"got {len(buf)} bytes, need {used * bytes_per_word}"

    out = np.zeros((M, N), dtype=np.int64)
    for w_addr in range(used):
        row    = w_addr // N_TILES
        tile_r = w_addr %  N_TILES
        wbase  = w_addr * bytes_per_word
        for j in range(S):
            n = tile_r * S + j
            if n >= N:
                continue
            lane_bytes = buf[wbase + j*bytes_per_lane : wbase + (j+1)*bytes_per_lane]
            v = int.from_bytes(lane_bytes, "little", signed=False)
            if v >= (1 << (ACC_W - 1)):
                v -= (1 << ACC_W)
            out[row, n] = v
    return out.astype(np.int32)


# -----------------------------------------------------------------------------
class FpgaLink:
    def __init__(self, port: str, baud: int, timeout_s: float):
        self.ser = serial.Serial(port, baud, timeout=timeout_s)
        # Drain anything left in the OS buffer
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def close(self):
        self.ser.close()

    # ---- low-level ---------------------------------------------------------
    def write(self, data: bytes) -> None:
        self.ser.write(data)

    def read_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.ser.read(n - len(buf))
            if not chunk:
                raise TimeoutError(f"serial timeout — wanted {n} bytes, got {len(buf)}")
            buf.extend(chunk)
        return bytes(buf)

    # ---- protocol primitives ----------------------------------------------
    def expect(self, tag: bytes, what: str) -> None:
        got = self.read_exact(len(tag))
        if got != tag:
            raise RuntimeError(f"{what}: expected {tag.hex()} got {got.hex()}")

    def ping(self) -> None:
        self.write(bytes([SYNC_HOST, OP_PING]))
        self.expect(bytes([SYNC_FPGA, RESP_PONG]), "PING")

    def load_bram(self, opcode: int, words: list[bytes]) -> None:
        n = len(words)
        hdr = bytes([SYNC_HOST, opcode]) + struct.pack("<HH", 0, n)
        self.write(hdr)
        for w in words:
            self.write(w)
        self.expect(bytes([SYNC_FPGA, RESP_ACK, opcode]),
                    f"LOAD_{'A' if opcode==OP_LOAD_A else 'B'} ACK")

    def run(self, M: int, N: int, K: int, run_timeout_s: float = 5.0) -> None:
        self.write(bytes([SYNC_HOST, OP_RUN, M & 0xFF, N & 0xFF, K & 0xFF]))
        self.expect(bytes([SYNC_FPGA, RESP_ACK, OP_RUN]), "RUN ACK")
        # Bump the read timeout because matmul + UART round-trip can stretch
        old = self.ser.timeout
        self.ser.timeout = run_timeout_s
        try:
            self.expect(bytes([SYNC_FPGA, RESP_DONE]), "RUN DONE")
        finally:
            self.ser.timeout = old

    def read_c(self, n_words: int) -> bytes:
        self.write(bytes([SYNC_HOST, OP_READ_C]) + struct.pack("<HH", 0, n_words))
        # Header: 0x5A 0x01 [n_bytes:u16 LE]
        hdr = self.read_exact(4)
        if hdr[0] != SYNC_FPGA or hdr[1] != RESP_DATA:
            raise RuntimeError(f"READ_C bad header: {hdr.hex()}")
        n_bytes = struct.unpack("<H", hdr[2:4])[0]
        return self.read_exact(n_bytes)


# -----------------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="e.g. COM5 or /dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=2.0,
                    help="per-read serial timeout (seconds)")
    args = ap.parse_args(argv)

    # Workload metadata
    meta_path = SIM_DIR / "workload.json"
    if not meta_path.exists():
        print(f"ERROR: {meta_path} not found — run gen_layer.py first")
        return 2
    meta = json.loads(meta_path.read_text())

    M, N, K   = meta["M"], meta["N"], meta["K"]
    S         = meta["S"]
    ACC_W     = meta["ACC_W"]
    M_TILES   = meta["M_TILES"]
    N_TILES   = meta["N_TILES"]

    A     = np.load(SIM_DIR / "A.npy")
    B     = np.load(SIM_DIR / "B.npy")
    C_ref = np.load(SIM_DIR / "C_ref.npy")
    assert A.shape == (M, K), A.shape
    assert B.shape == (K, N), B.shape

    a_words = build_a_bram_bytes(A, M_TILES, K, S)
    b_words = build_b_bram_bytes(B, N_TILES, K, S)
    print(f"Workload (M, N, K) = ({M}, {N}, {K})")
    print(f"A_BRAM words = {len(a_words)}   B_BRAM words = {len(b_words)}   "
          f"C readback words = {M*N_TILES}")

    print(f"Opening {args.port} @ {args.baud} 8-N-1 …")
    link = FpgaLink(args.port, args.baud, args.timeout)
    try:
        # ---------------------------------------------------------------------
        # 0. Sanity ping
        # ---------------------------------------------------------------------
        t0 = time.time()
        link.ping()
        print(f"PING/PONG ok ({(time.time()-t0)*1000:.1f} ms)")

        # ---------------------------------------------------------------------
        # 1. Load A
        # ---------------------------------------------------------------------
        t0 = time.time()
        link.load_bram(OP_LOAD_A, a_words)
        print(f"LOAD_A ok  ({len(a_words)} words / "
              f"{len(a_words)*8} bytes / {(time.time()-t0)*1000:.1f} ms)")

        # ---------------------------------------------------------------------
        # 2. Load B
        # ---------------------------------------------------------------------
        t0 = time.time()
        link.load_bram(OP_LOAD_B, b_words)
        print(f"LOAD_B ok  ({len(b_words)} words / "
              f"{len(b_words)*8} bytes / {(time.time()-t0)*1000:.1f} ms)")

        # ---------------------------------------------------------------------
        # 3. RUN
        # ---------------------------------------------------------------------
        t0 = time.time()
        link.run(M, N, K)
        print(f"RUN ok  ({(time.time()-t0)*1000:.1f} ms incl. matmul)")

        # ---------------------------------------------------------------------
        # 4. READ_C
        # ---------------------------------------------------------------------
        t0 = time.time()
        c_bytes = link.read_c(M * N_TILES)
        print(f"READ_C ok ({len(c_bytes)} bytes / {(time.time()-t0)*1000:.1f} ms)")
    finally:
        link.close()

    # -------------------------------------------------------------------------
    # Compare
    # -------------------------------------------------------------------------
    C_dut = parse_c_bytes(c_bytes, M, N, S, ACC_W)
    diff  = (C_dut.astype(np.int64) - C_ref.astype(np.int64))

    max_abs = int(np.abs(diff).max())
    n_match = int((diff == 0).sum())
    n_total = int(C_ref.size)

    print()
    print(f"max abs err : {max_abs}")
    print(f"exact match : {n_match}/{n_total}  ({100.0*n_match/n_total:.2f}%)")

    if max_abs == 0:
        print("PASS — bit-exact match against NumPy reference")
        return 0
    else:
        print("FAIL — DUT output diverges from reference")
        # Dump first 10 mismatches for debugging
        bad = np.argwhere(diff != 0)
        for r, c in bad[:10]:
            print(f"  C[{r},{c}]  ref={C_ref[r,c]}  dut={C_dut[r,c]}  "
                  f"diff={diff[r,c]}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
