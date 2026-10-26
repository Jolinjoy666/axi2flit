/*
 * 同步 FIFO 单元验证：空/满、满时同拍读写、指针回绕、两种读出模式和复位。
 * FWFT=1 时非空即可在 rd_data 看到队首；FWFT=0 时 rd_en 之后下一拍给出读出数据。
 * 期望队列使用独立软件 deque，不读取 DUT 的指针或存储内容。
 */
#include "Vaou_sync_fifo.h"
#include "verilated.h"
#include <deque>
#include <iostream>
#include <stdexcept>

#ifndef FIFO_FWFT
#define FIFO_FWFT 1
#endif

int main() {
    try {
        Vaou_sync_fifo dut;
        constexpr bool fwft = FIFO_FWFT != 0;
        std::deque<unsigned> expected;
        unsigned next = 1, seed = 0x12345678, full_replace = 0, pushes = 0, pops = 0;
        bool std_pending = false;     // 标准模式：上一拍有读出，本拍核对 rd_data
        unsigned std_expect = 0;
        auto check = [](bool ok, const char* msg) { if (!ok) throw std::runtime_error(msg); };
        auto edge = [&] { dut.clk = 1; dut.eval(); dut.clk = 0; dut.eval(); };
        auto reset = [&] {
            dut.rst_n = 0; dut.wr_en = 0; dut.rd_en = 0; dut.clk = 0; dut.eval(); edge();
            expected.clear(); std_pending = false;
            check(dut.empty && !dut.full && dut.level == 0, "reset state");
            dut.rst_n = 1; dut.eval();
        };
        reset();

        // 空队列同时读写：写入不直通，读请求被忽略；时钟沿后成为队首。
        dut.wr_en = 1; dut.wr_data = 0xa5; dut.rd_en = 1; dut.eval();
        edge();
        dut.wr_en = 0; dut.rd_en = 0; dut.eval();
        check(dut.level == 1 && !dut.empty, "write to empty FIFO lost");
        if (fwft) check(dut.rd_data == 0xa5, "FWFT head not visible");
        dut.rd_en = 1; dut.eval(); edge(); dut.rd_en = 0; dut.eval();
        check(dut.empty, "read did not consume head");
        if (!fwft) check(dut.rd_data == 0xa5, "standard mode read data not registered");
        reset();

        for (unsigned cycle = 0; cycle < 6000; cycle++) {
            if (cycle == 3000) reset();
            seed = seed * 1664525u + 1013904223u;
            // 先填满，再连续同拍读写，随后固定种子组合读写。
            dut.wr_en = cycle < 200 || (seed & 3) != 0;
            dut.wr_data = next;
            dut.rd_en = cycle >= 100 && (cycle < 200 || (seed & 0x70) != 0);
            dut.eval();
            check(dut.level == expected.size(), "occupancy differs from scoreboard");
            check(bool(dut.empty) == expected.empty(), "empty flag mismatch");
            check(bool(dut.full) == (expected.size() == FIFO_DEPTH), "full flag mismatch");
            if (!fwft && std_pending) check(dut.rd_data == std_expect, "standard mode data mismatch");
            if (fwft && !expected.empty()) check(dut.rd_data == expected.front(), "FWFT head mismatch");
            const bool pop = dut.rd_en && !expected.empty();
            const bool push = dut.wr_en && (expected.size() < FIFO_DEPTH || pop);
            if (expected.size() == FIFO_DEPTH && pop && push) ++full_replace;
            std_pending = pop;
            if (pop) { std_expect = expected.front(); expected.pop_front(); ++pops; }
            if (push) { expected.push_back(next++); ++pushes; }
            edge();
        }
        check(full_replace > 0 && pushes > FIFO_DEPTH * 4 && pops > FIFO_DEPTH * 4,
              "missing wrap/full replacement coverage");
        dut.final();
        std::cout << "FIFO PASS depth=" << FIFO_DEPTH << " fwft=" << FIFO_FWFT << " pushes=" << pushes
                  << " pops=" << pops << " simultaneous_full_replace=" << full_replace << "\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << "FIFO FAIL: " << e.what() << "\n"; return 1; }
}
