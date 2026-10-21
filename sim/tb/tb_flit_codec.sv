// 编解码器独立验证：发送、接收分别由 C++ 参考字节流驱动，避免互相掩盖错误。
module tb_flit_codec #(
    parameter int FRAME_DEPTH = 2
) (
    input logic clk,
    input logic rst_n,
    input logic tx_valid,
    output logic tx_ready,
    input aou_pkg::msg_t tx_message,
    output logic tx_flit_valid,
    input logic tx_flit_ready,
    output aou_pkg::flit_t tx_flit,
    output logic [7:0] tx_debit,
    input logic rx_flit_valid,
    output logic rx_flit_ready,
    input aou_pkg::flit_t rx_flit,
    output logic rx_valid,
    input logic rx_ready,
    output aou_pkg::msg_t rx_message,
    output logic rx_header_valid,
    output logic [15:0] rx_header_credit,
    output logic rx_fault
);
    import aou_pkg::*;

    // 单 RP 下分别激励五类消息；远端容量固定充足，只测编解码器固有吞吐。
    logic [MSG_KIND_COUNT-1:0] msg_valid[1], msg_ready[1];
    msg_t msg_data[1][MSG_KIND_COUNT];
    logic [11:0] available[1][MSG_KIND_COUNT], pending[1][MSG_KIND_COUNT];
    logic [7:0] consumed[1][MSG_KIND_COUNT], granted[1][MSG_KIND_COUNT];
    int kind;

    assign kind = msg_kind(tx_message);
    assign tx_ready = kind < MSG_KIND_COUNT ? msg_ready[0][kind] : 1'b0;
    always_comb begin
        msg_valid[0] = '0;
        for (int k = 0; k < MSG_KIND_COUNT; k++) begin
            msg_data[0][k] = tx_message;
            available[0][k] = 12'hfff;
            pending[0][k] = 0;
            if (kind == k) begin
                msg_valid[0][k] = tx_valid;
            end
        end
    end

    always_comb begin
        tx_debit = 0;
        for (int k = 0; k < MSG_KIND_COUNT; k++) begin
            tx_debit = tx_debit | consumed[0][k];
        end
    end

    aou_flit_tx #(
        .RP_COUNT(1)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .enable(rst_n),
        .msg_valid(msg_valid),
        .msg_ready(msg_ready),
        .msg_data(msg_data),
        .available(available),
        .pending(pending),
        .consumed(consumed),
        .granted(granted),
        .flit_valid(tx_flit_valid),
        .flit_ready(tx_flit_ready),
        .flit_data(tx_flit)
    );

    aou_flit_rx #(
        .FRAME_DEPTH(FRAME_DEPTH)
    ) u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .enable(rst_n),
        .flit_valid(rx_flit_valid),
        .flit_ready(rx_flit_ready),
        .flit_data(rx_flit),
        .msg_valid(rx_valid),
        .msg_ready(rx_ready),
        .msg_data(rx_message),
        .header_valid(rx_header_valid),
        .header_credit(rx_header_credit),
        .fault(rx_fault)
    );

    assert property (@(posedge clk) disable iff(!rst_n)
        rx_valid && !rx_ready |=> rx_valid && $stable(rx_message));
    assert property (@(posedge clk) disable iff(!rst_n)
        tx_flit_valid && !tx_flit_ready |=> tx_flit_valid && $stable(tx_flit));
endmodule
