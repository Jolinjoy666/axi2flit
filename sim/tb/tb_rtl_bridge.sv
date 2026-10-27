// 仅用于验证的装配顶层：SoC RTL ↔ 两个有限 Flit FIFO ↔ Target RTL。
// 主机激励与独立记分板位于同目录的 C++ testbench。存储侧二选一（sim/Makefile 的 MC_IF）：
//   TB_MC_HIF（MC_IF=hif，默认）：交付设计 flit2hif_target，控制器由本模块内的 hif_mc_model 建模，
//     C++ 只通过 mc_block/mc_stress 控制它并读取统计；
//   否则（MC_IF=ideal）：满速 MC 模型 sim/model/flit2mc_target.sv，MC 字节存储与乱序响应由 C++ 建模。
//   两种情况端口相同，未用的一组恒为 0。
// forward_enable/reverse_enable 只限制入链路握手，FIFO 内已接受数据不会被撤销。
module tb_rtl_bridge #(
    parameter int DATA_WIDTH=256, RP_COUNT=1,
    parameter int LINK_DEPTH=64,
    parameter int TX_DEPTH=2,
    parameter int WR_ROUTE_DEPTH=8,
    parameter int RD_OUTSTANDING=32,
    parameter int WR_OUTSTANDING=32,
    parameter int RDATA_DEPTH=24,
    parameter int WRESP_DEPTH=24,
    parameter int WREQ_DEPTH=24,
    parameter int RREQ_DEPTH=32,
    parameter int WDATA_DEPTH=24,
    parameter int RESPONSE_DEPTH=2,
    parameter int MC_RD_SLOTS=16,
    parameter int MC_WR_SLOTS=16,
    parameter int RD_TAG_WIDTH=MC_RD_SLOTS > 1 ? $clog2(MC_RD_SLOTS) : 1,
    parameter int WR_TAG_WIDTH=MC_WR_SLOTS > 1 ? $clog2(MC_WR_SLOTS) : 1,
    // HIF 后端与控制器模型的配置（仅 TB_MC_HIF 时使用）。
    parameter int HIF_DRAM_W=32, HIF_RATIO=4, HIF_BL=16,
    parameter int HIF_RD_LINES=32, HIF_WR_LINES=16,
    parameter int HIF_LPR=24, HIF_HPR=8, HIF_WR=32, HIF_CREDIT_BITS=1,
    parameter bit HIF_ECC_RMW=1'b0,
    parameter int HIF_HPR_QOS=2, HIF_LATENCY=8,   // 用例的 QoS 取 0～3，≥2 的读走 HPR
    parameter int HIF_MEM_BYTES=128*1024,        // 控制器模型的存储容量，超出报 addr_err
    parameter int HIF_POISON=20480+DATA_WIDTH/8  // 该偏移所在行读出时报 ECC 错误
) (
    input logic clk,rst_n,link_up,forward_enable,reverse_enable,
    input logic forward_deliver,reverse_deliver,
    input logic s_axi_awvalid, output logic s_axi_awready,
    input logic [63:0] s_axi_awaddr, input logic [9:0] s_axi_awid,
    input logic [7:0] s_axi_awlen, input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst, input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awcache,s_axi_awqos, input logic s_axi_awlock,
    input logic [15:0] s_axi_awuser,
    input logic s_axi_wvalid, output logic s_axi_wready,
    input logic [DATA_WIDTH-1:0] s_axi_wdata, input logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input logic s_axi_wlast, input logic [15:0] s_axi_wuser,
    input logic s_axi_arvalid, output logic s_axi_arready,
    input logic [63:0] s_axi_araddr, input logic [9:0] s_axi_arid,
    input logic [7:0] s_axi_arlen, input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst, input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arcache,s_axi_arqos, input logic s_axi_arlock,
    input logic [15:0] s_axi_aruser,
    output logic s_axi_bvalid, input logic s_axi_bready,
    output logic [9:0] s_axi_bid, output logic [1:0] s_axi_bresp,
    output logic [15:0] s_axi_buser,
    output logic s_axi_rvalid, input logic s_axi_rready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata, output logic [9:0] s_axi_rid,
    output logic [1:0] s_axi_rresp, output logic s_axi_rlast,
    output logic [15:0] s_axi_ruser,
    output logic mc_rd_valid, input logic mc_rd_ready, output logic [RD_TAG_WIDTH-1:0] mc_rd_tag,
    output logic [1:0] mc_rd_rp, output logic [9:0] mc_rd_id,
    output logic [63:0] mc_rd_addr, output logic [2:0] mc_rd_size,
    output logic [7:0] mc_rd_len,mc_rd_beat, output logic mc_rd_first,mc_rd_last,
    output logic [2:0] mc_rd_prot, output logic [3:0] mc_rd_cache,mc_rd_qos,
    output logic mc_rd_lock, output logic [15:0] mc_rd_user,
    input logic mc_rd_rsp_valid, output logic mc_rd_rsp_ready, input logic [RD_TAG_WIDTH-1:0] mc_rd_rsp_tag,
    input logic [DATA_WIDTH-1:0] mc_rd_rsp_data, input logic [1:0] mc_rd_rsp_resp,
    output logic mc_wr_valid, input logic mc_wr_ready, output logic [WR_TAG_WIDTH-1:0] mc_wr_tag,
    output logic [1:0] mc_wr_rp, output logic [9:0] mc_wr_id,
    output logic [63:0] mc_wr_addr, output logic [2:0] mc_wr_size,
    output logic [7:0] mc_wr_len,mc_wr_beat, output logic mc_wr_first,mc_wr_last,
    output logic [2:0] mc_wr_prot, output logic [3:0] mc_wr_cache,mc_wr_qos,
    output logic mc_wr_lock, output logic [15:0] mc_wr_user,mc_wr_wuser,
    output logic [DATA_WIDTH-1:0] mc_wr_data, output logic [DATA_WIDTH/8-1:0] mc_wr_strb,
    input logic mc_wr_rsp_valid, output logic mc_wr_rsp_ready, input logic [WR_TAG_WIDTH-1:0] mc_wr_rsp_tag,
    input logic [1:0] mc_wr_rsp_resp,
    output logic soc_error,target_error,
    output logic fwd_valid,fwd_ready,rev_valid,rev_ready,
    output aou_pkg::flit_t fwd_data,rev_data,
    output logic soc_rx_valid,soc_rx_ready,target_rx_valid,target_rx_ready,
    output aou_pkg::flit_t soc_rx_data,target_rx_data,
    input logic inject_valid,inject_soc,input aou_pkg::flit_t inject_data,
    output logic inject_ready,
    // 仿真观察端口：仅统计停顿原因，不进入 DUT 的握手逻辑。
    output logic [13:0] perf_stall,
    output logic [15:0] perf_rob_level,
    // 存储侧 WREQ 可发 credit，供 credit 饱和测试观察。
    output logic [11:0] target_wreq_available,
    // HIF 控制器模型的控制与统计；hif_obs 为 {写数据末拍接收, 读数据末拍, 命令接收}，用于测延迟。
    input logic mc_block,mc_stress,mc_inject_bad_token,
    output logic mc_model_error,
    output logic [31:0] mc_stat_rd,mc_stat_wr,mc_stat_ooo,mc_stat_interleave,mc_stat_stall,
    output logic [2:0] hif_obs
);
    import aou_pkg::*;
