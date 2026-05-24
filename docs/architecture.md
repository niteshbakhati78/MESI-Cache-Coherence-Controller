# Architecture Notes

This document captures the key microarchitecture decisions for the 2-core MESI system.

## Current implementation status
- Executable functional reference + metrics: `verif/mesi_model.py`
- RTL: reference skeleton under `rtl/` (to be completed for Vivado/Questa)

## Coherence model (Python reference)
- Two private L1 caches, 2-way set associative
- Shared inclusive L2 backing store
- Snooping operations: `BusRd`, `BusRdX`, `BusUpgr`

## Suggested RTL mapping
- `rtl/mesi_fsm.sv`: per-line MESI state transitions
- `rtl/l1_cache_controller.sv`: tag/data arrays + LRU + MESI integration
- `rtl/bus_arbiter.sv`: round-robin arbitration + snoop broadcast
- `rtl/l2_cache.sv`: line RAM backing store
- `rtl/coherence_system.sv`: top-level composition

