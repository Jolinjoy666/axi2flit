// 全链路联合仿真用的 RTL 封装：SoC 侧 axi2flit_soc 与存储侧各一份，
// 两者在本模块内不相连，Flit 端口分别接 SystemC 的 UCIe 适配器与链路模型。
// 存储侧：定义 FL_MC_HIF（MC_IF=hif，默认）时为交付设计 flit2hif_target，控制器由本模块内的 hif_mc_model 建模，
// SystemC 只控制与读取统计；否则（MC_IF=ideal）为满速 MC 模型 sim/model/flit2mc_target.sv，MC 由 SystemC 建模。
// 两种情况端口列表相同（未用的一组恒为 0），SystemC 绑定与 VCS 端口映射不必区分。
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
`define FL_RDATA_DEPTH (`FL_DATA_WIDTH < 1024 ? 32 : 24)
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
`define FL_WDATA_DEPTH (`FL_DATA_WIDTH < 1024 ? 36 : 24)
`endif
`ifndef FL_TX_DEPTH
`define FL_TX_DEPTH 2
`endif
`ifndef FL_WR_ROUTE_DEPTH
`define FL_WR_ROUTE_DEPTH 8
`endif
`ifndef FL_RD_OUTSTANDING
`define FL_RD_OUTSTANDING 32
`endif
`ifndef FL_WR_OUTSTANDING
`define FL_WR_OUTSTANDING 32
`endif
`ifndef FL_RESPONSE_DEPTH
`define FL_RESPONSE_DEPTH 2
`endif
// HIF 配置（仅 FL_MC_HIF）：含义同 sim/Makefile 的 HIF_* 变量。
`ifndef FL_HIF_DRAM_W
`define FL_HIF_DRAM_W 32
`endif
`ifndef FL_HIF_RATIO
`define FL_HIF_RATIO 4
`endif
`ifndef FL_HIF_BL
`define FL_HIF_BL 16
`endif
`ifndef FL_HIF_RD_LINES
`define FL_HIF_RD_LINES 32
`endif
`ifndef FL_HIF_WR_LINES
`define FL_HIF_WR_LINES 16
`endif
`ifndef FL_HIF_LPR
`define FL_HIF_LPR 24
`endif
`ifndef FL_HIF_HPR
`define FL_HIF_HPR 8
`endif
`ifndef FL_HIF_WR
`define FL_HIF_WR 32
`endif
`ifndef FL_HIF_LATENCY
`define FL_HIF_LATENCY 8
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
    output logic dbg_tgt_credit_wait,
    // ---- HIF 控制器模型的控制与统计；hif_obs 为 {写数据末拍接收, 读数据末拍, 命令接收} ----
    input logic mc_block, input logic mc_stress,
    output logic mc_model_error,
    output logic [31:0] mc_stat_rd, output logic [31:0] mc_stat_wr, output logic [31:0] mc_stat_ooo,
    output logic [31:0] mc_stat_interleave,
    output logic [2:0] hif_obs,
    // ---- 观察：组帧器接受消息，tx_obs 为 {存储侧 RDATA / WRESP, SoC 侧 RREQ / WDATA} ----
    output logic [1:0] tx_obs
);
    import aou_pkg::*;

    axi2flit_soc #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .TX_DEPTH(`FL_TX_DEPTH),
        .WR_ROUTE_DEPTH(`FL_WR_ROUTE_DEPTH),
        .RD_OUTSTANDING(`FL_RD_OUTSTANDING),
        .WR_OUTSTANDING(`FL_WR_OUTSTANDING),
        .RDATA_DEPTH(`FL_RDATA_DEPTH),
        .WRESP_DEPTH(`FL_WRESP_DEPTH)
    ) soc (
        .flit_tx_valid(soc_flit_tx_valid), .flit_tx_ready(soc_flit_tx_ready), .flit_tx_data(soc_flit_tx_data),
        .flit_rx_valid(soc_flit_rx_valid), .flit_rx_ready(soc_flit_rx_ready), .flit_rx_data(soc_flit_rx_data),
        .protocol_error(soc_error), .*);

`ifdef FL_MC_HIF
    localparam int HIF_CORE_W = `FL_HIF_DRAM_W * `FL_HIF_RATIO * 2;
    localparam int MEM_BYTES = 128 * 1024;   // 与 SystemC 记分板的 MEM_SIZE 一致
    logic hif_cmd_valid, hif_cmd_stall, hif_cmd_autopre;
    logic [1:0] hif_cmd_type, hif_cmd_pri, hif_wrecc_credit, hif_cmd_length;
    logic [39:0] hif_cmd_addr;
    logic [52:0] hif_cmd_token, hif_rdata_token;
    logic [18:0] hif_cmd_wdata_ptr, hif_wdata_ptr;
    logic [10:0] hif_cmd_latency;
    logic hif_lpr_credit, hif_hpr_credit, hif_wr_credit, hif_rdata_valid, hif_rdata_end;
    logic [HIF_CORE_W-1:0] hif_rdata, hif_wdata;
    logic [HIF_CORE_W/8-1:0] hif_wdata_mask;
    logic hif_rdata_uncorr_ecc_err, hif_rdata_addr_err, hif_rdata_crc_err;
    logic hif_wdata_valid, hif_wdata_end, hif_wdata_stall, hif_wdata_ptr_valid, hif_wdata_ptr_addr_err;
    logic hif_go2critical_lpr, hif_go2critical_hpr, hif_go2critical_wr;
    // 桥的地址窗口为存储容量的两倍：窗口内越界由控制器报 addr_err，窗口外由桥直接回 DECERR。
    flit2hif_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(`FL_WREQ_DEPTH),
        .RREQ_DEPTH(`FL_RREQ_DEPTH),
        .WDATA_DEPTH(`FL_WDATA_DEPTH),
        .RESPONSE_DEPTH(`FL_RESPONSE_DEPTH),
        .MEMC_DRAM_DATA_WIDTH(`FL_HIF_DRAM_W),
        .MEMC_FREQ_RATIO(`FL_HIF_RATIO),
        .MEMC_BURST_LENGTH(`FL_HIF_BL),
        .LPR_CREDITS(`FL_HIF_LPR),
        .HPR_CREDITS(`FL_HIF_HPR),
        .WR_CREDITS(`FL_HIF_WR),
        .ADDR_BASE(64'h1234567800000000),
        .MEM_BYTES(64'(2 * MEM_BYTES)),
        .HPR_QOS(2),
        .RD_LINES(`FL_HIF_RD_LINES),
        .WR_LINES(`FL_HIF_WR_LINES)
    ) target (
        .flit_tx_valid(tgt_flit_tx_valid), .flit_tx_ready(tgt_flit_tx_ready), .flit_tx_data(tgt_flit_tx_data),
        .flit_rx_valid(tgt_flit_rx_valid), .flit_rx_ready(tgt_flit_rx_ready), .flit_rx_data(tgt_flit_rx_data),
        .protocol_error(tgt_error), .*);
    hif_mc_model #(
        .CORE_DATA_WIDTH(HIF_CORE_W),
        .LINE_WORDS(`FL_HIF_BL * `FL_HIF_DRAM_W / HIF_CORE_W),
        .WORD_BYTES(`FL_HIF_DRAM_W / 8),
        .LPR_CREDITS(`FL_HIF_LPR),
        .HPR_CREDITS(`FL_HIF_HPR),
        .WR_CREDITS(`FL_HIF_WR),
        .MEM_BYTES(MEM_BYTES),
        .LATENCY(`FL_HIF_LATENCY)
    ) u_mc (
        .block(mc_block), .stress(mc_stress), .inject_bad_token(1'b0),
        .model_error(mc_model_error), .stat_rd(mc_stat_rd), .stat_wr(mc_stat_wr), .stat_ooo(mc_stat_ooo),
        .stat_interleave(mc_stat_interleave), .stat_stall(), .*);
    assign hif_obs = {hif_wdata_valid && !hif_wdata_stall && hif_wdata_end,
                      hif_rdata_valid && hif_rdata_end, hif_cmd_valid && !hif_cmd_stall};
    // 逐拍 MC 接口在 HIF 构建中不使用。
    assign {mc_rd_valid, mc_rd_tag, mc_rd_rp, mc_rd_id, mc_rd_addr, mc_rd_size, mc_rd_len, mc_rd_beat, mc_rd_first,
            mc_rd_last, mc_rd_prot, mc_rd_cache, mc_rd_qos, mc_rd_lock, mc_rd_user, mc_rd_rsp_ready} = '0;
    assign {mc_wr_valid, mc_wr_tag, mc_wr_rp, mc_wr_id, mc_wr_addr, mc_wr_size, mc_wr_len, mc_wr_beat, mc_wr_first,
            mc_wr_last, mc_wr_prot, mc_wr_cache, mc_wr_qos, mc_wr_lock, mc_wr_user, mc_wr_wuser, mc_wr_data,
            mc_wr_strb, mc_wr_rsp_ready} = '0;
`else
    flit2mc_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(`FL_WREQ_DEPTH),
        .RREQ_DEPTH(`FL_RREQ_DEPTH),
        .WDATA_DEPTH(`FL_WDATA_DEPTH),
        .RESPONSE_DEPTH(`FL_RESPONSE_DEPTH),
        .MC_RD_SLOTS(MC_SLOTS),
        .MC_WR_SLOTS(MC_SLOTS)
    ) target (
        .flit_tx_valid(tgt_flit_tx_valid), .flit_tx_ready(tgt_flit_tx_ready), .flit_tx_data(tgt_flit_tx_data),
        .flit_rx_valid(tgt_flit_rx_valid), .flit_rx_ready(tgt_flit_rx_ready), .flit_rx_data(tgt_flit_rx_data),
        .mc_rd_rsp_data(mc_rd_rsp_data), .protocol_error(tgt_error), .*);

    assign {mc_model_error, mc_stat_rd, mc_stat_wr, mc_stat_ooo, mc_stat_interleave, hif_obs} = '0;
`endif

    // 桥发送段的终点取“组帧器接受消息后 2 拍”（提交到输出寄存器、输出有效）：输出寄存器被链路未取走的
    // 前一帧占用时，等待的时间属于链路排队，不计入桥的延迟。
    always_comb begin
        tx_obs = '0;
        for (int p = 0; p < RP_COUNT; p++) begin
            tx_obs[0] = tx_obs[0] | soc.tx_ready[p][K_RREQ] | soc.tx_ready[p][K_WDATA];
            tx_obs[1] = tx_obs[1] | target.u_core.tx_ready[p][K_RDATA] | target.u_core.tx_ready[p][K_WRESP];
        end
    end

    always_comb begin
        dbg_tgt_credit_wait = 0;
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 3; k < MSG_KIND_COUNT; k++) begin
                dbg_tgt_credit_wait |= target.u_core.tx_valid[p][k] &&
                    int'(target.u_core.u_transport.available[p][k]) < msg_granules(target.u_core.tx_data[p][k]);
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
