/**
 * RTL 桥全链路联合仿真：AXI 主机模型 ⇄ RTL axi2flit_soc ⇄ UCIe 适配器 ⇄ UcieLink（训练、PHY、CRC、重放）
 *   ⇄ UCIe 适配器 ⇄ RTL flit2mc_target ⇄ MC 模型（读写分口，字节存储）。
 * 同一份代码用 Verilator（--sc --pins-bv 2）或 VCS（-sysc，端口映射为 sc_bv）编译。
 * 记分板仅依据 AXI 握手维护参考字节，结束时与 MC 存储比较。
 * 用法：
 *   默认：空载延迟分解 + 功能用例 TC1～TC12 + 满载吞吐 TC13～TC15，最后打印汇总与验收指标
 *   单个用例：<sim> --case 3        多个：--case 1,13   用例表见 case_title()
 *   其他：[--stress] [--replay] [--no-perf] [--negative-scoreboard] [--burst N] [--cycles N] [--vcd 文件]
 *   吞吐：<sim> --perf read|write|mixed（等价于 --case 13/14/15，另输出一行 FULL_LINK_PERF 供脚本解析）
 */
#include "fl_rtl_dut.h"
#include "axi_if.h"
#include "aou_wire.h"
#include "ucie_aou_adapter.h"
#include "ucie_link.h"
#include <algorithm>
#include <deque>
#include <fstream>
#include <iomanip>
#include <map>
#include <random>
#include <sstream>
#include <chrono>
#include <cstdio>

#ifndef FL_DATA_WIDTH
#define FL_DATA_WIDTH 256
#endif
#ifndef FL_RP_COUNT
#define FL_RP_COUNT 1
#endif
#ifndef FL_MC_SLOTS
#define FL_MC_SLOTS 16
#endif
#ifndef FL_FDI_DEPTH
#define FL_FDI_DEPTH 1
#endif
// 两端接收深度，仅用于报告；须与 fl_rtl_top.sv 的同名宏一致（Makefile 同时传给两边）。
#ifndef FL_RDATA_DEPTH
#define FL_RDATA_DEPTH 24
#endif
#ifndef FL_WRESP_DEPTH
#define FL_WRESP_DEPTH 24
#endif
#ifndef FL_WREQ_DEPTH
#define FL_WREQ_DEPTH 24
#endif
#ifndef FL_RREQ_DEPTH
#define FL_RREQ_DEPTH 32
#endif
#ifndef FL_WDATA_DEPTH
#define FL_WDATA_DEPTH 24
#endif
static_assert(FL_DATA_WIDTH == AXI_DATA_WIDTH, "RTL 与 SystemC 位宽配置不一致");
constexpr unsigned BYTES = AXI_DATA_BYTES;
constexpr unsigned TAG_W = FL_MC_SLOTS > 1 ? (FL_MC_SLOTS > 2 ? (FL_MC_SLOTS > 4 ? (FL_MC_SLOTS > 8 ? (FL_MC_SLOTS > 16 ? (FL_MC_SLOTS > 32 ? (FL_MC_SLOTS > 64 ? (FL_MC_SLOTS > 128 ? 8 : 7) : 6) : 5) : 4) : 3) : 2) : 1) : 1;
template <int N> using bv = sc_dt::sc_bv<N>;

// ---- sc_bv 与字节数组、整数之间的转换 ----
template <int N> bv<N> from_bytes(const uint8_t* b) {
    bv<N> v;
    for (int j = 0; j < N / 8; ++j) v.range(8 * j + 7, 8 * j) = b[j];
    return v;
}
template <int N> void to_bytes(const bv<N>& v, uint8_t* b) {
    for (int j = 0; j < N / 8; ++j) b[j] = uint8_t(v.range(8 * j + 7, 8 * j).to_uint());
}
template <int N> bv<N> from_bits(const uint8_t* b) {
    bv<N> v;
    for (int j = 0; j < N; ++j) v[j] = b[j] ? sc_dt::SC_LOGIC_1 : sc_dt::SC_LOGIC_0;
    return v;
}
bv<2000> flit_bits(const AouFlit& f) {
    const auto w = serialize_aou(f);
    bv<2000> v;
    for (unsigned i = 0; i < 250; ++i) v.range((249 - i) * 8 + 7, (249 - i) * 8) = w[i];
    return v;
}
AouFlit bits_flit(const bv<2000>& v) {
    AouWireFlit w{};
    for (unsigned i = 0; i < 250; ++i) w[i] = uint8_t(v.range((249 - i) * 8 + 7, (249 - i) * 8).to_uint());
    return deserialize_aou(w);
}

// 用例编号与标题。波形中 tb_case 信号显示当前编号：20 为空载延迟测量，0 为空闲。
static const char* case_title(unsigned id) {
    static const char* t[] = {"",
        "零初始化读", "单拍写后读", "2/4/16 拍及 4KB 突发", "写掩码与零选通覆盖",
        "4 字节窄突发（字节通道轮转）", "AXI 最大 256 拍突发", "突发恰好止于 4KB 边界", "越界访问返回 DECERR",
        "多 AW 并发、读写交错、多 RP", "同 ID 读写响应保序", "长时间 B/R 背压与 credit 恢复", "固定种子随机突发与选通",
        "满载读吞吐", "满载写吞吐", "满载读写同时吞吐"};
    return id < sizeof(t) / sizeof(t[0]) ? t[id] : "?";
}
constexpr unsigned CASE_PROBE = 20, FIRST_PERF_CASE = 13, LAST_CASE = 15;

// 把 SystemC 适配器的 FlitTransfer 握手转换为 RTL 的 valid/ready/2000 位向量。
SC_MODULE(FlitBridge) {
    // 适配器侧
    sc_in<FlitTransfer> from_adapter;   // 适配器 rx（入 RTL）
    sc_out<bool> to_adapter_ready;      // RTL flit_rx_ready → 适配器 rx_ready
    sc_out<FlitTransfer> to_adapter;    // RTL 发出的帧 → 适配器 tx
    sc_in<bool> from_adapter_ready;     // 适配器 tx_ready → RTL flit_tx_ready
    // RTL 侧
    sc_out<bool> rtl_rx_valid;
    sc_out<bv<2000>> rtl_rx_data;
    sc_in<bool> rtl_rx_ready;
    sc_in<bool> rtl_tx_valid;
    sc_in<bv<2000>> rtl_tx_data;
    sc_out<bool> rtl_tx_ready;
    SC_CTOR(FlitBridge) {
        SC_METHOD(run);
        sensitive << from_adapter << rtl_rx_ready << rtl_tx_valid << rtl_tx_data << from_adapter_ready;
    }
    void run() {
        const FlitTransfer f = from_adapter.read();
        rtl_rx_valid.write(f.valid);
        rtl_rx_data.write(f.valid ? flit_bits(f.flit) : bv<2000>());
        to_adapter_ready.write(rtl_rx_ready.read());
        to_adapter.write(rtl_tx_valid.read() ? FlitTransfer(bits_flit(rtl_tx_data.read())) : FlitTransfer{});
        rtl_tx_ready.write(from_adapter_ready.read());
    }
};

