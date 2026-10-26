/**
 * 桥与链路共用的速率、调制和credit环路预算。默认 8 通道、每通道 24G 符号率、PAM4（每符号 2bit），
 * 单向原始带宽 48 GB/s，与 1024 位桥的处理能力（64 GB/s）匹配，链路仍是瓶颈。
 * x16 PAM4（96 GB/s）时瓶颈转到桥上；NRZ 用 AOU_LINK_BITS_PER_SYMBOL=1。
 */
#pragma once

#ifndef AOU_LINK_LANES
#define AOU_LINK_LANES 8
#endif
#ifndef AOU_LINK_RATE_GTPS
#define AOU_LINK_RATE_GTPS 24.0
#endif
#ifndef AOU_LINK_BITS_PER_SYMBOL
#define AOU_LINK_BITS_PER_SYMBOL 2
#endif
#ifndef AOU_LINK_TAT_NS
#define AOU_LINK_TAT_NS 40.0
#endif

static constexpr unsigned LINK_LANES = AOU_LINK_LANES;
static constexpr unsigned LINK_BITS_PER_SYMBOL = AOU_LINK_BITS_PER_SYMBOL;
static constexpr double LINK_RATE_GTPS = AOU_LINK_RATE_GTPS;
static constexpr double LINK_GT_PER_LANE = LINK_RATE_GTPS * 1.0e9;
static constexpr double LINK_TAT_NS = AOU_LINK_TAT_NS;
static constexpr double LINK_BYTES_PER_NS =
    LINK_LANES * LINK_RATE_GTPS * LINK_BITS_PER_SYMBOL / 8.0;
static_assert(LINK_LANES > 0 && LINK_LANES <= 256, "lane 数须在 1..256");
static_assert(LINK_RATE_GTPS > 0 && LINK_RATE_GTPS <= 1000, "链路速率超出模型范围");
static_assert(LINK_BITS_PER_SYMBOL == 1 || LINK_BITS_PER_SYMBOL == 2,
              "只支持 NRZ(1) 或 PAM4(2)");
static_assert(LINK_TAT_NS >= 0 && LINK_TAT_NS <= 1000000, "TAT 预算超出模型范围");
