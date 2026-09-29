// 仅用于验证的装配顶层：SoC RTL ↔ 两个有限 Flit FIFO ↔ Target RTL。
// 主机激励、MC 字节存储、乱序响应、独立记分板位于同目录的 C++ testbench。
// forward_enable/reverse_enable 只限制入链路握手，FIFO 内已接受数据不会被撤销。
module tb_rtl_bridge #(
    parameter int DATA_WIDTH=256, RP_COUNT=1
) (
    input logic clk,rst_n,link_up,forward_enable,reverse_enable,
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
    output logic mc_req_valid, input logic mc_req_ready,
    output logic mc_req_write, output logic [3:0] mc_req_tag,
    output logic [1:0] mc_req_rp, output logic [9:0] mc_req_id,
    output logic [63:0] mc_req_addr, output logic [2:0] mc_req_size,
    output logic [7:0] mc_req_len,mc_req_beat,
    output logic mc_req_first,mc_req_last,
    output logic [2:0] mc_req_prot, output logic [3:0] mc_req_cache,mc_req_qos,
    output logic mc_req_lock, output logic [15:0] mc_req_auser,mc_req_wuser,
    output logic [DATA_WIDTH-1:0] mc_req_wdata, output logic [DATA_WIDTH/8-1:0] mc_req_wstrb,
    input logic mc_rsp_valid, output logic mc_rsp_ready, input logic [3:0] mc_rsp_tag,
    input logic [DATA_WIDTH-1:0] mc_rsp_rdata, input logic [1:0] mc_rsp_resp,
    output logic soc_error,target_error,
    output logic fwd_valid,fwd_ready,rev_valid,rev_ready,
    output aou_pkg::flit_t fwd_data,rev_data,
    output logic soc_rx_valid,soc_rx_ready,target_rx_valid,target_rx_ready,
    output aou_pkg::flit_t soc_rx_data,target_rx_data,
    input logic inject_valid,inject_soc,input aou_pkg::flit_t inject_data,
    output logic inject_ready
);
    import aou_pkg::*;
    logic fq_ready,rq_ready,fq_valid,rq_valid;
    flit_t fq_data,rq_data;
    assign fwd_ready=fq_ready && forward_enable;
    assign rev_ready=rq_ready && reverse_enable;
    aou_sync_fifo #(
        .WIDTH(FLIT_BITS),
        .DEPTH(2),
        .FWFT(1'b0)
    ) forward_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(fwd_valid && forward_enable),
        .s_ready(fq_ready),
        .s_data(fwd_data),
        .m_valid(fq_valid),
        .m_ready(target_rx_ready && !(inject_valid && !inject_soc)),
        .m_data(fq_data),
        .level()
    );
    aou_sync_fifo #(
        .WIDTH(FLIT_BITS),
        .DEPTH(2),
        .FWFT(1'b0)
    ) reverse_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(rev_valid && reverse_enable),
        .s_ready(rq_ready),
        .s_data(rev_data),
        .m_valid(rq_valid),
        .m_ready(soc_rx_ready && !(inject_valid && inject_soc)),
        .m_data(rq_data),
        .level()
    );
    assign soc_rx_valid=inject_valid && inject_soc ? 1'b1 : rq_valid;
    assign soc_rx_data=inject_valid && inject_soc ? inject_data : rq_data;
    assign target_rx_valid=inject_valid && !inject_soc ? 1'b1 : fq_valid;
    assign target_rx_data=inject_valid && !inject_soc ? inject_data : fq_data;
    assign inject_ready=inject_soc ? soc_rx_ready : target_rx_ready;
    axi2flit_soc #(.DATA_WIDTH(DATA_WIDTH),.RP_COUNT(RP_COUNT)) soc (
        .flit_tx_valid(fwd_valid),.flit_tx_ready(fwd_ready),.flit_tx_data(fwd_data),
        .flit_rx_valid(soc_rx_valid),.flit_rx_ready(soc_rx_ready),.flit_rx_data(soc_rx_data),
        .protocol_error(soc_error),.*);
    flit2mc_target #(.DATA_WIDTH(DATA_WIDTH),.RP_COUNT(RP_COUNT)) target (
        .flit_tx_valid(rev_valid),.flit_tx_ready(rev_ready),.flit_tx_data(rev_data),
        .flit_rx_valid(target_rx_valid),.flit_rx_ready(target_rx_ready),.flit_rx_data(target_rx_data),
        .protocol_error(target_error),.*);

    // 检查器不参与 DUT 数据通路。被背压的 valid 和完整载荷必须跨周期保持。
    assert property (@(posedge clk) disable iff(!rst_n)
        fwd_valid && !fwd_ready |=> fwd_valid && $stable(fwd_data));
    assert property (@(posedge clk) disable iff(!rst_n)
        rev_valid && !rev_ready |=> rev_valid && $stable(rev_data));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable({s_axi_rdata,s_axi_rid,s_axi_rresp,s_axi_rlast,s_axi_ruser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable({s_axi_bid,s_axi_bresp,s_axi_buser}));
    assert property (@(posedge clk) disable iff(!rst_n)
        mc_req_valid && !mc_req_ready |=> mc_req_valid && $stable({mc_req_tag,mc_req_write,
          mc_req_rp,mc_req_id,mc_req_addr,mc_req_size,mc_req_len,mc_req_beat,mc_req_first,mc_req_last,
          mc_req_prot,mc_req_cache,mc_req_qos,mc_req_lock,mc_req_auser,mc_req_wuser,mc_req_wdata,mc_req_wstrb}));
endmodule
