// 仅用于验证的装配顶层：SoC RTL ↔ 两个有限 Flit FIFO ↔ Target RTL。
// 主机激励、MC 字节存储、乱序响应、独立记分板位于同目录的 C++ testbench。
// forward_enable/reverse_enable 只限制入链路握手，FIFO 内已接受数据不会被撤销。
module tb_rtl_bridge #(
    parameter int DATA_WIDTH=256, RP_COUNT=1,
    parameter int LINK_DEPTH=64,
    parameter int TX_DEPTH=8,
    parameter int RDATA_DEPTH=24,
    parameter int WRESP_DEPTH=24,
    parameter int WREQ_DEPTH=24,
    parameter int RREQ_DEPTH=32,
    parameter int WDATA_DEPTH=24,
    parameter int RESPONSE_DEPTH=8,
    parameter int MC_RD_SLOTS=16,
    parameter int MC_WR_SLOTS=16,
    parameter int RD_TAG_WIDTH=MC_RD_SLOTS > 1 ? $clog2(MC_RD_SLOTS) : 1,
    parameter int WR_TAG_WIDTH=MC_WR_SLOTS > 1 ? $clog2(MC_WR_SLOTS) : 1
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
    output logic [11:0] target_wreq_available
);
    import aou_pkg::*;
    logic fq_ready,rq_ready,fq_valid,rq_valid,fq_full,rq_full,fq_empty,rq_empty;
    flit_t fq_data,rq_data;
    always_comb begin
        perf_stall = '0;
        perf_stall[0] = soc.u_transport.raw_valid && !soc.u_transport.raw_ready;
        perf_stall[1] = target.u_transport.raw_valid && !target.u_transport.raw_ready;
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                perf_stall[2] |= soc.tx_valid[p][k] &&
                    int'(soc.u_transport.available[p][k]) < granules(soc.tx_data[p][k][1199:1192]);
                perf_stall[3] |= target.tx_valid[p][k] &&
                    int'(target.u_transport.available[p][k]) < granules(target.tx_data[p][k][1199:1192]);
            end
        end
        perf_stall[4] = target.rd_count == MC_RD_SLOTS || target.wr_count == MC_WR_SLOTS;
        perf_stall[5] = (target.rd_count != 0 && !target.rd_completed[target.rd_head]) ||
                        (target.wr_count != 0 && !target.wr_completed[target.wr_head]);
        perf_stall[6] = (target.rd_count != 0 && target.rd_completed[target.rd_head] && !target.rd_retire) ||
                        (target.wr_count != 0 && target.wr_completed[target.wr_head] && !target.wr_retire);
        perf_stall[7] = soc_rx_valid && !soc_rx_ready;
        perf_stall[8] = target_rx_valid && !target_rx_ready;
        perf_stall[9] = fwd_valid && !fwd_ready;
        perf_stall[10] = rev_valid && !rev_ready;
        perf_stall[11] = (mc_rd_valid && !mc_rd_ready) || (mc_wr_valid && !mc_wr_ready);
        perf_stall[12] = !mc_rd_valid && !mc_wr_valid;
        perf_stall[13] = s_axi_rvalid && !s_axi_rready;
    end
    assign perf_rob_level = 16'(target.rd_count) + 16'(target.wr_count);
    assign target_wreq_available = target.u_transport.available[0][0];
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
        .RDATA_DEPTH(RDATA_DEPTH),
        .WRESP_DEPTH(WRESP_DEPTH)
    ) soc (
        .flit_tx_valid(fwd_valid),.flit_tx_ready(fwd_ready),.flit_tx_data(fwd_data),
        .flit_rx_valid(soc_rx_valid),.flit_rx_ready(soc_rx_ready),.flit_rx_data(soc_rx_data),
        .protocol_error(soc_error),.*);
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
    assert property (@(posedge clk) disable iff(!rst_n)
        mc_rd_valid && !mc_rd_ready |=> mc_rd_valid && $stable({mc_rd_tag,
          mc_rd_rp,mc_rd_id,mc_rd_addr,mc_rd_size,mc_rd_len,mc_rd_beat,mc_rd_first,mc_rd_last,
          mc_rd_prot,mc_rd_cache,mc_rd_qos,mc_rd_lock,mc_rd_user}));
    assert property (@(posedge clk) disable iff(!rst_n)
        mc_wr_valid && !mc_wr_ready |=> mc_wr_valid && $stable({mc_wr_tag,
          mc_wr_rp,mc_wr_id,mc_wr_addr,mc_wr_size,mc_wr_len,mc_wr_beat,mc_wr_first,mc_wr_last,
          mc_wr_prot,mc_wr_cache,mc_wr_qos,mc_wr_lock,mc_wr_user,mc_wr_wuser,mc_wr_data,mc_wr_strb}));
endmodule
