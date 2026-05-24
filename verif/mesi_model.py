from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from typing import Dict, List, Optional, Tuple


class MESIState(Enum):
    I = auto()
    S = auto()
    E = auto()
    M = auto()


class BusOp(Enum):
    BUS_RD = auto()
    BUS_RDX = auto()
    BUS_UPGR = auto()


@dataclass
class CacheLine:
    tag: Optional[int]
    state: MESIState
    data: List[int]


@dataclass
class SnoopResult:
    had_copy: bool
    supplied_data: Optional[List[int]] = None


class L2Inclusive:
    def __init__(self, line_words: int):
        self._line_words = line_words
        self._lines: Dict[int, List[int]] = {}

    def read_line(self, line_addr: int) -> List[int]:
        if line_addr not in self._lines:
            self._lines[line_addr] = [0 for _ in range(self._line_words)]
        return list(self._lines[line_addr])

    def write_line(self, line_addr: int, data: List[int]) -> None:
        if len(data) != self._line_words:
            raise ValueError("L2 write_line data length mismatch")
        self._lines[line_addr] = list(data)


class L1Cache:
    def __init__(self, *, cache_id: int, num_sets: int, num_ways: int, line_words: int):
        if num_ways != 2:
            raise ValueError("This model currently implements a 2-way cache (num_ways=2).")
        self.cache_id = cache_id
        self.num_sets = num_sets
        self.num_ways = num_ways
        self.line_words = line_words

        self._sets: List[List[CacheLine]] = []
        for _ in range(num_sets):
            ways = [CacheLine(tag=None, state=MESIState.I, data=[0] * line_words) for _ in range(num_ways)]
            self._sets.append(ways)

        # 2-way pseudo-LRU: store the way to evict next (0/1).
        self._lru_evict_way: List[int] = [0 for _ in range(num_sets)]

    def _decode(self, line_addr: int) -> Tuple[int, int]:
        set_idx = line_addr % self.num_sets
        tag = line_addr // self.num_sets
        return tag, set_idx

    def _find_way(self, tag: int, set_idx: int) -> Optional[int]:
        for way in range(self.num_ways):
            line = self._sets[set_idx][way]
            if line.state != MESIState.I and line.tag == tag:
                return way
        return None

    def peek_state(self, line_addr: int) -> MESIState:
        tag, set_idx = self._decode(line_addr)
        way = self._find_way(tag, set_idx)
        if way is None:
            return MESIState.I
        return self._sets[set_idx][way].state

    def read_word_hit(self, *, line_addr: int, word_off: int) -> int:
        tag, set_idx = self._decode(line_addr)
        way = self._find_way(tag, set_idx)
        if way is None:
            raise RuntimeError("read_word_hit called on miss")
        self._touch(set_idx=set_idx, way=way)
        return self._sets[set_idx][way].data[word_off]

    def write_word_hit(self, *, line_addr: int, word_off: int, value: int) -> None:
        tag, set_idx = self._decode(line_addr)
        way = self._find_way(tag, set_idx)
        if way is None:
            raise RuntimeError("write_word_hit called on miss")
        self._touch(set_idx=set_idx, way=way)
        self._sets[set_idx][way].data[word_off] = value

    def set_state(self, *, line_addr: int, new_state: MESIState) -> None:
        tag, set_idx = self._decode(line_addr)
        way = self._find_way(tag, set_idx)
        if way is None:
            raise RuntimeError("set_state called on miss")
        self._sets[set_idx][way].state = new_state
        self._touch(set_idx=set_idx, way=way)

    def has_line(self, line_addr: int) -> bool:
        return self.peek_state(line_addr) != MESIState.I

    def fill_line(
        self,
        *,
        line_addr: int,
        data: List[int],
        new_state: MESIState,
    ) -> Optional[Tuple[int, List[int]]]:
        tag, set_idx = self._decode(line_addr)

        empty_way = None
        for way in range(self.num_ways):
            if self._sets[set_idx][way].state == MESIState.I:
                empty_way = way
                break

        victim_way = empty_way if empty_way is not None else self._lru_evict_way[set_idx]
        victim = self._sets[set_idx][victim_way]

        writeback: Optional[Tuple[int, List[int]]] = None
        if victim.state == MESIState.M and victim.tag is not None:
            victim_line_addr = victim.tag * self.num_sets + set_idx
            writeback = (victim_line_addr, list(victim.data))

        self._sets[set_idx][victim_way] = CacheLine(tag=tag, state=new_state, data=list(data))
        self._touch(set_idx=set_idx, way=victim_way)
        return writeback

    def snoop(self, *, op: BusOp, line_addr: int) -> SnoopResult:
        tag, set_idx = self._decode(line_addr)
        way = self._find_way(tag, set_idx)
        if way is None:
            return SnoopResult(had_copy=False)

        line = self._sets[set_idx][way]
        prior = line.state

        if op == BusOp.BUS_RD:
            if prior == MESIState.I:
                return SnoopResult(had_copy=False)
            if prior == MESIState.M:
                # Supply data and downgrade to S (no Owned state in MESI).
                line.state = MESIState.S
                self._touch(set_idx=set_idx, way=way)
                return SnoopResult(had_copy=True, supplied_data=list(line.data))
            if prior == MESIState.E:
                # Downgrade to S; data is clean so we don't need to supply it.
                line.state = MESIState.S
                self._touch(set_idx=set_idx, way=way)
                return SnoopResult(had_copy=True)
            if prior == MESIState.S:
                self._touch(set_idx=set_idx, way=way)
                return SnoopResult(had_copy=True)

        if op == BusOp.BUS_RDX:
            if prior == MESIState.I:
                return SnoopResult(had_copy=False)
            if prior == MESIState.M:
                supplied = list(line.data)
                line.state = MESIState.I
                line.tag = None
                self._touch(set_idx=set_idx, way=way)
                return SnoopResult(had_copy=True, supplied_data=supplied)
            # E or S: invalidate, no data supply required (clean).
            line.state = MESIState.I
            line.tag = None
            self._touch(set_idx=set_idx, way=way)
            return SnoopResult(had_copy=True)

        if op == BusOp.BUS_UPGR:
            # Others must be in S (clean) for a valid upgrade.
            if prior in (MESIState.E, MESIState.M):
                raise AssertionError("Invalid BUS_UPGR snoop: other cache had E/M")
            if prior == MESIState.S:
                line.state = MESIState.I
                line.tag = None
                self._touch(set_idx=set_idx, way=way)
                return SnoopResult(had_copy=True)
            return SnoopResult(had_copy=False)

        raise ValueError(f"Unsupported snoop op: {op}")

    def _touch(self, *, set_idx: int, way: int) -> None:
        # For 2-way, mark the other way as eviction candidate.
        self._lru_evict_way[set_idx] = 1 - way


