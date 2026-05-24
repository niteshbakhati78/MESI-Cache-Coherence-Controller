import argparse
import json
import os
from typing import Any, Dict, List


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate plots from verif results metrics.json.")
    ap.add_argument("--input", default="results/metrics.json", help="Path to metrics.json (default: results/metrics.json)")
    ap.add_argument("--output", default="results/plots", help="Output directory for plots (default: results/plots)")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        metrics: List[Dict[str, Any]] = json.load(f)

    os.makedirs(args.output, exist_ok=True)

    import matplotlib.pyplot as plt  # type: ignore

    names = [m["name"] for m in metrics]
    bus_util = [float(m["bus_utilization"]) for m in metrics]
    rdx = [int(m.get("bus_counts", {}).get("BUS_RDX", 0)) for m in metrics]

    plt.figure(figsize=(8, 4))
    plt.bar(names, bus_util)
    plt.ylabel("Bus Utilization")
    plt.title("Bus Utilization by Workload")
    plt.tight_layout()
    plt.savefig(os.path.join(args.output, "bus_utilization.png"), dpi=160)
    plt.close()

    plt.figure(figsize=(8, 4))
    plt.bar(names, rdx)
    plt.ylabel("BUS_RDX Count")
    plt.title("BUS_RDX by Workload")
    plt.tight_layout()
    plt.savefig(os.path.join(args.output, "bus_rdx.png"), dpi=160)
    plt.close()

    print(f"Wrote plots to {args.output}")


if __name__ == "__main__":
    main()