SC_MODULE(FullLinkRtlTb) {
    static constexpr uint64_t BASE = 0x1234567800000000ULL;
    static constexpr unsigned MEM_SIZE = 128 * 1024;
    Config cfg;
    unsigned rp_count;
    bool stress, replay, corrupt_expected;
    std::string perf_dir;
    unsigned perf_burst = 16, perf_cycles = 20000, perf_warmup = 2000;
    std::vector<unsigned> only_cases;   // 空表示全部
    bool run_perf = true;

    // ---- 报告用统计 ----
    struct CaseRow { unsigned id; bool pass; double ns; uint64_t aw, w, ar, r;
                     double rd_avg, rd_max, wr_avg, wr_max; };
    struct PerfRow { unsigned id; std::string dir; double ns, rgb, wgb, rmin, rmax, wmin, wmax; uint64_t ff, rf, cw; };
    std::vector<CaseRow> rows;
    std::vector<PerfRow> perf_rows;
    bool probe_done = false;
    uint64_t probe_rd[8] = {}, probe_wr[8] = {};   // 单拍读、写各环节的时间点（周期）

    sc_clock clk{"clk", 2, SC_NS};
    sc_signal<bool> rst{"rst_n"}, link_up{"link_up"};
    sc_signal<unsigned> state{"link_state"};
    // AXI
    sc_signal<bool> awv{"awv"}, awr{"awr"}, wv{"wv"}, wr{"wr"}, arv{"arv"}, arr{"arr"};
    sc_signal<bool> bv_{"bv"}, br{"br"}, rv{"rv"}, rr{"rr"}, wlast{"wlast"}, rlast{"rlast"};
    sc_signal<bool> awlock{"awlock"}, arlock{"arlock"};
    sc_signal<bv<64>> awaddr{"awaddr"}, araddr{"araddr"};
    sc_signal<bv<10>> awid{"awid"}, arid{"arid"}, bid{"bid"}, rid{"rid"};
    sc_signal<bv<8>> awlen{"awlen"}, arlen{"arlen"};
    sc_signal<bv<3>> awsize{"awsize"}, arsize{"arsize"}, awprot{"awprot"}, arprot{"arprot"};
    sc_signal<bv<2>> awburst{"awburst"}, arburst{"arburst"}, bresp{"bresp"}, rresp{"rresp"};
    sc_signal<bv<4>> awcache{"awcache"}, arcache{"arcache"}, awqos{"awqos"}, arqos{"arqos"};
    sc_signal<bv<16>> awuser{"awuser"}, aruser{"aruser"}, wuser{"wuser"}, buser{"buser"}, ruser{"ruser"};
    sc_signal<bv<FL_DATA_WIDTH>> wdata{"wdata"}, rdata{"rdata"};
    sc_signal<bv<FL_DATA_WIDTH / 8>> wstrb{"wstrb"};
    // 两端 Flit（RTL 侧与适配器侧）
    sc_signal<bool> s_txv{"s_txv"}, s_txr{"s_txr"}, s_rxv{"s_rxv"}, s_rxr{"s_rxr"}, soc_err{"soc_err"};
    sc_signal<bool> t_txv{"t_txv"}, t_txr{"t_txr"}, t_rxv{"t_rxv"}, t_rxr{"t_rxr"}, tgt_err{"tgt_err"};
    sc_signal<bv<2000>> s_txd{"s_txd"}, s_rxd{"s_rxd"}, t_txd{"t_txd"}, t_rxd{"t_rxd"};
    sc_signal<FlitTransfer> a_soc_tx{"a_soc_tx"}, a_soc_rx{"a_soc_rx"}, a_mem_tx{"a_mem_tx"}, a_mem_rx{"a_mem_rx"};
    sc_signal<bool> a_soc_txr{"a_soc_txr"}, a_soc_rxr{"a_soc_rxr"}, a_mem_txr{"a_mem_txr"}, a_mem_rxr{"a_mem_rxr"};
    // MC 读写口
    sc_signal<bool> rd_v{"rd_v"}, rd_r{"rd_r"}, rd_first{"rd_first"}, rd_last{"rd_last"}, rd_lock{"rd_lock"};
    sc_signal<bool> rdr_v{"rdr_v"}, rdr_r{"rdr_r"};
    sc_signal<bv<TAG_W>> rd_tag{"rd_tag"}, rdr_tag{"rdr_tag"}, wr_tag{"wr_tag"}, wrr_tag{"wrr_tag"};
    sc_signal<bv<2>> rd_rp{"rd_rp"}, wr_rp{"wr_rp"}, rdr_resp{"rdr_resp"}, wrr_resp{"wrr_resp"};
    sc_signal<bv<10>> rd_id{"rd_id"}, wr_id{"wr_id"};
    sc_signal<bv<64>> rd_addr{"rd_addr"}, wr_addr{"wr_addr"};
    sc_signal<bv<3>> rd_size{"rd_size"}, wr_size{"wr_size"}, rd_prot{"rd_prot"}, wr_prot{"wr_prot"};
    sc_signal<bv<8>> rd_len{"rd_len"}, rd_beat{"rd_beat"}, wr_len{"wr_len"}, wr_beat{"wr_beat"};
    sc_signal<bv<4>> rd_cache{"rd_cache"}, rd_qos{"rd_qos"}, wr_cache{"wr_cache"}, wr_qos{"wr_qos"};
    sc_signal<bv<16>> rd_user{"rd_user"}, wr_user{"wr_user"}, wr_wuser{"wr_wuser"};
    sc_signal<bv<FL_DATA_WIDTH>> rdr_data{"rdr_data"}, wr_data{"wr_data"};
    sc_signal<bv<FL_DATA_WIDTH / 8>> wr_strb{"wr_strb"};
    sc_signal<bool> wr_v{"wr_v"}, wr_r{"wr_r"}, wr_first{"wr_first"}, wr_last{"wr_last"}, wr_lock{"wr_lock"};
    sc_signal<bool> wrr_v{"wrr_v"}, wrr_r{"wrr_r"}, credit_wait{"credit_wait"};
    sc_signal<bv<8>> tb_case{"tb_case"};

    Stats stats;
    sc_fifo<FdiFlit> soc_tx, soc_rx, mem_tx, mem_rx;
    FL_RTL_DUT dut;
    FlitBridge soc_bridge, mem_bridge;
    UcieAouAdapter soc_adapter, mem_adapter;
    UcieLink link;

    bool done = false;
    unsigned failures = 0, cases = 0;
    uint64_t aw_count = 0, w_count = 0, ar_count = 0, b_count = 0, r_count = 0, read_done = 0;
    uint64_t b_stalls = 0, r_stalls = 0, mc_ooo = 0, mc_cmds = 0, mc_rd_cmds = 0, mc_wr_cmds = 0, credit_wait_cycles = 0, cycle = 0;
    std::ofstream csv;

    SC_HAS_PROCESS(FullLinkRtlTb);
    FullLinkRtlTb(sc_module_name name, Config config, unsigned planes, bool pressure, bool errors,
                  bool negative, const std::string& prefix, const std::string& perf)
        : sc_module(name), cfg(config), rp_count(planes), stress(pressure), replay(errors),
          corrupt_expected(negative), perf_dir(perf),
          // 胶水与链路模型之间的通道深度（帧）。取 1 时胶水的 ready 基本跟随链路节奏，
          // 接近真实 D2D Adapter 在 FDI 上的 pl_trdy；帧周期短于两拍（x16 PAM4）时需取 2。
          soc_tx("soc_tx", FL_FDI_DEPTH), soc_rx("soc_rx", FL_FDI_DEPTH),
          mem_tx("mem_tx", FL_FDI_DEPTH), mem_rx("mem_rx", FL_FDI_DEPTH),
          dut("dut"), soc_bridge("soc_bridge"), mem_bridge("mem_bridge"),
          soc_adapter("soc_adapter", cfg), mem_adapter("mem_adapter", cfg, BusinessKind::Response),
          link("link", cfg, &stats, sc_time(cfg.ui_fs(), SC_FS)), csv(prefix + ".csv") {
        if (!csv) throw std::runtime_error("cannot open transaction CSV");
        bind_dut();
        soc_bridge.from_adapter(a_soc_rx); soc_bridge.to_adapter_ready(a_soc_rxr);
        soc_bridge.to_adapter(a_soc_tx); soc_bridge.from_adapter_ready(a_soc_txr);
        soc_bridge.rtl_rx_valid(s_rxv); soc_bridge.rtl_rx_data(s_rxd); soc_bridge.rtl_rx_ready(s_rxr);
        soc_bridge.rtl_tx_valid(s_txv); soc_bridge.rtl_tx_data(s_txd); soc_bridge.rtl_tx_ready(s_txr);
        mem_bridge.from_adapter(a_mem_rx); mem_bridge.to_adapter_ready(a_mem_rxr);
        mem_bridge.to_adapter(a_mem_tx); mem_bridge.from_adapter_ready(a_mem_txr);
        mem_bridge.rtl_rx_valid(t_rxv); mem_bridge.rtl_rx_data(t_rxd); mem_bridge.rtl_rx_ready(t_rxr);
        mem_bridge.rtl_tx_valid(t_txv); mem_bridge.rtl_tx_data(t_txd); mem_bridge.rtl_tx_ready(t_txr);
        soc_adapter.clk(clk); soc_adapter.rst_n(rst); soc_adapter.link_state(state);
        soc_adapter.tx(a_soc_tx); soc_adapter.tx_ready(a_soc_txr); soc_adapter.rx(a_soc_rx); soc_adapter.rx_ready(a_soc_rxr);
        soc_adapter.fifo_tx(soc_tx); soc_adapter.fifo_rx(soc_rx);
        mem_adapter.clk(clk); mem_adapter.rst_n(rst); mem_adapter.link_state(state);
        mem_adapter.tx(a_mem_tx); mem_adapter.tx_ready(a_mem_txr); mem_adapter.rx(a_mem_rx); mem_adapter.rx_ready(a_mem_rxr);
        mem_adapter.fifo_tx(mem_tx); mem_adapter.fifo_rx(mem_rx);
        link.soc_tx_in(soc_tx); link.soc_rx_out(soc_rx); link.mem_tx_in(mem_tx); link.mem_rx_out(mem_rx);
        link.link_state(state);
        csv << "time_ns,channel,id,address,beat,last,resp\n";
        SC_THREAD(stimulus);
        SC_THREAD(monitor); sensitive << clk.posedge_event();
        SC_THREAD(drivers); sensitive << clk.negedge_event();
        SC_METHOD(link_up_follow); sensitive << state;
    }

    void bind_dut() {
        dut.clk(clk); dut.rst_n(rst); dut.link_up(link_up); dut.tb_case(tb_case);
        dut.s_axi_awvalid(awv); dut.s_axi_awready(awr); dut.s_axi_awaddr(awaddr); dut.s_axi_awid(awid);
        dut.s_axi_awlen(awlen); dut.s_axi_awsize(awsize); dut.s_axi_awburst(awburst); dut.s_axi_awprot(awprot);
        dut.s_axi_awcache(awcache); dut.s_axi_awqos(awqos); dut.s_axi_awlock(awlock); dut.s_axi_awuser(awuser);
        dut.s_axi_wvalid(wv); dut.s_axi_wready(wr); dut.s_axi_wdata(wdata); dut.s_axi_wstrb(wstrb);
        dut.s_axi_wlast(wlast); dut.s_axi_wuser(wuser);
        dut.s_axi_arvalid(arv); dut.s_axi_arready(arr); dut.s_axi_araddr(araddr); dut.s_axi_arid(arid);
        dut.s_axi_arlen(arlen); dut.s_axi_arsize(arsize); dut.s_axi_arburst(arburst); dut.s_axi_arprot(arprot);
        dut.s_axi_arcache(arcache); dut.s_axi_arqos(arqos); dut.s_axi_arlock(arlock); dut.s_axi_aruser(aruser);
        dut.s_axi_bvalid(bv_); dut.s_axi_bready(br); dut.s_axi_bid(bid); dut.s_axi_bresp(bresp); dut.s_axi_buser(buser);
        dut.s_axi_rvalid(rv); dut.s_axi_rready(rr); dut.s_axi_rdata(rdata); dut.s_axi_rid(rid);
        dut.s_axi_rresp(rresp); dut.s_axi_rlast(rlast); dut.s_axi_ruser(ruser);
        dut.soc_flit_tx_valid(s_txv); dut.soc_flit_tx_ready(s_txr); dut.soc_flit_tx_data(s_txd);
        dut.soc_flit_rx_valid(s_rxv); dut.soc_flit_rx_ready(s_rxr); dut.soc_flit_rx_data(s_rxd);
        dut.soc_error(soc_err);
        dut.tgt_flit_tx_valid(t_txv); dut.tgt_flit_tx_ready(t_txr); dut.tgt_flit_tx_data(t_txd);
        dut.tgt_flit_rx_valid(t_rxv); dut.tgt_flit_rx_ready(t_rxr); dut.tgt_flit_rx_data(t_rxd);
        dut.tgt_error(tgt_err);
        dut.mc_rd_valid(rd_v); dut.mc_rd_ready(rd_r); dut.mc_rd_tag(rd_tag); dut.mc_rd_rp(rd_rp); dut.mc_rd_id(rd_id);
        dut.mc_rd_addr(rd_addr); dut.mc_rd_size(rd_size); dut.mc_rd_len(rd_len); dut.mc_rd_beat(rd_beat);
        dut.mc_rd_first(rd_first); dut.mc_rd_last(rd_last); dut.mc_rd_prot(rd_prot); dut.mc_rd_cache(rd_cache);
        dut.mc_rd_qos(rd_qos); dut.mc_rd_lock(rd_lock); dut.mc_rd_user(rd_user);
        dut.mc_rd_rsp_valid(rdr_v); dut.mc_rd_rsp_ready(rdr_r); dut.mc_rd_rsp_tag(rdr_tag);
        dut.mc_rd_rsp_data(rdr_data); dut.mc_rd_rsp_resp(rdr_resp);
        dut.mc_wr_valid(wr_v); dut.mc_wr_ready(wr_r); dut.mc_wr_tag(wr_tag); dut.mc_wr_rp(wr_rp); dut.mc_wr_id(wr_id);
        dut.mc_wr_addr(wr_addr); dut.mc_wr_size(wr_size); dut.mc_wr_len(wr_len); dut.mc_wr_beat(wr_beat);
        dut.mc_wr_first(wr_first); dut.mc_wr_last(wr_last); dut.mc_wr_prot(wr_prot); dut.mc_wr_cache(wr_cache);
        dut.mc_wr_qos(wr_qos); dut.mc_wr_lock(wr_lock); dut.mc_wr_user(wr_user); dut.mc_wr_wuser(wr_wuser);
        dut.mc_wr_data(wr_data); dut.mc_wr_strb(wr_strb);
        dut.mc_wr_rsp_valid(wrr_v); dut.mc_wr_rsp_ready(wrr_r); dut.mc_wr_rsp_tag(wrr_tag); dut.mc_wr_rsp_resp(wrr_resp);
        dut.dbg_tgt_credit_wait(credit_wait);
    }

    // RTL 的 link_up 跟随链路训练状态（Active/Degraded）。
    void link_up_follow() {
        const auto s = static_cast<LinkState>(state.read());
        link_up.write(s == LinkState::Active || s == LinkState::Degraded);
    }

private:
    struct WriteCtx { AxChannel a; unsigned beat = 0; };
    struct McPending { unsigned tag; uint8_t resp; uint64_t due, seq; uint8_t data[BYTES]; };
    std::deque<WriteCtx> wctx_;
    std::map<unsigned, std::deque<BChannel>> expect_b_;
    std::map<unsigned, std::deque<RChannel>> expect_r_;
    std::map<uint64_t, uint8_t> reference_;
    std::vector<uint8_t> storage_ = std::vector<uint8_t>(MEM_SIZE, 0);
    std::vector<McPending> rd_pend_, wr_pend_;
    std::mt19937 stim_rng_{0xA012};
    unsigned hold_r_ = 0, hold_b_ = 0;
    bool random_ready_ = false;
    uint64_t seq_ = 0, next_rd_ok_ = 0, next_wr_ok_ = 0;
    unsigned mc_latency_ = 10;
    // 事务延迟：读为 AR 握手到最后一个 R，写为最后一个 W 到 B（含链路与 MC）。
    std::map<unsigned, std::deque<uint64_t>> ar_t_, wl_t_;
    uint64_t rd_lat_sum_ = 0, rd_lat_n_ = 0, rd_lat_max_ = 0, wr_lat_sum_ = 0, wr_lat_n_ = 0, wr_lat_max_ = 0;
    // 空载延迟测量：依次等待 8 个事件，记录各自的周期。-1 未启用，-2 完成。
    int probe_step_ = -1;
    bool probe_write_ = false;
    uint64_t probe_t_[8] = {};
    static bool has_msg(const bv<2000>& v) { return bits_flit(v).msg_start != 0; }
    void probe_edge() {
        const bool w = probe_write_;
        bool ev = false;
        switch (probe_step_) {
        case 0: ev = w ? wv.read() && wr.read() && wlast.read() : arv.read() && arr.read(); break;   // AXI 请求/最后一拍写数据
        case 1: ev = s_txv.read() && s_txr.read() && has_msg(s_txd.read()); break;                   // SoC 桥送出帧
        case 2: ev = t_rxv.read() && t_rxr.read() && has_msg(t_rxd.read()); break;                   // 存储侧桥收到帧
        case 3: ev = w ? wr_v.read() && wr_r.read() : rd_v.read() && rd_r.read(); break;             // MC 命令握手
        case 4: ev = w ? wrr_v.read() && wrr_r.read() : rdr_v.read() && rdr_r.read(); break;         // MC 完成握手
        case 5: ev = t_txv.read() && t_txr.read() && has_msg(t_txd.read()); break;                   // 存储侧桥送出响应帧
        case 6: ev = s_rxv.read() && s_rxr.read() && has_msg(s_rxd.read()); break;                   // SoC 桥收到响应帧
        case 7: ev = w ? bv_.read() && br.read() : rv.read() && rr.read() && rlast.read(); break;    // AXI 响应握手
        }
        if (!ev) return;
        probe_t_[probe_step_] = cycle;
        probe_step_ = probe_step_ == 7 ? -2 : probe_step_ + 1;
    }

    void check(bool ok, const std::string& what) {
        if (ok) return;
        ++failures;
        if (failures <= 20) std::cerr << "[FAIL] " << sc_time_stamp() << " " << what << "\n";
    }
    void tick() { wait(clk.negedge_event()); }
    void cycles(unsigned n) { while (n--) tick(); }
    template <class P> void until(P p, const char* what, unsigned limit = 400000) {
        for (unsigned n = 0; n < limit; ++n) { if (p()) return; tick(); }
        throw std::runtime_error(what);
    }
    static unsigned status(const AxChannel& a) {
        const uint64_t len = (uint64_t(a.len) + 1) << a.size;
        if (a.addr < BASE || a.addr - BASE >= MEM_SIZE || len > MEM_SIZE - (a.addr - BASE)) return 3;
        return a.lock ? 2 : 0;
    }
    static uint64_t u64(const bv<64>& v) { return v.to_uint64(); }

    // 上升沿：AXI 握手更新记分板，MC 命令与完成在 MC 模型中处理。
    void monitor() {
        while (true) {
            wait();
            ++cycle;
            if (!rst.read()) continue;
            check(!soc_err.read() && !tgt_err.read(), "RTL protocol_error asserted");
            if (credit_wait.read()) ++credit_wait_cycles;
            b_stalls += bv_.read() && !br.read();
            r_stalls += rv.read() && !rr.read();
            if (awv.read() && awr.read()) {
                AxChannel a;
                a.id = uint16_t(awid.read().to_uint()); a.addr = u64(awaddr.read()); a.len = uint8_t(awlen.read().to_uint());
                a.size = uint8_t(awsize.read().to_uint()); a.lock = awlock.read(); a.user = uint16_t(awuser.read().to_uint());
                wctx_.push_back({a, 0}); ++aw_count;
                csv << sc_time_stamp().to_seconds() * 1e9 << ",AW," << a.id << ",0x" << std::hex << a.addr << std::dec << ",0,0,0\n";
            }
            if (wv.read() && wr.read()) {
                ++w_count;
                if (wctx_.empty()) { check(false, "W without AW"); continue; }
                auto& c = wctx_.front();
                uint8_t d[BYTES], s[BYTES];
                to_bytes<FL_DATA_WIDTH>(wdata.read(), d);
                for (unsigned j = 0; j < BYTES; ++j) s[j] = wstrb.read()[j].to_bool();
                if (!status(c.a)) {
                    const uint64_t addr = c.a.addr + (uint64_t(c.beat) << c.a.size);
                    const uint64_t bus = addr & ~uint64_t(BYTES - 1);
                    for (unsigned j = 0; j < BYTES; ++j) if (s[j]) reference_[bus + j] = d[j];
                }
                if (++c.beat > c.a.len) {
                    wl_t_[c.a.id].push_back(cycle);
                    BChannel e; e.id = c.a.id; e.user = c.a.user; e.resp = uint8_t(status(c.a));
                    expect_b_[e.id].push_back(e);
                    wctx_.pop_front();
                }
            }
            if (arv.read() && arr.read()) {
                AxChannel a;
                a.id = uint16_t(arid.read().to_uint()); a.addr = u64(araddr.read()); a.len = uint8_t(arlen.read().to_uint());
                a.size = uint8_t(arsize.read().to_uint()); a.lock = arlock.read(); a.user = uint16_t(aruser.read().to_uint());
                ++ar_count; ar_t_[a.id].push_back(cycle);
                csv << sc_time_stamp().to_seconds() * 1e9 << ",AR," << a.id << ",0x" << std::hex << a.addr << std::dec << ",0,0,0\n";
                for (unsigned n = 0; n <= a.len; ++n) {
                    RChannel e; e.id = a.id; e.user = a.user; e.last = n == a.len; e.resp = uint8_t(status(a));
                    const uint64_t addr = a.addr + (uint64_t(n) << a.size);
                    const unsigned size = 1u << a.size, n_chunk = size <= 32 ? 32 : size;
                    const unsigned lane = unsigned(addr % BYTES), base = lane / n_chunk * n_chunk;
                    uint8_t chunk[BYTES] = {};
                    if (!e.resp) for (unsigned j = 0; j < size; ++j) chunk[lane - base + j] = reference_[addr + j];
                    // SoC 桥把窄读数据复制到整条总线。
                    for (unsigned j = 0; j < BYTES; ++j) e.data[j] = chunk[j % n_chunk];
                    if (corrupt_expected) { e.data[lane] ^= 1; corrupt_expected = false; }
                    expect_r_[a.id].push_back(e);
                }
            }
            if (bv_.read() && br.read()) {
                ++b_count;
                const unsigned id = bid.read().to_uint();
                if (!wl_t_[id].empty()) {
                    const uint64_t l = cycle - wl_t_[id].front(); wl_t_[id].pop_front();
                    wr_lat_sum_ += l; ++wr_lat_n_; wr_lat_max_ = std::max(wr_lat_max_, l);
                }
                auto& q = expect_b_[id];
                check(!q.empty(), "unexpected B id=" + std::to_string(id));
                if (!q.empty()) {
                    check(q.front().resp == bresp.read().to_uint() && q.front().user == buser.read().to_uint(),
                          "B RESP/USER mismatch id=" + std::to_string(id));
                    q.pop_front();
                }
            }
            if (rv.read() && rr.read()) {
                ++r_count;
                const unsigned id = rid.read().to_uint();
                auto& q = expect_r_[id];
                check(!q.empty(), "unexpected R id=" + std::to_string(id));
                if (!q.empty()) {
                    const RChannel e = q.front(); q.pop_front();
                    uint8_t d[BYTES]; to_bytes<FL_DATA_WIDTH>(rdata.read(), d);
                    check(e.resp == rresp.read().to_uint() && e.last == rlast.read() && e.user == ruser.read().to_uint(),
                          "R RESP/LAST/USER mismatch id=" + std::to_string(id));
                    if (!e.resp) check(std::equal(d, d + BYTES, e.data), "R data mismatch id=" + std::to_string(id));
                    if (e.last) {
                        ++read_done;
                        if (!ar_t_[id].empty()) {
                            const uint64_t l = cycle - ar_t_[id].front(); ar_t_[id].pop_front();
                            rd_lat_sum_ += l; ++rd_lat_n_; rd_lat_max_ = std::max(rd_lat_max_, l);
                        }
                    }
                }
            }
            if (probe_step_ >= 0) probe_edge();
            mc_edge();
        }
    }

    // MC 模型：读写分口，按 latency 拍返回完成；压力模式加入背压和乱序。
    uint8_t mc_access(bool write, uint64_t addr, unsigned size_code, unsigned beat, const AxChannel& meta,
                      const uint8_t* wd, const uint8_t* ws, uint8_t* rd) {
        AxChannel burst = meta; burst.size = uint8_t(size_code);
        burst.addr = addr - (uint64_t(beat) << size_code);
        uint8_t st = uint8_t(status(burst));
        const unsigned size = 1u << size_code, lane = unsigned(addr % BYTES);
        if (write) for (unsigned j = 0; j < BYTES; ++j) if (ws[j] && (j < lane || j >= lane + size)) st = 2;
        if (st) return st;
        for (unsigned j = 0; j < size; ++j) {
            uint8_t& b = storage_[addr - BASE + j];
            if (write) { if (ws[lane + j]) b = wd[lane + j]; } else rd[lane + j] = b;
        }
        return 0;
    }
    void mc_edge() {
        auto settle = [&](std::vector<McPending>& list, bool fired, int shown) {
            if (shown < 0 || !fired) return;
            for (const auto& p : list) if (p.seq < list[shown].seq) { ++mc_ooo; break; }
            list.erase(list.begin() + shown);
        };
        settle(rd_pend_, rdr_v.read() && rdr_r.read(), rd_shown_);
        settle(wr_pend_, wrr_v.read() && wrr_r.read(), wr_shown_);
        auto lat = [&] { return cycle + (stress ? mc_latency_ + (mc_cmds * 7) % 23 : mc_latency_); };
        if (rd_v.read() && rd_r.read()) {
            McPending p{}; p.tag = rd_tag.read().to_uint(); p.seq = seq_++; ++mc_cmds; ++mc_rd_cmds;
            AxChannel meta; meta.len = uint8_t(rd_len.read().to_uint()); meta.lock = rd_lock.read();
            p.resp = mc_access(false, u64(rd_addr.read()), rd_size.read().to_uint(), rd_beat.read().to_uint(), meta,
                               nullptr, nullptr, p.data);
            p.due = lat(); rd_pend_.push_back(p); next_rd_ok_ = cycle + 1;
        }
        if (wr_v.read() && wr_r.read()) {
            McPending p{}; p.tag = wr_tag.read().to_uint(); p.seq = seq_++; ++mc_cmds; ++mc_wr_cmds;
            AxChannel meta; meta.len = uint8_t(wr_len.read().to_uint()); meta.lock = wr_lock.read();
            uint8_t d[BYTES], s[BYTES];
            to_bytes<FL_DATA_WIDTH>(wr_data.read(), d);
            for (unsigned j = 0; j < BYTES; ++j) s[j] = wr_strb.read()[j].to_bool();
            p.resp = mc_access(true, u64(wr_addr.read()), wr_size.read().to_uint(), wr_beat.read().to_uint(), meta, d, s, nullptr);
            p.due = lat(); wr_pend_.push_back(p); next_wr_ok_ = cycle + 1;
        }
    }
    int rd_shown_ = -1, wr_shown_ = -1;

    // 下降沿：驱动 AXI 响应背压与 MC 输出，保证下一个上升沿采样稳定。
    void drivers() {
        std::mt19937 rng(0xB031);
        br.write(false); rr.write(false); rd_r.write(false); wr_r.write(false); rdr_v.write(false); wrr_v.write(false);
        while (true) {
            wait();
            if (!rst.read()) continue;
            br.write(!hold_b_ && (!random_ready_ || rng() % 4 != 0));
            rr.write(!hold_r_ && (!random_ready_ || rng() % 3 != 0));
            if (hold_b_) --hold_b_;
            if (hold_r_) --hold_r_;
            rd_r.write(!stress || cycle % 9 >= 3);
            wr_r.write(!stress || cycle % 7 >= 2);
            auto pick = [&](std::vector<McPending>& list) {
                int s = -1;
                for (unsigned i = 0; i < list.size(); ++i) if (list[i].due <= cycle) { s = int(i); if (!stress) break; }
                return s;
            };
            rd_shown_ = pick(rd_pend_); wr_shown_ = pick(wr_pend_);
            rdr_v.write(rd_shown_ >= 0); wrr_v.write(wr_shown_ >= 0);
            if (rd_shown_ >= 0) {
                const auto& p = rd_pend_[rd_shown_];
                rdr_tag.write(p.tag); rdr_resp.write(p.resp); rdr_data.write(from_bytes<FL_DATA_WIDTH>(p.data));
            }
            if (wr_shown_ >= 0) { const auto& p = wr_pend_[wr_shown_]; wrr_tag.write(p.tag); wrr_resp.write(p.resp); }
        }
    }

    // ---------------- 激励 ----------------
    AxChannel address(uint16_t id, uint64_t offset, unsigned beats, unsigned size = AXI_SIZE_CODE) {
        AxChannel a; a.id = id; a.addr = BASE + offset; a.len = uint8_t(beats - 1);
        a.size = uint8_t(size); a.qos = uint8_t(id % rp_count); a.user = uint16_t(0xA000 | id); a.burst = 1;
        return a;
    }
    void drive_ax(const AxChannel& a, bool read) {
        auto& addr = read ? araddr : awaddr; auto& id = read ? arid : awid; auto& len = read ? arlen : awlen;
        auto& size = read ? arsize : awsize; auto& burst = read ? arburst : awburst; auto& qos = read ? arqos : awqos;
        auto& user = read ? aruser : awuser; auto& lock = read ? arlock : awlock;
        addr.write(a.addr); id.write(a.id); len.write(a.len); size.write(a.size); burst.write(a.burst);
        qos.write(a.qos); user.write(a.user); lock.write(a.lock);
        (read ? arprot : awprot).write(a.prot); (read ? arcache : awcache).write(a.cache);
    }
    void send_address(const AxChannel& a, bool read) {
        const uint64_t before = read ? ar_count : aw_count;
        drive_ax(a, read); (read ? arv : awv).write(true);
        until([&] { return (read ? ar_count : aw_count) > before; }, "AXI address timeout");
        (read ? arv : awv).write(false);
    }
    void send_data(const AxChannel& a, unsigned salt, unsigned mask = 0, bool gaps = false) {
        for (unsigned n = 0; n <= a.len; ++n) {
            if (gaps) cycles(stim_rng_() % 4);
            const uint64_t addr = a.addr + (uint64_t(n) << a.size);
            const unsigned lane = unsigned(addr % BYTES);
            uint8_t d[BYTES], s[BYTES];
            for (unsigned j = 0; j < BYTES; ++j) {
                d[j] = uint8_t(salt + n * 37 + j * 13 + (j >> 3));
                s[j] = j >= lane && j < lane + (1u << a.size) && (mask == 0 || (mask == 1 && j % 3 != 1));
            }
            wdata.write(from_bytes<FL_DATA_WIDTH>(d)); wstrb.write(from_bits<FL_DATA_WIDTH / 8>(s));
            wlast.write(n == a.len); wuser.write(0x5100 | n);
            const auto before = w_count; wv.write(true);
            until([&] { return w_count > before; }, "AXI W timeout");
            wv.write(false);
        }
    }
    void drain() {
        until([&] {
            if (!wctx_.empty()) return false;
            for (auto& p : expect_b_) if (!p.second.empty()) return false;
            for (auto& p : expect_r_) if (!p.second.empty()) return false;
            return b_count == aw_count;
        }, "AXI response timeout");
    }
    void write_read(AxChannel a, unsigned salt, unsigned mask = 0, bool gaps = false) {
        send_address(a, false); send_data(a, salt, mask, gaps); drain();
        send_address(a, true); drain();
    }
    bool selected(unsigned id) const {
        return only_cases.empty() ? (id < FIRST_PERF_CASE || run_perf)
                                  : std::find(only_cases.begin(), only_cases.end(), id) != only_cases.end();
    }
    template <class Body> void run_case(unsigned id, const char*, Body body) {
        if (!selected(id)) return;
        tb_case.write(id);
        tick(); const unsigned before = failures;
        const uint64_t c0 = cycle, aw0 = aw_count, w0 = w_count, ar0 = ar_count, r0 = r_count;
        rd_lat_sum_ = rd_lat_n_ = rd_lat_max_ = wr_lat_sum_ = wr_lat_n_ = wr_lat_max_ = 0;
        body(); drain(); cycles(4); ++cases;
        auto avg = [](uint64_t s, uint64_t n) { return n ? 2.0 * s / n : 0.0; };
        rows.push_back({id, before == failures, double(cycle - c0) * 2, aw_count - aw0, w_count - w0,
                        ar_count - ar0, r_count - r0, avg(rd_lat_sum_, rd_lat_n_), 2.0 * rd_lat_max_,
                        avg(wr_lat_sum_, wr_lat_n_), 2.0 * wr_lat_max_});
        if (before != failures) std::cerr << "[FAIL] TC" << id << " " << case_title(id) << "\n";
        tb_case.write(0);
    }
    // 空载延迟分解：链路空闲时各发一笔单拍读、单拍写，记录请求经过每个边界的时刻。
    // 写先发 AW、等写请求越过链路后再发 W，使测量从写数据开始。
    void latency_probe() {
        tb_case.write(CASE_PROBE);
        const unsigned saved = mc_latency_; mc_latency_ = 10;
        probe_write_ = false; probe_step_ = 0;
        send_address(address(250, 0x1E000, 1), true); drain();
        until([&] { return probe_step_ == -2; }, "latency probe (read) timeout");
        std::copy(probe_t_, probe_t_ + 8, probe_rd);
        cycles(50);
        const auto a = address(251, 0x1E000, 1);
        send_address(a, false); cycles(50);
        probe_write_ = true; probe_step_ = 0;
        send_data(a, 0x77); drain();
        until([&] { return probe_step_ == -2; }, "latency probe (write) timeout");
        std::copy(probe_t_, probe_t_ + 8, probe_wr);
        probe_step_ = -1; probe_done = true; mc_latency_ = saved;
        cycles(50); tb_case.write(0);
    }
    void functional() {
        random_ready_ = stress;
        if (!stress) latency_probe();
        run_case(1, "zero-initialized read", [&] { send_address(address(1, 0, 1), true); });
        run_case(2, "single-beat write/read", [&] { write_read(address(2, 0x1000, 1), 0x31); });
        run_case(3, "burst 2/4/16 and full-width 4KB limit", [&] {
            for (unsigned count : {2u, 4u, 16u, 4096u / BYTES}) write_read(address(3, 0x2000, count), count);
        });
        run_case(4, "masked and zero-strobe overwrite", [&] {
            auto a = address(4, 0x3000, 4);
            write_read(a, 0x11); write_read(a, 0x89, 1); write_read(a, 0xE1, 2);
        });
        run_case(5, "narrow 4-byte burst with lane rotation", [&] {
            write_read(address(5, 0x4004, 16, 2), 0x53, 1, true);
            send_address(address(5, 0x4000, 4), true);
        });
        run_case(6, "maximum AXI 256-beat burst", [&] { write_read(address(6, 0x5000, 256, 2), 0xAB); });
        run_case(7, "burst ends exactly at 4KB", [&] { write_read(address(7, 0x8000 - 4 * BYTES, 4), 0xD1); });
        run_case(8, "out-of-range DECERR", [&] {
            write_read(address(8, MEM_SIZE, 4), 0x22);
            auto high = address(8, 0x1000, 1); high.addr += 1ULL << 32; write_read(high, 0xF2);
        });
        run_case(9, "multiple AW, mixed outstanding reads/writes, multiple RP", [&] {
            std::vector<AxChannel> jobs;
            for (unsigned i = 0; i < 8; ++i) { jobs.push_back(address(32 + i, 0x9000 + i * 256, 2)); send_address(jobs.back(), false); }
            for (unsigned i = 0; i < 8; ++i) { send_address(address(64 + i, 0, 2), true); send_data(jobs[i], 0x60 + i, 0, true); }
            drain();
            for (auto a : jobs) send_address(a, true);
        });
        run_case(10, "same-ID read/write response ordering", [&] {
            for (unsigned i = 0; i < 6; ++i) { auto a = address(100, 0xB000 + i * 256, 2); send_address(a, false); send_data(a, 11 + i); }
            drain();
            for (unsigned i = 0; i < 6; ++i) send_address(address(100, 0xB000 + i * 256, 2), true);
        });
        run_case(11, "long B/R backpressure and credit recovery", [&] {
            hold_b_ = 800; hold_r_ = 1800; random_ready_ = true;
            const unsigned count = 4096 / BYTES;
            for (unsigned i = 0; i < 4; ++i) {
                auto a = address(120 + i * rp_count, 0xC000 + i * 4096, count); send_address(a, false); send_data(a, 0x40 + i);
            }
            drain();
            hold_r_ = 3000;
            for (unsigned i = 0; i < 4; ++i) send_address(address(120 + i * rp_count, 0xC000 + i * 4096, count), true);
            drain(); random_ready_ = stress;
        });
        run_case(12, "fixed-seed random legal bursts and strobes", [&] {
            for (unsigned i = 0; i < 24; ++i) {
                const unsigned beats = 1 + stim_rng_() % 16, page = 16 + stim_rng_() % 8;
                write_read(address(200 + i, page * 4096, beats), stim_rng_(), i % 3, true);
            }
        });
    }

    // 吞吐：RP0、固定突发长度，读写可同时；读按 R 字节、写按 B 突发计。
    // 另按 2 µs 窗口统计带宽的最小、最大值，用来说明满载期间是否稳定。
    void performance(unsigned id, const std::string& dir) {
        if (!selected(id)) return;
        tb_case.write(id);
        const bool rd = dir == "read" || dir == "mixed", wt = dir == "write" || dir == "mixed";
        const unsigned saved = mc_latency_; mc_latency_ = 10;
        unsigned rseq = 0, wseq = 0;
        std::deque<std::pair<AxChannel, unsigned>> wq;
        auto pump = [&](bool accept) {
            if (wt) {
                const auto a = address(uint16_t(wseq % 32), 0x10000, perf_burst);
                drive_ax(a, false); awv.write(accept && wq.size() < 8);
                wv.write(!wq.empty());
                if (!wq.empty()) {
                    const auto& c = wq.front();
                    uint8_t d[BYTES], s[BYTES];
                    for (unsigned j = 0; j < BYTES; ++j) { d[j] = uint8_t(c.first.id * 17 + c.second * 29 + j * 7); s[j] = 1; }
                    wdata.write(from_bytes<FL_DATA_WIDTH>(d)); wstrb.write(from_bits<FL_DATA_WIDTH / 8>(s));
                    wlast.write(c.second == c.first.len); wuser.write(0x5100 + c.second);
                }
            }
            if (rd) { drive_ax(address(uint16_t(32 + rseq % 32), 0, perf_burst), true); arv.write(accept); }
            const auto aw0 = aw_count, w0 = w_count, ar0 = ar_count;
            tick();
            if (w_count > w0 && ++wq.front().second > wq.front().first.len) wq.pop_front();
            if (aw_count > aw0) { wq.push_back({address(uint16_t(wseq % 32), 0x10000, perf_burst), 0}); ++wseq; }
            if (ar_count > ar0) ++rseq;
        };
        for (unsigned n = 0; n < perf_warmup; ++n) pump(true);
        const auto r0 = r_count, b0 = b_count, c0 = cycle, cw0 = credit_wait_cycles;
        const auto f0 = stats.forward.tx_new_flits, v0 = stats.reverse.tx_new_flits;
        constexpr unsigned WIN = 1000;
        double rmin = 1e9, rmax = 0, wmin = 1e9, wmax = 0;
        uint64_t wr0 = r_count, ww0 = w_count;
        for (unsigned n = 1; n <= perf_cycles; ++n) {
            pump(true);
            if (n % WIN == 0) {
                const double rg = double(r_count - wr0) * BYTES / (WIN * 2), wg = double(w_count - ww0) * BYTES / (WIN * 2);
                rmin = std::min(rmin, rg); rmax = std::max(rmax, rg); wmin = std::min(wmin, wg); wmax = std::max(wmax, wg);
                wr0 = r_count; ww0 = w_count;
            }
        }
        const double ns = double(cycle - c0) * 2;
        const double rgb = double(r_count - r0) * BYTES / ns, wgb = double(b_count - b0) * BYTES * perf_burst / ns;
        const auto ff = stats.forward.tx_new_flits - f0, rf = stats.reverse.tx_new_flits - v0;
        const auto cw = credit_wait_cycles - cw0;
        awv.write(false); arv.write(false);
        while (!wq.empty()) pump(false);
        wv.write(false);
        drain(); cycles(4);
        mc_latency_ = saved;
        perf_rows.push_back({id, dir, ns, rd ? rgb : 0, wt ? wgb : 0, rd ? rmin : 0, rmax, wt ? wmin : 0, wmax, ff, rf, cw});
        if (!perf_dir.empty()) {   // 兼容脚本：--perf 模式额外输出一行机器可读结果
            std::cout << std::fixed << std::setprecision(4) << "FULL_LINK_PERF " << dir << " width=" << AXI_DATA_WIDTH
                      << " burst=" << perf_burst << " duration_ns=" << ns;
            if (rd) std::cout << " read_GBps=" << rgb;
            if (wt) std::cout << " write_GBps=" << wgb;
            std::cout << " forward_flits=" << ff << " reverse_flits=" << rf
                      << " link_flit_GBps=" << LINK_BYTES_PER_NS << " target_credit_wait_cycles=" << cw << "\n";
        }
        tb_case.write(0);
    }

    void stimulus() {
        try {
            rst.write(false); awv.write(false); arv.write(false); wv.write(false);
            until([&] { return state.read() == unsigned(LinkState::Active); }, "link training timeout");
            cycles(2); rst.write(true); cycles(100);
            functional();
            performance(13, "read"); performance(14, "write"); performance(15, "mixed");
            until([&] { return !soc_tx.num_available() && !soc_rx.num_available() &&
                               !mem_tx.num_available() && !mem_rx.num_available() &&
                               rd_pend_.empty() && wr_pend_.empty(); }, "link drain timeout");
            cycles(1000);
            for (const auto& [addr, byte] : reference_)
                if (addr >= BASE && addr - BASE < MEM_SIZE && storage_[addr - BASE] != byte) {
                    check(false, "reference and MC storage differ"); break;
                }
            if (only_cases.empty()) {
                check(b_stalls > 0 && r_stalls > 0, "backpressure coverage missing");
                if (stress) check(mc_ooo > 0, "MC out-of-order completion not exercised");
            }
            if (replay) check(stats.forward.crc_fail_count + stats.reverse.crc_fail_count > 0 &&
                              stats.forward.tx_replay_flits + stats.reverse.tx_replay_flits > 0,
                              "requested CRC/replay coverage missing");
            else check(stats.forward.crc_fail_count + stats.reverse.crc_fail_count == 0, "unexpected CRC error");
        } catch (const std::exception& e) {
            check(false, e.what());
        }
        done = true; csv.flush(); sc_stop();
    }
};

