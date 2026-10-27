// HIF 控制器行为模型（仅用于仿真，不可综合）。
// 按 MC HIF 接口的时序图建模主机可见的行为：
//   命令：valid && !stall 时接收；读进入 LPR/HPR 队列，写进入写队列，各自不超过 credit 初值，
//         超出即主机违反 credit 流控。
//   写：接收命令后至少 2 拍回送 hif_wdata_ptr（按命令顺序），主机随后送 LINE_WORDS 拍数据与掩码。
//   读：等更早接收的写数据都到齐后取数（读写同址时保证先写后读），延迟 LATENCY 拍后按 token 返回；
//       stress 时乱序选择、在两个 token 间交织返回，并随机插入 stall 和空拍。
//   credit：读开始返回（视为已发往 DFI）时归还 LPR/HPR，写数据写入后若干拍归还 WR；
//           同一拍的多个归还排队输出，credit 为 2 位时每拍最多归还 2 个。
// 存储为 MEM_BYTES 字节，超出的地址返回 addr_err；POISON_LINE 所在行读出时报不可纠正 ECC 错误。
// 发现主机违反接口约定时置 model_error 并打印原因。
module hif_mc_model #(
    parameter int CORE_DATA_WIDTH = 256,
    parameter int LINE_WORDS = 2,
    parameter int WORD_BYTES = 4,
    parameter int CORE_ADDR_WIDTH = 40,
    parameter int CORE_TAG_WIDTH = 53,
    parameter int CMD_LEN_BITS = 2,
    parameter int WDATA_PTR_BITS = 19,
    parameter int RD_LATENCY_BITS = 11,
    parameter int HIF_PRI_BITS = 2,
    parameter bit VPRW_EN = 1'b0,
    parameter int HIF_CREDIT_BITS = 1,
    parameter int LPR_CREDITS = 24,
    parameter int HPR_CREDITS = 8,
    parameter int WR_CREDITS = 32,
    parameter int MEM_BYTES = 128 * 1024,
    parameter int POISON_LINE = -1,
    parameter int LATENCY = 8,
    parameter int SEED = 1
) (
    input logic clk,
    input logic rst_n,
    input logic block,
    input logic stress,
    input logic inject_bad_token,

    input logic hif_cmd_valid,
    input logic [1:0] hif_cmd_type,
    input logic [CORE_ADDR_WIDTH-1:0] hif_cmd_addr,
    input logic [HIF_PRI_BITS-1:0] hif_cmd_pri,
    input logic [CORE_TAG_WIDTH-1:0] hif_cmd_token,
    input logic [CMD_LEN_BITS-1:0] hif_cmd_length,
    input logic [WDATA_PTR_BITS-1:0] hif_cmd_wdata_ptr,
    input logic hif_cmd_autopre,
    input logic [RD_LATENCY_BITS-1:0] hif_cmd_latency,
    output logic hif_cmd_stall,
    output logic [HIF_CREDIT_BITS-1:0] hif_lpr_credit,
    output logic [HIF_CREDIT_BITS-1:0] hif_hpr_credit,
    output logic hif_wr_credit,
    output logic [1:0] hif_wrecc_credit,
    output logic hif_rdata_valid,
    output logic hif_rdata_end,
    output logic [CORE_TAG_WIDTH-1:0] hif_rdata_token,
    output logic [CORE_DATA_WIDTH-1:0] hif_rdata,
    output logic hif_rdata_uncorr_ecc_err,
    output logic hif_rdata_addr_err,
    output logic hif_rdata_crc_err,
    input logic hif_wdata_valid,
    input logic [CORE_DATA_WIDTH-1:0] hif_wdata,
    input logic [CORE_DATA_WIDTH/8-1:0] hif_wdata_mask,
    input logic hif_wdata_end,
    output logic hif_wdata_stall,
    output logic hif_wdata_ptr_valid,
    output logic [WDATA_PTR_BITS-1:0] hif_wdata_ptr,
    output logic hif_wdata_ptr_addr_err,
    input logic hif_go2critical_lpr,
    input logic hif_go2critical_hpr,
    input logic hif_go2critical_wr,

    output logic model_error,
    output logic [31:0] stat_rd,
    output logic [31:0] stat_wr,
    output logic [31:0] stat_ooo,
    output logic [31:0] stat_interleave,
    output logic [31:0] stat_stall
);
    localparam int HIF_BYTES = CORE_DATA_WIDTH / 8;
    localparam int LINE_BYTES = LINE_WORDS * HIF_BYTES;
    localparam int LINE_BITS = LINE_BYTES * 8;
    localparam int RQ = LPR_CREDITS + HPR_CREDITS + 2;   // 另加 2 项给正在返回数据的读
    localparam int WQ = WR_CREDITS;
    localparam int STREAMS = 2;

    logic [7:0] mem [MEM_BYTES];

    // 读队列
    logic r_v [RQ], r_hpr [RQ], r_snap [RQ], r_active [RQ], r_aerr [RQ], r_ecc [RQ], r_started [RQ];
    logic [CORE_TAG_WIDTH-1:0] r_tok [RQ];
    longint r_off [RQ];
    int r_wseq [RQ], r_due [RQ], r_seq [RQ], r_words [RQ];
    logic [LINE_BITS-1:0] r_data [RQ];
    // 写队列：state 0 等待回送指针，1 等待数据，2 数据已写入、等待归还 credit
    logic w_v [WQ], w_aerr [WQ], w_rmw [WQ];
    logic [1:0] w_state [WQ];
    logic [WDATA_PTR_BITS-1:0] w_ptr [WQ];
    longint w_off [WQ];
    int w_seq [WQ], w_due [WQ];
    // 按回送顺序等待写数据的写队列下标
    int exp_q [WQ];
    int exp_head, exp_count, exp_words;

    int cyc, wseq_next, wdone, rseq_next, n_lpr, n_hpr, n_wr, pend_lpr, pend_hpr, pend_wr;
    int last_tok_stream;
    logic [31:0] rnd;

    function automatic logic [31:0] xorshift(input logic [31:0] x);
        logic [31:0] y;
        y = x ^ (x << 13);
        y = y ^ (y >> 17);
        return y ^ (y << 5);
    endfunction

    task automatic fail(input string why);
        if (!model_error) begin
            $display("HIF MODEL ERROR @%0d: %s", cyc, why);
        end
        model_error <= 1'b1;
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h0;
            for (int i = 0; i < RQ; i++) begin
                r_v[i] = 0; r_active[i] = 0; r_started[i] = 0;
            end
            for (int i = 0; i < WQ; i++) w_v[i] = 0;
            exp_head = 0; exp_count = 0; exp_words = 0;
            cyc = 0; wseq_next = 0; wdone = 0; rseq_next = 0;
            n_lpr = 0; n_hpr = 0; n_wr = 0; pend_lpr = 0; pend_hpr = 0; pend_wr = 0;
            last_tok_stream = -1;
            rnd = 32'(SEED) | 32'h1;
            hif_cmd_stall <= 1'b0;
            hif_wdata_stall <= 1'b0;
            hif_lpr_credit <= '0;
            hif_hpr_credit <= '0;
            hif_wr_credit <= 1'b0;
            hif_wrecc_credit <= '0;
            hif_rdata_valid <= 1'b0;
            hif_rdata_end <= 1'b0;
            hif_rdata_token <= '0;
            hif_rdata <= '0;
            hif_rdata_uncorr_ecc_err <= 1'b0;
            hif_rdata_addr_err <= 1'b0;
            hif_wdata_ptr_valid <= 1'b0;
            hif_wdata_ptr <= '0;
            hif_wdata_ptr_addr_err <= 1'b0;
            model_error <= 1'b0;
            stat_rd <= '0;
            stat_wr <= '0;
            stat_ooo <= '0;
            stat_interleave <= '0;
            stat_stall <= '0;
        end else begin
            int pick, oldest, active_n, out;
            rnd = xorshift(rnd);

            // ---------------- 命令 ----------------
            if (hif_cmd_valid && hif_cmd_stall) begin
                stat_stall <= stat_stall + 1;
            end
            if (hif_cmd_valid && !hif_cmd_stall) begin
                longint off;
                off = longint'(hif_cmd_addr) * WORD_BYTES;
                if (off % LINE_BYTES != 0) fail("command address not aligned to a burst");
                if (hif_cmd_type == 2'b01) begin
                    logic hpr;
                    hpr = VPRW_EN ? hif_cmd_pri == HIF_PRI_BITS'(2) : hif_cmd_pri[0];
                    if (hif_cmd_length != 0) fail("only full-burst reads are modelled");
                    if (hpr ? n_hpr >= HPR_CREDITS : n_lpr >= LPR_CREDITS) fail("read accepted without credit");
                    for (int i = 0; i < RQ; i++)
                        if (r_v[i] && r_tok[i] == hif_cmd_token) fail("read token reused while outstanding");
                    pick = -1;
                    for (int i = 0; i < RQ; i++) if (pick < 0 && !r_v[i]) pick = i;
                    if (pick < 0) fail("read queue overflow");
                    else begin
                        r_v[pick] = 1; r_hpr[pick] = hpr; r_tok[pick] = hif_cmd_token; r_off[pick] = off;
                        r_wseq[pick] = wseq_next; r_snap[pick] = 0; r_active[pick] = 0; r_started[pick] = 0;
                        r_seq[pick] = rseq_next; r_words[pick] = 0;
                        rseq_next++;
                        if (hpr) n_hpr++; else n_lpr++;
                    end
                    stat_rd <= stat_rd + 1;
                end else if (hif_cmd_type == 2'b00 || hif_cmd_type == 2'b10) begin
                    if (n_wr >= WR_CREDITS) fail("write accepted without credit");
                    if (hif_cmd_type == 2'b10 && n_lpr >= LPR_CREDITS) fail("RMW accepted without LPR credit");
                    // 指针标识主机侧写数据缓冲：数据送达后即可复用，此前不可。
                    for (int i = 0; i < WQ; i++)
                        if (w_v[i] && w_state[i] != 2 && w_ptr[i] == hif_cmd_wdata_ptr)
                            fail("write pointer reused before its data was transferred");
                    pick = -1;
                    for (int i = 0; i < WQ; i++) if (pick < 0 && !w_v[i]) pick = i;
                    if (pick < 0) fail("write queue overflow");
                    else begin
                        w_v[pick] = 1; w_state[pick] = 0; w_ptr[pick] = hif_cmd_wdata_ptr; w_off[pick] = off;
                        w_seq[pick] = wseq_next; w_aerr[pick] = off + LINE_BYTES > MEM_BYTES;
                        w_rmw[pick] = hif_cmd_type == 2'b10;
                        w_due[pick] = cyc + 2 + (stress ? int'(rnd[3:0]) : 0);
                        wseq_next++;
                        n_wr++;
                        if (w_rmw[pick]) n_lpr++;
                    end
                    stat_wr <= stat_wr + 1;
                end else begin
                    fail("reserved command type");
                end
            end

            // ---------------- 写数据：按回送顺序接收 ----------------
            if (hif_wdata_valid && !hif_wdata_stall) begin
                if (exp_count == 0) fail("write data without a returned pointer");
                else begin
                    int e;
                    e = exp_q[exp_head];
                    if (hif_wdata_end != (exp_words == LINE_WORDS - 1)) fail("hif_wdata_end on the wrong beat");
                    if (!w_aerr[e]) begin
                        for (int b = 0; b < HIF_BYTES; b++)
                            if (hif_wdata_mask[b]) mem[int'(w_off[e]) + exp_words * HIF_BYTES + b] = hif_wdata[b*8 +: 8];
                    end
                    if (exp_words == LINE_WORDS - 1) begin
                        exp_words = 0;
                        exp_head = (exp_head + 1) % WQ;
                        exp_count--;
                        w_state[e] = 2;
                        w_due[e] = cyc + LATENCY / 2 + (stress ? int'(rnd[7:4]) : 0);
                        wdone++;
                    end else begin
                        exp_words++;
                    end
                end
            end

            // ---------------- 读取数：更早的写都写入后取数 ----------------
            for (int i = 0; i < RQ; i++) begin
                if (r_v[i] && !r_snap[i] && r_wseq[i] <= wdone) begin
                    r_snap[i] = 1;
                    r_aerr[i] = r_off[i] + LINE_BYTES > MEM_BYTES;
                    r_ecc[i] = POISON_LINE >= 0 && r_off[i] == longint'(POISON_LINE / LINE_BYTES * LINE_BYTES);
                    for (int b = 0; b < LINE_BYTES; b++)
                        r_data[i][b*8 +: 8] = (r_aerr[i] || r_ecc[i]) ? 8'h0 : mem[int'(r_off[i]) + b];
                    r_due[i] = cyc + LATENCY + (stress ? int'(rnd[11:8]) : 0);
                end
            end

            // ---------------- 写指针回送：按命令顺序，至少晚 2 拍 ----------------
            hif_wdata_ptr_valid <= 1'b0;
            oldest = -1;
            for (int i = 0; i < WQ; i++)
                if (w_v[i] && w_state[i] == 0 && (oldest < 0 || w_seq[i] < w_seq[oldest])) oldest = i;
            if (oldest >= 0 && w_due[oldest] <= cyc && !block && !(stress && rnd[13:12] == 0)) begin
                hif_wdata_ptr_valid <= 1'b1;
                hif_wdata_ptr <= w_ptr[oldest];
                hif_wdata_ptr_addr_err <= w_aerr[oldest];
                w_state[oldest] = 1;
                exp_q[(exp_head + exp_count) % WQ] = oldest;
                exp_count++;
            end

            // ---------------- 写 credit 归还 ----------------
            for (int i = 0; i < WQ; i++) begin
                if (w_v[i] && w_state[i] == 2 && w_due[i] <= cyc) begin
                    w_v[i] = 0;
                    n_wr--;
                    pend_wr++;
                    if (w_rmw[i]) begin
                        n_lpr--;
                        pend_lpr++;
                    end
                    break;
                end
            end

            // ---------------- 读数据返回 ----------------
            active_n = 0;
            for (int i = 0; i < RQ; i++) if (r_v[i] && r_active[i]) active_n++;
            if (!block && active_n < (stress ? STREAMS : 1)) begin
                pick = -1;
                for (int i = 0; i < RQ; i++) begin
                    if (r_v[i] && r_snap[i] && !r_active[i] && !r_started[i] && r_due[i] <= cyc) begin
                        // 正常时选最早的；stress 时选最晚的，制造乱序。
                        if (pick < 0 || (stress ? r_seq[i] > r_seq[pick] : r_seq[i] < r_seq[pick])) pick = i;
                    end
                end
                if (pick >= 0) begin
                    for (int i = 0; i < RQ; i++)
                        if (r_v[i] && !r_started[i] && i != pick && r_seq[i] < r_seq[pick]) begin
                            stat_ooo <= stat_ooo + 1;
                            break;
                        end
                    r_active[pick] = 1;
                    r_started[pick] = 1;
                    if (r_hpr[pick]) begin
                        n_hpr--;
                        pend_hpr++;
                    end else begin
                        n_lpr--;
                        pend_lpr++;
                    end
                end
            end
            hif_rdata_valid <= 1'b0;
            hif_rdata_end <= 1'b0;
            hif_rdata_addr_err <= 1'b0;
            hif_rdata_uncorr_ecc_err <= 1'b0;
            if (inject_bad_token) begin
                hif_rdata_valid <= 1'b1;
                hif_rdata_token <= '1;
            end else if (!block && !(stress && rnd[17:16] == 0)) begin
                // stress 时优先换一个 token，形成交织。
                out = -1;
                for (int i = 0; i < RQ; i++) begin
                    if (r_v[i] && r_active[i]) begin
                        if (out < 0 || (stress && out == last_tok_stream)) out = i;
                    end
                end
                if (out >= 0) begin
                    if (last_tok_stream >= 0 && last_tok_stream != out && r_v[last_tok_stream] &&
                        r_active[last_tok_stream]) begin
                        stat_interleave <= stat_interleave + 1;
                    end
                    hif_rdata_valid <= 1'b1;
                    hif_rdata_token <= r_tok[out];
                    hif_rdata <= r_data[out][r_words[out]*CORE_DATA_WIDTH +: CORE_DATA_WIDTH];
                    hif_rdata_end <= r_words[out] == LINE_WORDS - 1;
                    hif_rdata_addr_err <= r_aerr[out];
                    hif_rdata_uncorr_ecc_err <= r_ecc[out];
                    last_tok_stream = out;
                    if (r_words[out] == LINE_WORDS - 1) begin
                        r_v[out] = 0;
                        r_active[out] = 0;
                    end else begin
                        r_words[out]++;
                    end
                end
            end

            // ---------------- credit 脉冲 ----------------
            begin
                int k;
                logic [HIF_CREDIT_BITS-1:0] v;
                k = pend_lpr < HIF_CREDIT_BITS ? pend_lpr : HIF_CREDIT_BITS;
                v = '0;
                for (int b = 0; b < HIF_CREDIT_BITS; b++) v[b] = b < k;
                hif_lpr_credit <= v;
                pend_lpr -= k;
                k = pend_hpr < HIF_CREDIT_BITS ? pend_hpr : HIF_CREDIT_BITS;
                v = '0;
                for (int b = 0; b < HIF_CREDIT_BITS; b++) v[b] = b < k;
                hif_hpr_credit <= v;
                pend_hpr -= k;
                hif_wr_credit <= pend_wr > 0;
                if (pend_wr > 0) pend_wr--;
            end

            // ---------------- 下一拍的 stall ----------------
            hif_cmd_stall <= block || (stress && rnd[21:20] == 0);
            hif_wdata_stall <= block || (stress && rnd[25:24] == 0);
            cyc++;
        end
    end

    // 读返回过程中队列项本身不计入 CAM，但需要保留数据；未用到的 HIF 输入。
    assign hif_rdata_crc_err = 1'b0;
endmodule