`ifdef TB_MC_HIF
    localparam int HIF_CORE_W = HIF_DRAM_W * HIF_RATIO * 2;
    localparam int HIF_LINE_WORDS = HIF_BL * HIF_DRAM_W / HIF_CORE_W;
    logic hif_cmd_valid, hif_cmd_stall, hif_cmd_autopre;
    logic [1:0] hif_cmd_type, hif_cmd_pri, hif_wrecc_credit;
    logic [39:0] hif_cmd_addr;
    logic [52:0] hif_cmd_token, hif_rdata_token;
    logic [1:0] hif_cmd_length;
    logic [18:0] hif_cmd_wdata_ptr, hif_wdata_ptr;
    logic [10:0] hif_cmd_latency;
    logic [HIF_CREDIT_BITS-1:0] hif_lpr_credit, hif_hpr_credit;
    logic hif_wr_credit, hif_rdata_valid, hif_rdata_end;
    logic [HIF_CORE_W-1:0] hif_rdata, hif_wdata;
    logic [HIF_CORE_W/8-1:0] hif_wdata_mask;
    logic hif_rdata_uncorr_ecc_err, hif_rdata_addr_err, hif_rdata_crc_err;
    logic hif_wdata_valid, hif_wdata_end, hif_wdata_stall, hif_wdata_ptr_valid, hif_wdata_ptr_addr_err;
    logic hif_go2critical_lpr, hif_go2critical_hpr, hif_go2critical_wr;
`endif
    logic fq_ready,rq_ready,fq_valid,rq_valid,fq_full,rq_full,fq_empty,rq_empty;
    flit_t fq_data,rq_data;
    always_comb begin
        perf_stall = '0;
        perf_stall[0] = soc.u_transport.raw_valid && !soc.u_transport.raw_ready;
        perf_stall[1] = target.u_core.u_transport.raw_valid && !target.u_core.u_transport.raw_ready;
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                perf_stall[2] |= soc.tx_valid[p][k] &&
                    int'(soc.u_transport.available[p][k]) < msg_granules(soc.tx_data[p][k]);
                perf_stall[3] |= target.u_core.tx_valid[p][k] &&
                    int'(target.u_core.u_transport.available[p][k]) < msg_granules(target.u_core.tx_data[p][k]);
            end
        end
