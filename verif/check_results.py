import argparse
import json
import math
from typing import Any, Dict, List


def check_metrics(metrics: List[Dict[str, Any]]) -> List[str]:
    errors: List[str] = []
    for entry in metrics:
        name = entry.get("name", "<unknown>")
        total_cycles = entry.get("total_cycles")
        bus_util = entry.get("bus_utilization")
        if not isinstance(total_cycles, int) or total_cycles <= 0:
            errors.append(f"{name}: total_cycles must be a positive int")
        if not isinstance(bus_util, (float, int)) or not (0.0 <= float(bus_util) <= 1.0):
            errors.append(f"{name}: bus_utilization must be in [0, 1]")

        for k in ("l1_hit_rate_core0", "l1_hit_rate_core1"):
            v = entry.get(k)
            if not isinstance(v, (float, int)) or math.isnan(float(v)) or not (0.0 <= float(v) <= 1.0):
                errors.append(f"{name}: {k} must be in [0, 1]")

        bus_counts = entry.get("bus_counts", {})
        if not isinstance(bus_counts, dict):
            errors.append(f"{name}: bus_counts must be a dict")
        else:
            for op, cnt in bus_counts.items():
                if not isinstance(cnt, int) or cnt < 0:
                    errors.append(f"{name}: bus_counts[{op}] must be a non-negative int")
    return errors


def main() -> None:
    ap = argparse.ArgumentParser(description="Sanity-check generated metrics/results.")
    ap.add_argument("--metrics", default="results/metrics.json", help="Path to metrics.json (default: results/metrics.json)")
    args = ap.parse_args()

    with open(args.metrics, "r", encoding="utf-8") as f:
        metrics = json.load(f)

    if not isinstance(metrics, list):
        raise SystemExit("metrics.json must contain a JSON list")

    errors = check_metrics(metrics)
    if errors:
        for e in errors:
            print("ERROR:", e)
        raise SystemExit(1)

    print("check_results: PASS")


if __name__ == "__main__":
    main()

