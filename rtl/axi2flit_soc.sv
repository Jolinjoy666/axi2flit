// SoC 侧协议桥：对主机表现为 AXI4 Slave；对链路提供双向 250B Flit ready/valid。
// 线上协议字段固定为 ADDR=64、ID=10、USER=16；AXI 侧宽度可配置为不超过线上宽度，上线时高位补零。
// DATA_WIDTH 与 RP_COUNT 可参数化。
// AW/W/AR 独立缓冲；W 依次关联 AW，不要求 AW 与 W 同拍到达。
// 写数据与读数据消息按每拍传输大小选择宽度（256/512/1024 位），窄传输只携带所在通道组。
// 读、写在途事务各记入一张小 CAM 表：表满或同 ID 未完成事务跨 RP 时背压，后者避免跨 RP 响应乱序。
// AXI 侧 READY 只取决于寄存器状态（队列未满、表未满）与本拍输入，不经过组帧器的选择逻辑。
module axi2flit_soc #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,  // RP 数量
    // 每个 RP 的 WREQ/RREQ/WDATA 发送 FIFO 深度（≥ 2）。READY 取自"队列未满"，不等同拍出队，
    // 深度 2 时组帧器每拍取一条仍不断流；满时直接反压 AXI 的 AWREADY/WREADY/ARREADY。
    parameter int TX_DEPTH = 2,
    // 写路由 FIFO 深度：已接受 AW、W 尚未收完的写突发数，即 AW 最多可领先 W 的笔数。
    parameter int WR_ROUTE_DEPTH = 8,
    // 每个 RP 的接收缓冲深度（单位：本端全宽消息条数），决定向对端公布的 RDATA/WRESP credit。
    // 读数据深度 ≈ credit 往返时间 ÷ 消息间隔：256/512 位时每 2ns 一条，约 53ns 往返需 27 条，取 32；
    // 1024 位时受链路限制约 3ns 一条，需 19 条，取 24。推导见设计文档 6.1 节。
    parameter int RDATA_DEPTH = DATA_WIDTH < 1024 ? 32 : 24,
    parameter int WRESP_DEPTH = 24,
    // 读、写最大在途事务数（已握手 AR/AW、尚未返回 RLAST/B 的笔数），即在途表项数；表满时背压 ARREADY/AWREADY。
    parameter int RD_OUTSTANDING = 32,
    parameter int WR_OUTSTANDING = 32,
    // AXI 侧 ID/地址/USER 宽度，不超过线上宽度。
    parameter int AXI_ID_W = aou_pkg::WIRE_ID_W,
    parameter int AXI_ADDR_W = aou_pkg::WIRE_ADDR_W,
    parameter int AXI_USER_W = aou_pkg::WIRE_USER_W
) (
    // 时钟、复位与链路使能。
    input logic clk,
    input logic rst_n,
    input logic link_up,

    // AXI 写地址通道。
    input logic s_axi_awvalid,
    output logic s_axi_awready,
    input logic [AXI_ADDR_W-1:0] s_axi_awaddr,
    input logic [AXI_ID_W-1:0] s_axi_awid,
    input logic [7:0] s_axi_awlen,
    input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst,
    input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awcache,
    input logic [3:0] s_axi_awqos,
    input logic s_axi_awlock,
    input logic [AXI_USER_W-1:0] s_axi_awuser,

    // AXI 写数据通道。
    input logic s_axi_wvalid,
    output logic s_axi_wready,
    input logic [DATA_WIDTH-1:0] s_axi_wdata,
    input logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input logic s_axi_wlast,
    input logic [AXI_USER_W-1:0] s_axi_wuser,

    // AXI 读地址通道。
    input logic s_axi_arvalid,
    output logic s_axi_arready,
    input logic [AXI_ADDR_W-1:0] s_axi_araddr,
    input logic [AXI_ID_W-1:0] s_axi_arid,
    input logic [7:0] s_axi_arlen,
    input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst,
    input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arcache,
    input logic [3:0] s_axi_arqos,
    input logic s_axi_arlock,
    input logic [AXI_USER_W-1:0] s_axi_aruser,

    // AXI 写响应通道。
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    output logic [AXI_ID_W-1:0] s_axi_bid,
    output logic [1:0] s_axi_bresp,
    output logic [AXI_USER_W-1:0] s_axi_buser,

    // AXI 读响应通道。
    output logic s_axi_rvalid,
    input logic s_axi_rready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [AXI_ID_W-1:0] s_axi_rid,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rlast,
    output logic [AXI_USER_W-1:0] s_axi_ruser,

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
    // 写请求路由 FIFO 表项：W 依此找到所属 RP、突发长度、拍大小和起始字节通道。
    typedef struct packed {
        logic [RP_W-1:0] rp;
        logic [7:0] len;
        logic [2:0] size;
        logic [LANE_W-1:0] lane;
    } route_t;

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
    logic r_locked,b_locked, route_valid,route_ready,route_pop,route_full,route_empty;

    // 写请求路由 FIFO 队首；W beat 位置与本拍字节通道。
    route_t route_head;
    logic [8:0] w_index;
    logic [LANE_W-1:0] w_lane;
    logic aw_legal,ar_legal,w_legal,r_bad,b_bad;

    // 在途事务表：每笔一项 {有效, ID, RP}。同 ID 的各项 RP 必然相同（准入时保证）。
    logic [RD_OUTSTANDING-1:0] rd_live, ar_same, ar_other, r_match;
    logic [WR_OUTSTANDING-1:0] wr_live, aw_same, aw_other, b_match;
    logic [AXI_ID_W-1:0] rd_id[RD_OUTSTANDING], wr_id[WR_OUTSTANDING];
    logic [RP_W-1:0] rd_rp[RD_OUTSTANDING], wr_rp[WR_OUTSTANDING];
    int rd_alloc, rd_free, wr_alloc, wr_free;

    // 当前选中的读、写响应消息及其头部。
    msg_t r_message,b_message;
    rdata_hdr_t r_hdr;
    wresp_hdr_t b_hdr;

    // 组合逻辑：AXI 字段封装、路由选择与握手条件。
    assign protocol_error = local_error || transport_error;
    assign aw_fields = '{WIRE_ID_W'(s_axi_awid), WIRE_ADDR_W'(s_axi_awaddr), s_axi_awlen, s_axi_awsize, s_axi_awprot,
                         s_axi_awcache, s_axi_awqos, s_axi_awlock, WIRE_USER_W'(s_axi_awuser)};
    assign ar_fields = '{WIRE_ID_W'(s_axi_arid), WIRE_ADDR_W'(s_axi_araddr), s_axi_arlen, s_axi_arsize, s_axi_arprot,
                         s_axi_arcache, s_axi_arqos, s_axi_arlock, WIRE_USER_W'(s_axi_aruser)};
    assign aw_rp = int'(s_axi_awqos)%RP_COUNT;
    assign ar_rp = int'(s_axi_arqos)%RP_COUNT;
    assign w_rp = int'(route_head.rp);
    assign aw_legal = legal_req(aw_fields, DATA_WIDTH) && s_axi_awburst == 1;
    assign ar_legal = legal_req(ar_fields, DATA_WIDTH) && s_axi_arburst == 1;
    assign w_legal = s_axi_wlast == (w_index == {1'b0, route_head.len});
    assign w_lane = LANE_W'((int'(route_head.lane) + (int'(w_index) << route_head.size)) % (DATA_WIDTH/8));
    // 表未满，且同 ID 的在途事务（若有）都在本 RP。
    assign s_axi_awready = link_up && !protocol_error && route_ready && in_ready[aw_rp][K_WREQ] &&
                           !(&wr_live) && !(|aw_other);
    assign s_axi_arready = link_up && !protocol_error && in_ready[ar_rp][K_RREQ] &&
                           !(&rd_live) && !(|ar_other);
    assign s_axi_wready = link_up && !protocol_error && route_valid && in_ready[w_rp][K_WDATA];
    assign aw_fire = s_axi_awvalid && s_axi_awready;
    assign ar_fire = s_axi_arvalid && s_axi_arready;
    assign w_fire = s_axi_wvalid && s_axi_wready;
    assign b_fire = s_axi_bvalid && s_axi_bready;
    assign r_done = s_axi_rvalid && s_axi_rready && s_axi_rlast;
    assign route_pop = w_fire && w_legal && s_axi_wlast;

    // 实例连接：AW 对应的 RP/长度先进入路由 FIFO，W 依序取出。
    aou_sync_fifo #(
        .WIDTH($bits(route_t)),
        .DEPTH(WR_ROUTE_DEPTH)
    ) u_write_route (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(aw_fire && aw_legal),
        .wr_data(route_t'{rp: RP_W'(aw_rp), len: s_axi_awlen, size: s_axi_awsize, lane: LANE_W'(s_axi_awaddr)}),
        .full(route_full),
        .rd_en(route_pop),
        .rd_data(route_head),
        .empty(route_empty),
        .level()
    );
    assign route_ready = !route_full;
    assign route_valid = !route_empty;

    // 组合逻辑：在途表查找。准入看同 ID 表项的 RP；新事务占最低空闲项，完成时释放最低匹配项。
    always_comb begin
        rd_alloc = 0;
        wr_alloc = 0;
        rd_free = 0;
        wr_free = 0;
        for (int i = 0; i < RD_OUTSTANDING; i++) begin
            ar_same[i] = rd_live[i] && rd_id[i] == s_axi_arid;
            ar_other[i] = ar_same[i] && rd_rp[i] != RP_W'(ar_rp);
        end
        for (int i = 0; i < WR_OUTSTANDING; i++) begin
            aw_same[i] = wr_live[i] && wr_id[i] == s_axi_awid;
            aw_other[i] = aw_same[i] && wr_rp[i] != RP_W'(aw_rp);
        end
        for (int i = RD_OUTSTANDING-1; i >= 0; i--) begin
            if (!rd_live[i]) rd_alloc = i;
            if (r_match[i]) rd_free = i;
        end
        for (int i = WR_OUTSTANDING-1; i >= 0; i--) begin
            if (!wr_live[i]) wr_alloc = i;
            if (b_match[i]) wr_free = i;
        end
    end

    // 组合逻辑：AXI 请求转换为 AoU 消息，并写入对应 RP/类型 FIFO。
    always_comb begin
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            in_valid[rp] = '0;
            for (int k = 0; k < MSG_KIND_COUNT; k++) begin
                in_data[rp][k] = '0;
            end
        end
        in_valid[aw_rp][K_WREQ] = aw_fire && aw_legal;
        in_data[aw_rp][K_WREQ] = make_req(aw_fields,1,aw_rp);
        in_valid[ar_rp][K_RREQ] = ar_fire && ar_legal;
        in_data[ar_rp][K_RREQ] = make_req(ar_fields,0,ar_rp);
        if (route_valid) begin
            in_valid[w_rp][K_WDATA] = w_fire && w_legal;
            in_data[w_rp][K_WDATA] = make_wdata(MAX_DATA_W'(s_axi_wdata),MAX_STRB_W'(s_axi_wstrb),
                                                WIRE_USER_W'(s_axi_wuser),w_rp,route_head.size,w_lane);
        end
    end

    // 实例连接：请求 FIFO 与共享传输层。
    // SoC 侧只发送写请求、读请求和写数据三类；发送队列按该类消息在本端位宽下的最大位数存储，
    // 出队时补零为完整消息向量。
    for (genvar rp = 0; rp < RP_COUNT; rp++) begin : g_rp
        for (genvar k = 0; k < MSG_KIND_COUNT; k++) begin : g_tx
            if (k == K_WREQ || k == K_RREQ || k == K_WDATA) begin : g_queue
                localparam int W = msg_bits(k, DATA_WIDTH);
                logic [W-1:0] m_bits;
                logic full, empty;
                aou_sync_fifo #(
                    .WIDTH(W),
                    .DEPTH(TX_DEPTH)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .wr_en(in_valid[rp][k]),
                    .wr_data(in_data[rp][k][MSG_BITS-1 -: W]),
                    .full(full),
                    .rd_en(tx_ready[rp][k]),
                    .rd_data(m_bits),
                    .empty(empty),
                    .level()
                );
                assign in_ready[rp][k] = !full;
                assign tx_valid[rp][k] = !empty;
                assign tx_data[rp][k] = {m_bits, {(MSG_BITS-W){1'b0}}};
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
        .RX_DEPTH3(RDATA_DEPTH),
        .RX_DEPTH4(WRESP_DEPTH)
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
            if (r_sel < 0 && rx_valid[p][K_RDATA]) begin
                r_sel = p;
            end
            p = (int'(b_next)+n)%RP_COUNT;
            if (b_sel < 0 && rx_valid[p][K_WRESP]) begin
                b_sel = p;
            end
        end
        if (r_locked) begin
            r_sel = int'(r_hold);
        end
        if (b_locked) begin
            b_sel = int'(b_hold);
        end
        // 已收到的响应在 link_up 为低时照常交给主机，VALID 拉高后保持到握手；只有协议错误后停止输出。
        s_axi_rvalid = r_sel >= 0 && !protocol_error;
        s_axi_bvalid = b_sel >= 0 && !protocol_error;
        if (r_sel >= 0) begin
            r_message = rx_data[r_sel][K_RDATA];
            rx_ready[r_sel][K_RDATA] = s_axi_rready && s_axi_rvalid;
        end
        if (b_sel >= 0) begin
            b_message = rx_data[b_sel][K_WRESP];
            rx_ready[b_sel][K_WRESP] = s_axi_bready && s_axi_bvalid;
        end
        r_hdr = rdata_hdr(r_message);
        b_hdr = wresp_hdr(b_message);
        s_axi_rdata = DATA_WIDTH'(get_data(r_message, DATA_WIDTH));
        s_axi_rid = AXI_ID_W'(r_hdr.id);
        s_axi_ruser = AXI_USER_W'(r_hdr.user);
        s_axi_rresp = r_hdr.resp;
        s_axi_rlast = r_hdr.last;
        s_axi_bid = AXI_ID_W'(b_hdr.id);
        s_axi_buser = AXI_USER_W'(b_hdr.user);
        s_axi_bresp = b_hdr.resp;
        // 响应必须属于本方向已接受的 ID/RP。错误响应不能先交给主机再报告错误。
        // 此处仅核对 ID/RP 和在途计数（AXI ID 较窄时线上高位必须为 0）；RLAST/LEN 一致性由响应端保证。
        for (int i = 0; i < RD_OUTSTANDING; i++) begin
            r_match[i] = rd_live[i] && rd_id[i] == s_axi_rid && rd_rp[i] == RP_W'(r_sel);
        end
        for (int i = 0; i < WR_OUTSTANDING; i++) begin
            b_match[i] = wr_live[i] && wr_id[i] == s_axi_bid && wr_rp[i] == RP_W'(b_sel);
        end
        r_bad = r_sel >= 0 && (!(|r_match) || WIRE_ID_W'(s_axi_rid) != r_hdr.id);
        b_bad = b_sel >= 0 && (!(|b_match) || WIRE_ID_W'(s_axi_bid) != b_hdr.id);
        if (r_bad) begin
            s_axi_rvalid = 0;
            rx_ready[r_sel][K_RDATA] = 0;
        end
        if (b_bad) begin
            s_axi_bvalid = 0;
            rx_ready[b_sel][K_WRESP] = 0;
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
            rd_live <= '0;
            wr_live <= '0;
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
            // 分配项为空闲项、释放项为有效项，同拍分配与释放不会落在同一项。
            if (ar_fire && ar_legal) begin
                rd_live[rd_alloc] <= 1'b1;
            end
            if (r_done) begin
                rd_live[rd_free] <= 1'b0;
            end
            if (aw_fire && aw_legal) begin
                wr_live[wr_alloc] <= 1'b1;
            end
            if (b_fire) begin
                wr_live[wr_free] <= 1'b0;
            end
        end
    end

    // 时序逻辑：在途表的 ID 与 RP 只在分配时写入，由有效位屏蔽，存储内容无需复位。
    always_ff @(posedge clk) begin
        if (ar_fire && ar_legal) begin
            rd_id[rd_alloc] <= s_axi_arid;
            rd_rp[rd_alloc] <= RP_W'(ar_rp);
        end
        if (aw_fire && aw_legal) begin
            wr_id[wr_alloc] <= s_axi_awid;
            wr_rp[wr_alloc] <= RP_W'(aw_rp);
        end
    end

    // 仿真期检查 FIFO 深度；综合时排除。
`ifndef SYNTHESIS
    initial begin
        if (TX_DEPTH < 2 || WR_ROUTE_DEPTH < 1 || RDATA_DEPTH < 1 || WRESP_DEPTH < 1 ||
            RD_OUTSTANDING < 1 || WR_OUTSTANDING < 1) begin
            $fatal(1, "SoC TX_DEPTH must be >= 2; other depths and outstanding limits must be positive");
        end
        if (AXI_ID_W < 1 || AXI_ID_W > WIRE_ID_W || AXI_ADDR_W < 12 || AXI_ADDR_W > WIRE_ADDR_W ||
            AXI_USER_W < 1 || AXI_USER_W > WIRE_USER_W) begin
            $fatal(1, "AXI ID/ADDR/USER widths must not exceed the wire format");
        end
    end
`endif
endmodule
