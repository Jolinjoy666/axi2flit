// 存储侧公共部分：AoU 传输层 + 读数据/写响应发送队列。
// 不同存储接口的后端（HIF 接口 flit2hif_target，以及仿真用的满速 MC 模型 sim/model/flit2mc_target）共用本模块：
// 后端从 rx_* 取 WREQ/RREQ/WDATA，把 RDATA/WRESP 写入 reply_*，其余协议处理都在这里完成。
module aou_target_core #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    // 接收缓冲深度（全宽消息条数），决定向对端公布的 WREQ/RREQ/WDATA credit。
    parameter int WREQ_DEPTH = 24,
    parameter int RREQ_DEPTH = 32,
    parameter int WDATA_DEPTH = 24,
    // 每个 RP 的读数据、写响应发送队列深度；组帧器每拍取一条，深度 1 即可满速，满时反压后端。
    parameter int RESPONSE_DEPTH = 2
) (
    input logic clk,
    input logic rst_n,
    input logic link_up,
    // 后端检测到的错误：置位后停止收发；传输层错误单独输出。
    input logic local_error,
    output logic transport_error,

    // 双向 Flit 链路。
    output logic flit_tx_valid,
    input logic flit_tx_ready,
    output aou_pkg::flit_t flit_tx_data,
    input logic flit_rx_valid,
    output logic flit_rx_ready,
    input aou_pkg::flit_t flit_rx_data,

    // 已接收的请求消息（只用 WREQ/RREQ/WDATA 三类）。
    output logic [aou_pkg::MSG_KIND_COUNT-1:0] rx_valid [RP_COUNT],
    input logic [aou_pkg::MSG_KIND_COUNT-1:0] rx_ready [RP_COUNT],
    output aou_pkg::msg_t rx_data [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    // 待发送的响应消息（只用 RDATA/WRESP 两类）；reply_ready 为队列可写。
    input logic [aou_pkg::MSG_KIND_COUNT-1:0] reply_valid [RP_COUNT],
    output logic [aou_pkg::MSG_KIND_COUNT-1:0] reply_ready [RP_COUNT],
    input aou_pkg::msg_t reply_data [RP_COUNT][aou_pkg::MSG_KIND_COUNT]
);
    import aou_pkg::*;

    // 响应队列出口，接传输层发送侧。
    logic [MSG_KIND_COUNT-1:0] tx_valid[RP_COUNT],tx_ready[RP_COUNT];
    msg_t tx_data[RP_COUNT][MSG_KIND_COUNT];

    aou_transport #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .RX_DEPTH0(WREQ_DEPTH),
        .RX_DEPTH1(RREQ_DEPTH),
        .RX_DEPTH2(WDATA_DEPTH),
        .RX_DEPTH3(0),
        .RX_DEPTH4(0)
    ) u_transport (
        .clk(clk),
        .rst_n(rst_n),
        .link_up(link_up && !local_error),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .rx_data(rx_data),
        .flit_tx_valid(flit_tx_valid),
        .flit_tx_ready(flit_tx_ready),
        .flit_tx_data(flit_tx_data),
        .flit_rx_valid(flit_rx_valid),
        .flit_rx_ready(flit_rx_ready),
        .flit_rx_data(flit_rx_data),
        .fault(transport_error)
    );
    // 存储侧只发送读数据和写响应两类；响应队列按消息在本端位宽下的最大位数存储。
    for (genvar rp = 0; rp < RP_COUNT; rp++) begin : g_rp
        for (genvar q = 0; q < MSG_KIND_COUNT; q++) begin : g_reply
            if (q == K_RDATA || q == K_WRESP) begin : g_queue
                localparam int W = msg_bits(q, DATA_WIDTH);
                logic [W-1:0] m_bits;
                logic full, empty;
                aou_sync_fifo #(
                    .WIDTH(W),
                    .DEPTH(RESPONSE_DEPTH)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .wr_en(reply_valid[rp][q]),
                    .wr_data(reply_data[rp][q][MSG_BITS-1 -: W]),
                    .full(full),
                    .rd_en(tx_ready[rp][q]),
                    .rd_data(m_bits),
                    .empty(empty),
                    .level()
                );
                assign reply_ready[rp][q] = !full || (tx_ready[rp][q] && !empty);
                assign tx_valid[rp][q] = !empty;
                assign tx_data[rp][q] = {m_bits, {(MSG_BITS-W){1'b0}}};
            end else begin : g_no_queue
                assign tx_valid[rp][q] = 0;
                assign tx_data[rp][q] = '0;
                assign reply_ready[rp][q] = 0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (WREQ_DEPTH < 1 || RREQ_DEPTH < 1 || WDATA_DEPTH < 1 || RESPONSE_DEPTH < 1) begin
            $fatal(1, "Target FIFO depths must be positive");
        end
    end
`endif
endmodule