@dataclass
class OpResult:
    cycles: int
    read_value: Optional[int] = None
    bus_op: Optional[BusOp] = None


class MesiSystem:
    def __init__(
        self,
        *,
        num_sets: int = 16,
        num_ways: int = 2,
        line_words: int = 4,
        word_bytes: int = 4,
        l1_hit_cycles: int = 1,
        bus_cycles: int = 4,
        l2_cycles: int = 12,
    ):
        if word_bytes != 4:
            raise ValueError("word_bytes must be 4 in this model")
        self.num_cores = 2
        self.line_words = line_words
        self.word_bytes = word_bytes
        self.line_bytes = line_words * word_bytes

        self.l1_hit_cycles = l1_hit_cycles
        self.bus_cycles = bus_cycles
        self.l2_cycles = l2_cycles

        self.l2 = L2Inclusive(line_words=line_words)
        self.l1 = [
            L1Cache(cache_id=0, num_sets=num_sets, num_ways=num_ways, line_words=line_words),
            L1Cache(cache_id=1, num_sets=num_sets, num_ways=num_ways, line_words=line_words),
        ]

        self.total_cycles = 0
        self.bus_busy_cycles = 0

        self.bus_counts: Dict[BusOp, int] = {BusOp.BUS_RD: 0, BusOp.BUS_RDX: 0, BusOp.BUS_UPGR: 0}
        self.l1_hits = [0, 0]
        self.l1_misses = [0, 0]

    def _addr_to_line(self, addr: int) -> Tuple[int, int]:
        if addr < 0:
            raise ValueError("addr must be >= 0")
        line_addr = addr // self.line_bytes
        word_off = (addr % self.line_bytes) // self.word_bytes
        return line_addr, word_off

    def read(self, *, core: int, addr: int) -> OpResult:
        line_addr, word_off = self._addr_to_line(addr)
        state = self.l1[core].peek_state(line_addr)
        if state != MESIState.I:
            self.l1_hits[core] += 1
            value = self.l1[core].read_word_hit(line_addr=line_addr, word_off=word_off)
            self._tick(self.l1_hit_cycles, bus_busy=0)
            self._check_invariants(line_addr)
            return OpResult(cycles=self.l1_hit_cycles, read_value=value)

        self.l1_misses[core] += 1
        data, shared = self._bus_transaction(core=core, op=BusOp.BUS_RD, line_addr=line_addr)
        new_state = MESIState.S if shared else MESIState.E
        self._install_line(core=core, line_addr=line_addr, data=data, state=new_state)
        value = self.l1[core].read_word_hit(line_addr=line_addr, word_off=word_off)
        self._check_invariants(line_addr)
        return OpResult(cycles=self.bus_cycles + self.l2_cycles, read_value=value, bus_op=BusOp.BUS_RD)

    def write(self, *, core: int, addr: int, value: int) -> OpResult:
        line_addr, word_off = self._addr_to_line(addr)
        state = self.l1[core].peek_state(line_addr)

        if state == MESIState.M:
            self.l1_hits[core] += 1
            self.l1[core].write_word_hit(line_addr=line_addr, word_off=word_off, value=value)
            self._tick(self.l1_hit_cycles, bus_busy=0)
            self._check_invariants(line_addr)
            return OpResult(cycles=self.l1_hit_cycles)

        if state == MESIState.E:
            self.l1_hits[core] += 1
            self.l1[core].set_state(line_addr=line_addr, new_state=MESIState.M)
            self.l1[core].write_word_hit(line_addr=line_addr, word_off=word_off, value=value)
            self._tick(self.l1_hit_cycles, bus_busy=0)
            self._check_invariants(line_addr)
            return OpResult(cycles=self.l1_hit_cycles)

        if state == MESIState.S:
            self.l1_hits[core] += 1
            self._bus_transaction(core=core, op=BusOp.BUS_UPGR, line_addr=line_addr)
            self.l1[core].set_state(line_addr=line_addr, new_state=MESIState.M)
            self.l1[core].write_word_hit(line_addr=line_addr, word_off=word_off, value=value)
            self._check_invariants(line_addr)
            return OpResult(cycles=self.bus_cycles, bus_op=BusOp.BUS_UPGR)

        # Miss: BUS_RDX (read-for-ownership).
        self.l1_misses[core] += 1
        data, _shared = self._bus_transaction(core=core, op=BusOp.BUS_RDX, line_addr=line_addr)
        self._install_line(core=core, line_addr=line_addr, data=data, state=MESIState.M)
        self.l1[core].write_word_hit(line_addr=line_addr, word_off=word_off, value=value)
        self._check_invariants(line_addr)
        return OpResult(cycles=self.bus_cycles + self.l2_cycles, bus_op=BusOp.BUS_RDX)

    def _install_line(self, *, core: int, line_addr: int, data: List[int], state: MESIState) -> None:
        writeback = self.l1[core].fill_line(line_addr=line_addr, data=data, new_state=state)
        if writeback is not None:
            victim_line_addr, victim_data = writeback
            self.l2.write_line(victim_line_addr, victim_data)

    def _bus_transaction(self, *, core: int, op: BusOp, line_addr: int) -> Tuple[List[int], bool]:
        self.bus_counts[op] += 1

        snoop_data: Optional[List[int]] = None
        shared = False

        for other in range(self.num_cores):
            if other == core:
                continue
            res = self.l1[other].snoop(op=op, line_addr=line_addr)
            shared |= res.had_copy
            if res.supplied_data is not None:
                snoop_data = res.supplied_data

        # Always account bus occupancy. L2 cycles are charged by caller for RD/RDX.
        self._tick(self.bus_cycles, bus_busy=self.bus_cycles)

        if op == BusOp.BUS_UPGR:
            self._check_invariants(line_addr)
            return self.l2.read_line(line_addr), shared

        if snoop_data is not None:
            self.l2.write_line(line_addr, snoop_data)
            self._tick(self.l2_cycles, bus_busy=0)
            return list(snoop_data), True

        data = self.l2.read_line(line_addr)
        self._tick(self.l2_cycles, bus_busy=0)
        return data, shared

    def _tick(self, cycles: int, *, bus_busy: int) -> None:
        self.total_cycles += cycles
        self.bus_busy_cycles += bus_busy

    def line_sharers(self, line_addr: int) -> List[MESIState]:
        return [self.l1[0].peek_state(line_addr), self.l1[1].peek_state(line_addr)]

    def _check_invariants(self, line_addr: int) -> None:
        s0 = self.l1[0].peek_state(line_addr)
        s1 = self.l1[1].peek_state(line_addr)

        # At most one M.
        if s0 == MESIState.M and s1 == MESIState.M:
            raise AssertionError("Invariant violation: both caches in M for same line")

        # At most one E, and if one is E the other must be I.
        if s0 == MESIState.E and s1 != MESIState.I:
            raise AssertionError("Invariant violation: E must be unshared")
        if s1 == MESIState.E and s0 != MESIState.I:
            raise AssertionError("Invariant violation: E must be unshared")

        # If one is M, the other must be I.
        if s0 == MESIState.M and s1 != MESIState.I:
            raise AssertionError("Invariant violation: M must be exclusive owner")
        if s1 == MESIState.M and s0 != MESIState.I:
            raise AssertionError("Invariant violation: M must be exclusive owner")