`ifdef TB_MC_HIF
        perf_stall[4] = target.rob_count == HIF_RD_LINES || target.free_count == 0;
        perf_stall[5] = target.rc_count != 0 && !target.rt_ready;
        perf_stall[6] = target.rt_ready && !target.rt_fire;
`else
        perf_stall[4] = target.rd_count == MC_RD_SLOTS || target.wr_count == MC_WR_SLOTS;
        perf_stall[5] = (target.rd_count != 0 && !target.rd_completed[target.rd_head]) ||
                        (target.wr_count != 0 && !target.wr_completed[target.wr_head]);
        perf_stall[6] = (target.rd_count != 0 && target.rd_completed[target.rd_head] && !target.rd_retire) ||
                        (target.wr_count != 0 && target.wr_completed[target.wr_head] && !target.wr_retire);
`endif
        perf_stall[7] = soc_rx_valid && !soc_rx_ready;
        perf_stall[8] = target_rx_valid && !target_rx_ready;
        perf_stall[9] = fwd_valid && !fwd_ready;
        perf_stall[10] = rev_valid && !rev_ready;
`ifdef TB_MC_HIF
        perf_stall[11] = hif_cmd_valid && hif_cmd_stall;
        perf_stall[12] = !hif_cmd_valid;
`else
        perf_stall[11] = (mc_rd_valid && !mc_rd_ready) || (mc_wr_valid && !mc_wr_ready);
        perf_stall[12] = !mc_rd_valid && !mc_wr_valid;
`endif
        perf_stall[13] = s_axi_rvalid && !s_axi_rready;
    end
`ifdef TB_MC_HIF
    assign perf_rob_level = 16'(target.rob_count) + 16'(HIF_WR_LINES - int'(target.free_count));
`else
    assign perf_rob_level = 16'(target.rd_count) + 16'(target.wr_count);
