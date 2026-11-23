// ============================================================================
// AXI 主机任务与记分板（被 tb_top.sv 以 `include 方式包含，可直接使用 tb_top 中的信号）
//
// 用法（在 tests.svh 的用例中）：
//   txn_t t = make_txn(地址, 拍数, SIZE, ID);   描述一笔突发；期望响应按地址自动算出
//   axi_write(t);                               发 AW 与全部 W，等到 B 并核对 BRESP
//   axi_read(t);                                发 AR，等到最后一拍 R；每拍 R 由监视器自动核对
//   需要多笔并发时，依次调用 send_aw / send_w / send_ar（只入队、立即返回），再用 wait_done 等待，见 tc_outstanding；
//   这种用法中每笔事务要用 make_txn 新建（编号用来对应发送与完成）。
//
// 检查方法（记分板）：
//   写：每个 W 握手时，把选通为 1 的字节写入参考存储 ref_mem（只在期望响应为 OKAY 时）。
//   读：每个 R 握手时，取本拍地址范围内的字节与 ref_mem 比对，并核对 RRESP、RLAST。
//   B ：按 ID 取出最早的在途写，核对 BRESP。
//   存储：每个用例结束后，直接读取控制器模型的存储（后门），与 ref_mem 逐字节比对整个存储空间。
//         因此只写不读的用例也会检查数据；没写过的字节必须仍为 0，写到错误地址也能发现。
// 同一 ID 的响应必须按请求顺序返回，因此每个 ID 用一个队列记录在途事务，响应总是与队首比对。
// ============================================================================

// ---------------- 事务描述 ----------------
typedef enum int {
    STRB_FULL,   // 本拍字节范围内全部选通
    STRB_PART,   // 部分选通：约 1/3 的字节不写
    STRB_ZERO    // 全零选通：不写任何字节
} strb_mode_e;

typedef struct {
    longint unsigned addr;   // 起始字节地址：须按 2^size 对齐，整个突发不跨 4KB
    int              len;    // 拍数 1～256（即 AxLEN + 1）
    int              size;   // 每拍字节数的 log2，0～log2(BYTES)
    int              id;     // AXI ID
    int              qos;    // AxQOS
    int              seed;   // 写数据图样的种子
    strb_mode_e      strb;   // 写选通方式
    logic [1:0]      resp;   // 期望的 BRESP / RRESP
    int              seq;    // 内部编号（make_txn 分配），用于等待完成
} txn_t;

// ---------------- 记分板状态 ----------------
bit [7:0] ref_mem [longint unsigned];   // 参考存储：只记录写过的字节，未写过的字节为 0
txn_t     wr_exp [int][$];              // 每个 ID 的在途写，按发出顺序
txn_t     rd_exp [int][$];              // 每个 ID 的在途读，按发出顺序
int       rd_beat [int];                // 每个 ID 当前读突发已收到的拍数
bit       done [4096];                  // done[seq % 4096] = 1 表示该事务已完成
int       seq_next = 0;

int n_err = 0, n_wr = 0, n_rd = 0, n_rbeat = 0;   // 统计

// ---------------- 小工具 ----------------
function automatic void fail(string msg);
    n_err++;
    $display("[%t] 错误：%s", $realtime, msg);
endfunction

// 写数据图样：由字节地址与种子决定，读回时可以重新算出
function automatic bit [7:0] pattern(longint unsigned a, int seed);
    return 8'(a * 13 + (a >> 8) + seed * 7);
endfunction

function automatic bit [7:0] ref_byte(longint unsigned a);
    return ref_mem.exists(a) ? ref_mem[a] : 8'h00;
endfunction

// 期望响应：按地址映射（见 tb_top 的常量说明）
function automatic logic [1:0] expect_resp(longint unsigned addr, int len, int size);
    longint unsigned last = addr + longint'(len) * (1 << size) - 1;
    if (addr >= WINDOW) return DECERR;        // 窗口外：桥直接回 DECERR
    if (last >= MEM_BYTES) return DECERR;     // 超出控制器容量：控制器报 addr_err
    return OKAY;
endfunction

