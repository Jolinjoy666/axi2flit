// 屏蔽两种仿真器在 SystemC 封装上的差异：
//   Verilator：模块类为 Vfl_rtl_top，波形用 VerilatedVcdSc 写 VCD（GTKWave 查看）；
//   VCS      ：模块类为 fl_rtl_top，波形由 RTL 内 $fsdbDumpvars 写 FSDB（Verdi 查看）。
#pragma once
#include <systemc.h>
#include <string>

#ifdef VERILATOR_FLOW
#include "Vfl_rtl_top.h"
#include "verilated.h"
#include "verilated_vcd_sc.h"
using FL_RTL_DUT = Vfl_rtl_top;
inline VerilatedVcdSc*& fl_trace_file() { static VerilatedVcdSc* t = nullptr; return t; }
inline void fl_dut_trace_open(FL_RTL_DUT& dut, const std::string& path) {
    if (path.empty()) return;
    Verilated::traceEverOn(true);
    sc_start(SC_ZERO_TIME);
    fl_trace_file() = new VerilatedVcdSc;
    dut.trace(fl_trace_file(), 99);
    fl_trace_file()->open(path.c_str());
}
inline void fl_dut_trace_close() {
    if (fl_trace_file()) { fl_trace_file()->close(); delete fl_trace_file(); fl_trace_file() = nullptr; }
}
#else
#include "fl_rtl_top.h"
using FL_RTL_DUT = fl_rtl_top;
inline void fl_dut_trace_open(FL_RTL_DUT&, const std::string&) {}
inline void fl_dut_trace_close() {}
#endif