def run_trace(system: MesiSystem, trace: List[Tuple[int, str, int, Optional[int]]]) -> None:
    """
    trace item: (core, op, addr, value)
      - op: "R" or "W"
      - for "R", value must be None
      - for "W", value must be int
    """
    for core, op, addr, value in trace:
        if op == "R":
            if value is not None:
                raise ValueError("Read trace item must have value=None")
            system.read(core=core, addr=addr)
        elif op == "W":
            if value is None:
                raise ValueError("Write trace item must have a value")
            system.write(core=core, addr=addr, value=value)
        else:
            raise ValueError(f"Unknown op: {op}")


def workload_private(*, iters: int = 2000, base0: int = 0x0000, base1: int = 0x4000, stride: int = 4) -> List[Tuple[int, str, int, Optional[int]]]:
    trace: List[Tuple[int, str, int, Optional[int]]] = []
    for i in range(iters):
        a0 = base0 + (i % 64) * stride
        a1 = base1 + (i % 64) * stride
        trace.append((0, "W", a0, i))
        trace.append((0, "R", a0, None))
        trace.append((1, "W", a1, i))
        trace.append((1, "R", a1, None))
    return trace


def workload_producer_consumer(*, iters: int = 2000, base: int = 0x8000, stride: int = 4) -> List[Tuple[int, str, int, Optional[int]]]:
    trace: List[Tuple[int, str, int, Optional[int]]] = []
    for i in range(iters):
        addr = base + (i % 128) * stride
        trace.append((0, "W", addr, i))
        trace.append((1, "R", addr, None))
    return trace


def workload_false_sharing(*, iters: int = 2000, base: int = 0xC000) -> List[Tuple[int, str, int, Optional[int]]]:
    # Two different words on the same line -> ping-pong invalidations.
    # word0 and word1 are within the same cache line when line_words >= 2.
    trace: List[Tuple[int, str, int, Optional[int]]] = []
    a0 = base + 0 * 4
    a1 = base + 1 * 4
    for i in range(iters):
        trace.append((0, "W", a0, i))
        trace.append((1, "W", a1, i))
    return trace