// ---------------- 汇总报告 ----------------
// 中文按显示宽度对齐：汉字占 2 列。
static std::string pad(const std::string& t, int width) {
    int cols = 0;
    for (unsigned char c : t) { if (c < 0x80) ++cols; else if ((c & 0xC0) != 0x80) cols += 2; }
    return t + std::string(std::max(0, width - cols), ' ');
}
static std::string fmt(const char* f, double a, double b = 0) {
    char buf[64]; std::snprintf(buf, sizeof buf, f, a, b); return buf;
}

static void report(const FullLinkRtlTb& tb, const Config& cfg, bool stress, bool replay, double wall_s) {
    const double raw = cfg.num_lanes * cfg.lane_rate_gtps * cfg.bits_per_ui() / 8;   // GB/s
    const double payload = raw * 240 / 256;   // 扣除 Flit 头、CRC 与协议头后的消息区带宽
    const double port = BYTES / 2.0;          // AXI 端口带宽：每拍 BYTES 字节，2 ns 一拍
    auto u = [](uint64_t v) { return (unsigned long long)v; };
    std::printf("\n============ 全链路仿真  DATA_WIDTH=%u  RP=%u%s%s ============\n", AXI_DATA_WIDTH, FL_RP_COUNT,
                stress ? "  压力模式" : "", replay ? "  CRC 错误注入 2%" : "");
    std::printf("配置  x%u @ %.0f GT/s %s，消息区 %.0f GB/s；深度 RDATA/WRESP %d/%d，WREQ/RREQ/WDATA %d/%d/%d；MC_SLOTS %d，MC 延迟 10 拍\n",
                cfg.num_lanes, cfg.lane_rate_gtps, cfg.bits_per_ui() == 2 ? "PAM4" : "NRZ", payload, FL_RDATA_DEPTH, FL_WRESP_DEPTH,
                FL_WREQ_DEPTH, FL_RREQ_DEPTH, FL_WDATA_DEPTH, FL_MC_SLOTS);

    if (!tb.rows.empty()) {
        std::printf("%s%s%s%s%s%s\n", pad("用例", 36).c_str(), pad("用时ns", 9).c_str(), pad("写 笔/拍", 11).c_str(),
                    pad("读 笔/拍", 11).c_str(), pad("读延迟ns 均/大", 16).c_str(), "写延迟ns 均/大");
        for (const auto& r : tb.rows) {
            char wb[32], rb[32];
            std::snprintf(wb, sizeof wb, "%llu/%llu", u(r.aw), u(r.w));
            std::snprintf(rb, sizeof rb, "%llu/%llu", u(r.ar), u(r.r));
            std::printf("%s%s%s%s%s%s%s\n", pad("TC" + std::to_string(r.id) + " " + case_title(r.id), 36).c_str(),
                        pad(fmt("%.0f", r.ns), 9).c_str(), pad(wb, 11).c_str(), pad(rb, 11).c_str(),
                        pad(r.ar ? fmt("%.0f/%.0f", r.rd_avg, r.rd_max) : "-", 16).c_str(),
                        r.aw ? fmt("%.0f/%.0f", r.wr_avg, r.wr_max).c_str() : "-", r.pass ? "" : "  FAIL");
        }
    }

    double soc_lat = 0, tgt_lat = 0;
    if (tb.probe_done) {
        auto row = [&](const char* head, const char* name, const uint64_t* t) {
            auto d = [&](int a, int b) { return 2.0 * double(t[b] - t[a]); };
            std::printf("%s%s %3.0f ns = SoC发送 %.0f + 链路 %.0f + 存储侧请求 %.0f + MC %.0f + 存储侧返回 %.0f + 链路 %.0f + SoC接收 %.0f\n",
                        head, name, d(0, 7), d(0, 1), d(1, 2), d(2, 3), d(3, 4), d(4, 5), d(5, 6), d(6, 7));
            soc_lat = std::max(soc_lat, d(0, 1) + d(6, 7));
            tgt_lat = std::max(tgt_lat, d(2, 3) + d(4, 5));
        };
        row("延迟  ", "单拍读", tb.probe_rd);
        row("      ", "单拍写", tb.probe_wr);
    }

    double umin = 1e9;
    for (const auto& p : tb.perf_rows) {
        std::string t = p.dir == "read" ? "读" : p.dir == "write" ? "写" : "同时读写";
        if (p.rgb > 0 && p.wgb > 0)
            std::printf("%s%s %.2f / %.2f GB/s（窗口波动 %.2f～%.2f / %.2f～%.2f）\n", &p == &tb.perf_rows[0] ? "吞吐  " : "      ",
                        t.c_str(), p.rgb, p.wgb, p.rmin, p.rmax, p.wmin, p.wmax);
        else {
            const double g = p.rgb > 0 ? p.rgb : p.wgb;
            std::printf("%s%s %.2f GB/s（窗口波动 %.2f～%.2f）\n", &p == &tb.perf_rows[0] ? "吞吐  " : "      ",
                        t.c_str(), g, p.rgb > 0 ? p.rmin : p.wmin, p.rgb > 0 ? p.rmax : p.wmax);
        }
        if (p.rgb > 0) umin = std::min(umin, p.rgb / payload);
        if (p.wgb > 0) umin = std::min(umin, p.wgb / payload);
    }

    std::printf("指标  速率 %.0f GT/s", cfg.lane_rate_gtps);
    if (umin < 1e9) std::printf(" | 带宽利用率 %.1f%%%s", umin * 100,
                                port < payload ? fmt("（受 %.0f GB/s 端口限制）", port).c_str() : "");
    if (tb.probe_done) std::printf(" | 桥延迟 SoC 侧 %.0f ns、存储侧 %.0f ns", soc_lat, tgt_lat);
    std::printf("\n");
    std::printf("统计  写 %llu/%llu、读 %llu/%llu（笔/拍），MC 乱序 %llu，链路帧 %llu/%llu，CRC 错误 %llu，重传 %llu，数据错误 %u\n",
                u(tb.aw_count), u(tb.w_count), u(tb.ar_count), u(tb.r_count), u(tb.mc_ooo),
                u(tb.stats.forward.tx_new_flits), u(tb.stats.reverse.tx_new_flits),
                u(tb.stats.forward.crc_fail_count + tb.stats.reverse.crc_fail_count),
                u(tb.stats.forward.tx_replay_flits + tb.stats.reverse.tx_replay_flits), tb.failures);
    std::printf("用时  仿真 %.1f us，运行 %.1f s\n", tb.cycle * 2 / 1000.0, wall_s);
    if (tb.failures) std::printf("FAIL  %u 处错误，详见上方 [FAIL] 行\n", tb.failures);
}

