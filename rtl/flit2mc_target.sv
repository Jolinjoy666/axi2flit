// 存储侧响应端：AoU Flit→逐拍 MC 命令，MC 完成→RDATA/WRESP。
// 一条 MC 命令表示一个 AXI beat 的读/写：addr 为字节地址，size 决定访问范围，
// wdata/wstrb 保留完整 AXI lane 布局。first/last/len/beat 保留原 burst 上下文。
// MC 不需要理解 AoU credit；必须为每条命令返回一次带 tag 的响应（包括每拍写）。
// 固定深度 ROB 接受 MC 乱序完成，按命令发出顺序退休；写每拍状态聚合成一个 B。
// 该接口位于 MC 请求侧，不生成 bank/ACT/PRE/刷新或 DFI 引脚，后者属于 MC/PHY。
module flit2mc_target #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    parameter int REQUEST_DEPTH = 4,
    parameter int WDATA_DEPTH = 32,
    parameter int RESPONSE_DEPTH = 8,
    parameter int MC_SLOTS = 16,
    parameter int TAG_WIDTH = MC_SLOTS > 1 ? $clog2(MC_SLOTS) : 1
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

    // MC 命令：每次握手对应一个 AXI beat，并携带 tag 和 burst 上下文。
    output logic mc_req_valid,
    input logic mc_req_ready,
    output logic mc_req_write,
    output logic [TAG_WIDTH-1:0] mc_req_tag,
    output logic [1:0] mc_req_rp,
    output logic [9:0] mc_req_id,
    output logic [63:0] mc_req_addr,
    output logic [2:0] mc_req_size,
    output logic [7:0] mc_req_len,
    output logic [7:0] mc_req_beat,
    output logic mc_req_first,
    output logic mc_req_last,
    output logic [2:0] mc_req_prot,
    output logic [3:0] mc_req_cache,
    output logic [3:0] mc_req_qos,
    output logic mc_req_lock,
    output logic [15:0] mc_req_auser,
    output logic [15:0] mc_req_wuser,
    output logic [DATA_WIDTH-1:0] mc_req_wdata,
    output logic [DATA_WIDTH/8-1:0] mc_req_wstrb,

    // MC 完成：每条命令需回送一次，tag 用于重排。
    input logic mc_rsp_valid,
    output logic mc_rsp_ready,
    input logic [TAG_WIDTH-1:0] mc_rsp_tag,
    input logic [DATA_WIDTH-1:0] mc_rsp_rdata,
    input logic [1:0] mc_rsp_resp,

    // 锁存的协议错误。
    output logic protocol_error
);
    import aou_pkg::*;

    // ROB 计数宽度由可配置槽数推导。
    localparam int CW = $clog2(MC_SLOTS + 1);

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

    // MC 重排缓冲：head 按发出顺序退休，tail 为下一个分配的 tag。
    logic [TAG_WIDTH-1:0] head,tail;
    logic [CW-1:0] count;
    logic occupied[MC_SLOTS],completed[MC_SLOTS],is_write[MC_SLOTS],is_last[MC_SLOTS];
    logic [1:0] plane[MC_SLOTS],status[MC_SLOTS];
    logic [9:0] id[MC_SLOTS];
    logic [15:0] user[MC_SLOTS];
    logic [DATA_WIDTH-1:0] data[MC_SLOTS];

    // 请求仲裁位置、背压锁定与发出/退休握手。
    int unsigned next_slot,held_slot;
    logic locked,issue,retire;
    int selected,p,k,slot;

    // 当前选中请求的地址、beat 与退休写响应状态。
    ax_t address;
    logic [8:0] beat;
    logic [1:0] merged_status;

    // 组合逻辑：汇总本地与传输层错误。
    assign protocol_error = local_error || transport_error;

    // 实例连接：传输层及响应 FIFO。
    aou_transport #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .RX_DEPTH0(REQUEST_DEPTH),
        .RX_DEPTH1(REQUEST_DEPTH),
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
    for (genvar rp = 0; rp < RP_COUNT; rp++) begin : g_rp
        for (genvar q = 0; q < MSG_KIND_COUNT; q++) begin : g_reply
            if (q >= 3) begin : g_queue
                aou_sync_fifo #(
                    .WIDTH(MSG_BITS),
                    .DEPTH(RESPONSE_DEPTH),
                    .FWFT(1'b0)
                ) u_fifo (
                    .clk(clk),
                    .rst_n(rst_n),
                    .s_valid(reply_valid[rp][q]),
                    .s_ready(reply_ready[rp][q]),
                    .s_data(reply_data[rp][q]),
                    .m_valid(tx_valid[rp][q]),
                    .m_ready(tx_ready[rp][q]),
                    .m_data(tx_data[rp][q]),
                    .level()
                );
            end else begin : g_no_queue
                assign tx_valid[rp][q] = 0;
                assign tx_data[rp][q] = '0;
                assign reply_ready[rp][q] = 0;
            end
        end
    end

    // 仲裁只在成功 MC 握手后推进。被拒绝时保持选中的请求和 tag，不能重新选路。
    always_comb begin
        selected = -1;
        p = 0;
        k = 0;
        slot = 0;
        address = '0;
        beat = 0;
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            rx_ready[rp] = '0;
        end
        for (int n = 0; n < RP_COUNT*2; n++) begin
            slot = (int'(next_slot)+n)%(RP_COUNT*2);
            p = slot/2;
            if (selected < 0 && ((slot%2 == 0 && rx_valid[p][1]) ||
                                 (slot%2 == 1 && rx_valid[p][0] && rx_valid[p][2]))) begin
                selected = slot;
            end
        end
        if (locked) begin
            selected = int'(held_slot);
        end
        mc_req_valid = selected >= 0 && count < MC_SLOTS && link_up && !protocol_error;
        mc_req_write = 0;
        mc_req_wdata = '0;
        mc_req_wstrb = '0;
        mc_req_wuser = 0;
        mc_req_rp = 0;
        if (selected >= 0) begin
            p = selected/2;
            mc_req_rp = 2'(p);
            mc_req_write = selected%2 == 1;
            k = mc_req_write ? 0 : 1;
            address = get_req(rx_data[p][k]);
            beat = mc_req_write ? wr_beat[p] : rd_beat[p];
            if (mc_req_write) begin
                mc_req_wdata = DATA_WIDTH'(get_data(rx_data[p][2],DATA_WIDTH));
                mc_req_wstrb = (DATA_WIDTH/8)'(get_strb(rx_data[p][2],DATA_WIDTH));
                mc_req_wuser = rx_data[p][2][1191:1176];
            end
            if (mc_req_valid && mc_req_ready) begin
                if (mc_req_write) begin
                    rx_ready[p][2] = 1;
                end
                if (beat == {1'b0,address.len}) begin
                    rx_ready[p][k] = 1;
                end
            end
        end
        mc_req_tag = tail;
        mc_req_id = address.id;
        mc_req_addr = address.addr+(64'(beat)<<address.size);
        mc_req_size = address.size;
        mc_req_len = address.len;
        mc_req_beat = 8'(beat);
        mc_req_first = beat == 0;
        mc_req_last = beat == {1'b0,address.len};
        mc_req_prot = address.prot;
        mc_req_cache = address.cache;
        mc_req_qos = address.qos;
        mc_req_lock = address.lock;
        mc_req_auser = address.user;
    end

    assign issue = mc_req_valid && mc_req_ready;
    assign mc_rsp_ready = link_up && !protocol_error;

    // 只有 ROB 头完成才退休；后续 tag 提前返回时只置 completed，不提前产生 AXI 响应。
    always_comb begin
        retire = 0;
        merged_status = 0;
        for (int rp = 0; rp < RP_COUNT; rp++) begin
            reply_valid[rp] = '0;
            for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                reply_data[rp][q] = '0;
            end
        end
        if (count != 0 && occupied[head] && completed[head] && link_up && !protocol_error) begin
            if (is_write[head]) begin
                merged_status = status[head] > write_status[plane[head]] ? status[head] : write_status[plane[head]];
                if (!is_last[head]) begin
                    retire = 1;
                end else begin
                    reply_valid[plane[head]][4] = 1;
                    reply_data[plane[head]][4] = make_b(id[head],user[head],merged_status,int'(plane[head]));
                    retire = reply_ready[plane[head]][4];
                end
            end else begin
                reply_valid[plane[head]][3] = 1;
                reply_data[plane[head]][3] = make_rdata(1024'(data[head]),id[head],user[head],
                    status[head],is_last[head],int'(plane[head]),DATA_WIDTH);
                retire = reply_ready[plane[head]][3];
            end
        end
    end

    // 时序逻辑：分配 ROB、登记乱序完成、按 head 退休。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= 0;
            tail <= 0;
            count <= 0;
            local_error <= 0;
            next_slot <= 0;
            held_slot <= 0;
            locked <= 0;
            for (int rp = 0; rp < RP_COUNT; rp++) begin
                rd_beat[rp] <= 0;
                wr_beat[rp] <= 0;
                write_status[rp] <= 0;
            end
            for (int s = 0; s < MC_SLOTS; s++) begin
                occupied[s] <= 0;
                completed[s] <= 0;
                is_write[s] <= 0;
                is_last[s] <= 0;
                plane[s] <= 0;
                id[s] <= 0;
                user[s] <= 0;
                status[s] <= 0;
                data[s] <= '0;
            end
        end else begin
            if (mc_req_valid) begin
                locked <= !mc_req_ready;
                held_slot <= unsigned'(selected);
            end
            if (issue) begin
                occupied[tail] <= 1;
                completed[tail] <= 0;
                is_write[tail] <= mc_req_write;
                is_last[tail] <= mc_req_last;
                plane[tail] <= mc_req_rp;
                id[tail] <= mc_req_id;
                user[tail] <= mc_req_auser;
                tail <= tail == MC_SLOTS-1 ? '0 : tail+1'b1;
                next_slot <= unsigned'((selected+1)%(RP_COUNT*2));
                if (mc_req_write) begin
                    wr_beat[mc_req_rp] <= mc_req_last ? 0 : wr_beat[mc_req_rp]+1'b1;
                end else begin
                    rd_beat[mc_req_rp] <= mc_req_last ? 0 : rd_beat[mc_req_rp]+1'b1;
                end
            end
            if (mc_rsp_valid && mc_rsp_ready) begin
                if (int'(mc_rsp_tag) >= MC_SLOTS) begin
                    local_error <= 1;
                end else if (!occupied[mc_rsp_tag] || completed[mc_rsp_tag]) begin
                    local_error <= 1;
                end else begin
                    completed[mc_rsp_tag] <= 1;
                    data[mc_rsp_tag] <= mc_rsp_rdata;
                    status[mc_rsp_tag] <= mc_rsp_resp;
                end
            end
            if (retire) begin
                occupied[head] <= 0;
                completed[head] <= 0;
                if (is_write[head]) begin
                    write_status[plane[head]] <= is_last[head] ? 0 : merged_status;
                end
                head <= head == MC_SLOTS-1 ? '0 : head+1'b1;
            end
            case ({issue, retire})
                2'b10: count <= count+1'b1;
                2'b01: count <= count-1'b1;
                default: ;
            endcase
        end
    end

    // 仿真期检查 FIFO 深度与 ROB tag 容量；综合时排除。
`ifndef SYNTHESIS
    initial begin
        if (REQUEST_DEPTH < 1 || WDATA_DEPTH < 1 || RESPONSE_DEPTH < 1) begin
            $fatal(1, "Target FIFO depths must be positive");
        end
        if (MC_SLOTS < 1 || MC_SLOTS > 256 || (1<<TAG_WIDTH) < MC_SLOTS) begin
            $fatal(1, "Invalid MC tag/ROB capacity");
        end
    end
`endif
endmodule
