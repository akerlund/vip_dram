////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Description:
// dram_vip_top
//
// Minimal Verilator toplevel for the pure-TLM vip_dram pyUVM/cocotb port. The
// device has NO signals -- every delay is a cocotb Timer against absolute ns --
// so this shell exists only to give Verilator/cocotb something to elaborate and
// to fix the time unit/precision at 1 ns / 1 ps (every DDR4 preset value is an
// exact integer picosecond). Counterpart of the SV example's dram_tb_top.sv,
// which likewise carries no clock/reset/interface.
//
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps
module dram_vip_top;

  // A single dummy net keeps the module non-empty for Verilator; cocotb never
  // touches it (the testbench is entirely TLM + Timer driven).
  logic unused = 1'b0;

endmodule
