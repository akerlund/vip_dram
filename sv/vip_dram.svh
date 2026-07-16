// -----------------------------------------------------------------------------
// vip_dram.svh
//
// Compile header for the vip_dram VIP: pulls in the standalone packages (types,
// timing, address-map) and the umbrella vip_dram_pkg (which `include`s the
// parameterized class items). Adding this one file to a filelist (with +incdir
// pointing at vip_dram/) compiles the whole VIP. Depends on the vip_memory VIP
// (vip_mem_types_pkg / vip_memory_pkg) being compiled first.
// -----------------------------------------------------------------------------
`ifndef VIP_DRAM_SVH
`define VIP_DRAM_SVH

`include "vip_dram_types_pkg.sv"
`include "vip_dram_timing_pkg.sv"
`include "vip_dram_addr_pkg.sv"
`include "vip_dram_pkg.sv"

`endif
