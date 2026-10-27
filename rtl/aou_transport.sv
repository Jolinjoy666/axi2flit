// 两端共用的 AoU 传输层：封包/解包、每 RP/消息类型接收缓冲、双向 credit。
// 接口数组类型顺序：WREQ、RREQ、WDATA、RDATA、WRESP。DEPTH=0 表示该端不接收此类。
// DEPTH 以本端全宽消息条数计；请求与写响应用定长 FIFO，数据消息用分块缓冲，
// 因而能接收按传输大小选择宽度的窄数据消息。credit 单位是 5B 粒度。
// 两张计数表：available 为远端给予的可发量，promised 为已公布但尚未收到的量；
// 待归还量由空闲存储减去 promised 直接算出。对端授信超过计数上限时饱和（规范 6.4 节）。
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

    // credit 计数表：可发量、已公布但尚未收到量；待归还量为组合结果。
    logic [CREDIT_CNT_W-1:0] available [RP_COUNT][MSG_KIND_COUNT], pending [RP_COUNT][MSG_KIND_COUNT];
    logic [CREDIT_CNT_W-1:0] promised [RP_COUNT][MSG_KIND_COUNT];
    int fifo_level [RP_COUNT][MSG_KIND_COUNT];
    logic [GRANT_W-1:0] consumed [RP_COUNT][MSG_KIND_COUNT], granted [RP_COUNT][MSG_KIND_COUNT];
    logic [UPDATE_W-1:0] updates [RP_COUNT][MSG_KIND_COUNT];

    // credit 下一拍计算值：用整型保留越界信息，再决定是否写回计数器。
    int available_calc [RP_COUNT][MSG_KIND_COUNT];
    int promised_calc [RP_COUNT][MSG_KIND_COUNT];
    int received_calc [RP_COUNT][MSG_KIND_COUNT];

    // 接收 FIFO 的逐 RP/类型握手信号。
    logic [MSG_KIND_COUNT-1:0] fifo_valid [RP_COUNT], fifo_ready [RP_COUNT];

    // 帧解包结果、PH credit 和协议错误状态。
    logic raw_valid, raw_ready, ph_valid, rx_fault, own_fault, bad_msg;
    logic [PH_CREDIT_W-1:0] ph_credit;
    msg_t raw_msg;
    int raw_rp, raw_kind, raw_size;
    // 各类消息头视图（先赋给变量再取成员，兼容不支持函数返回值成员选择的综合工具）。
    req_hdr_t raw_req_hdr;
    rdata_hdr_t raw_rdata_hdr;
    wresp_hdr_t raw_wresp_hdr;

    // 固定五类消息的本端深度（全宽消息条数）；零深度表示该类不接收。
    localparam int DEPTHS [MSG_KIND_COUNT] = '{RX_DEPTH0, RX_DEPTH1, RX_DEPTH2, RX_DEPTH3, RX_DEPTH4};
    function automatic int depth(input int k);
        return DEPTHS[k];
    endfunction
    // 每类的存储单元数与 credit 换算比例在 elaboration 时求出，运行期只做乘除常数。
    localparam int UNITS [MSG_KIND_COUNT] = '{unit_count(0, DATA_WIDTH), unit_count(1, DATA_WIDTH),
        unit_count(2, DATA_WIDTH), unit_count(3, DATA_WIDTH), unit_count(4, DATA_WIDTH)};
    localparam int CR_GRAN [MSG_KIND_COUNT] = '{credit_gran(0, DATA_WIDTH), credit_gran(1, DATA_WIDTH),
        credit_gran(2, DATA_WIDTH), credit_gran(3, DATA_WIDTH), credit_gran(4, DATA_WIDTH)};
    localparam int CR_UNITS [MSG_KIND_COUNT] = '{credit_units(0, DATA_WIDTH), credit_units(1, DATA_WIDTH),
        credit_units(2, DATA_WIDTH), credit_units(3, DATA_WIDTH), credit_units(4, DATA_WIDTH)};
    // 存储单元总数，以及空闲单元可公布的 credit 上限。
    function automatic int capacity(input int k);
        return depth(k) * UNITS[k];
    endfunction
    function automatic int grantable(input int k, input int free_units);
        return free_units * CR_GRAN[k] / CR_UNITS[k];
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
            // 先取成局部常量再用于 generate 条件，各仿真器的求值结果一致。
            localparam int D = DEPTHS[k];
            localparam int BANKS = UNITS[k];
            if (D > 0 && is_data_kind(k)) begin : g_chunk
                logic [$clog2(D*BANKS+1)-1:0] level;
                aou_chunk_fifo #(
                    .BANKS(BANKS),
                    .ROWS(D)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .s_valid(fifo_valid[p][k]),
                    .s_ready(fifo_ready[p][k]),
                    .s_data(raw_msg),
                    .m_valid(rx_valid[p][k]),
                    .m_ready(rx_ready[p][k]),
                    .m_data(rx_data[p][k]),
                    .level(level)
                );
                assign fifo_level[p][k] = int'(level);
            end else if (D > 0) begin : g_fixed
                localparam int W = msg_bits(k, DATA_WIDTH);
                logic [W-1:0] m_bits;
                logic [$clog2(D+1)-1:0] level;
                logic full, empty;
                aou_sync_fifo #(
                    .WIDTH(W),
                    .DEPTH(D)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .wr_en(fifo_valid[p][k]),
                    .wr_data(raw_msg[MSG_BITS-1 -: W]),
                    .full(full),
                    .rd_en(rx_ready[p][k]),
                    .rd_data(m_bits),
                    .empty(empty),
                    .level(level)
                );
                assign fifo_ready[p][k] = !full || (rx_ready[p][k] && !empty);
                assign rx_valid[p][k] = !empty;
                assign rx_data[p][k] = {m_bits, {(MSG_BITS-W){1'b0}}};
                assign fifo_level[p][k] = int'(level);
            end else begin : g_disabled
                assign fifo_ready[p][k] = 0;
                assign rx_valid[p][k] = 0;
                assign rx_data[p][k] = '0;
                assign fifo_level[p][k] = 0;
            end
        end
    end

    // 检查保留位与本地 DLENGTH；未知类型置错并停止接收，不生成 AXI 响应。
    always_comb begin
        raw_rp = msg_rp(raw_msg);
        raw_kind = msg_kind(raw_msg);
        raw_size = msg_granules(raw_msg);
        raw_req_hdr = req_hdr(raw_msg);
        raw_rdata_hdr = rdata_hdr(raw_msg);
        raw_wresp_hdr = wresp_hdr(raw_msg);
        bad_msg = 0;
        raw_ready = 0;
        for (int p = 0; p < RP_COUNT; p++) begin
            fifo_valid[p] = '0;
        end
        if (raw_valid && link_up && !fault) begin
            if (raw_kind == K_MISC) begin
                bad_msg = !legal_crdtgrant(raw_msg);
                raw_ready = 1;
            end else begin
                // 对端发送超出已授 credit 的消息属于协议违规，在进入存储前即判错；
                // 未启用的类型始终没有 credit，同样被判错。
                bad_msg = raw_rp >= RP_COUNT || raw_size > int'(promised[raw_rp][raw_kind]);
                if (raw_kind == K_WREQ || raw_kind == K_RREQ) begin
                    bad_msg = bad_msg || raw_req_hdr.rsvd || !legal_req(get_req(raw_msg), DATA_WIDTH);
                end
                if (is_data_kind(raw_kind)) begin
                    bad_msg = bad_msg || msg_dl(raw_msg) > dl_code(DATA_WIDTH);
                end
                if (raw_kind == K_RDATA) begin
                    bad_msg = bad_msg || raw_rdata_hdr.rsvd != 0;
                end
                if (raw_kind == K_WRESP) begin
                    bad_msg = bad_msg || raw_wresp_hdr.rsvd0 != 0 || raw_wresp_hdr.rsvd1 != 0;
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

    // PH 授信与消息路由分开计算，输入 ready 不进入消息输出 ready 的组合锥。
    always_comb begin
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                updates[p][k] = '0;
            end
        end
        if (ph_valid && ph_credit_rp(ph_credit) < RP_COUNT) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                updates[ph_credit_rp(ph_credit)][k] = UPDATE_W'(credit_amount(ph_credit_enc(ph_credit, k)));
            end
        end
        // CrdtGrant：四类三位 credit 按类型及 RP 排列，最后四组为两位写响应 credit。
        if (raw_valid && raw_ready && !bad_msg && raw_kind == K_MISC) begin
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    if (k != K_WRESP) begin
                        updates[p][k] = updates[p][k] + UPDATE_W'(credit_amount(cg_credit3(raw_msg, k*MAX_RP+p)));
                    end else begin
                        updates[p][k] = updates[p][k] + UPDATE_W'(credit_amount(cg_credit2(raw_msg, p)));
                    end
                end
            end
        end
    end

    // 组合逻辑：待归还量由空闲存储直接算出；再计算本拍的接收、消耗和授出。
    always_comb begin
        for (int p = 0; p < RP_COUNT; p++) begin
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                pending[p][k] = CREDIT_CNT_W'(grantable(k, capacity(k) - fifo_level[p][k]) - int'(promised[p][k]));
                received_calc[p][k] = (raw_valid && raw_ready && !bad_msg && raw_kind == k && raw_rp == p)
                                      ? raw_size : 0;
                available_calc[p][k] = int'(available[p][k]) + int'(updates[p][k])
                                       - int'(consumed[p][k]);
                promised_calc[p][k] = int'(promised[p][k]) + int'(granted[p][k])
                                      - received_calc[p][k];
            end
        end
    end

    // 可发量超过计数上限时饱和。发送只在 credit 足够时扣减、授出不超过待归还量、
    // 接收已核对 credit，因而 available 与 promised 不会越界；仿真断言另行检查。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            own_fault <= 0;
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    available[p][k] <= 0;
                    promised[p][k] <= 0;
                end
            end
        end else if (link_up && !fault) begin
            if (raw_valid && bad_msg) begin
                own_fault <= 1;
            end
            if (ph_valid && ph_credit != 0 && ph_credit_rp(ph_credit) >= RP_COUNT) begin
                own_fault <= 1;
            end
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    available[p][k] <= CREDIT_CNT_W'(available_calc[p][k] > CREDIT_CNT_MAX ? CREDIT_CNT_MAX
                                                                                         : available_calc[p][k]);
                    promised[p][k] <= CREDIT_CNT_W'(promised_calc[p][k]);
                end
            end
        end
    end

    // 仿真期检查数据位宽、RP 数及 credit 计数容量，并断言 credit 账目不越界；综合时排除。
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && link_up && !fault) begin
            for (int p = 0; p < RP_COUNT; p++) begin
                for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                    assert (available_calc[p][k] >= 0 && promised_calc[p][k] >= 0 &&
                            promised_calc[p][k] <= grantable(k, capacity(k)))
                        else $error("credit accounting out of range rp=%0d kind=%0d", p, k);
                end
            end
        end
    end
    initial begin
        if (DATA_WIDTH > MAX_DATA_W || DATA_WIDTH != (MIN_DATA_W << dl_code(DATA_WIDTH)) ||
            RP_COUNT < 1 || RP_COUNT > MAX_RP) begin
            $fatal(1, "Unsupported AoU width/RP configuration");
        end
        for (int k = 0; k < MSG_KIND_COUNT; k++) begin
            if (depth(k) < 0 || grantable(k, capacity(k)) > CREDIT_CNT_MAX) begin
                $fatal(1, "Receive capacity exceeds credit counter range");
            end
        end
    end
`endif
endmodule
