/*
 * 固定深度 FIFO 单元验证：检查空/满、同拍读写、指针回绕、FWFT 直通和联合清空。
 * 期望队列使用独立软件 deque，不读取 DUT 的指针或存储内容。
 * 此测试不依赖 SystemC，只驱动 aou_sync_fifo 的实际 RTL 端口。
 */
#include "Vaou_sync_fifo.h"
#include "verilated.h"
#include <deque>
#include <iostream>
#include <stdexcept>

#ifndef FIFO_FWFT
#define FIFO_FWFT 0
#endif

int main() {
    try {
        Vaou_sync_fifo dut;
        std::deque<unsigned> expected;
        constexpr bool fwft=FIFO_FWFT!=0;
        unsigned next=1,seed=0x12345678,full_replace=0,pushes=0,pops=0,bypasses=0;
        bool held=false;
        auto check=[](bool ok,const char* msg) { if(!ok) throw std::runtime_error(msg); };
        auto reset=[&] {
            dut.rst_n=0; dut.clk=0; dut.eval(); dut.clk=1; dut.eval();
            expected.clear(); held=false;
            check(!dut.m_valid&&!dut.s_ready&&dut.level==0,"reset state");
            dut.rst_n=1;
        };
        reset();

        // 空队列、上下游同时 ready/valid：FWFT 当拍直通，默认模式在时钟沿后出队。
        dut.clk=0; dut.s_valid=1; dut.s_data=0xa5; dut.m_ready=1; dut.eval();
        check(bool(dut.s_ready),"empty FIFO must accept input");
        check(bool(dut.m_valid)==fwft,"empty-cycle FWFT valid mismatch");
        if(fwft) check(dut.m_data==0xa5,"FWFT bypass data mismatch");
        dut.clk=1; dut.eval();
        dut.clk=0; dut.s_valid=0; dut.eval();
        check(dut.level==(fwft?0u:1u),"empty-cycle bypass occupancy mismatch");
        if(!fwft) check(dut.m_valid&&dut.m_data==0xa5,"registered first word mismatch");
        if(fwft) ++bypasses;
        reset();

        // 下游背压时先写入存储，撤掉输入后队首仍须保持有效和数据稳定。
        dut.clk=0; dut.s_valid=1; dut.s_data=0x5a; dut.m_ready=0; dut.eval();
        check(bool(dut.m_valid)==fwft,"stalled empty FIFO valid mismatch");
        dut.clk=1; dut.eval();
        dut.clk=0; dut.s_valid=0; dut.m_ready=1; dut.eval();
        check(dut.level==1&&dut.m_valid&&dut.m_data==0x5a,"stalled first word lost");
        reset();

        for(unsigned cycle=0;cycle<6000;cycle++) {
            if(cycle==3000) reset();
            seed=seed*1664525u+1013904223u;
            dut.clk=0;
            // 先填满，再连续同拍出入，随后固定种子组合背压。被背压的输入不撤回。
            dut.s_valid=held||cycle<200||(seed&3)!=0;
            dut.s_data=next;
            dut.m_ready=cycle>=100&&(cycle<200||(seed&0x70)!=0);
            dut.eval();
            const bool bypass=fwft&&expected.empty()&&bool(dut.s_valid);
            check(dut.level==expected.size(),"occupancy differs from scoreboard");
            check(bool(dut.m_valid)==(!expected.empty()||bypass),"empty/valid mismatch");
            const bool pop=dut.m_valid&&dut.m_ready,push=dut.s_valid&&dut.s_ready;
            check(bool(dut.s_ready)==(expected.size()<FIFO_DEPTH||pop),"full/ready mismatch");
            if(expected.size()==FIFO_DEPTH&&pop&&push) ++full_replace;
            if(dut.m_valid) check(dut.m_data==(bypass?next:expected.front()),"FIFO ordering/data mismatch");
            if(bypass&&pop&&push) { ++bypasses; ++pops; ++pushes; ++next; }
            else {
                if(pop) { expected.pop_front(); ++pops; }
                if(push) { expected.push_back(next++); ++pushes; }
            }
            held=dut.s_valid&&!dut.s_ready;
            dut.clk=1; dut.eval();
        }
        check(full_replace>0&&pushes>FIFO_DEPTH*4&&pops>FIFO_DEPTH*4,"missing wrap/full replacement coverage");
        dut.final();
        std::cout<<"FIFO PASS depth="<<FIFO_DEPTH<<" fwft="<<FIFO_FWFT
                 <<" pushes="<<pushes<<" pops="<<pops
                 <<" simultaneous_full_replace="<<full_replace
                 <<" empty_bypass="<<bypasses<<"\n";
        return 0;
    } catch(const std::exception& e) { std::cerr<<"FIFO FAIL: "<<e.what()<<"\n"; return 1; }
}
