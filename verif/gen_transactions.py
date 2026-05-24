import argparse
import random
from typing import List, Optional, Tuple


def gen_trace(*, ops: int, addr_space_words: int, read_pct: int) -> List[Tuple[int, str, int, Optional[int]]]:
    """
    Returns a trace list of tuples: (core, op, addr, value)
      - core: 0 or 1
      - op: "R" or "W"
      - addr: byte address
      - value: int for writes, None for reads
    """
    if not (0 <= read_pct <= 100):
        raise ValueError("read_pct must be 0..100")
    if addr_space_words <= 0:
        raise ValueError("addr_space_words must be > 0")

    trace: List[Tuple[int, str, int, Optional[int]]] = []
    for i in range(ops):
        core = random.randint(0, 1)
        addr = random.randrange(addr_space_words) * 4
        if random.randrange(100) < read_pct:
            trace.append((core, "R", addr, None))
        else:
            trace.append((core, "W", addr, random.randint(0, 2**31 - 1)))
    return trace


def write_tv(trace: List[Tuple[int, str, int, Optional[int]]], path: str) -> None:
    """
    Simple "transaction vector" format for optional SystemVerilog consumption:
      core op addr value
    For reads, value is '-'.
    """
    with open(path, "w", encoding="utf-8") as f:
        for core, op, addr, value in trace:
            if op == "R":
                f.write(f"{core} R 0x{addr:08x} -\n")
            else:
                f.write(f"{core} W 0x{addr:08x} 0x{value:08x}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate randomized coherence transaction traces.")
    ap.add_argument("--out", default="results/transactions.tv", help="Output .tv path (default: results/transactions.tv)")
    ap.add_argument("--ops", type=int, default=2000, help="Number of operations to generate")
    ap.add_argument("--addr-words", type=int, default=256, help="Address space in 32-bit words")
    ap.add_argument("--read-pct", type=int, default=50, help="Percent reads (0..100)")
    ap.add_argument("--seed", type=int, default=None, help="Random seed")
    args = ap.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    trace = gen_trace(ops=args.ops, addr_space_words=args.addr_words, read_pct=args.read_pct)
    write_tv(trace, args.out)
    print(f"Wrote {len(trace)} transactions to {args.out}")


if __name__ == "__main__":
    main()

