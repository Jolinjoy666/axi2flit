// 两端共用的 AoU 传输层：封包/解包、每 RP/消息类型接收 FIFO、双向 credit。
// 接口数组类型顺序：WREQ、RREQ、WDATA、RDATA、WRESP。DEPTH=0 表示该端不接收此类。
// FIFO 单位是消息条数，credit 单位是 5B；WDATA 按最短消息公布容量，防止条数溢出。
// 三张固定计数表分别表示：远端给予的可发量、本端待归还量、本端已公布但尚未收到量。
module aou_transport #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    parameter int RX_DEPTH0 = 0,
    parameter int RX_DEPTH1 = 0,
    parameter int RX_DEPTH2 = 0,
    parameter int RX_DEPTH3 = 32,
    parameter int RX_DEPTH4 = 32
) (
    // 时钟、复位与链路使能。
    input logic clk,
    input logic rst_n,
    input logic link_up,
    // 待发送消息通道。
    input logic [aou_pkg::MSG_KIND_COUNT-1:0] tx_valid [RP_COUNT],
    output logic [aou_pkg::MSG_KIND_COUNT-1:0] tx_ready [RP_COUNT],
    input aou_pkg::msg_t tx_data [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    // 已接收消息通道。
    output logic [aou_pkg::MSG_KIND_COUNT-1:0] rx_valid [RP_COUNT],
    input logic [aou_pkg::MSG_KIND_COUNT-1:0] rx_ready [RP_COUNT],
    output aou_pkg::msg_t rx_data [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    // 双向 Flit 与 sticky 故障。
    output logic flit_tx_valid,
    input logic flit_tx_ready,
    output aou_pkg::flit_t flit_tx_data,
    input logic flit_rx_valid,
    output logic flit_rx_ready,
    input aou_pkg::flit_t flit_rx_data,
    output logic fault
);
    import aou_pkg::*;

    // 三张 credit 计数表：可发、待归还、已公布但尚未收到。
    logic [11:0] available [RP_COUNT][MSG_KIND_COUNT], pending [RP_COUNT][MSG_KIND_COUNT];
    logic [11:0] promised [RP_COUNT][MSG_KIND_COUNT];
    logic [7:0] consumed [RP_COUNT][MSG_KIND_COUNT], granted [RP_COUNT][MSG_KIND_COUNT];
    logic [8:0] updates [RP_COUNT][MSG_KIND_COUNT];

    // credit 下一拍计算值：用整型保留越界信息，再决定是否写回 12 位计数器。
    int available_calc [RP_COUNT][MSG_KIND_COUNT];
    int pending_calc [RP_COUNT][MSG_KIND_COUNT];
    int promised_calc [RP_COUNT][MSG_KIND_COUNT];
    int received_calc [RP_COUNT][MSG_KIND_COUNT];
    int freed_calc [RP_COUNT][MSG_KIND_COUNT];

    // 接收 FIFO 的逐 RP/类型握手信号。
    logic [MSG_KIND_COUNT-1:0] fifo_valid [RP_COUNT], fifo_ready [RP_COUNT];

    // 帧解包结果、PH credit 和协议错误状态。
    logic raw_valid, raw_ready, ph_valid, rx_fault, own_fault, bad_msg;
    logic [15:0] ph_credit;
    msg_t raw_msg;
    int raw_rp, raw_kind, raw_size;

    // 固定五类消息的本端 FIFO 深度；零深度表示该类不接收。
    function automatic int depth(input int k);
        case (k)
            0: return RX_DEPTH0;
            1: return RX_DEPTH1;
            2: return RX_DEPTH2;
            3: return RX_DEPTH3;
            default: return RX_DEPTH4;
        endcase
    endfunction

    // 组合逻辑：错误汇总与子模块连接。
    assign fault = own_fault || rx_fault;

    aou_flit_tx #(
        .RP_COUNT(RP_COUNT)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .enable(link_up && !fault),
        .msg_valid(tx_valid),
        .msg_ready(tx_ready),
        .msg_data(tx_data),
        .available(available),
        .pending(pending),
        .consumed(consumed),
        .granted(granted),
        .flit_valid(flit_tx_valid),
        .flit_ready(flit_tx_ready),
        .flit_data(flit_tx_data)
    );
    aou_flit_rx u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .enable(link_up && !fault),
        .flit_valid(flit_rx_valid),
        .flit_ready(flit_rx_ready),
        .flit_data(flit_rx_data),
        .msg_valid(raw_valid),
        .msg_ready(raw_ready),
        .msg_data(raw_msg),
        .header_valid(ph_valid),
        .header_credit(ph_credit),
        .fault(rx_fault)
    );
    for (genvar p = 0; p < RP_COUNT; p++) begin : g_rp
        for (genvar k = 0; k < MSG_KIND_COUNT; k++) begin : g_kind
            if (depth(k) > 0) begin : g_enabled
                aou_sync_fifo #(
                    .WIDTH(MSG_BITS),
                    .DEPTH(depth(k)),
                    .FWFT(1'b0)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .s_valid(fifo_valid[p][k]),
                    .s_ready(fifo_ready[p][k]),
                    .s_data(raw_msg),
                    .m_valid(rx_valid[p][k]),
                    .m_ready(rx_ready[p][k]),
                    .m_data(rx_data[p][k]),
                    .level()
                );
            end else begin : g_disabled
                assign fifo_ready[p][k] = 0;
                assign rx_valid[p][k] = 0;
                assign rx_data[p][k] = '0;
            end
        end
    end

    // 检查保留位与本地 DLENGTH；未知类型置错并停止接收，不生成 AXI 响应。
    always_comb begin
        raw_rp = msg_rp(raw_msg);
        raw_kind = msg_kind(raw_msg);
        raw_size = granules(raw_msg[1199:1192]);
        bad_msg = 0;
        raw_ready = 0;
        for (int p = 0; p < RP_COUNT; p++) begin
            fifo_valid[p] = '0;
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                updates[p][k] = '0;
            end
        end
        if (ph_valid && int'(ph_credit[15:14]) < RP_COUNT) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                if (k < 4) begin
                    updates[ph_credit[15:14]][k] = 9'(credit_amount(int'(ph_credit[k*3 +:3])));
                end else begin
                    updates[ph_credit[15:14]][k] = 9'(credit_amount(int'(ph_credit[13:12])));
                end
            end
        end
        if (raw_valid && link_up && !fault) begin
            if (raw_kind == 5) begin
                bad_msg = raw_msg[1199:1196] != 0 || raw_msg[1195:1193] != 4 || raw_msg[1136:1120] != 0;
                raw_ready = 1;
                if (!bad_msg) begin
                    // CrdtGrant：类型 0、操作码 100；四类三位 credit 按类型及 RP0～3 排列，
                    // 最后是四组两位写响应 credit，未启用 RP 的字段不入账。
                    for (int p = 0; p < RP_COUNT; p++) begin
                        for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                            if (k < 4) begin
                                updates[p][k] = updates[p][k] + 9'(credit_amount(int'(raw_msg[1199-7-(k*4+p)*3 -:3])));
                            end else begin
                                updates[p][k] = updates[p][k] + 9'(credit_amount(int'(raw_msg[1199-55-p*2 -:2])));
                            end
                        end
                    end
                end
            end else begin
                bad_msg = raw_rp >= RP_COUNT || depth(raw_kind) == 0 || raw_size == 0;
                if (raw_kind == 0 || raw_kind == 1) begin
                    bad_msg = bad_msg || raw_msg[1193] || !legal_req(get_req(raw_msg), DATA_WIDTH);
                end
                if (raw_kind == 2 || raw_kind == 3) begin
                    bad_msg = bad_msg || raw_msg[1193:1192] != 2'(dl_code(DATA_WIDTH));
                end
                if (raw_kind == 3) begin
                    bad_msg = bad_msg || raw_msg[1162:1160] != 0;
                end
                if (raw_kind == 4) begin
                    bad_msg = bad_msg || raw_msg[1193:1192] != 0 || raw_msg[1163:1160] != 0;
                end
                if (bad_msg) begin
                    raw_ready = 1;
                end else begin
                    fifo_valid[raw_rp][raw_kind] = 1;
                    raw_ready = fifo_ready[raw_rp][raw_kind];
                end
            end
        end
    end

    // 组合逻辑：先用整型计算本拍 credit 的接收、消耗和归还。
    always_comb begin
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                received_calc[p][k] = (raw_valid && raw_ready && !bad_msg && raw_kind == k && raw_rp == p)
                                      ? raw_size : 0;
                freed_calc[p][k] = (rx_valid[p][k] && rx_ready[p][k])
                                   ? granules(rx_data[p][k][1199:1192]) : 0;
                available_calc[p][k] = int'(available[p][k]) + int'(updates[p][k])
                                       - int'(consumed[p][k]);
                pending_calc[p][k] = int'(pending[p][k]) + freed_calc[p][k]
                                     - int'(granted[p][k]);
                promised_calc[p][k] = int'(promised[p][k]) + int'(granted[p][k])
                                      - received_calc[p][k];
            end
        end
    end

    // 加法先用整型临时量计算范围；违规置错而非饱和截断，便于发现重复授信/返回。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            own_fault <= 0;
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    available[p][k] <= 0;
                    pending[p][k] <= 12'(depth(k)*min_granules(k, DATA_WIDTH));
                    promised[p][k] <= 0;
                end
            end
        end else if (link_up && !fault) begin
            if (raw_valid && bad_msg) begin
                own_fault <= 1;
            end
            if (ph_valid && ph_credit != 0 && int'(ph_credit[15:14]) >= RP_COUNT) begin
                own_fault <= 1;
            end
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    if (available_calc[p][k] < 0 || available_calc[p][k] > 4095 ||
                        pending_calc[p][k] < 0 ||
                        pending_calc[p][k] > depth(k)*min_granules(k, DATA_WIDTH) ||
                        promised_calc[p][k] < 0 || promised_calc[p][k] > 4095) begin
                        own_fault <= 1;
                    end else begin
                        available[p][k] <= 12'(available_calc[p][k]);
                        pending[p][k] <= 12'(pending_calc[p][k]);
                        promised[p][k] <= 12'(promised_calc[p][k]);
                    end
                end
            end
        end
    end

    // 仿真期检查数据位宽、RP 数及 12 位 credit 容量；综合时排除。
`ifndef SYNTHESIS
    initial begin
        if (!(DATA_WIDTH == 256 || DATA_WIDTH == 512 || DATA_WIDTH == 1024) || RP_COUNT < 1 || RP_COUNT > 4) begin
            $fatal(1, "Unsupported AoU width/RP configuration");
        end
        for (int k = 0; k < MSG_KIND_COUNT; k++) begin
            if (depth(k) < 0 || depth(k)*min_granules(k, DATA_WIDTH) > 4095) begin
                $fatal(1, "Receive capacity exceeds 12-bit credit range");
            end
        end
    end
`endif
endmodule
