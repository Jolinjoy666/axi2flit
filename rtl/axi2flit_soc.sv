// SoC 侧协议桥：对主机表现为 AXI4 Slave；对链路提供双向 250B Flit ready/valid。
// 固定协议字段：ADDR=64、ID=10、USER=16；DATA_WIDTH 与 RP_COUNT 可参数化。
// AW/W/AR 独立缓冲；W 依次关联 AW，不要求 AW 与 W 同拍到达。
// 同 ID 未完成事务跨 RP 时先背压，等旧事务完成后再接收，避免跨 RP 响应乱序。
module axi2flit_soc #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    parameter int TX_DEPTH = 8,
    parameter int RX_DEPTH = 32
) (
    // 时钟、复位与链路使能。
    input logic clk,
    input logic rst_n,
    input logic link_up,

    // AXI 写地址通道。
    input logic s_axi_awvalid,
    output logic s_axi_awready,
    input logic [63:0] s_axi_awaddr,
    input logic [9:0] s_axi_awid,
    input logic [7:0] s_axi_awlen,
    input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst,
    input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awcache,
    input logic [3:0] s_axi_awqos,
    input logic s_axi_awlock,
    input logic [15:0] s_axi_awuser,

    // AXI 写数据通道。
    input logic s_axi_wvalid,
    output logic s_axi_wready,
    input logic [DATA_WIDTH-1:0] s_axi_wdata,
    input logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input logic s_axi_wlast,
    input logic [15:0] s_axi_wuser,

    // AXI 读地址通道。
    input logic s_axi_arvalid,
    output logic s_axi_arready,
    input logic [63:0] s_axi_araddr,
    input logic [9:0] s_axi_arid,
    input logic [7:0] s_axi_arlen,
    input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst,
    input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arcache,
    input logic [3:0] s_axi_arqos,
    input logic s_axi_arlock,
    input logic [15:0] s_axi_aruser,

    // AXI 写响应通道。
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    output logic [9:0] s_axi_bid,
    output logic [1:0] s_axi_bresp,
    output logic [15:0] s_axi_buser,

    // AXI 读响应通道。
    output logic s_axi_rvalid,
    input logic s_axi_rready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [9:0] s_axi_rid,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rlast,
    output logic [15:0] s_axi_ruser,

    // 双向 Flit 链路与协议错误状态。
    output logic flit_tx_valid,
    input logic flit_tx_ready,
    output aou_pkg::flit_t flit_tx_data,
    input logic flit_rx_valid,
    output logic flit_rx_ready,
    input aou_pkg::flit_t flit_rx_data,
    output logic protocol_error
);
    import aou_pkg::*;

    // 各 RP 的五类消息通道：发送、接收及入队握手。
    logic [MSG_KIND_COUNT-1:0] tx_valid[RP_COUNT],tx_ready[RP_COUNT];
    logic [MSG_KIND_COUNT-1:0] rx_valid[RP_COUNT],rx_ready[RP_COUNT];
    logic [MSG_KIND_COUNT-1:0] in_valid[RP_COUNT],in_ready[RP_COUNT];
    msg_t tx_data[RP_COUNT][MSG_KIND_COUNT],rx_data[RP_COUNT][MSG_KIND_COUNT];
    msg_t in_data[RP_COUNT][MSG_KIND_COUNT];

    // AXI 请求字段、握手、协议合法性与错误状态。
    logic local_error, transport_error, aw_fire, ar_fire, w_fire, b_fire, r_done;
    ax_t aw_fields, ar_fields;
    int aw_rp, ar_rp, w_rp, r_sel, b_sel, p;

    // 响应仲裁轮询位置及背压期间的 RP 锁定状态。
    int unsigned r_next, b_next, r_hold, b_hold;
    logic r_locked,b_locked, route_valid,route_ready,route_pop;

    // 写请求路由 FIFO 及 W beat 位置。
    logic [9:0] route_head;
    logic [8:0] w_index;
    logic aw_legal,ar_legal,w_legal,r_bad,b_bad;

    // 每个 AXI ID 的未完成事务数与固定 RP 归属。
    logic [15:0] rd_count[AXI_ID_COUNT],wr_count[AXI_ID_COUNT];
    logic [1:0] rd_rp[AXI_ID_COUNT],wr_rp[AXI_ID_COUNT];

    // 当前选中的读、写响应消息。
    msg_t r_message,b_message;

    // 组合逻辑：AXI 字段封装、路由选择与握手条件。
    assign protocol_error = local_error || transport_error;
    assign aw_fields = '{s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awprot,
                         s_axi_awcache, s_axi_awqos, s_axi_awlock, s_axi_awuser};
    assign ar_fields = '{s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arprot,
                         s_axi_arcache, s_axi_arqos, s_axi_arlock, s_axi_aruser};
    assign aw_rp = int'(s_axi_awqos)%RP_COUNT;
    assign ar_rp = int'(s_axi_arqos)%RP_COUNT;
    assign w_rp = int'(route_head[9:8]);
    assign aw_legal = legal_req(aw_fields, DATA_WIDTH) && s_axi_awburst == 1;
    assign ar_legal = legal_req(ar_fields, DATA_WIDTH) && s_axi_arburst == 1;
    assign w_legal = s_axi_wlast == (w_index == {1'b0, route_head[7:0]});
    assign s_axi_awready = link_up && !protocol_error && route_ready && in_ready[aw_rp][0] &&
                           wr_count[s_axi_awid] != 16'hffff &&
                           (wr_count[s_axi_awid] == 0 || wr_rp[s_axi_awid] == 2'(aw_rp));
    assign s_axi_arready = link_up && !protocol_error && in_ready[ar_rp][1] &&
                           rd_count[s_axi_arid] != 16'hffff &&
                           (rd_count[s_axi_arid] == 0 || rd_rp[s_axi_arid] == 2'(ar_rp));
    assign s_axi_wready = link_up && !protocol_error && route_valid && in_ready[w_rp][2];
    assign aw_fire = s_axi_awvalid && s_axi_awready;
    assign ar_fire = s_axi_arvalid && s_axi_arready;
    assign w_fire = s_axi_wvalid && s_axi_wready;
    assign b_fire = s_axi_bvalid && s_axi_bready;
    assign r_done = s_axi_rvalid && s_axi_rready && s_axi_rlast;
    assign route_pop = w_fire && w_legal && s_axi_wlast;

    // 实例连接：AW 对应的 RP/长度先进入路由 FIFO，W 依序取出。
    aou_sync_fifo #(
        .WIDTH(10),
        .DEPTH(TX_DEPTH * RP_COUNT),
        .FWFT(1'b0)
    ) u_write_route (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(aw_fire && aw_legal),
        .s_ready(route_ready),
        .s_data({2'(aw_rp), s_axi_awlen}),
        .m_valid(route_valid),
        .m_ready(route_pop),
        .m_data(route_head),
        .level()
    );

    // 组合逻辑：AXI 请求转换为 AoU 消息，并写入对应 RP/类型 FIFO。
    always_comb begin
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            in_valid[rp] = '0;
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                in_data[rp][k] = '0;
            end
        end
        in_valid[aw_rp][0] = aw_fire && aw_legal;
        in_data[aw_rp][0] = make_req(aw_fields,1,aw_rp);
        in_valid[ar_rp][1] = ar_fire && ar_legal;
        in_data[ar_rp][1] = make_req(ar_fields,0,ar_rp);
        if (route_valid) begin
            in_valid[w_rp][2] = w_fire && w_legal;
            in_data[w_rp][2] = make_wdata(1024'(s_axi_wdata),128'(s_axi_wstrb),s_axi_wuser,w_rp,DATA_WIDTH);
        end
    end

    // 实例连接：请求 FIFO 与共享传输层。
    for (genvar rp = 0; rp < RP_COUNT; rp++) begin : g_rp
        for (genvar k = 0; k < MSG_KIND_COUNT; k++) begin : g_tx
            if (k < 3) begin : g_queue
                aou_sync_fifo #(
                    .WIDTH(MSG_BITS),
                    .DEPTH(TX_DEPTH),
                    .FWFT(1'b0)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .s_valid(in_valid[rp][k]),
                    .s_ready(in_ready[rp][k]),
                    .s_data(in_data[rp][k]),
                    .m_valid(tx_valid[rp][k]),
                    .m_ready(tx_ready[rp][k]),
                    .m_data(tx_data[rp][k]),
                    .level()
                );
            end else begin : g_no_queue
                assign tx_valid[rp][k] = 0;
                assign tx_data[rp][k] = '0;
                assign in_ready[rp][k] = 0;
            end
        end
    end
    aou_transport #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .RX_DEPTH3(RX_DEPTH),
        .RX_DEPTH4(RX_DEPTH)
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

    // 已公布 VALID 后锁定 RP，直到握手，避免另一个 RP 新到数据改变输出。
    always_comb begin
        r_sel = -1;
        b_sel = -1;
        p = 0;
        r_message = '0;
        b_message = '0;
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            rx_ready[rp] = '0;
        end
        for (int n = 0; n < RP_COUNT; n++) begin
            p = (int'(r_next)+n)%RP_COUNT;
            if (r_sel < 0 && rx_valid[p][3]) begin
                r_sel = p;
            end
            p = (int'(b_next)+n)%RP_COUNT;
            if (b_sel < 0 && rx_valid[p][4]) begin
                b_sel = p;
            end
        end
        if (r_locked) begin
            r_sel = int'(r_hold);
        end
        if (b_locked) begin
            b_sel = int'(b_hold);
        end
        s_axi_rvalid = r_sel >= 0 && link_up && !protocol_error;
        s_axi_bvalid = b_sel >= 0 && link_up && !protocol_error;
        if (r_sel >= 0) begin
            r_message = rx_data[r_sel][3];
            rx_ready[r_sel][3] = s_axi_rready && s_axi_rvalid;
        end
        if (b_sel >= 0) begin
            b_message = rx_data[b_sel][4];
            rx_ready[b_sel][4] = s_axi_bready && s_axi_bvalid;
        end
        s_axi_rdata = DATA_WIDTH'(get_data(r_message, DATA_WIDTH));
        s_axi_rid = r_message[1175:1166];
        s_axi_ruser = r_message[1191:1176];
        s_axi_rresp = r_message[1165:1164];
        s_axi_rlast = r_message[1163];
        s_axi_bid = b_message[1175:1166];
        s_axi_buser = b_message[1191:1176];
        s_axi_bresp = b_message[1165:1164];
        // 响应必须属于本方向已接受的 ID/RP。错误响应不能先交给主机再报告错误。
        // 此处仅核对 ID/RP 和在途计数；RLAST/LEN 一致性由响应端保证。
        r_bad = r_sel >= 0 && (rd_count[s_axi_rid] == 0 || rd_rp[s_axi_rid] != 2'(r_sel));
        b_bad = b_sel >= 0 && (wr_count[s_axi_bid] == 0 || wr_rp[s_axi_bid] != 2'(b_sel));
        if (r_bad) begin
            s_axi_rvalid = 0;
            rx_ready[r_sel][3] = 0;
        end
        if (b_bad) begin
            s_axi_bvalid = 0;
            rx_ready[b_sel][4] = 0;
        end
    end

    // 时序逻辑：事务计数、W beat 位置及响应 RP 锁定。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            local_error <= 0;
            w_index <= 0;
            r_next <= 0;
            b_next <= 0;
            r_hold <= 0;
            b_hold <= 0;
            r_locked <= 0;
            b_locked <= 0;
            for (int i = 0; i < AXI_ID_COUNT; i++) begin
                rd_count[i] <= 0;
                wr_count[i] <= 0;
                rd_rp[i] <= 0;
                wr_rp[i] <= 0;
            end
        end else begin
            if ((aw_fire && !aw_legal)||(ar_fire && !ar_legal)||(w_fire && !w_legal)) begin
                local_error <= 1;
            end
            if (link_up && (r_bad || b_bad)) begin
                local_error <= 1;
            end
            if (w_fire && w_legal) begin
                w_index <= s_axi_wlast ? 0 : w_index+1'b1;
            end
            if (s_axi_rvalid) begin
                r_locked <= !s_axi_rready;
                r_hold <= unsigned'(r_sel);
                if (s_axi_rready) begin
                    r_next <= unsigned'((r_sel+1)%RP_COUNT);
                end
            end
            if (s_axi_bvalid) begin
                b_locked <= !s_axi_bready;
                b_hold <= unsigned'(b_sel);
                if (s_axi_bready) begin
                    b_next <= unsigned'((b_sel+1)%RP_COUNT);
                end
            end
            for (int i = 0; i < AXI_ID_COUNT; i++) begin
                case ({ar_fire && ar_legal && s_axi_arid==i,r_done && s_axi_rid==i})
                    2'b10: rd_count[i] <= rd_count[i]+1'b1;
                    2'b01: rd_count[i] <= rd_count[i]-1'b1;
                    default: ;
                endcase
                case ({aw_fire && aw_legal && s_axi_awid==i,b_fire && s_axi_bid==i})
                    2'b10: wr_count[i] <= wr_count[i]+1'b1;
                    2'b01: wr_count[i] <= wr_count[i]-1'b1;
                    default: ;
                endcase
                if (ar_fire && ar_legal && s_axi_arid == i) begin
                    rd_rp[i] <= 2'(ar_rp);
                end
                if (aw_fire && aw_legal && s_axi_awid == i) begin
                    wr_rp[i] <= 2'(aw_rp);
                end
            end
        end
    end

    // 仿真期检查 FIFO 深度；综合时排除。
`ifndef SYNTHESIS
    initial begin
        if (TX_DEPTH < 1 || RX_DEPTH < 1) begin
            $fatal(1, "SoC FIFO depths must be positive");
        end
    end
`endif
endmodule