int sc_main(int argc, char** argv) {
    unsigned rp = FL_RP_COUNT; bool stress = false, replay = false, negative = false;
    std::string perf, vcd;
    unsigned burst = 16, cycles = 20000;
    std::vector<unsigned> only; bool no_perf = false;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&] { if (i + 1 >= argc) throw std::runtime_error("missing value for " + a); return std::string(argv[++i]); };
        if (a == "--stress") stress = true;
        else if (a == "--replay") replay = true;
        else if (a == "--negative-scoreboard") negative = true;
        else if (a == "--rp") rp = unsigned(std::stoul(next()));
        else if (a == "--perf") perf = next();
        else if (a == "--burst") burst = unsigned(std::stoul(next()));
        else if (a == "--cycles") cycles = unsigned(std::stoul(next()));
        else if (a == "--vcd") vcd = next();
        else if (a == "--case") {
            std::stringstream ss(next()); std::string t;
            while (std::getline(ss, t, ',')) {
                const unsigned id = unsigned(std::stoul(t));
                if (!id || id > LAST_CASE) { std::cerr << "用例编号范围 1～" << LAST_CASE << "\n"; return 2; }
                only.push_back(id);
            }
        }
        else if (a == "--no-perf") no_perf = true;
        else if (a.rfind("+", 0) == 0) continue;   // 仿真器自身的 plusarg
        else if (a == "-l" || a == "-ucli") { ++i; continue; }   // VCS simv 的日志等带参数选项
        else if (a.size() > 1 && a[0] == '-' && a[1] != '-') continue;   // 其他 simv 单横线选项，如 -no_save
        else {
            const bool help = a == "--help";
            (help ? std::cout : std::cerr) << "usage: [--case N[,M..]] [--no-perf] [--stress] [--replay] [--negative-scoreboard]\n"
                         "       [--perf read|write|mixed] [--burst N] [--cycles N] [--vcd file]\n用例：\n";
            for (unsigned id = 1; id <= LAST_CASE; ++id) (help ? std::cout : std::cerr) << "  " << id << "  " << case_title(id) << "\n";
            return help ? 0 : 2;
        }
    }
    if (rp != FL_RP_COUNT) { std::cerr << "RP 数在编译期确定（FL_RP_COUNT=" << FL_RP_COUNT << "）\n"; return 2; }
    sc_set_time_resolution(1, SC_FS);
    sc_report_handler::set_actions("/OSCI/SystemC", SC_INFO, SC_DO_NOTHING);   // 不打印 sc_stop 的提示
    g_aou_verbose = false;
    Config cfg = make_aou_ucie_config();
    cfg.awgn_sigma = cfg.jitter_sigma_ui = cfg.isi_h1 = cfg.isi_h2 = 0;
    cfg.lane_skew_max_ui = 0; cfg.extra_flit_error_rate = replay ? 0.02 : 0.0;
    cfg.retry_buffer_size = stress ? 8 : 64;
    cfg.feedback_ui = stress ? 256 : 32;
    require_valid_config(cfg);
