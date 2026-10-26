// 仿真场景参数：速率均为单向 GB/s，时间为 ns；不把协议消息头重复扣除。
#pragma once
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include "link_config.h"

struct BridgeTestConfig {
    std::string scenario="baseline", direction="both", package="S";
    unsigned burst=16, warmup=2000, cycles=20000, mc_latency=2, mc_interval=1;
    unsigned lanes=16, modules=1, credit_rtt_cycles=32;
    // 链路速率默认取 link_config.h（x8、24 GT/s、PAM4 → 48 GB/s），消息区为其 240/256。
    double link_gbps=LINK_BYTES_PER_NS, lane_gbps=32, shoreline_mm=0, density_gbps_mm=0;
    double phy_ns=2, prop_ns=0.2, cdc_ns=2, adapter_ns=0;
    double target_gbps=LINK_BYTES_PER_NS*240/256, min_efficiency=0;
    int size=-1;   // 每拍传输大小 log2(字节)；-1 表示全宽

    bool physical() const { return scenario=="physical"; }
    bool paced() const { return scenario!="ideal"; }
    double raw_gbps() const { return lanes*double(modules)*lane_gbps/8; }
    double wire_gbps() const { return physical() ? std::min(link_gbps,raw_gbps()) : link_gbps; }
    double serial_ns() const { return 256/raw_gbps(); }
    double flight_ns() const { return serial_ns()+phy_ns+prop_ns+cdc_ns+adapter_ns; }

    void validate(unsigned bytes) const {
        if(scenario!="baseline" && scenario!="saturated" && scenario!="ideal" &&
           scenario!="physical" && scenario!="backpressure") throw std::runtime_error("unknown performance scenario");
        if(direction!="read" && direction!="write" && direction!="both" && direction!="mixed")
            throw std::runtime_error("invalid direction");
        if(size>=0 && (1u<<size)>bytes) throw std::runtime_error("size exceeds bus width");
        const unsigned beat=size<0 ? bytes : 1u<<size;
        if(!burst || burst>256 || burst*beat>4096 || !cycles || !warmup ||
           !mc_latency || !mc_interval || !credit_rtt_cycles) throw std::runtime_error("invalid burst/window/MC/credit setting");
        for(double value:{link_gbps,lane_gbps,target_gbps})
            if(!std::isfinite(value)||value<=0) throw std::runtime_error("bandwidth must be finite and positive");
        for(double value:{shoreline_mm,density_gbps_mm,phy_ns,prop_ns,cdc_ns,adapter_ns,min_efficiency})
            if(!std::isfinite(value)||value<0) throw std::runtime_error("invalid physical/efficiency setting");
        if(min_efficiency>1) throw std::runtime_error("min-efficiency must be in [0,1]");
        if(physical()) {
            if(!modules || !((package=="S"&&lanes==16)||(package=="A"&&lanes==64)))
                throw std::runtime_error("physical model supports S/x16 or A/x64; 3D requires a separate model");
            if(shoreline_mm<=0 || density_gbps_mm<=0)
                throw std::runtime_error("physical scenario requires --shoreline-mm and --density-gbps-mm from package assumptions");
            if(raw_gbps()>shoreline_mm*density_gbps_mm+1e-9)
                throw std::runtime_error("configured lanes/rate exceed shoreline bandwidth ceiling");
        }
    }
};

inline void bridge_help() {
    std::cout<<
        "Functional: --scenario functional|negative [--trace]\n"
        "Performance: --scenario baseline|saturated|ideal|physical|backpressure\n"
        "  --direction read|write|both|mixed --burst N --size S --warmup N --cycles N\n"
        "    size: 每拍传输大小 2^S 字节，默认全宽\n"
        "    both: 读、写分别运行；mixed: 读写同时持续供数\n"
        "  --mc-latency N --mc-interval N --link-gbps B\n"
        "  --target-gbps B --min-efficiency 0..1 --credit-rtt-cycles N\n"
        "Physical: --package S|A --lanes 16|64 --modules N --lane-gbps B\n"
        "  --shoreline-mm L --density-gbps-mm D (required physical assumptions)\n"
        "  --phy-ns T --prop-ns T --cdc-ns T --adapter-ns T\n"
        "  CDC/PHY/adapter times are totals for one direction; RTL codec time is measured separately.\n"
        "Compatibility: --perf (baseline), --negative, --corrupt-read, --trace\n";
}