`endif
    assign target_wreq_available = target.u_core.u_transport.available[0][0];
    assign fwd_ready=fq_ready && forward_enable;
    assign rev_ready=rq_ready && reverse_enable;
    aou_sync_fifo #(
        .WIDTH(FLIT_BITS),
        .DEPTH(LINK_DEPTH)
    ) forward_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(fwd_valid && forward_enable),
        .wr_data(fwd_data),
        .full(fq_full),
        .rd_en(target_rx_ready && forward_deliver && !(inject_valid && !inject_soc)),
        .rd_data(fq_data),
        .empty(fq_empty),
        .level()
    );
    assign fq_ready = !fq_full || (target_rx_ready && forward_deliver && !(inject_valid && !inject_soc) && !fq_empty);
    assign fq_valid = !fq_empty;
    aou_sync_fifo #(
        .WIDTH(FLIT_BITS),
        .DEPTH(LINK_DEPTH)
    ) reverse_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(rev_valid && reverse_enable),
        .wr_data(rev_data),
        .full(rq_full),
        .rd_en(soc_rx_ready && reverse_deliver && !(inject_valid && inject_soc)),
        .rd_data(rq_data),
        .empty(rq_empty),
        .level()
    );
    assign rq_ready = !rq_full || (soc_rx_ready && reverse_deliver && !(inject_valid && inject_soc) && !rq_empty);
    assign rq_valid = !rq_empty;
    assign soc_rx_valid=inject_valid && inject_soc ? 1'b1 : rq_valid && reverse_deliver;
    assign soc_rx_data=inject_valid && inject_soc ? inject_data : rq_data;
    assign target_rx_valid=inject_valid && !inject_soc ? 1'b1 : fq_valid && forward_deliver;
    assign target_rx_data=inject_valid && !inject_soc ? inject_data : fq_data;
    assign inject_ready=inject_soc ? soc_rx_ready : target_rx_ready;
    axi2flit_soc #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .TX_DEPTH(TX_DEPTH),
        .WR_ROUTE_DEPTH(WR_ROUTE_DEPTH),
        .RD_OUTSTANDING(RD_OUTSTANDING),
        .WR_OUTSTANDING(WR_OUTSTANDING),
        .RDATA_DEPTH(RDATA_DEPTH),
        .WRESP_DEPTH(WRESP_DEPTH)
    ) soc (
        .flit_tx_valid(fwd_valid),.flit_tx_ready(fwd_ready),.flit_tx_data(fwd_data),
        .flit_rx_valid(soc_rx_valid),.flit_rx_ready(soc_rx_ready),.flit_rx_data(soc_rx_data),
        .protocol_error(soc_error),.*);
`ifdef TB_MC_HIF
    // 桥的地址窗口取模型容量的两倍：窗口内越界由控制器报 addr_err，窗口外由桥直接回 DECERR。
    flit2hif_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(WREQ_DEPTH),
        .RREQ_DEPTH(RREQ_DEPTH),
        .WDATA_DEPTH(WDATA_DEPTH),
        .RESPONSE_DEPTH(RESPONSE_DEPTH),
        .MEMC_DRAM_DATA_WIDTH(HIF_DRAM_W),
        .MEMC_FREQ_RATIO(HIF_RATIO),
        .MEMC_BURST_LENGTH(HIF_BL),
        .HIF_CREDIT_BITS(HIF_CREDIT_BITS),
        .LPR_CREDITS(HIF_LPR),
        .HPR_CREDITS(HIF_HPR),
        .WR_CREDITS(HIF_WR),
        .ECC_RMW(HIF_ECC_RMW),
        .ADDR_BASE(64'h1234567800000000),
        .MEM_BYTES(64'(2 * HIF_MEM_BYTES)),
        .HPR_QOS(HIF_HPR_QOS),
        .RD_LINES(HIF_RD_LINES),
        .WR_LINES(HIF_WR_LINES)
    ) target (
        .clk(clk),.rst_n(rst_n),.link_up(link_up),
        .flit_tx_valid(rev_valid),.flit_tx_ready(rev_ready),.flit_tx_data(rev_data),
        .flit_rx_valid(target_rx_valid),.flit_rx_ready(target_rx_ready),.flit_rx_data(target_rx_data),
        .protocol_error(target_error),.*);
    hif_mc_model #(
        .CORE_DATA_WIDTH(HIF_CORE_W),
        .LINE_WORDS(HIF_LINE_WORDS),
        .WORD_BYTES(HIF_DRAM_W / 8),
        .HIF_CREDIT_BITS(HIF_CREDIT_BITS),
        .LPR_CREDITS(HIF_LPR),
        .HPR_CREDITS(HIF_HPR),
        .WR_CREDITS(HIF_WR),
        .MEM_BYTES(HIF_MEM_BYTES),
        .POISON_LINE(HIF_POISON),
        .LATENCY(HIF_LATENCY)
    ) u_mc (
        .block(mc_block),.stress(mc_stress),.inject_bad_token(mc_inject_bad_token),
        .model_error(mc_model_error),.stat_rd(mc_stat_rd),.stat_wr(mc_stat_wr),.stat_ooo(mc_stat_ooo),
        .stat_interleave(mc_stat_interleave),.stat_stall(mc_stat_stall),.*);
    assign hif_obs = {hif_wdata_valid && !hif_wdata_stall && hif_wdata_end,
                      hif_rdata_valid && hif_rdata_end, hif_cmd_valid && !hif_cmd_stall};
    // 逐拍 MC 接口在 HIF 构建中不使用。
    assign {mc_rd_valid,mc_rd_tag,mc_rd_rp,mc_rd_id,mc_rd_addr,mc_rd_size,mc_rd_len,mc_rd_beat,mc_rd_first,mc_rd_last,
            mc_rd_prot,mc_rd_cache,mc_rd_qos,mc_rd_lock,mc_rd_user,mc_rd_rsp_ready} = '0;
    assign {mc_wr_valid,mc_wr_tag,mc_wr_rp,mc_wr_id,mc_wr_addr,mc_wr_size,mc_wr_len,mc_wr_beat,mc_wr_first,mc_wr_last,
            mc_wr_prot,mc_wr_cache,mc_wr_qos,mc_wr_lock,mc_wr_user,mc_wr_wuser,mc_wr_data,mc_wr_strb,mc_wr_rsp_ready} = '0;
    assert property (@(posedge clk) disable iff(!rst_n)
        hif_cmd_valid && hif_cmd_stall |=> hif_cmd_valid && $stable({hif_cmd_type,hif_cmd_addr,hif_cmd_pri,
          hif_cmd_token,hif_cmd_length,hif_cmd_wdata_ptr}));
    assert property (@(posedge clk) disable iff(!rst_n)
        hif_wdata_valid && hif_wdata_stall |=> hif_wdata_valid && $stable({hif_wdata,hif_wdata_mask,hif_wdata_end}));