// 构造一笔突发：其余字段取默认值，用例可再修改（例如 t.strb = STRB_PART）
function automatic txn_t make_txn(longint unsigned addr, int len, int size, int id);
    txn_t t;
    t.addr = addr;  t.len = len;  t.size = size;  t.id = id;  t.qos = 0;
    t.seed = seq_next;  t.strb = STRB_FULL;  t.resp = expect_resp(addr, len, size);
    t.seq = seq_next++;
    done[t.seq % 4096] = 0;
    return t;
endfunction

// 第 n 拍的字节地址、在总线上的起始字节通道
function automatic longint unsigned beat_addr(txn_t t, int n);
    return t.addr + longint'(n) * (1 << t.size);
endfunction
function automatic int beat_lane(txn_t t, int n);
    return int'(beat_addr(t, n) % BYTES);
endfunction

// 第 n 拍中总线第 j 个字节是否选通
function automatic bit strobe_on(txn_t t, int n, int j);
    int lane = beat_lane(t, n);
    if (j < lane || j >= lane + (1 << t.size)) return 0;      // 不在本拍的字节范围内
    case (t.strb)
        STRB_FULL: return 1;
        STRB_PART: return (beat_addr(t, n) + j + t.seed) % 3 != 0;
        default:   return 0;
    endcase
endfunction

// ---------------- 复位 ----------------
// 复位后拉高 link_up，并等两端用只含协议头（PH）的帧交换初始 credit。
// 这些帧由两端桥自己发出（aou_flit_tx：没有消息但有待归还 credit 时提交只含 PH 的帧），测试平台不需要做任何事；
// 波形见设计文档“链路 credit 初始化”一节。
task automatic reset_dut();
    rst_n <= 0; link_up <= 0;
    repeat (5) @(posedge clk);
    rst_n <= 1;
    repeat (3) @(posedge clk);
    link_up <= 1;
    repeat (50) @(posedge clk);
endtask

// ---------------- 通道级任务 ----------------
// send_aw / send_w / send_ar 只把事务放进发送队列，立即返回；真正驱动 AXI 信号的是下面的三个驱动器。
// W 按 send_w 的调用顺序发送，必须与 send_aw 的顺序一致（AXI 规定写数据按写地址顺序）。
// 发出后用 wait_done 等待完成。
txn_t aw_q [$], w_q [$], ar_q [$];   // 待发送的 AW、W、AR（队首为正在发送的一笔）

task automatic send_aw(txn_t t);
    wr_exp[t.id].push_back(t);      // 记入在途写，供 B 监视器核对
    aw_q.push_back(t);
endtask

task automatic send_w(txn_t t);
    w_q.push_back(t);
endtask

task automatic send_ar(txn_t t);
    rd_exp[t.id].push_back(t);      // 记入在途读，供 R 监视器逐拍核对
    ar_q.push_back(t);
endtask

// ---------------- 驱动器 ----------------
// AW、W、AR 各由一个 always @(posedge clk) 块驱动，写法与可综合 RTL 相同：
//   每个上升沿先看本沿是否握手（VALID && READY，读到的是沿前的值），握手则队首出队；
//   再用非阻塞赋值给出下一拍的 VALID 与内容，队列为空时 VALID 为 0。
// 这样同一信号只在一个 always 块里赋值，VCS 与 Verilator 的行为一致。
// （原先在任务中直接用非阻塞赋值驱动，Verilator 5.052 会丢失部分赋值：循环逐字节赋值只剩最后一个字节，
//  连续两笔之间 VALID 丢失。改为由 always 块驱动后，VCS 与 Verilator 结果一致。）
always @(posedge clk) begin
    if (s_axi_awvalid && s_axi_awready) void'(aw_q.pop_front());
    s_axi_awvalid <= aw_q.size() > 0;
    if (aw_q.size() > 0) begin
        s_axi_awaddr <= aw_q[0].addr;
        s_axi_awid   <= aw_q[0].id;
        s_axi_awlen  <= aw_q[0].len - 1;
        s_axi_awsize <= aw_q[0].size;
        s_axi_awqos  <= aw_q[0].qos;
        s_axi_awuser <= 16'(aw_q[0].seq);
    end
