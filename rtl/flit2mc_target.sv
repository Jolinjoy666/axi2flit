// 存储侧响应端：AoU Flit→逐拍 MC 命令，MC 完成→RDATA/WRESP。
// 读、写各有一组命令口和完成口，每拍可各发一条命令。一条命令表示一个 AXI beat：
// addr 为本拍字节地址，size 决定访问范围；写数据复制到整条总线，选通只在本拍所在通道组。
// first/last/len/beat 保留原 burst 上下文。MC 必须为每条命令返回一次带 tag 的完成。
// 读、写各有一个固定深度 ROB，接受乱序完成并按发出顺序退休；写每拍状态合并为一个 B。
// 读数据消息宽度按读请求的 SIZE 选择（规范 5.7 节）。
// 该接口位于 MC 请求侧，不生成 bank/ACT/PRE/刷新或 DFI 引脚，后者属于 MC/PHY。
module flit2mc_target #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    // 接收缓冲深度（全宽消息条数），决定向对端公布的 WREQ/RREQ/WDATA credit。
    parameter int WREQ_DEPTH = 24,
    parameter int RREQ_DEPTH = 32,
    parameter int WDATA_DEPTH = 24,
    parameter int RESPONSE_DEPTH = 8,
    parameter int MC_RD_SLOTS = 16,
    parameter int MC_WR_SLOTS = 16,
    parameter int RD_TAG_WIDTH = MC_RD_SLOTS > 1 ? $clog2(MC_RD_SLOTS) : 1,
    parameter int WR_TAG_WIDTH = MC_WR_SLOTS > 1 ? $clog2(MC_WR_SLOTS) : 1
) (
    // 时钟、复位与链路使能。
    input logic clk,
    input logic rst_n,
    input logic link_up,

    // 双向 Flit 链路。
    output logic flit_tx_valid,
    input logic flit_tx_ready,
    output aou_pkg::flit_t flit_tx_data,
    input logic flit_rx_valid,
    output logic flit_rx_ready,
    input aou_pkg::flit_t flit_rx_data,

    // MC 读命令：每次握手对应一个 AXI 读 beat。
    output logic mc_rd_valid,
    input logic mc_rd_ready,
    output logic [RD_TAG_WIDTH-1:0] mc_rd_tag,
    output logic [1:0] mc_rd_rp,
    output logic [9:0] mc_rd_id,
    output logic [63:0] mc_rd_addr,
    output logic [2:0] mc_rd_size,
    output logic [7:0] mc_rd_len,
    output logic [7:0] mc_rd_beat,
    output logic mc_rd_first,
    output logic mc_rd_last,
    output logic [2:0] mc_rd_prot,
    output logic [3:0] mc_rd_cache,
    output logic [3:0] mc_rd_qos,
    output logic mc_rd_lock,
    output logic [15:0] mc_rd_user,
    // MC 读完成：每条读命令回送一次，tag 用于重排。
    input logic mc_rd_rsp_valid,
    output logic mc_rd_rsp_ready,
    input logic [RD_TAG_WIDTH-1:0] mc_rd_rsp_tag,
    input logic [DATA_WIDTH-1:0] mc_rd_rsp_data,
    input logic [1:0] mc_rd_rsp_resp,

    // MC 写命令：每次握手对应一个 AXI 写 beat。
    output logic mc_wr_valid,
    input logic mc_wr_ready,
    output logic [WR_TAG_WIDTH-1:0] mc_wr_tag,
    output logic [1:0] mc_wr_rp,
    output logic [9:0] mc_wr_id,
    output logic [63:0] mc_wr_addr,
    output logic [2:0] mc_wr_size,
    output logic [7:0] mc_wr_len,
    output logic [7:0] mc_wr_beat,
    output logic mc_wr_first,
    output logic mc_wr_last,
    output logic [2:0] mc_wr_prot,
    output logic [3:0] mc_wr_cache,
    output logic [3:0] mc_wr_qos,
    output logic mc_wr_lock,
    output logic [15:0] mc_wr_user,
    output logic [15:0] mc_wr_wuser,
    output logic [DATA_WIDTH-1:0] mc_wr_data,
    output logic [DATA_WIDTH/8-1:0] mc_wr_strb,
    // MC 写完成：每条写命令回送一次。
    input logic mc_wr_rsp_valid,
    output logic mc_wr_rsp_ready,
    input logic [WR_TAG_WIDTH-1:0] mc_wr_rsp_tag,
    input logic [1:0] mc_wr_rsp_resp,

    // 锁存的协议错误。
    output logic protocol_error
);
    import aou_pkg::*;

    // ROB 计数宽度由可配置槽数推导。
    localparam int RCW = $clog2(MC_RD_SLOTS + 1);
    localparam int WCW = $clog2(MC_WR_SLOTS + 1);

    // 各 RP 的接收请求与待发响应消息通道。
    logic [MSG_KIND_COUNT-1:0] tx_valid[RP_COUNT],tx_ready[RP_COUNT];
    logic [MSG_KIND_COUNT-1:0] rx_valid[RP_COUNT],rx_ready[RP_COUNT];
    logic [MSG_KIND_COUNT-1:0] reply_valid[RP_COUNT],reply_ready[RP_COUNT];
    msg_t tx_data[RP_COUNT][MSG_KIND_COUNT],rx_data[RP_COUNT][MSG_KIND_COUNT];
    msg_t reply_data[RP_COUNT][MSG_KIND_COUNT];

    // 协议错误状态、读写 beat 位置和聚合写响应状态。
    logic transport_error,local_error;
    logic [8:0] rd_beat[RP_COUNT],wr_beat[RP_COUNT];
    logic [1:0] write_status[RP_COUNT];

    // 读 ROB：head 按发出顺序退休，tail 为下一个分配的 tag；保存读数据及其 SIZE/通道。
    logic [RD_TAG_WIDTH-1:0] rd_head,rd_tail;
    logic [RCW-1:0] rd_count;
    logic rd_occupied[MC_RD_SLOTS],rd_completed[MC_RD_SLOTS],rd_last[MC_RD_SLOTS];
    logic [1:0] rd_plane[MC_RD_SLOTS],rd_status[MC_RD_SLOTS];
    logic [9:0] rd_id[MC_RD_SLOTS];
    logic [15:0] rd_user[MC_RD_SLOTS];
    logic [2:0] rd_size[MC_RD_SLOTS];
    logic [6:0] rd_lane[MC_RD_SLOTS];
    logic [DATA_WIDTH-1:0] rd_data[MC_RD_SLOTS];

    // 写 ROB：只记录完成状态。
    logic [WR_TAG_WIDTH-1:0] wr_head,wr_tail;
    logic [WCW-1:0] wr_count;
    logic wr_occupied[MC_WR_SLOTS],wr_completed[MC_WR_SLOTS],wr_last[MC_WR_SLOTS];
    logic [1:0] wr_plane[MC_WR_SLOTS],wr_status[MC_WR_SLOTS];
    logic [9:0] wr_id[MC_WR_SLOTS];
    logic [15:0] wr_user[MC_WR_SLOTS];

    // 读写各自的轮询位置、背压锁定与发出/退休握手。
    int unsigned rd_next,rd_held,wr_next,wr_held;
    logic rd_locked,wr_locked,rd_issue,wr_issue,rd_retire,wr_retire,w_bad;
    int rd_sel,wr_sel,p;

    // 当前选中请求的地址、beat 与退休写响应状态。
    ax_t rd_address,wr_address;
    logic [8:0] rbeat,wbeat;
    logic [63:0] wr_beat_addr;
    logic [1:0] merged_status;

    // 组合逻辑：汇总本地与传输层错误。
    assign protocol_error = local_error || transport_error;

    // 实例连接：传输层及响应 FIFO。
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
    // 响应队列按消息在本端位宽下的最大位数存储。
    for (genvar rp = 0; rp < RP_COUNT; rp++) begin : g_rp
        for (genvar q = 0; q < MSG_KIND_COUNT; q++) begin : g_reply
            if (q >= 3) begin : g_queue
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

    // 读写仲裁各自只在成功 MC 握手后推进。被拒绝时保持选中的请求和 tag，不能重新选路。
    always_comb begin
        rd_sel = -1;
        wr_sel = -1;
        p = 0;
        rd_address = '0;
        wr_address = '0;
        rbeat = 0;
        wbeat = 0;
        w_bad = 0;
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            rx_ready[rp] = '0;
        end
        for (int n = 0; n < RP_COUNT; n++) begin
            p = (int'(rd_next)+n)%RP_COUNT;
            if (rd_sel < 0 && rx_valid[p][1]) begin
                rd_sel = p;
            end
            p = (int'(wr_next)+n)%RP_COUNT;
            if (wr_sel < 0 && rx_valid[p][0] && rx_valid[p][2]) begin
                wr_sel = p;
            end
        end
        if (rd_locked) begin
            rd_sel = int'(rd_held);
        end
        if (wr_locked) begin
            wr_sel = int'(wr_held);
        end

        // 读命令
        mc_rd_valid = rd_sel >= 0 && rd_count < MC_RD_SLOTS && link_up && !protocol_error;
        if (rd_sel >= 0) begin
            rd_address = get_req(rx_data[rd_sel][1]);
            rbeat = rd_beat[rd_sel];
            if (mc_rd_valid && mc_rd_ready && rbeat == {1'b0,rd_address.len}) begin
                rx_ready[rd_sel][1] = 1;
            end
        end
        mc_rd_tag = rd_tail;
        mc_rd_rp = 2'(rd_sel >= 0 ? rd_sel : 0);
        mc_rd_id = rd_address.id;
        mc_rd_addr = rd_address.addr+(64'(rbeat)<<rd_address.size);
        mc_rd_size = rd_address.size;
        mc_rd_len = rd_address.len;
        mc_rd_beat = 8'(rbeat);
        mc_rd_first = rbeat == 0;
        mc_rd_last = rbeat == {1'b0,rd_address.len};
        mc_rd_prot = rd_address.prot;
        mc_rd_cache = rd_address.cache;
        mc_rd_qos = rd_address.qos;
        mc_rd_lock = rd_address.lock;
        mc_rd_user = rd_address.user;

        // 写命令：写数据消息必须能容纳本拍传输大小。
        mc_wr_data = '0;
        mc_wr_strb = '0;
        mc_wr_wuser = 0;
        if (wr_sel >= 0) begin
            wr_address = get_req(rx_data[wr_sel][0]);
            wbeat = wr_beat[wr_sel];
            w_bad = dl_bytes(int'(rx_data[wr_sel][2][1193:1192])) < (1 << wr_address.size);
        end
        wr_beat_addr = wr_address.addr+(64'(wbeat)<<wr_address.size);
        mc_wr_valid = wr_sel >= 0 && !w_bad && wr_count < MC_WR_SLOTS && link_up && !protocol_error;
        if (wr_sel >= 0) begin
            mc_wr_data = DATA_WIDTH'(get_data(rx_data[wr_sel][2],DATA_WIDTH));
            mc_wr_strb = (DATA_WIDTH/8)'(get_strb(rx_data[wr_sel][2],7'(wr_beat_addr % (DATA_WIDTH/8))));
            mc_wr_wuser = rx_data[wr_sel][2][1191:1176];
            if (mc_wr_valid && mc_wr_ready) begin
                rx_ready[wr_sel][2] = 1;
                if (wbeat == {1'b0,wr_address.len}) begin
                    rx_ready[wr_sel][0] = 1;
                end
            end
        end
        mc_wr_tag = wr_tail;
        mc_wr_rp = 2'(wr_sel >= 0 ? wr_sel : 0);
        mc_wr_id = wr_address.id;
        mc_wr_addr = wr_beat_addr;
        mc_wr_size = wr_address.size;
        mc_wr_len = wr_address.len;
        mc_wr_beat = 8'(wbeat);
        mc_wr_first = wbeat == 0;
        mc_wr_last = wbeat == {1'b0,wr_address.len};
        mc_wr_prot = wr_address.prot;
        mc_wr_cache = wr_address.cache;
        mc_wr_qos = wr_address.qos;
        mc_wr_lock = wr_address.lock;
        mc_wr_user = wr_address.user;
    end

    assign rd_issue = mc_rd_valid && mc_rd_ready;
    assign wr_issue = mc_wr_valid && mc_wr_ready;
    assign mc_rd_rsp_ready = link_up && !protocol_error;
    assign mc_wr_rsp_ready = link_up && !protocol_error;

    // 只有 ROB 头完成才退休；后续 tag 提前返回时只置 completed，不提前产生 AXI 响应。
    // 读、写 ROB 写入不同响应队列，可同拍各退休一项。
    always_comb begin
        rd_retire = 0;
        wr_retire = 0;
        merged_status = 0;
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            reply_valid[rp] = '0;
            for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                reply_data[rp][q] = '0;
            end
        end
        if (rd_count != 0 && rd_occupied[rd_head] && rd_completed[rd_head] && link_up && !protocol_error) begin
            reply_valid[rd_plane[rd_head]][3] = 1;
            reply_data[rd_plane[rd_head]][3] = make_rdata(1024'(rd_data[rd_head]),rd_id[rd_head],rd_user[rd_head],
                rd_status[rd_head],rd_last[rd_head],int'(rd_plane[rd_head]),rd_size[rd_head],rd_lane[rd_head]);
            rd_retire = reply_ready[rd_plane[rd_head]][3];
        end
        if (wr_count != 0 && wr_occupied[wr_head] && wr_completed[wr_head] && link_up && !protocol_error) begin
            merged_status = wr_status[wr_head] > write_status[wr_plane[wr_head]] ?
                            wr_status[wr_head] : write_status[wr_plane[wr_head]];
            if (!wr_last[wr_head]) begin
                wr_retire = 1;
            end else begin
                reply_valid[wr_plane[wr_head]][4] = 1;
                reply_data[wr_plane[wr_head]][4] = make_b(wr_id[wr_head],wr_user[wr_head],merged_status,
                                                          int'(wr_plane[wr_head]));
                wr_retire = reply_ready[wr_plane[wr_head]][4];
            end
        end
    end

    // 时序逻辑：分配 ROB、登记乱序完成、按 head 退休。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_head <= 0;
            rd_tail <= 0;
            rd_count <= 0;
            wr_head <= 0;
            wr_tail <= 0;
            wr_count <= 0;
            local_error <= 0;
            rd_next <= 0;
            wr_next <= 0;
            rd_held <= 0;
            wr_held <= 0;
            rd_locked <= 0;
            wr_locked <= 0;
            for (int rp = 0; rp < RP_COUNT; rp++) begin
                rd_beat[rp] <= 0;
                wr_beat[rp] <= 0;
                write_status[rp] <= 0;
            end
            for (int s = 0; s < MC_RD_SLOTS; s++) begin
                rd_occupied[s] <= 0;
                rd_completed[s] <= 0;
            end
            for (int s = 0; s < MC_WR_SLOTS; s++) begin
                wr_occupied[s] <= 0;
                wr_completed[s] <= 0;
            end
        end else begin
            if (wr_sel >= 0 && w_bad && link_up) begin
                local_error <= 1;
            end
            // ---- 读 ----
            if (mc_rd_valid) begin
                rd_locked <= !mc_rd_ready;
                rd_held <= unsigned'(rd_sel);
            end
            if (rd_issue) begin
                rd_occupied[rd_tail] <= 1;
                rd_completed[rd_tail] <= 0;
                rd_last[rd_tail] <= mc_rd_last;
                rd_plane[rd_tail] <= mc_rd_rp;
                rd_id[rd_tail] <= mc_rd_id;
                rd_user[rd_tail] <= mc_rd_user;
                rd_size[rd_tail] <= mc_rd_size;
                rd_lane[rd_tail] <= 7'(mc_rd_addr % (DATA_WIDTH/8));
                rd_tail <= rd_tail == MC_RD_SLOTS-1 ? '0 : rd_tail+1'b1;
                rd_next <= unsigned'((rd_sel+1)%RP_COUNT);
                rd_beat[mc_rd_rp] <= mc_rd_last ? 0 : rd_beat[mc_rd_rp]+1'b1;
            end
            if (mc_rd_rsp_valid && mc_rd_rsp_ready) begin
                if (int'(mc_rd_rsp_tag) >= MC_RD_SLOTS || !rd_occupied[mc_rd_rsp_tag] || rd_completed[mc_rd_rsp_tag]) begin
                    local_error <= 1;
                end else begin
                    rd_completed[mc_rd_rsp_tag] <= 1;
                    rd_data[mc_rd_rsp_tag] <= mc_rd_rsp_data;
                    rd_status[mc_rd_rsp_tag] <= mc_rd_rsp_resp;
                end
            end
            if (rd_retire) begin
                rd_occupied[rd_head] <= 0;
                rd_completed[rd_head] <= 0;
                rd_head <= rd_head == MC_RD_SLOTS-1 ? '0 : rd_head+1'b1;
            end
            case ({rd_issue, rd_retire})
                2'b10: rd_count <= rd_count+1'b1;
                2'b01: rd_count <= rd_count-1'b1;
                default: ;
            endcase
            // ---- 写 ----
            if (mc_wr_valid) begin
                wr_locked <= !mc_wr_ready;
                wr_held <= unsigned'(wr_sel);
            end
            if (wr_issue) begin
                wr_occupied[wr_tail] <= 1;
                wr_completed[wr_tail] <= 0;
                wr_last[wr_tail] <= mc_wr_last;
                wr_plane[wr_tail] <= mc_wr_rp;
                wr_id[wr_tail] <= mc_wr_id;
                wr_user[wr_tail] <= mc_wr_user;
                wr_tail <= wr_tail == MC_WR_SLOTS-1 ? '0 : wr_tail+1'b1;
                wr_next <= unsigned'((wr_sel+1)%RP_COUNT);
                wr_beat[mc_wr_rp] <= mc_wr_last ? 0 : wr_beat[mc_wr_rp]+1'b1;
            end
            if (mc_wr_rsp_valid && mc_wr_rsp_ready) begin
                if (int'(mc_wr_rsp_tag) >= MC_WR_SLOTS || !wr_occupied[mc_wr_rsp_tag] || wr_completed[mc_wr_rsp_tag]) begin
                    local_error <= 1;
                end else begin
                    wr_completed[mc_wr_rsp_tag] <= 1;
                    wr_status[mc_wr_rsp_tag] <= mc_wr_rsp_resp;
                end
            end
            if (wr_retire) begin
                wr_occupied[wr_head] <= 0;
                wr_completed[wr_head] <= 0;
                write_status[wr_plane[wr_head]] <= wr_last[wr_head] ? 0 : merged_status;
                wr_head <= wr_head == MC_WR_SLOTS-1 ? '0 : wr_head+1'b1;
            end
            case ({wr_issue, wr_retire})
                2'b10: wr_count <= wr_count+1'b1;
                2'b01: wr_count <= wr_count-1'b1;
                default: ;
            endcase
        end
    end

    // 仿真期检查 FIFO 深度与 ROB tag 容量；综合时排除。
`ifndef SYNTHESIS
    initial begin
        if (WREQ_DEPTH < 1 || RREQ_DEPTH < 1 || WDATA_DEPTH < 1 || RESPONSE_DEPTH < 1) begin
            $fatal(1, "Target FIFO depths must be positive");
        end
        if (MC_RD_SLOTS < 1 || MC_RD_SLOTS > 256 || (1<<RD_TAG_WIDTH) < MC_RD_SLOTS ||
            MC_WR_SLOTS < 1 || MC_WR_SLOTS > 256 || (1<<WR_TAG_WIDTH) < MC_WR_SLOTS) begin
            $fatal(1, "Invalid MC tag/ROB capacity");
        end
    end
`endif
endmodule