`else
    flit2mc_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(WREQ_DEPTH),
        .RREQ_DEPTH(RREQ_DEPTH),
        .WDATA_DEPTH(WDATA_DEPTH),
        .RESPONSE_DEPTH(RESPONSE_DEPTH),
        .MC_RD_SLOTS(MC_RD_SLOTS),
        .MC_WR_SLOTS(MC_WR_SLOTS),
        .RD_TAG_WIDTH(RD_TAG_WIDTH),
        .WR_TAG_WIDTH(WR_TAG_WIDTH)
    ) target (
        .flit_tx_valid(rev_valid),.flit_tx_ready(rev_ready),.flit_tx_data(rev_data),
        .flit_rx_valid(target_rx_valid),.flit_rx_ready(target_rx_ready),.flit_rx_data(target_rx_data),
        .protocol_error(target_error),.*);
    assign {mc_model_error,mc_stat_rd,mc_stat_wr,mc_stat_ooo,mc_stat_interleave,mc_stat_stall,hif_obs} = '0;

`endif
    // 检查器不参与 DUT 数据通路。被背压的 valid 和完整载荷必须跨周期保持。
    assert property (@(posedge clk) disable iff(!rst_n)
        fwd_valid && !fwd_ready |=> fwd_valid && $stable(fwd_data));
    assert property (@(posedge clk) disable iff(!rst_n)
        rev_valid && !rev_ready |=> rev_valid && $stable(rev_data));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_awvalid && !s_axi_awready |=> s_axi_awvalid &&
        $stable({s_axi_awaddr,s_axi_awid,s_axi_awlen,s_axi_awsize,s_axi_awburst,
                 s_axi_awprot,s_axi_awcache,s_axi_awqos,s_axi_awlock,s_axi_awuser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_arvalid && !s_axi_arready |=> s_axi_arvalid &&
        $stable({s_axi_araddr,s_axi_arid,s_axi_arlen,s_axi_arsize,s_axi_arburst,
                 s_axi_arprot,s_axi_arcache,s_axi_arqos,s_axi_arlock,s_axi_aruser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_wvalid && !s_axi_wready |=> s_axi_wvalid &&
        $stable({s_axi_wdata,s_axi_wstrb,s_axi_wlast,s_axi_wuser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable({s_axi_rdata,s_axi_rid,s_axi_rresp,s_axi_rlast,s_axi_ruser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable({s_axi_bid,s_axi_bresp,s_axi_buser}));
`ifndef TB_MC_HIF
    assert property (@(posedge clk) disable iff(!rst_n)
        mc_rd_valid && !mc_rd_ready |=> mc_rd_valid && $stable({mc_rd_tag,
          mc_rd_rp,mc_rd_id,mc_rd_addr,mc_rd_size,mc_rd_len,mc_rd_beat,mc_rd_first,mc_rd_last,
          mc_rd_prot,mc_rd_cache,mc_rd_qos,mc_rd_lock,mc_rd_user}));
    assert property (@(posedge clk) disable iff(!rst_n)
        mc_wr_valid && !mc_wr_ready |=> mc_wr_valid && $stable({mc_wr_tag,
          mc_wr_rp,mc_wr_id,mc_wr_addr,mc_wr_size,mc_wr_len,mc_wr_beat,mc_wr_first,mc_wr_last,
          mc_wr_prot,mc_wr_cache,mc_wr_qos,mc_wr_lock,mc_wr_user,mc_wr_wuser,mc_wr_data,mc_wr_strb}));
`endif
endmodule