end

always @(posedge clk) begin
    if (s_axi_arvalid && s_axi_arready) void'(ar_q.pop_front());
    s_axi_arvalid <= ar_q.size() > 0;
    if (ar_q.size() > 0) begin
        s_axi_araddr <= ar_q[0].addr;
        s_axi_arid   <= ar_q[0].id;
        s_axi_arlen  <= ar_q[0].len - 1;
        s_axi_arsize <= ar_q[0].size;
        s_axi_arqos  <= ar_q[0].qos;
        s_axi_aruser <= 16'(ar_q[0].seq);
    end
end

// W：w_beat 为队首突发正在发送的拍号；握手时更新参考存储（期望出错的突发不改变存储内容）。
int                    w_beat = 0;
logic [DATA_WIDTH-1:0] w_data_n;
logic [BYTES-1:0]      w_strb_n;
always @(posedge clk) begin
    if (s_axi_wvalid && s_axi_wready) begin
        if (w_q[0].resp == OKAY)
            for (int j = 0; j < BYTES; j++)
                if (strobe_on(w_q[0], w_beat, j))
                    ref_mem[beat_addr(w_q[0], w_beat) + j - beat_lane(w_q[0], w_beat)] =
                        pattern(beat_addr(w_q[0], w_beat) + j - beat_lane(w_q[0], w_beat), w_q[0].seed);
        if (w_beat == w_q[0].len - 1) begin
            void'(w_q.pop_front());
            w_beat = 0;
        end else begin
            w_beat++;
        end
    end
    s_axi_wvalid <= w_q.size() > 0;
    if (w_q.size() > 0) begin
        // 先在局部变量里拼好整拍，再一次性赋给总线
        for (int j = 0; j < BYTES; j++) begin
            w_data_n[j*8 +: 8] = pattern(beat_addr(w_q[0], w_beat) + j - beat_lane(w_q[0], w_beat), w_q[0].seed);
            w_strb_n[j]        = strobe_on(w_q[0], w_beat, j);
        end
        s_axi_wdata <= w_data_n;
        s_axi_wstrb <= w_strb_n;
        s_axi_wlast <= w_beat == w_q[0].len - 1;
        s_axi_wuser <= 16'(w_beat);
    end
end

// 其余 AXI 输入为常量
assign s_axi_awburst = 2'b01;   // INCR
assign s_axi_arburst = 2'b01;
assign {s_axi_awprot, s_axi_awcache, s_axi_awlock} = '0;
assign {s_axi_arprot, s_axi_arcache, s_axi_arlock} = '0;

// 等待一笔事务完成（写收到 B、读收到 RLAST）；超过 max_cycles 个周期记为失败。
// 逐拍查询完成标志，不用 fork：Verilator 5.052 在 fork 中引用任务参数会崩溃。
task automatic wait_done(txn_t t, int max_cycles = 20000);
    int k = t.seq % 4096;
    int n = 0;
    while (!done[k] && n < max_cycles) begin
        @(posedge clk);
        n++;
    end
    if (!done[k])
        fail($sformatf("等待事务超时：seq=%0d addr=0x%0h len=%0d id=%0d", t.seq, t.addr, t.len, t.id));
endtask

// ---------------- 事务级任务 ----------------
// 每次调用都给事务一个新编号，因此同一个 txn_t 可以先写后读、或重复使用。
function automatic txn_t renew(txn_t t);
    t.seq = seq_next++;
    done[t.seq % 4096] = 0;
    return t;
endfunction

task automatic axi_write(txn_t t);
    t = renew(t);
    send_aw(t);
    send_w(t);
    wait_done(t);
endtask

task automatic axi_read(txn_t t);
    t = renew(t);
    send_ar(t);
    wait_done(t);
endtask

