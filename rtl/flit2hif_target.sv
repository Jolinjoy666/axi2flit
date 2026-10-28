// 存储侧响应端（MC 的 HIF 接口）：AoU Flit→HIF 命令/写数据，HIF 读数据→RDATA，桥自行产生 WRESP。
// 与 MC 同一时钟。HIF 一条命令访问一个 DRAM burst（下称“行”，LINE_BYTES 字节，按行对齐），
// 命令地址为以 DRAM 数据宽度为单位的字地址。AXI 突发是一段连续字节，桥把它切成若干行：
//   读：每行发一条读命令，token 为读 ROB 槽号；数据按 token 写回（可乱序、可在不同 token 间交织），
//       ROB 按发出顺序退休，再按 AXI 拍切出 RDATA。
//   写：同一行内的若干拍先合并（窄传输），行写满或突发结束时发一条写命令，wdata_ptr 为写缓冲槽号；
//       MC 通过 hif_wdata_ptr_valid 回送指针表示可以送数据，桥再送出该行的 LINE_WORDS 拍数据与掩码。
//       HIF 没有写完成，突发的所有行数据都交给 MC 后由桥生成 B。
// 流控：命令被接收时扣减 lpr/hpr/wr credit，MC 发 credit 脉冲时归还；初值必须与控制器的 CAM 配置一致。
// 不支持的 AXI 属性：独占访问按普通访问处理并返回 OKAY（AXI 规定不支持独占的从机返回 OKAY）。
module flit2hif_target #(
    parameter int DATA_WIDTH = 256,
    parameter int RP_COUNT = 1,
    // 接收缓冲深度（全宽消息条数）与响应队列深度，含义同 flit2mc_target。
    parameter int WREQ_DEPTH = 24,
    parameter int RREQ_DEPTH = 32,
    parameter int WDATA_DEPTH = DATA_WIDTH < 1024 ? 36 : 24,  // 写数据往返比读数据长，见设计文档 6.1 节
    parameter int RESPONSE_DEPTH = 2,
    // ---- 控制器配置：与 MC 的同名配置参数一致 ----
    parameter int MEMC_DRAM_DATA_WIDTH = 32,
    parameter int MEMC_FREQ_RATIO = 4,
    parameter int MEMC_BURST_LENGTH = 16,
    parameter int CORE_DATA_WIDTH = MEMC_DRAM_DATA_WIDTH * MEMC_FREQ_RATIO * 2,
    parameter int CORE_MASK_WIDTH = CORE_DATA_WIDTH / 8,
    parameter int CORE_ADDR_WIDTH = 40,
    parameter int CORE_TAG_WIDTH = 53,
    parameter int CMD_LEN_BITS = 2,
    parameter int WDATA_PTR_BITS = 19,
    parameter int RD_LATENCY_BITS = 11,
    parameter int HIF_PRI_BITS = 2,           // hif_cmd_pri 宽度（VPRW 关闭时只用 bit0）
    parameter bit VPRW_EN = 1'b0,             // 1：pri 编码为 00 LPR / 10 HPR
    parameter int HIF_CREDIT_BITS = 1,        // Inline ECC 配置下 lpr/hpr credit 为 2 位
    // 控制器读 CAM（LPR/HPR 两部分）与写 CAM 的表项数，即三类 credit 的初值。
    parameter int LPR_CREDITS = 24,
    parameter int HPR_CREDITS = 8,
    parameter int WR_CREDITS = 32,
    // 开启 ECC 时非全掩码写须用 RMW 命令（同时占用 LPR 与 WR credit）。
    parameter bit ECC_RMW = 1'b0,
    // ---- 桥的配置 ----
    // AXI 地址窗口：[ADDR_BASE, ADDR_BASE+MEM_BYTES) 映射到 HIF 字地址 0 起；窗口外返回 DECERR。
    parameter logic [63:0] ADDR_BASE = 64'h0,
    parameter logic [63:0] MEM_BYTES = 64'h1_0000_0000,
    parameter int HPR_QOS = 16,               // AxQOS ≥ 该值的读走高优先级；16 表示不用 HPR
    parameter int RD_LINES = 32,              // 读 ROB 行数
    parameter int WR_LINES = 16,              // 写缓冲行数
    parameter int RD_BURSTS = 16,             // 已接收、未退休的读突发数
    parameter int WR_BURSTS = 16              // 已接收、未回 B 的写突发数
) (
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

    // HIF 命令。
    output logic hif_cmd_valid,
    output logic [1:0] hif_cmd_type,
    output logic [CORE_ADDR_WIDTH-1:0] hif_cmd_addr,
    output logic [HIF_PRI_BITS-1:0] hif_cmd_pri,
    output logic [CORE_TAG_WIDTH-1:0] hif_cmd_token,
    output logic [CMD_LEN_BITS-1:0] hif_cmd_length,
    output logic [WDATA_PTR_BITS-1:0] hif_cmd_wdata_ptr,
    output logic hif_cmd_autopre,
    output logic [RD_LATENCY_BITS-1:0] hif_cmd_latency,
    input logic hif_cmd_stall,
    // credit 归还脉冲。
    input logic [HIF_CREDIT_BITS-1:0] hif_lpr_credit,
    input logic [HIF_CREDIT_BITS-1:0] hif_hpr_credit,
    input logic hif_wr_credit,
    input logic [1:0] hif_wrecc_credit,
    // 读数据。
    input logic hif_rdata_valid,
    input logic hif_rdata_end,
    input logic [CORE_TAG_WIDTH-1:0] hif_rdata_token,
    input logic [CORE_DATA_WIDTH-1:0] hif_rdata,
    input logic hif_rdata_uncorr_ecc_err,
    input logic hif_rdata_addr_err,
    input logic hif_rdata_crc_err,
    // 写数据。
    output logic hif_wdata_valid,
    output logic [CORE_DATA_WIDTH-1:0] hif_wdata,
    output logic [CORE_MASK_WIDTH-1:0] hif_wdata_mask,
    output logic hif_wdata_end,
    input logic hif_wdata_stall,
    input logic hif_wdata_ptr_valid,
    input logic [WDATA_PTR_BITS-1:0] hif_wdata_ptr,
    input logic hif_wdata_ptr_addr_err,
    // 读写模式切换提示，本桥不使用。
    output logic hif_go2critical_lpr,
    output logic hif_go2critical_hpr,
    output logic hif_go2critical_wr,

    // 锁存的协议错误。
    output logic protocol_error
);
    import aou_pkg::*;

    // ---------------- 尺寸 ----------------
    localparam int DATA_BYTES = DATA_WIDTH / 8;
    localparam int LINE_BYTES = MEMC_BURST_LENGTH * MEMC_DRAM_DATA_WIDTH / 8;   // 一条命令的字节数
    localparam int LINE_BITS = LINE_BYTES * 8;
    localparam int LINE_SHIFT = $clog2(LINE_BYTES);
    localparam int WORD_SHIFT = $clog2(MEMC_DRAM_DATA_WIDTH / 8);               // HIF 字地址单位
    localparam int HIF_BYTES = CORE_DATA_WIDTH / 8;
    localparam int LINE_WORDS = LINE_BYTES / HIF_BYTES;                         // 每条命令的数据拍数
    localparam int LWW = LINE_WORDS > 1 ? $clog2(LINE_WORDS) : 1;
    localparam int LPB = DATA_BYTES > LINE_BYTES ? DATA_BYTES / LINE_BYTES : 1; // 全宽一拍覆盖的行数
    localparam int BPL = LINE_BYTES > DATA_BYTES ? LINE_BYTES / DATA_BYTES : 1; // 一行容纳的全宽拍数
    localparam int RLW = RD_LINES > 1 ? $clog2(RD_LINES) : 1;
    localparam int RLC = $clog2(RD_LINES + 1);
    localparam int WLW = WR_LINES > 1 ? $clog2(WR_LINES) : 1;
    localparam int WLC = $clog2(WR_LINES + 1);
    localparam int RBW = RD_BURSTS > 1 ? $clog2(RD_BURSTS) : 1;
    localparam int RBC = $clog2(RD_BURSTS + 1);
    localparam int WBW = WR_BURSTS > 1 ? $clog2(WR_BURSTS) : 1;
    localparam int WBC = $clog2(WR_BURSTS + 1);
    localparam int MAX_CREDITS = LPR_CREDITS > HPR_CREDITS ? (LPR_CREDITS > WR_CREDITS ? LPR_CREDITS : WR_CREDITS)
                                                          : (HPR_CREDITS > WR_CREDITS ? HPR_CREDITS : WR_CREDITS);
    localparam int CRW = $clog2(MAX_CREDITS + 3) + 1;
    localparam int NLW = $clog2(4096 / LINE_BYTES + 1) + 1;                     // 一个突发的行数
    localparam logic [1:0] CMD_WR = 2'b00, CMD_RD = 2'b01, CMD_RMW = 2'b10;
    localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10, RESP_DECERR = 2'b11;

    // 地址分两段：突发不跨 4KB（接收时已检查），突发内的地址运算只用页内 12 位偏移；
    // 页对应的 HIF 字地址在接收请求时算一次并锁存，发命令时与行偏移拼接。
    localparam int PAGE_SHIFT = 12;
    typedef logic [WIRE_ADDR_W-1:0] addr_t;
    typedef logic [PAGE_SHIFT-1:0] off_t;
    typedef logic [CORE_ADDR_WIDTH-1:0] hif_addr_t;
    function automatic off_t line_of(input off_t a);
        return a & ~off_t'(LINE_BYTES - 1);
    endfunction
    function automatic logic in_window(input addr_t a);
        // 低于基址时差值回绕为大数，同样落在窗口外。
        return a - ADDR_BASE < MEM_BYTES;
    endfunction
    // 页起始的 HIF 字地址；ADDR_BASE 按 4KB 对齐，页内偏移不参与减法。
    function automatic hif_addr_t page_hif_of(input addr_t a);
        return hif_addr_t'(((a - ADDR_BASE) >> PAGE_SHIFT) << (PAGE_SHIFT - WORD_SHIFT));
    endfunction
    function automatic hif_addr_t hif_addr_of(input hif_addr_t page, input off_t off);
        return page | hif_addr_t'(off >> WORD_SHIFT);
    endfunction
    function automatic logic [1:0] worse(input logic [1:0] a, input logic [1:0] b);
        return a > b ? a : b;
    endfunction
    function automatic int popcount(input logic [HIF_CREDIT_BITS-1:0] v);
        int n;
        n = 0;
        for (int i = 0; i < HIF_CREDIT_BITS; i++) begin
            n += int'(v[i]);
        end
        return n;
    endfunction

    // ---------------- 公共部分 ----------------
    logic [MSG_KIND_COUNT-1:0] rx_valid[RP_COUNT],rx_ready[RP_COUNT];
    logic [MSG_KIND_COUNT-1:0] reply_valid[RP_COUNT],reply_ready[RP_COUNT];
    msg_t rx_data[RP_COUNT][MSG_KIND_COUNT];
    msg_t reply_data[RP_COUNT][MSG_KIND_COUNT];
    logic transport_error, local_error, active;

    assign protocol_error = local_error || transport_error;
    assign active = link_up && !protocol_error;

    aou_target_core #(
        .DATA_WIDTH(DATA_WIDTH),
        .RP_COUNT(RP_COUNT),
        .WREQ_DEPTH(WREQ_DEPTH),
        .RREQ_DEPTH(RREQ_DEPTH),
        .WDATA_DEPTH(WDATA_DEPTH),
        .RESPONSE_DEPTH(RESPONSE_DEPTH)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .link_up(link_up),
        .local_error(local_error),
        .transport_error(transport_error),
        .flit_tx_valid(flit_tx_valid),
        .flit_tx_ready(flit_tx_ready),
        .flit_tx_data(flit_tx_data),
        .flit_rx_valid(flit_rx_valid),
        .flit_rx_ready(flit_rx_ready),
        .flit_rx_data(flit_rx_data),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .rx_data(rx_data),
        .reply_valid(reply_valid),
        .reply_ready(reply_ready),
        .reply_data(reply_data)
    );

    // ---------------- credit 计数 ----------------
    // 命令被接收（valid && !stall）时扣减，收到脉冲时归还；归还超过初值属于对端错误。
    logic [CRW-1:0] lpr_credit, hpr_credit, wr_credit;
    logic cmd_accept, cmd_is_read, cmd_is_hpr, cmd_is_rmw;
    int lpr_next, hpr_next, wr_next;
    always_comb begin
        lpr_next = int'(lpr_credit) + popcount(hif_lpr_credit) -
                   ((cmd_accept && ((cmd_is_read && !cmd_is_hpr) || cmd_is_rmw)) ? 1 : 0);
        hpr_next = int'(hpr_credit) + popcount(hif_hpr_credit) - ((cmd_accept && cmd_is_read && cmd_is_hpr) ? 1 : 0);
        wr_next = int'(wr_credit) + int'(hif_wr_credit) - ((cmd_accept && !cmd_is_read) ? 1 : 0);
    end

    // ================================================================
    // 读通路
    // ================================================================
    // 读上下文：每个已接收的读突发一项，按接收顺序退休。窗口外突发不发命令，直接回 DECERR。
    typedef struct packed {
        logic [RP_W-1:0] rp;
        logic [WIRE_ID_W-1:0] id;
        logic [WIRE_USER_W-1:0] user;
        off_t off;
        logic [2:0] size;
        logic [7:0] len;
        logic outside;
    } rctx_t;
    rctx_t rctx [RD_BURSTS];
    logic [RBW-1:0] rc_head, rc_tail;
    logic [RBC-1:0] rc_count;

    // 读发起：一次处理一个突发，按行发命令。
    logic r_busy, r_hpr;
    off_t r_line;
    hif_addr_t r_page;
    logic [NLW-1:0] r_left;
    int unsigned r_next_rp;
    int r_sel;
    ax_t r_req;
    logic r_start, r_want;
    off_t r_first, r_last_line;

    // 读 ROB：环形队列，按发出顺序分配与退休，完成可乱序。
    logic [LINE_BITS-1:0] rob_data [RD_LINES];
    logic rob_busy [RD_LINES], rob_done [RD_LINES];
    logic [1:0] rob_err [RD_LINES];
    logic [LWW-1:0] rob_words [RD_LINES];
    logic [RLW-1:0] rob_head, rob_tail;
    logic [RLC-1:0] rob_count;

    always_comb begin
        r_sel = -1;
        for (int n = 0; n < RP_COUNT; n++) begin
            int p;
            p = (int'(r_next_rp) + n) % RP_COUNT;
            if (r_sel < 0 && rx_valid[p][K_RREQ]) begin
                r_sel = p;
            end
        end
        r_req = r_sel >= 0 ? get_req(rx_data[r_sel][K_RREQ]) : '0;
        // 末字节偏移不超过 4095（突发不跨 4KB），16 位中间量足够容纳 256 拍 × 128B。
        r_first = line_of(off_t'(r_req.addr));
        r_last_line = line_of(off_t'(16'(r_req.addr[PAGE_SHIFT-1:0]) + ((16'(r_req.len) + 16'd1) << r_req.size) - 16'd1));
        // 上一个突发的行全部发出后才接收下一个；接收即出队，字段锁存在发起寄存器与上下文中。
        r_start = active && !r_busy && r_sel >= 0 && rc_count < RD_BURSTS;
        r_want = active && r_busy && rob_count < RD_LINES &&
                 (r_hpr ? hpr_credit != 0 : lpr_credit != 0);
    end

    // 读退休：队首突发逐拍输出，所需的行在 ROB 头部且已完成时组装一拍 RDATA。
    rctx_t rh;
    logic [8:0] rt_beat;
    off_t rt_addr;
    int rt_bytes, rt_need, rt_pop;
    logic rt_ready, rt_fire, rt_last;
    logic [1:0] rt_resp;
    logic [LANE_W-1:0] rt_lane;
    logic [DATA_WIDTH-1:0] rt_bus, rt_beat_data;
    logic [LINE_BITS-1:0] rt_line [LPB];

    always_comb begin
        rh = rctx[rc_head];
        rt_addr = rh.off + off_t'(16'(rt_beat) << rh.size);
        rt_bytes = 1 << rh.size;
        rt_need = rh.outside ? 0 : (rt_bytes >= LINE_BYTES ? rt_bytes / LINE_BYTES : 1);
        rt_last = rt_beat == {1'b0, rh.len};
        rt_lane = LANE_W'(rt_addr % DATA_BYTES);
        rt_ready = rc_count != 0;
        rt_resp = rh.outside ? RESP_DECERR : RESP_OKAY;
        for (int i = 0; i < LPB; i++) begin
            logic [RLW-1:0] s;
            s = RLW'((int'(rob_head) + i) % RD_LINES);
            rt_line[i] = rob_data[s];
            if (i < rt_need) begin
                rt_ready = rt_ready && int'(rob_count) > i && rob_done[s];
                rt_resp = worse(rt_resp, rob_err[s]);
            end
        end
        // 窄传输的末拍未写到行尾时也要释放该行。
        rt_pop = rt_bytes >= LINE_BYTES ? rt_need :
                 (!rh.outside && (((rt_addr + off_t'(rt_bytes)) & off_t'(LINE_BYTES - 1)) == 0 || rt_last)) ? 1 : 0;
    end

    always_comb begin
        for (int j = 0; j < DATA_BYTES; j++) begin
            rt_beat_data[j*8 +: 8] = (j >= int'(rt_lane) && j < int'(rt_lane) + rt_bytes) ? rt_bus[j*8 +: 8] : 8'h0;
        end
    end
    // 由 ROB 头部的行拼出总线数据：总线按 DATA_BYTES 对齐，本拍所在字节通道即为有效数据。
    if (DATA_BYTES >= LINE_BYTES) begin : g_rd_wide
        always_comb begin
            int p;
            p = int'(rt_lane) / LINE_BYTES;
            rt_bus = '0;
            for (int s = 0; s < DATA_BYTES / LINE_BYTES; s++) begin
                for (int i = 0; i < LPB; i++) begin
                    if (s - p == i) begin
                        rt_bus[s*LINE_BITS +: LINE_BITS] = rt_line[i];
                    end
                end
            end
        end
    end else begin : g_rd_narrow
        always_comb begin
            int t;
            t = int'(rt_addr % LINE_BYTES) / DATA_BYTES;
            rt_bus = '0;
            for (int i = 0; i < BPL; i++) begin
                if (i == t) begin
                    rt_bus = rt_line[0][i*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end


    // ================================================================
    // 写通路
    // ================================================================
    // 写上下文：每个已接收的写突发一项；outstanding 为已发命令但数据尚未交给 MC 的行数。
    typedef struct packed {
        logic [RP_W-1:0] rp;
        logic [WIRE_ID_W-1:0] id;
        logic [WIRE_USER_W-1:0] user;
        logic [1:0] status;
        logic assembled;
        logic [NLW-1:0] outstanding;
    } wctx_t;
    wctx_t wctx [WR_BURSTS];
    logic [WBW-1:0] wc_head, wc_tail;
    logic [WBC-1:0] wc_count;

    // 写组装：一次处理一个突发；w_part 为大于一行的拍内正在发出的行序号。
    logic w_busy, w_outside;
    logic [RP_W-1:0] w_rp;
    off_t w_off;
    hif_addr_t w_page;
    logic [2:0] w_size;
    logic [7:0] w_len;
    logic [8:0] w_beat;
    logic [NLW-1:0] w_part;
    logic [WBW-1:0] w_ctx;
    int unsigned w_next_rp;
    int w_sel;
    ax_t w_sel_req;  // 被选中 RP 的写请求
    logic w_start, w_have, w_bad_len, w_beat_bad, w_last_beat, w_last_part, w_emit, w_want, w_consume;
    off_t w_addr, w_line;
    int w_bytes, w_parts;
    logic [LANE_W-1:0] w_lane;
    logic [DATA_WIDTH-1:0] w_bus;
    logic [DATA_WIDTH/8-1:0] w_strb;
    logic [LINE_BITS-1:0] part_data, merged_data;
    logic [LINE_BYTES-1:0] part_mask, merged_mask;

    // 窄传输的行合并寄存器。
    logic stage_valid;
    logic [LINE_BITS-1:0] stage_data;
    logic [LINE_BYTES-1:0] stage_mask;

    // 写缓冲：空闲槽号队列（分配与释放顺序可不同），槽内为整行数据与掩码。
    localparam logic [1:0] WB_FREE = 2'd0, WB_ISSUED = 2'd1, WB_PULLED = 2'd2;
    logic [LINE_BITS-1:0] wb_data [WR_LINES];
    logic [LINE_BYTES-1:0] wb_mask [WR_LINES];
    logic [WBW-1:0] wb_ctx [WR_LINES];
    logic [1:0] wb_state [WR_LINES];
    logic [WLW-1:0] free_q [WR_LINES];
    logic [WLW-1:0] free_head, free_tail;
    logic [WLC-1:0] free_count;
    // MC 已回送、等待送数据的指针，按回送顺序发送。
    logic [WLW-1:0] pull_q [WR_LINES];
    logic [WLW-1:0] pull_head, pull_tail;
    logic [WLC-1:0] pull_count;
    logic [LWW-1:0] pull_word;
    logic wd_fire, wd_done;
    logic [WLW-1:0] wd_slot;

    always_comb begin
        w_sel = -1;
        for (int n = 0; n < RP_COUNT; n++) begin
            int p;
            p = (int'(w_next_rp) + n) % RP_COUNT;
            if (w_sel < 0 && rx_valid[p][K_WREQ]) begin
                w_sel = p;
            end
        end
        w_start = active && !w_busy && w_sel >= 0 && wc_count < WR_BURSTS;
        w_sel_req = get_req(rx_data[w_sel < 0 ? 0 : w_sel][K_WREQ]);

        // 当前拍：地址、字节通道、本拍需要拆成的行数与本部分所在的行。
        w_have = active && w_busy && rx_valid[w_rp][K_WDATA];
        w_addr = w_off + off_t'(16'(w_beat) << w_size);
        w_bytes = 1 << w_size;
        w_lane = LANE_W'(w_addr % DATA_BYTES);
        w_parts = w_bytes >= LINE_BYTES ? w_bytes / LINE_BYTES : 1;
        w_line = line_of(w_addr) + off_t'(w_bytes >= LINE_BYTES ? int'(w_part) * LINE_BYTES : 0);
        w_last_beat = w_beat == {1'b0, w_len};
        w_last_part = int'(w_part) == w_parts - 1;
        w_bus = DATA_WIDTH'(get_data(rx_data[w_rp][K_WDATA], DATA_WIDTH));
        w_strb = (DATA_WIDTH/8)'(get_strb(rx_data[w_rp][K_WDATA], w_lane));
        // 写数据消息必须能容纳本拍传输大小；选通落在本拍字节范围外时本拍不写入并回 SLVERR。
        w_bad_len = w_have && dl_bytes(msg_dl(rx_data[w_rp][K_WDATA])) < w_bytes;
        w_beat_bad = 0;
        for (int j = 0; j < DATA_BYTES; j++) begin
            if (w_strb[j] && (j < int'(w_lane) || j >= int'(w_lane) + w_bytes)) begin
                w_beat_bad = 1;
            end
        end
        // 行写满（本部分写到行尾）或突发结束时发出写命令。
        w_emit = w_bytes >= LINE_BYTES || (((w_addr + off_t'(w_bytes)) & off_t'(LINE_BYTES - 1)) == 0) ||
                 (w_last_beat && w_last_part);
    end
    // 发命令所需资源：空闲写缓冲槽、WR credit；RMW 另需 LPR credit。
    assign w_want = w_have && !w_bad_len && !w_outside && w_emit && free_count != 0 &&
                    wr_credit != 0 && (!(ECC_RMW && !(&merged_mask)) || lpr_credit != 0);

    // 本部分的行映像：按字节地址把总线上的数据放到行内位置。
    if (DATA_BYTES >= LINE_BYTES) begin : g_wr_wide
        always_comb begin
            int s;
            s = int'(w_lane) / LINE_BYTES + (w_bytes >= LINE_BYTES ? int'(w_part) : 0);
            part_data = '0;
            part_mask = '0;
            for (int i = 0; i < DATA_BYTES / LINE_BYTES; i++) begin
                if (i == s) begin
                    part_data = w_bus[i*LINE_BITS +: LINE_BITS];
                    part_mask = w_strb[i*LINE_BYTES +: LINE_BYTES];
                end
            end
            if (w_beat_bad) begin
                part_mask = '0;
            end
        end
    end else begin : g_wr_narrow
        always_comb begin
            int t;
            t = int'(w_addr % LINE_BYTES) / DATA_BYTES;
            part_data = '0;
            part_mask = '0;
            for (int i = 0; i < BPL; i++) begin
                if (i == t) begin
                    part_data[i*DATA_WIDTH +: DATA_WIDTH] = w_bus;
                    part_mask[i*DATA_BYTES +: DATA_BYTES] = w_strb;
                end
            end
            if (w_beat_bad) begin
                part_mask = '0;
            end
        end
    end
    // 与同一行已合并的拍叠加；新选通的字节覆盖旧值。
    always_comb begin
        merged_mask = (stage_valid ? stage_mask : '0) | part_mask;
        for (int i = 0; i < LINE_BYTES; i++) begin
            merged_data[i*8 +: 8] = part_mask[i] ? part_data[i*8 +: 8] : (stage_valid ? stage_data[i*8 +: 8] : 8'h0);
        end
    end

    // 写响应退休：队首突发组装完成且所有行的数据已交给 MC。
    wctx_t wh;
    logic wb_ready, wb_fire;
    assign wh = wctx[wc_head];
    assign wb_ready = wc_count != 0 && wh.assembled && wh.outstanding == 0;
    assign wb_fire = active && wb_ready && reply_ready[wh.rp][K_WRESP];

    // 响应：读数据与写响应各写入所属 RP 的发送队列。
    always_comb begin
        for (int p = 0; p < RP_COUNT; p++) begin
            reply_valid[p] = '0;
            for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                reply_data[p][q] = '0;
            end
        end
        reply_valid[rh.rp][K_RDATA] = active && rt_ready;
        // 只返回本拍字节范围内的数据；出错的拍不返回数据。
        reply_data[rh.rp][K_RDATA] = make_rdata(rt_resp == RESP_OKAY ? MAX_DATA_W'(rt_beat_data) : '0, rh.id, rh.user,
                                                rt_resp, rt_last, int'(rh.rp), rh.size, rt_lane);
        reply_valid[wh.rp][K_WRESP] = active && wb_ready;
        reply_data[wh.rp][K_WRESP] = make_b(wh.id, wh.user, wh.status, int'(wh.rp));
    end
    assign rt_fire = active && rt_ready && reply_ready[rh.rp][K_RDATA];

    // 写数据发送：按指针回送顺序逐行送出 LINE_WORDS 拍。
    always_comb begin
        wd_slot = pull_q[pull_head];
        hif_wdata_valid = active && pull_count != 0;
        hif_wdata = wb_data[wd_slot][int'(pull_word)*CORE_DATA_WIDTH +: CORE_DATA_WIDTH];
        hif_wdata_mask = wb_mask[wd_slot][int'(pull_word)*CORE_MASK_WIDTH +: CORE_MASK_WIDTH];
        hif_wdata_end = int'(pull_word) == LINE_WORDS - 1;
        wd_fire = hif_wdata_valid && !hif_wdata_stall;
        wd_done = wd_fire && hif_wdata_end;
    end

    // ================================================================
    // 命令仲裁：读写共用一个命令口，轮流发出；被 stall 时保持本次选择不变。
    // ================================================================
    logic grant_wr, last_wr, cmd_locked, lock_wr;
    always_comb begin
        if (cmd_locked) begin
            grant_wr = lock_wr;
        end else if (r_want && w_want) begin
            grant_wr = !last_wr;
        end else begin
            grant_wr = w_want;
        end
        hif_cmd_valid = grant_wr ? w_want : r_want;
        cmd_is_read = !grant_wr;
        cmd_is_hpr = r_hpr;
        cmd_is_rmw = grant_wr && ECC_RMW && !(&merged_mask);
        hif_cmd_type = !grant_wr ? CMD_RD : cmd_is_rmw ? CMD_RMW : CMD_WR;
        hif_cmd_addr = grant_wr ? hif_addr_of(w_page, w_line) : hif_addr_of(r_page, r_line);
        hif_cmd_pri = (!grant_wr && r_hpr) ? (VPRW_EN ? HIF_PRI_BITS'(2) : HIF_PRI_BITS'(1)) : '0;
        hif_cmd_token = CORE_TAG_WIDTH'(rob_tail);
        hif_cmd_length = '0;                         // 读整行
        hif_cmd_wdata_ptr = WDATA_PTR_BITS'(free_q[free_head]);
        hif_cmd_autopre = 1'b0;
        hif_cmd_latency = '0;
        cmd_accept = hif_cmd_valid && !hif_cmd_stall;
        // 窗口外的写或不需要发命令的部分直接消耗。
        w_consume = w_have && !w_bad_len && (w_outside || !w_emit || (cmd_accept && grant_wr));
        for (int p = 0; p < RP_COUNT; p++) begin
            rx_ready[p][K_WREQ] = w_start && p == w_sel;
            rx_ready[p][K_RREQ] = r_start && p == r_sel;
            rx_ready[p][K_WDATA] = w_consume && w_last_part && p == int'(w_rp);
            rx_ready[p][K_RDATA] = 1'b0;
            rx_ready[p][K_WRESP] = 1'b0;
        end
    end
    assign hif_go2critical_lpr = 1'b0;
    assign hif_go2critical_hpr = 1'b0;
    assign hif_go2critical_wr = 1'b0;

    // ================================================================
    // HIF 读数据接收与指针回送的合法性
    // ================================================================
    logic [RLW-1:0] rd_tok;
    logic rd_tok_bad, ptr_bad;
    always_comb begin
        rd_tok = RLW'(hif_rdata_token);
        rd_tok_bad = hif_rdata_valid && (hif_rdata_token >= CORE_TAG_WIDTH'(RD_LINES) ||
                     !rob_busy[rd_tok] || rob_done[rd_tok] ||
                     (hif_rdata_end != (int'(rob_words[rd_tok]) == LINE_WORDS - 1)));
        ptr_bad = hif_wdata_ptr_valid && (hif_wdata_ptr >= WDATA_PTR_BITS'(WR_LINES) ||
                  wb_state[WLW'(hif_wdata_ptr)] != WB_ISSUED);
    end

    // ================================================================
    // 时序逻辑
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            local_error <= 0;
            lpr_credit <= CRW'(LPR_CREDITS);
            hpr_credit <= CRW'(HPR_CREDITS);
            wr_credit <= CRW'(WR_CREDITS);
            last_wr <= 0;
            cmd_locked <= 0;
            lock_wr <= 0;
            r_busy <= 0;
            r_hpr <= 0;
            r_line <= '0;
            r_page <= '0;
            r_left <= '0;
            r_next_rp <= 0;
            rc_head <= '0;
            rc_tail <= '0;
            rc_count <= '0;
            // 上下文队首在首次写入前也会被读（四值仿真中为 X），因此复位清零。
            for (int c = 0; c < RD_BURSTS; c++) begin
                rctx[c] <= '0;
            end
            for (int c = 0; c < WR_BURSTS; c++) begin
                wctx[c] <= '0;
            end
            rt_beat <= '0;
            rob_head <= '0;
            rob_tail <= '0;
            rob_count <= '0;
            for (int s = 0; s < RD_LINES; s++) begin
                rob_busy[s] <= 0;
                rob_done[s] <= 0;
            end
            w_busy <= 0;
            w_outside <= 0;
            w_rp <= '0;
            w_off <= '0;
            w_page <= '0;
            w_size <= '0;
            w_len <= '0;
            w_beat <= '0;
            w_part <= '0;
            w_ctx <= '0;
            w_next_rp <= 0;
            stage_valid <= 0;
            wc_head <= '0;
            wc_tail <= '0;
            wc_count <= '0;
            for (int s = 0; s < WR_LINES; s++) begin
                wb_state[s] <= WB_FREE;
                free_q[s] <= WLW'(s);
            end
            free_head <= '0;
            free_tail <= '0;
            free_count <= WLC'(WR_LINES);
            pull_head <= '0;
            pull_tail <= '0;
            pull_count <= '0;
            pull_word <= '0;
        end else begin
            // ---- credit 与命令口 ----
            if (lpr_next > LPR_CREDITS || hpr_next > HPR_CREDITS || wr_next > WR_CREDITS) begin
                local_error <= 1;
            end
            lpr_credit <= CRW'(lpr_next);
            hpr_credit <= CRW'(hpr_next);
            wr_credit <= CRW'(wr_next);
            cmd_locked <= hif_cmd_valid && hif_cmd_stall;
            lock_wr <= grant_wr;
            if (cmd_accept) begin
                last_wr <= grant_wr;
            end

            // ---- 读发起 ----
            if (r_start) begin
                rctx[rc_tail] <= '{rp: RP_W'(r_sel), id: r_req.id, user: r_req.user, off: off_t'(r_req.addr),
                                   size: r_req.size, len: r_req.len, outside: !in_window(r_req.addr)};
                rc_tail <= rc_tail == RBW'(RD_BURSTS - 1) ? '0 : rc_tail + 1'b1;
                r_next_rp <= unsigned'((r_sel + 1) % RP_COUNT);
                if (in_window(r_req.addr)) begin
                    r_busy <= 1;
                    r_line <= r_first;
                    r_page <= page_hif_of(r_req.addr);
                    r_left <= NLW'(((r_last_line - r_first) >> LINE_SHIFT) + 1);
                    r_hpr <= int'(r_req.qos) >= HPR_QOS;
                end
            end
            if (cmd_accept && !grant_wr) begin
                rob_busy[rob_tail] <= 1;
                rob_done[rob_tail] <= 0;
                rob_err[rob_tail] <= RESP_OKAY;
                rob_words[rob_tail] <= '0;
                rob_tail <= rob_tail == RLW'(RD_LINES - 1) ? '0 : rob_tail + 1'b1;
                r_line <= r_line + off_t'(LINE_BYTES);
                r_left <= r_left - 1'b1;
                if (r_left == 1) begin
                    r_busy <= 0;
                end
            end
            // ---- 读数据：按 token 写入行内第 rob_words 拍，可与其他 token 交织 ----
            if (hif_rdata_valid && active) begin
                if (rd_tok_bad) begin
                    local_error <= 1;
                end else begin
                    rob_data[rd_tok][int'(rob_words[rd_tok])*CORE_DATA_WIDTH +: CORE_DATA_WIDTH] <= hif_rdata;
                    rob_words[rd_tok] <= rob_words[rd_tok] + 1'b1;
                    rob_err[rd_tok] <= worse(rob_err[rd_tok],
                        hif_rdata_addr_err ? RESP_DECERR :
                        (hif_rdata_uncorr_ecc_err || hif_rdata_crc_err) ? RESP_SLVERR : RESP_OKAY);
                    if (hif_rdata_end) begin
                        rob_done[rd_tok] <= 1;
                    end
                end
            end
            // ---- 读退休 ----
            if (rt_fire) begin
                for (int i = 0; i < LPB; i++) begin
                    if (i < rt_pop) begin
                        rob_busy[RLW'((int'(rob_head) + i) % RD_LINES)] <= 0;
                        rob_done[RLW'((int'(rob_head) + i) % RD_LINES)] <= 0;
                    end
                end
                rob_head <= RLW'((int'(rob_head) + rt_pop) % RD_LINES);
                rt_beat <= rt_last ? '0 : rt_beat + 1'b1;
                if (rt_last) begin
                    rc_head <= rc_head == RBW'(RD_BURSTS - 1) ? '0 : rc_head + 1'b1;
                end
            end
            rob_count <= RLC'(int'(rob_count) + ((cmd_accept && !grant_wr) ? 1 : 0) - (rt_fire ? rt_pop : 0));
            rc_count <= RBC'(int'(rc_count) + (r_start ? 1 : 0) - ((rt_fire && rt_last) ? 1 : 0));

            // ---- 写发起 ----
            if (w_start) begin
                w_busy <= 1;
                w_rp <= RP_W'(w_sel);
                w_off <= off_t'(w_sel_req.addr);
                w_page <= page_hif_of(w_sel_req.addr);
                w_size <= w_sel_req.size;
                w_len <= w_sel_req.len;
                w_outside <= !in_window(w_sel_req.addr);
                w_beat <= '0;
                w_part <= '0;
                w_ctx <= wc_tail;
                w_next_rp <= unsigned'((w_sel + 1) % RP_COUNT);
                wctx[wc_tail] <= '{rp: RP_W'(w_sel), id: w_sel_req.id,
                                   user: w_sel_req.user,
                                   status: in_window(w_sel_req.addr) ? RESP_OKAY : RESP_DECERR,
                                   assembled: 1'b0, outstanding: '0};
                wc_tail <= wc_tail == WBW'(WR_BURSTS - 1) ? '0 : wc_tail + 1'b1;
            end
            if (w_bad_len) begin
                local_error <= 1;
            end
            // ---- 写组装：消耗一个部分 ----
            if (w_consume) begin
                if (w_emit) begin
                    stage_valid <= 0;
                end else begin
                    stage_valid <= 1;
                    stage_data <= merged_data;
                    stage_mask <= merged_mask;
                end
                if (w_last_part) begin
                    w_part <= '0;
                    w_beat <= w_beat + 1'b1;
                    if (w_last_beat) begin
                        w_busy <= 0;
                        wctx[w_ctx].assembled <= 1;
                    end
                end else begin
                    w_part <= w_part + 1'b1;
                end
            end
            // 发出写命令：占用空闲槽，写入整行；该突发未送数据的行数加一。
            if (cmd_accept && grant_wr) begin
                wb_data[free_q[free_head]] <= merged_data;
                wb_mask[free_q[free_head]] <= merged_mask;
                wb_ctx[free_q[free_head]] <= w_ctx;
                wb_state[free_q[free_head]] <= WB_ISSUED;
                free_head <= free_head == WLW'(WR_LINES - 1) ? '0 : free_head + 1'b1;
            end
            // MC 回送指针：可以送这一行的数据了；地址错误记入该突发的状态。
            if (hif_wdata_ptr_valid && active) begin
                if (ptr_bad) begin
                    local_error <= 1;
                end else begin
                    wb_state[WLW'(hif_wdata_ptr)] <= WB_PULLED;
                    pull_q[pull_tail] <= WLW'(hif_wdata_ptr);
                    pull_tail <= pull_tail == WLW'(WR_LINES - 1) ? '0 : pull_tail + 1'b1;
                end
            end
            // 写数据：最后一拍被接收后释放该槽。
            if (wd_fire) begin
                pull_word <= wd_done ? '0 : pull_word + 1'b1;
            end
            if (wd_done) begin
                wb_state[wd_slot] <= WB_FREE;
                free_q[free_tail] <= wd_slot;
                free_tail <= free_tail == WLW'(WR_LINES - 1) ? '0 : free_tail + 1'b1;
                pull_head <= pull_head == WLW'(WR_LINES - 1) ? '0 : pull_head + 1'b1;
            end
            free_count <= WLC'(int'(free_count) - ((cmd_accept && grant_wr) ? 1 : 0) + (wd_done ? 1 : 0));
            pull_count <= WLC'(int'(pull_count) + ((hif_wdata_ptr_valid && active && !ptr_bad) ? 1 : 0) -
                               (wd_done ? 1 : 0));
            // 每个突发的状态：本拍选通越界记 SLVERR，MC 回送指针时报地址错误记 DECERR。
            // 待送行数：发命令加一，送完数据减一（可能是不同突发）。
            for (int c = 0; c < WR_BURSTS; c++) begin
                if ((w_consume && w_beat_bad && w_ctx == WBW'(c)) ||
                    (hif_wdata_ptr_valid && active && !ptr_bad && hif_wdata_ptr_addr_err &&
                     wb_ctx[WLW'(hif_wdata_ptr)] == WBW'(c))) begin
                    wctx[c].status <= worse(wctx[c].status,
                        (hif_wdata_ptr_valid && active && !ptr_bad && hif_wdata_ptr_addr_err &&
                         wb_ctx[WLW'(hif_wdata_ptr)] == WBW'(c)) ? RESP_DECERR : RESP_SLVERR);
                end
                if ((cmd_accept && grant_wr && w_ctx == WBW'(c)) != (wd_done && wb_ctx[wd_slot] == WBW'(c))) begin
                    if (cmd_accept && grant_wr && w_ctx == WBW'(c)) begin
                        wctx[c].outstanding <= wctx[c].outstanding + 1'b1;
                    end else begin
                        wctx[c].outstanding <= wctx[c].outstanding - 1'b1;
                    end
                end
            end
            // ---- 写响应退休 ----
            if (wb_fire) begin
                wc_head <= wc_head == WBW'(WR_BURSTS - 1) ? '0 : wc_head + 1'b1;
            end
            wc_count <= WBC'(int'(wc_count) + (w_start ? 1 : 0) - (wb_fire ? 1 : 0));
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (LINE_BYTES * 8 != MEMC_BURST_LENGTH * MEMC_DRAM_DATA_WIDTH || (LINE_BYTES & (LINE_BYTES - 1)) != 0 ||
            LINE_BYTES > 4096 || CORE_DATA_WIDTH != MEMC_DRAM_DATA_WIDTH * MEMC_FREQ_RATIO * 2 ||
            LINE_BYTES % HIF_BYTES != 0 || CORE_MASK_WIDTH != CORE_DATA_WIDTH / 8) begin
            $fatal(1, "Inconsistent HIF width/burst configuration");
        end
        if (ADDR_BASE % 4096 != 0 || MEM_BYTES % 4096 != 0 || MEM_BYTES == 0 ||
            ((MEM_BYTES - 1) >> WORD_SHIFT) >> CORE_ADDR_WIDTH != 0) begin
            $fatal(1, "HIF address window must be 4KB aligned and fit CORE_ADDR_WIDTH");
        end
        if (RD_LINES < LPB || WR_LINES < 1 || RD_BURSTS < 1 || WR_BURSTS < 1 ||
            CORE_TAG_WIDTH < RLW || WDATA_PTR_BITS < WLW ||
            LPR_CREDITS < 1 || WR_CREDITS < 1 || HPR_CREDITS < 0 || (HPR_QOS < 16 && HPR_CREDITS < 1)) begin
            $fatal(1, "Invalid HIF buffer, token or credit configuration");
        end
    end
`endif
endmodule