#ifndef FL_RESULTS_DIR
#define FL_RESULTS_DIR "results"
#endif
    const std::string prefix = std::string(FL_RESULTS_DIR) + "/full_link_rtl_" + std::to_string(AXI_DATA_WIDTH) + "_rp" + std::to_string(rp)
        + (stress ? "_stress" : "") + (replay ? "_replay" : "") + (perf.empty() ? "" : "_perf_" + perf);
    FullLinkRtlTb tb("tb", cfg, rp, stress, replay, negative, prefix, perf);
    tb.perf_burst = burst; tb.perf_cycles = cycles;
    if (!perf.empty()) {
        if (perf != "read" && perf != "write" && perf != "mixed") { std::cerr << "--perf read|write|mixed\n"; return 2; }
        only.push_back(perf == "read" ? 13 : perf == "write" ? 14 : 15);
    }
    tb.only_cases = only;
    tb.run_perf = !no_perf && !stress && !replay;   // 压力/重放模式默认只跑功能，需要时用 --case 13 等指定
    fl_dut_trace_open(tb.dut, vcd);
    const auto t0 = std::chrono::steady_clock::now();
    sc_start(20, SC_MS);
    fl_dut_trace_close();
    if (!tb.done) { std::cerr << "[FAIL] global simulation watchdog\n"; return 1; }
    report(tb, cfg, stress, replay, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
    return tb.failures ? 1 : 0;
}
