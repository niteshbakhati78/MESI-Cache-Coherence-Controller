import argparse
import random
import sys
import unittest

from mesi_model import (
    BusOp,
    MESIState,
    MesiSystem,
    workload_false_sharing,
    run_trace,
)


class TestBasic(unittest.TestCase):
    def test_read_read_shared(self) -> None:
        sys = MesiSystem()
        addr = 0x100
        r0 = sys.read(core=0, addr=addr)
        self.assertIsNotNone(r0.read_value)
        self.assertEqual(sys.l1[0].peek_state(addr // sys.line_bytes), MESIState.E)

        r1 = sys.read(core=1, addr=addr)
        self.assertEqual(r1.read_value, r0.read_value)
        line = addr // sys.line_bytes
        self.assertEqual(sys.l1[0].peek_state(line), MESIState.S)
        self.assertEqual(sys.l1[1].peek_state(line), MESIState.S)

    def test_write_invalidate_and_transfer(self) -> None:
        sys = MesiSystem()
        addr = 0x200

        sys.read(core=0, addr=addr)  # E in core0
        sys.write(core=0, addr=addr, value=123)  # M in core0
        line = addr // sys.line_bytes
        self.assertEqual(sys.l1[0].peek_state(line), MESIState.M)
        self.assertEqual(sys.l1[1].peek_state(line), MESIState.I)

        # Core1 reads -> core0 downgrades to S, core1 gets S.
        r1 = sys.read(core=1, addr=addr)
        self.assertEqual(r1.read_value, 123)
        self.assertEqual(sys.l1[0].peek_state(line), MESIState.S)
        self.assertEqual(sys.l1[1].peek_state(line), MESIState.S)

        # Core1 writes -> BUS_UPGR invalidates core0, core1 becomes M.
        sys.write(core=1, addr=addr, value=456)
        self.assertEqual(sys.l1[0].peek_state(line), MESIState.I)
        self.assertEqual(sys.l1[1].peek_state(line), MESIState.M)

        # Core0 reads -> sees latest.
        r0 = sys.read(core=0, addr=addr)
        self.assertEqual(r0.read_value, 456)


class TestCoherenceSystem(unittest.TestCase):
    def test_false_sharing_generates_bus_traffic(self) -> None:
        sys = MesiSystem(line_words=4)
        run_trace(sys, workload_false_sharing(iters=500))
        # False sharing should drive coherence traffic (predominantly BUS_RDX).
        self.assertGreater(sys.bus_counts[BusOp.BUS_RDX], 0)


class TestStress(unittest.TestCase):
    def test_random_stress_invariants(self) -> None:
        sys = MesiSystem(num_sets=8, line_words=4)
        addrs = [0x1000 + i * 4 for i in range(64)]
        for _ in range(5000):
            core = random.randint(0, 1)
            addr = random.choice(addrs)
            if random.random() < 0.5:
                sys.read(core=core, addr=addr)
            else:
                sys.write(core=core, addr=addr, value=random.randint(0, 100000))


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Python MESI model tests.")
    ap.add_argument(
        "--test",
        default="all",
        choices=["all", "basic", "coherence_system", "stress"],
        help="Which test group to run",
    )
    ap.add_argument("--waves", default="off", choices=["on", "off"], help="Placeholder for SV wave dumping")
    ap.add_argument("--seed", type=int, default=None, help="Random seed for stress tests")
    args = ap.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    if args.test in ("all", "basic"):
        suite.addTests(loader.loadTestsFromTestCase(TestBasic))
    if args.test in ("all", "coherence_system"):
        suite.addTests(loader.loadTestsFromTestCase(TestCoherenceSystem))
    if args.test in ("all", "stress"):
        suite.addTests(loader.loadTestsFromTestCase(TestStress))

    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
