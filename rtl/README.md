# RTL (reference)

This directory is a **reference skeleton** for a synthesizable SystemVerilog MESI implementation matching the Python
golden model in `verif/mesi_model.py`.

If you want, the next step is to:
- Implement `rtl/top_2core_mesi.sv` + `rtl/l1_cache_mesi.sv` as a cycle-accurate RTL version of the Python model
- Add SVA properties for MESI invariants
- Hook into Vivado (`scripts/`) or Questa for simulation