// ---------------- 监视器（记分板） ----------------
// B：与该 ID 最早的在途写比对 BRESP
always @(posedge clk) begin
    if (rst_n && s_axi_bvalid && s_axi_bready) begin
        // 注意：always 块中的局部变量是静态的，带初值的声明只在仿真开始时赋值一次，所以先声明再赋值
        txn_t t;
        int id;
        id = s_axi_bid;
        if (!wr_exp.exists(id) || wr_exp[id].size() == 0) begin
            fail($sformatf("收到 B，但 ID %0d 没有在途写", id));
        end else begin
            t = wr_exp[id].pop_front();
            if (s_axi_bresp !== t.resp)
                fail($sformatf("BRESP 错误：ID %0d 地址 0x%0h，期望 %0d，实际 %0d", id, t.addr, t.resp, s_axi_bresp));
            done[t.seq % 4096] = 1;
            n_wr++;
        end
    end
end

// R：按该 ID 最早的在途读算出本拍地址，逐字节比对数据，并核对 RRESP、RLAST
always @(posedge clk) begin
    if (rst_n && s_axi_rvalid && s_axi_rready) begin
        txn_t t;
        int id, n, lane;
        longint unsigned a;
        id = s_axi_rid;
        if (!rd_exp.exists(id) || rd_exp[id].size() == 0) begin
            fail($sformatf("收到 R，但 ID %0d 没有在途读", id));
        end else begin
            t = rd_exp[id][0];
            n = rd_beat.exists(id) ? rd_beat[id] : 0;
            a = beat_addr(t, n);
            lane = beat_lane(t, n);
            if (s_axi_rresp !== t.resp)
                fail($sformatf("RRESP 错误：ID %0d 地址 0x%0h 第 %0d 拍，期望 %0d，实际 %0d", id, a, n, t.resp, s_axi_rresp));
            if (t.resp == OKAY)
                for (int j = lane; j < lane + (1 << t.size); j++)
                    if (s_axi_rdata[j*8 +: 8] !== ref_byte(a + j - lane)) begin
                        fail($sformatf("读数据错误：地址 0x%0h，期望 0x%02h，实际 0x%02h（ID %0d 第 %0d 拍）",
                                       a + j - lane, ref_byte(a + j - lane), s_axi_rdata[j*8 +: 8], id, n));
                        break;
                    end
            if (s_axi_rlast !== (n == t.len - 1))
                fail($sformatf("RLAST 错误：ID %0d 第 %0d 拍（共 %0d 拍）", id, n, t.len));
            n_rbeat++;
            if (n == t.len - 1) begin
                void'(rd_exp[id].pop_front());
                rd_beat[id] = 0;
                done[t.seq % 4096] = 1;
                n_rd++;
            end else begin
                rd_beat[id] = n + 1;
            end
        end
    end
end

// 存储后门检查：控制器模型的存储 u_mc.mem 按字节地址存放（桥的 ADDR_BASE 为 0，地址 a 即 mem[a]），
// 与参考存储逐字节比对。只打印前几处不一致，避免刷屏。
task automatic check_mem();
    int n_bad = 0;
    for (int a = 0; a < MEM_BYTES; a++)
        if (u_mc.mem[a] !== ref_byte(a)) begin
            if (n_bad < 4)
                fail($sformatf("存储内容错误：地址 0x%0h，期望 0x%02h，实际 0x%02h", a, ref_byte(a), u_mc.mem[a]));
            n_bad++;
        end
    if (n_bad > 4) fail($sformatf("存储内容共 %0d 字节不一致（只列出前 4 处）", n_bad));
endtask

// ---------------- 运行与汇总 ----------------
task automatic run_test(string name);
    int     err0 = n_err;
    longint c0 = cycle;
    $display("---- %s", name);
    run_case(name);                  // tests.svh 中按用例名分派
    repeat (20) @(posedge clk);      // 等最后的写数据进入控制器模型
    check_mem();
    $display("     %s，用时 %0d 周期", n_err == err0 ? "通过" : "失败", cycle - c0);
endtask

task automatic report();
    $display("统计  写 %0d 笔、读 %0d 笔（%0d 拍），错误 %0d", n_wr, n_rd, n_rbeat, n_err);
    if (n_err == 0) $display("SV TB PASS");
    else            $display("SV TB FAIL  %0d 处错误", n_err);
endtask
