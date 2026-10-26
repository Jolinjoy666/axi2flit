// 全链路联合仿真用的 RTL 封装：SoC 侧 axi2flit_soc 与存储侧 flit2mc_target 各一份，
// 两者在本模块内不相连，Flit 端口分别接 SystemC 的 UCIe 适配器与链路模型。
// 配置用宏传入（Verilator 与 VCS 都支持 +define+），SystemC 侧用同一组宏确定端口宽度。
`ifndef FL_DATA_WIDTH
`define FL_DATA_WIDTH 256
`endif
`ifndef FL_RP_COUNT
`define FL_RP_COUNT 1
`endif
`ifndef FL_MC_SLOTS
`define FL_MC_SLOTS 16
`endif
// 两端接收深度（全宽消息条数）与发送队列深度，默认与 RTL 参数默认值相同。
`ifndef FL_RDATA_DEPTH
`define FL_RDATA_DEPTH 24
`endif
`ifndef FL_WRESP_DEPTH
`define FL_WRESP_DEPTH 24
`endif
`ifndef FL_WREQ_DEPTH
`define FL_WREQ_DEPTH 24
`endif
`ifndef FL_RREQ_DEPTH
`define FL_RREQ_DEPTH 32
`endif
`ifndef FL_WDATA_DEPTH
`define FL_WDATA_DEPTH 24
`endif
module fl_rtl_top #(
    parameter int DATA_WIDTH = `FL_DATA_WIDTH,
    parameter int RP_COUNT = `FL_RP_COUNT,
    parameter int MC_SLOTS = `FL_MC_SLOTS,
    localparam int TW = MC_SLOTS > 1 ? $clog2(MC_SLOTS) : 1
) (
    input logic clk, rst_n, link_up,
    input logic [7:0] tb_case,   // 测试平台当前用例编号，只用于看波形，设计内部不使用
    // ---- SoC 侧 AXI 从机 ----
    input logic s_axi_awvalid, output logic s_axi_awready,
    input logic [63:0] s_axi_awaddr, input logic [9:0] s_axi_awid,
    input logic [7:0] s_axi_awlen, input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst, input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awcache, input logic [3:0] s_axi_awqos, input logic s_axi_awlock,
    input logic [15:0] s_axi_awuser,
    input logic s_axi_wvalid, output logic s_axi_wready,
    input logic [DATA_WIDTH-1:0] s_axi_wdata, input logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input logic s_axi_wlast, input logic [15:0] s_axi_wuser,
    input logic s_axi_arvalid, output logic s_axi_arready,
    input logic [63:0] s_axi_araddr, input logic [9:0] s_axi_arid,
    input logic [7:0] s_axi_arlen, input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst, input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arcache, input logic [3:0] s_axi_arqos, input logic s_axi_arlock,
    input logic [15:0] s_axi_aruser,
    output logic s_axi_bvalid, input logic s_axi_bready,
    output logic [9:0] s_axi_bid, output logic [1:0] s_axi_bresp, output logic [15:0] s_axi_buser,
    output logic s_axi_rvalid, input logic s_axi_rready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata, output logic [9:0] s_axi_rid,
    output logic [1:0] s_axi_rresp, output logic s_axi_rlast, output logic [15:0] s_axi_ruser,
    // ---- SoC 侧 Flit ----
    output logic soc_flit_tx_valid, input logic soc_flit_tx_ready,
    output logic [aou_pkg::FLIT_BITS-1:0] soc_flit_tx_data,
    input logic soc_flit_rx_valid, output logic soc_flit_rx_ready,
    input logic [aou_pkg::FLIT_BITS-1:0] soc_flit_rx_data,
    output logic soc_error,
    // ---- 存储侧 Flit ----
    output logic tgt_flit_tx_valid, input logic tgt_flit_tx_ready,
    output logic [aou_pkg::FLIT_BITS-1:0] tgt_flit_tx_data,
    input logic tgt_flit_rx_valid, output logic tgt_flit_rx_ready,
    input logic [aou_pkg::FLIT_BITS-1:0] tgt_flit_rx_data,
    output logic tgt_error,
    // ---- 存储侧 MC 读口 ----
    output logic mc_rd_valid, input logic mc_rd_ready, output logic [TW-1:0] mc_rd_tag,
    output logic [1:0] mc_rd_rp, output logic [9:0] mc_rd_id,
    output logic [63:0] mc_rd_addr, output logic [2:0] mc_rd_size,
    output logic [7:0] mc_rd_len, output logic [7:0] mc_rd_beat,
    output logic mc_rd_first, output logic mc_rd_last,
    output logic [2:0] mc_rd_prot, output logic [3:0] mc_rd_cache, output logic [3:0] mc_rd_qos,
    output logic mc_rd_lock, output logic [15:0] mc_rd_user,
    input logic mc_rd_rsp_valid, output logic mc_rd_rsp_ready, input logic [TW-1:0] mc_rd_rsp_tag,
    input logic [DATA_WIDTH-1:0] mc_rd_rsp_data, input logic [1:0] mc_rd_rsp_resp,
    // ---- 存储侧 MC 写口 ----
    output logic mc_wr_valid, input logic mc_wr_ready, output logic [TW-1:0] mc_wr_tag,
    output logic [1:0] mc_wr_rp, output logic [9:0] mc_wr_id,
    output logic [63:0] mc_wr_addr, output logic [2:0] mc_wr_size,
    output logic [7:0] mc_wr_len, output logic [7:0] mc_wr_beat,
    output logic mc_wr_first, output logic mc_wr_last,
    output logic [2:0] mc_wr_prot, output logic [3:0] mc_wr_cache, output logic [3:0] mc_wr_qos,
    output logic mc_wr_lock, output logic [15:0] mc_wr_user, output logic [15:0] mc_wr_wuser,
    output logic [DATA_WIDTH-1:0] mc_wr_data, output logic [DATA_WIDTH/8-1:0] mc_wr_strb,
    input logic mc_wr_rsp_valid, output logic mc_wr_rsp_ready, input logic [TW-1:0] mc_wr_rsp_tag,
    input logic [1:0] mc_wr_rsp_resp,
    // ---- 观察：存储侧有响应因 credit 不足而等待 ----
    output logic dbg_tgt_credit_wait
);
    import aou_pkg::*;

    axi2flit_soc #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .RDATA_DEPTH(`FL_RDATA_DEPTH),
        .WRESP_DEPTH(`FL_WRESP_DEPTH)
    ) soc (
        .flit_tx_valid(soc_flit_tx_valid), .flit_tx_ready(soc_flit_tx_ready), .flit_tx_data(soc_flit_tx_data),
        .flit_rx_valid(soc_flit_rx_valid), .flit_rx_ready(soc_flit_rx_ready), .flit_rx_data(soc_flit_rx_data),
        .protocol_error(soc_error), .*);

    flit2mc_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(`FL_WREQ_DEPTH),
        .RREQ_DEPTH(`FL_RREQ_DEPTH),
        .WDATA_DEPTH(`FL_WDATA_DEPTH),
        .MC_RD_SLOTS(MC_SLOTS),
        .MC_WR_SLOTS(MC_SLOTS)
    ) target (
        .flit_tx_valid(tgt_flit_tx_valid), .flit_tx_ready(tgt_flit_tx_ready), .flit_tx_data(tgt_flit_tx_data),
        .flit_rx_valid(tgt_flit_rx_valid), .flit_rx_ready(tgt_flit_rx_ready), .flit_rx_data(tgt_flit_rx_data),
        .mc_rd_rsp_data(mc_rd_rsp_data), .protocol_error(tgt_error), .*);

    always_comb begin
        dbg_tgt_credit_wait = 0;
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 3; k < MSG_KIND_COUNT; k++) begin
                dbg_tgt_credit_wait |= target.tx_valid[p][k] &&
                    int'(target.u_transport.available[p][k]) < granules(target.tx_data[p][k][1199:1192]);
            end
        end
    end

`ifdef FSDB
    // VCS + Verdi：dump 本模块以下的全部层次。
    initial begin
        $fsdbDumpfile(`FSDB);
        $fsdbDumpvars(0, fl_rtl_top, "+all");
    end
`endif
endmodule
