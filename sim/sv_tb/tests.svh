// ============================================================================
// 测试用例（被 tb_top.sv 以 `include 方式包含）
//
// 每个用例是一个 task，开头的注释说明：测什么 / 怎么测 / 波形里看什么。
// 新增用例的步骤：
//   1. 仿照下面的用例写一个 task，例如 task automatic tc_my_case(); ... endtask
//   2. 把用例名加到 ALL_TESTS 列表中（运行全部用例时按列表顺序执行）
//   3. 在 run_case 的 case 语句里加一行 "tc_my_case": tc_my_case();
//   4. make -C sim sv-vcs TEST=tc_my_case 单独运行
// 地址约定：每个用例使用自己的 4KB 页（P(n) = n × 4KB），互不覆盖；控制器容量为 MEM_BYTES（默认 64KB，16 页）。
// ============================================================================

localparam longint PAGE = 4096;
localparam int     FULL = $clog2(BYTES);            // 全宽传输的 SIZE（256 位总线为 5）
function automatic longint unsigned P(int n);
    return longint'(n) * PAGE;
endfunction

string ALL_TESTS [$] = '{
    "tc_single", "tc_bursts", "tc_strobe", "tc_narrow", "tc_long_burst", "tc_4k_edge",
    "tc_decerr", "tc_outstanding", "tc_same_id", "tc_backpressure", "tc_link_down", "tc_mc_stress",
    "tc_random", "tc_write_only", "tc_throughput"
};

task automatic run_case(string name);
    case (name)
        "tc_single":       tc_single();
        "tc_bursts":       tc_bursts();
        "tc_strobe":       tc_strobe();
        "tc_narrow":       tc_narrow();
        "tc_long_burst":   tc_long_burst();
        "tc_4k_edge":      tc_4k_edge();
        "tc_decerr":       tc_decerr();
        "tc_outstanding":  tc_outstanding();
        "tc_same_id":      tc_same_id();
        "tc_backpressure": tc_backpressure();
        "tc_link_down":    tc_link_down();
        "tc_mc_stress":    tc_mc_stress();
        "tc_random":       tc_random();
        "tc_write_only":   tc_write_only();
        "tc_throughput":   tc_throughput();
        default:           fail($sformatf("没有名为 %s 的用例", name));
    endcase
endtask

// ----------------------------------------------------------------------------
// tc_single：单拍写后读
//   测什么：最基本的一笔全宽写和一笔全宽读能否走通两端桥、链路和控制器。
//   怎么测：在 P1 写 1 拍，再读回，记分板核对数据与 RESP。
//   看波形：AW/W 握手 → soc_tx_valid（请求帧发出）→ hif_cmd_valid（写命令）→ hif_wdata_ptr_valid（控制器
//           回送写指针）→ hif_wdata_valid（写数据）→ B；读同理，看 hif_rdata_valid 与 R。
// ----------------------------------------------------------------------------
//   自检：运行时加 +CORRUPT（make sv-vcs TEST=tc_single SV_ARGS=+CORRUPT），写完后故意改错参考存储中的
//         一个字节，读回时记分板必须报“读数据错误”，用例结束时存储后门检查必须报“存储内容错误”，
//         用来确认两种检查确实生效。
task automatic tc_single();
    txn_t t = make_txn(P(1) + 2 * BYTES, 1, FULL, 1);
    axi_write(t);
    if ($test$plusargs("CORRUPT")) ref_mem[t.addr] = ~ref_byte(t.addr);
    axi_read(t);
endtask

// ----------------------------------------------------------------------------
// tc_bursts：不同长度的突发
//   测什么：2、4、16 拍，以及正好写满一个 4KB 页的突发。
//   怎么测：在 P2 依次写入并读回，每次用不同的数据种子。
//   看波形：长突发时组帧器一帧装多条 WDATA，消息跨帧（u_soc.u_transport.u_tx 的 used、spill_offset）。
// ----------------------------------------------------------------------------
task automatic tc_bursts();
    int lens [$] = '{2, 4, 16, int'(PAGE / BYTES)};
    foreach (lens[i]) begin
        txn_t t = make_txn(P(2), lens[i], FULL, 2 + i);
        axi_write(t);
        axi_read(t);
    end
endtask

// ----------------------------------------------------------------------------
// tc_strobe：写选通
//   测什么：部分选通只改写选中的字节；全零选通不改写任何字节。
//   怎么测：先全选通写，再用部分选通覆盖，读回检查新旧数据混合；再全零选通写，读回检查不变。
//   看波形：部分选通时 WDATA 消息带 WSTRB（8 粒度），全选通时为 WDATAFULL（7 粒度）；存储侧 hif_wdata_mask。
// ----------------------------------------------------------------------------
task automatic tc_strobe();
    txn_t t;
    t = make_txn(P(3), 4, FULL, 6);                     axi_write(t);
    t = make_txn(P(3), 4, FULL, 6); t.strb = STRB_PART; axi_write(t);
    axi_read(make_txn(P(3), 4, FULL, 6));
    t = make_txn(P(3), 4, FULL, 6); t.strb = STRB_ZERO; axi_write(t);
    axi_read(make_txn(P(3), 4, FULL, 6));
endtask

// ----------------------------------------------------------------------------
// tc_narrow：窄传输
//   测什么：每拍字节数小于总线宽度时，字节通道按地址轮转；存储侧把相邻窄拍合并成一行再发 HIF 命令。
//   怎么测：4 字节 × 16 拍（部分选通）；再对每种窄 SIZE 各做一笔 4 拍突发。
//   看波形：s_axi_wstrb 每拍右移 4 字节；存储侧 stage_valid（行合并）与 hif_cmd_valid 的次数少于 W 拍数。
// ----------------------------------------------------------------------------
task automatic tc_narrow();
    txn_t t = make_txn(P(4) + 4, 16, 2, 7);
    t.strb = STRB_PART;
    axi_write(t);
    axi_read(t);
    for (int s = 0; s < FULL; s++) begin
        t = make_txn(P(4) + 1024 + s * 512, 4, s, 8);
        axi_write(t);
        axi_read(t);
    end
endtask

// ----------------------------------------------------------------------------
// tc_long_burst：AXI 最长突发
//   测什么：256 拍（AxLEN = 255）的读写。
//   怎么测：SIZE = 2（每拍 4 字节，共 1KB），在 P5 写入并读回。
// ----------------------------------------------------------------------------
task automatic tc_long_burst();
    txn_t t = make_txn(P(5), 256, 2, 9);
    axi_write(t);
    axi_read(t);
endtask

// ----------------------------------------------------------------------------
// tc_4k_edge：恰好止于 4KB 边界的突发
//   测什么：突发的最后一个字节是一页的最后一个字节时，桥的边界检查不误报、切行正确。
//   怎么测：从 P7 往前 4 拍处开始写 4 拍。
// ----------------------------------------------------------------------------
task automatic tc_4k_edge();
    txn_t t = make_txn(P(7) - 4 * BYTES, 4, FULL, 10);
    axi_write(t);
    axi_read(t);
endtask

// ----------------------------------------------------------------------------
// tc_decerr：错误响应
//   测什么：(1) 在桥的窗口内、超出控制器容量的地址：控制器报 addr_err，桥回 DECERR；
//           (2) 在桥的窗口外的地址：桥直接回 DECERR，不发 HIF 命令；
//           错误响应不是协议错误，之后的正常访问不受影响。
//   怎么测：两种地址各写、读一次，期望 RESP = DECERR；最后做一次正常读写。
//   看波形：情况 (2) 时 hif_cmd_valid 不拉高，B / R 直接返回。
// ----------------------------------------------------------------------------
task automatic tc_decerr();
    txn_t t;
    t = make_txn(MEM_BYTES + 256, 2, FULL, 11);  axi_write(t);  axi_read(t);
    t = make_txn(WINDOW + 256, 2, FULL, 12);     axi_write(t);  axi_read(t);
    t = make_txn(P(1), 2, FULL, 13);             axi_write(t);  axi_read(t);
endtask

// ----------------------------------------------------------------------------
// tc_outstanding：多笔事务并发
//   测什么：多笔写与多笔读同时在途；AW、W、AR 三个通道各自推进，写数据按 AW 顺序发送。
//   怎么测：先在 P7 写好 4 段数据；然后同时发出 4 笔写（P8）和 4 笔读（P7，不同 ID），
//           等全部完成后再读回 P8。
//   看波形：AW 连续握手、W 与 AR 同时进行；u_soc 的 wr_live / rd_live（在途表）有多位为 1。
// ----------------------------------------------------------------------------
task automatic tc_outstanding();
    txn_t wr [4], rd [4];
    for (int i = 0; i < 4; i++) axi_write(make_txn(P(7) + i * 1024, 4, FULL, 20 + i));
    for (int i = 0; i < 4; i++) begin
        wr[i] = make_txn(P(8) + i * 1024, 4, FULL, 30 + i);
        rd[i] = make_txn(P(7) + i * 1024, 4, FULL, 40 + i);
    end
    fork
        for (int i = 0; i < 4; i++) send_aw(wr[i]);
        for (int i = 0; i < 4; i++) send_w(wr[i]);
        for (int i = 0; i < 4; i++) send_ar(rd[i]);
    join
    for (int i = 0; i < 4; i++) begin wait_done(wr[i]); wait_done(rd[i]); end
    for (int i = 0; i < 4; i++) axi_read(make_txn(P(8) + i * 1024, 4, FULL, 50 + i));
endtask

// ----------------------------------------------------------------------------
// tc_same_id：同 ID 保序
//   测什么：同一 ID 的多笔写、多笔读，响应按发出顺序返回（记分板按 ID 队首比对，顺序错了数据就对不上）。
//   怎么测：ID = 60，连续发 4 笔写不等 B，再连续发 4 笔读不等 R。
// ----------------------------------------------------------------------------
task automatic tc_same_id();
    txn_t t [4];
    for (int i = 0; i < 4; i++) t[i] = make_txn(P(9) + i * 1024, 4, FULL, 60);
    fork
        for (int i = 0; i < 4; i++) send_aw(t[i]);
        for (int i = 0; i < 4; i++) send_w(t[i]);
    join
    for (int i = 0; i < 4; i++) wait_done(t[i]);
    for (int i = 0; i < 4; i++) t[i] = make_txn(P(9) + i * 1024, 4, FULL, 60);
    for (int i = 0; i < 4; i++) send_ar(t[i]);
    for (int i = 0; i < 4; i++) wait_done(t[i]);
endtask

// ----------------------------------------------------------------------------
// tc_backpressure：长时间背压
//   测什么：主机不收 R、主机不收 B、控制器停顿、链路停顿时，各级缓冲逐级反压、不丢数据，解除后自动恢复。
//   怎么测：每种停顿持续数百个周期，期间发起访问；解除后核对结果。
//   看波形：r_hold = 1 时 s_axi_rvalid 保持、RDATA 不变（u_soc.r_locked = 1）；接收缓冲填满后
//           链路 credit 不再归还，存储侧停发；mc_block 时 hif_cmd_stall = 1。
// ----------------------------------------------------------------------------
task automatic tc_backpressure();
    txn_t t;
    t = make_txn(P(10), 64, 2, 70);
    axi_write(t);
    r_hold = 1;                                         // (1) 主机不收 R
    fork
        axi_read(t);
        begin repeat (300) @(posedge clk); r_hold = 0; end
    join
    b_hold = 1;                                         // (2) 主机不收 B
    fork
        axi_write(make_txn(P(10) + 1024, 8, FULL, 71));
        begin repeat (300) @(posedge clk); b_hold = 0; end
    join
    mc_block = 1;                                       // (3) 控制器停顿
    fork
        axi_read(make_txn(P(10) + 1024, 8, FULL, 72));
        begin repeat (200) @(posedge clk); mc_block = 0; end
    join
    link_stop = 1;                                      // (4) 链路停顿
    fork
        axi_read(make_txn(P(10), 64, 2, 73));
        begin repeat (200) @(posedge clk); link_stop = 0; end
    join
endtask

// ----------------------------------------------------------------------------
// tc_link_down：事务在途时 link_up 拉低（模拟链路重训练，前提是链路保留在途帧）
//   测什么：link_up 为低期间桥只暂停新的工作（不收新 AXI 请求、不收发新帧、不发新 HIF 命令），
//           已开始的握手照常完成：已呈现的 HIF 命令保持到被接收，HIF 读数据、写指针与写数据照常收发，
//           已拉高的 RVALID / BVALID 保持到握手；link_up 恢复后自动继续，不丢数据、不报错。
//   怎么测：(1) 主机不收 R 时让 RVALID 先拉高，再拉低 link_up；
//           (2) 多笔读写的 HIF 命令刚被接收时拉低 link_up，此时控制器继续返回读数据、回送写指针；
//           (3) 控制器停顿（hif_cmd_stall = 1）、命令已呈现未接收时拉低 link_up，掉链期间解除停顿，
//               该命令必须保持并被接收，之后不再发新命令。
//           每次持续 300 个周期后恢复，核对全部结果；握手与命令保持由 tb_top 中的检查负责。
//   看波形：link_up = 0 期间 hif_rdata_valid、hif_wdata_ptr_valid 仍有脉冲；(3) 中 hif_cmd_valid 保持到
//           stall 解除后被接收，随后不再拉高；s_axi_rvalid 保持为 1 直到 r_hold 解除。
// ----------------------------------------------------------------------------
task automatic tc_link_down();
    txn_t wr [4], rd [4];
    for (int i = 0; i < 4; i++) axi_write(make_txn(P(6) + i * 256, 2, FULL, 150 + i));
    // (1) RVALID 已拉高、主机未接收时掉链
    r_hold = 1;
    fork
        axi_read(make_txn(P(6), 2, FULL, 160));
        begin
            wait (s_axi_rvalid);
            @(posedge clk) link_up <= 0;
            repeat (300) @(posedge clk);
            link_up <= 1;
            repeat (20) @(posedge clk);
            r_hold = 0;
        end
    join
    // (2) HIF 命令刚发出、控制器即将返回时掉链
    for (int i = 0; i < 4; i++) begin
        wr[i] = make_txn(P(6) + 1024 + i * 256, 2, FULL, 170 + i);
        rd[i] = make_txn(P(6) + i * 256, 2, FULL, 180 + i);
    end
    fork
        for (int i = 0; i < 4; i++) send_aw(wr[i]);
        for (int i = 0; i < 4; i++) send_w(wr[i]);
        for (int i = 0; i < 4; i++) send_ar(rd[i]);
        begin
            wait (hif_cmd_valid && !hif_cmd_stall);
            @(posedge clk) link_up <= 0;
            repeat (300) @(posedge clk);
            link_up <= 1;
        end
    join
    for (int i = 0; i < 4; i++) begin wait_done(wr[i]); wait_done(rd[i]); end
    for (int i = 0; i < 4; i++) axi_read(make_txn(P(6) + 1024 + i * 256, 2, FULL, 190 + i));
    // (3) 命令已呈现、被 stall 时掉链；掉链期间解除 stall
    for (int i = 0; i < 4; i++) begin
        wr[i] = make_txn(P(6) + 2048 + i * 256, 2, FULL, 200 + i);
        rd[i] = make_txn(P(6) + 1024 + i * 256, 2, FULL, 210 + i);
    end
    mc_block = 1;
    fork
        for (int i = 0; i < 4; i++) send_aw(wr[i]);
        for (int i = 0; i < 4; i++) send_w(wr[i]);
        for (int i = 0; i < 4; i++) send_ar(rd[i]);
        begin
            wait (hif_cmd_valid && hif_cmd_stall);
            @(posedge clk) link_up <= 0;
            repeat (20) @(posedge clk);
            mc_block = 0;
            repeat (280) @(posedge clk);
            link_up <= 1;
        end
    join
    for (int i = 0; i < 4; i++) begin wait_done(wr[i]); wait_done(rd[i]); end
    for (int i = 0; i < 4; i++) axi_read(make_txn(P(6) + 2048 + i * 256, 2, FULL, 220 + i));
endtask

// ----------------------------------------------------------------------------
// tc_mc_stress：控制器乱序、交织返回
//   测什么：控制器打乱读数据返回顺序、在不同 token 间交织、随机 stall 时，读 ROB 仍按顺序还原数据。
//   怎么测：打开 mc_stress 与随机 READY，多笔读写并发；结束时打印控制器的乱序、交织次数。
//   看波形：hif_rdata_token 不按 0、1、2… 递增；u_target.rob_head 仍按顺序前进。
// ----------------------------------------------------------------------------
task automatic tc_mc_stress();
    txn_t wr [8], rd [8];
    int ooo0 = mc_stat_ooo, itl0 = mc_stat_interleave;
    mc_stress = 1;
    rand_ready = 1;
    for (int i = 0; i < 8; i++) begin
        wr[i] = make_txn(P(11) + i * 512, 4, FULL, 80 + i);
        rd[i] = make_txn(P(11) + i * 512, 4, FULL, 90 + i);
    end
    fork
        for (int i = 0; i < 8; i++) send_aw(wr[i]);
        for (int i = 0; i < 8; i++) send_w(wr[i]);
    join
    for (int i = 0; i < 8; i++) wait_done(wr[i]);
    for (int i = 0; i < 8; i++) send_ar(rd[i]);
    for (int i = 0; i < 8; i++) wait_done(rd[i]);
    mc_stress = 0;
    rand_ready = 0;
    $display("     控制器乱序返回 %0d 次、交织 %0d 次", mc_stat_ooo - ooo0, mc_stat_interleave - itl0);
endtask

// ----------------------------------------------------------------------------
// tc_random：随机合法突发
//   测什么：随机的地址、长度、SIZE、选通组合（种子固定，可用 +SEED= 更换）。
//   怎么测：30 笔，每笔写后读回；地址落在 P12、P13，突发不跨 4KB。
// ----------------------------------------------------------------------------
task automatic tc_random();
    for (int k = 0; k < 30; k++) begin
        int size = $urandom_range(0, FULL);
        int len  = $urandom_range(1, 16);
        int span = len * (1 << size);
        longint unsigned off = ($urandom_range(0, int'(PAGE) - span) >> size) << size;
        txn_t t = make_txn(P(12 + k % 2) + off, len, size, 100 + k % 8);
        t.strb = strb_mode_e'($urandom_range(0, 1));
        axi_write(t);
        axi_read(make_txn(t.addr, len, size, 110 + k % 8));
    end
endtask

// ----------------------------------------------------------------------------
// tc_write_only：只写不读
//   测什么：数据是否真的按地址、按选通写进了控制器的存储（不经过读通路）。
//   怎么测：在 P15 做全宽、窄传输、部分选通、全零选通的写，以及 4 笔不同 ID 的并发写；全程不读。
//           只有 BRESP 由 B 监视器实时核对，数据由用例结束后的存储后门检查（check_mem）核对。
//   看波形：hif_wdata_mask 与 s_axi_wstrb 对应；全零选通那笔的掩码全为 0。
// ----------------------------------------------------------------------------
task automatic tc_write_only();
    txn_t t, wr [4];
    axi_write(make_txn(P(15), 8, FULL, 15));
    t = make_txn(P(15) + 512 + 4, 16, 2, 16);  t.strb = STRB_PART;  axi_write(t);
    t = make_txn(P(15), 4, FULL, 17);          t.strb = STRB_ZERO;  axi_write(t);
    for (int i = 0; i < 4; i++) wr[i] = make_txn(P(15) + 1024 + i * 512, 4, FULL, 140 + i);
    fork
        for (int i = 0; i < 4; i++) send_aw(wr[i]);
        for (int i = 0; i < 4; i++) send_w(wr[i]);
    join
    for (int i = 0; i < 4; i++) wait_done(wr[i]);
endtask

// ----------------------------------------------------------------------------
// tc_throughput：满载吞吐
//   测什么：连续 16 拍写、连续 16 拍读时的带宽。默认 HIF 为 256 位、500MHz，上限 16 GB/s；
//           写每笔突发另有一条 WREQ 占用组帧器一拍，256 位 AXI 时上限为 16 × 16/17 = 15.06 GB/s。
//   怎么测：AW 与 W 各用一个进程连续发送 TP_N 笔；读同理。带宽按“第一个数据拍握手到最后一个数据拍握手”计算，
//           不含首笔请求的延迟与末笔的收尾，即稳态带宽，可直接与上限比较。
//           写在 HIF 写数据口统计（数据真正写入存储的速率）：AXI W 口前面有写缓冲，AXI 端快于 HIF 时（512、1024 位）
//           W 会先以超过上限的速率灌满缓冲，在 W 口统计会偏高。读在 AXI R 口统计，即主机实际收到数据的速率。
// ----------------------------------------------------------------------------
localparam int TP_N = 32, TP_LEN = 16;

// 统计一个方向的数据拍：第一拍与最后一拍握手的周期、总拍数（在后台运行，由调用者停止）
//   写：HIF 写数据口（hif_wdata_valid && !hif_wdata_stall），每拍 HIF_W/8 字节
//   读：AXI R 口（s_axi_rvalid && s_axi_rready），每拍 BYTES 字节
longint tp_first, tp_last;
int     tp_beats;
task automatic count_beats(bit is_write);
    tp_first = 0; tp_last = 0; tp_beats = 0;
    forever begin
        @(posedge clk);
        if (is_write ? (hif_wdata_valid && !hif_wdata_stall) : (s_axi_rvalid && s_axi_rready)) begin
            if (tp_beats == 0) tp_first = cycle;
            tp_last = cycle;
            tp_beats++;
        end
    end
endtask

// N 拍之间有 N-1 个间隔：带宽 = (N-1) 拍的字节数 ÷ 首拍到末拍的时间（每周期 2ns）
function automatic void print_bw(string dir, string port, int beat_bytes);
    real gbps = real'((tp_beats - 1) * beat_bytes) / real'((tp_last - tp_first) * 2);
    $display("     %s吞吐 %.2f GB/s（%s %0d 拍，首拍到末拍 %0d 周期）", dir, gbps, port, tp_beats, tp_last - tp_first);
endfunction

task automatic tc_throughput();
    txn_t t [TP_N];
    for (int i = 0; i < TP_N; i++) t[i] = make_txn(P(14) + (i % 4) * TP_LEN * BYTES, TP_LEN, FULL, 120 + i % 8);
    fork : wr_count
        count_beats(1);
    join_none
    fork
        for (int i = 0; i < TP_N; i++) send_aw(t[i]);
        for (int i = 0; i < TP_N; i++) send_w(t[i]);
    join
    for (int i = 0; i < TP_N; i++) wait_done(t[i]);
    disable wr_count;
    print_bw("写", "HIF 写数据口", HIF_W / 8);

    for (int i = 0; i < TP_N; i++) t[i] = make_txn(P(14) + (i % 4) * TP_LEN * BYTES, TP_LEN, FULL, 130 + i % 8);
    fork : rd_count
        count_beats(0);
    join_none
    for (int i = 0; i < TP_N; i++) send_ar(t[i]);
    for (int i = 0; i < TP_N; i++) wait_done(t[i]);
    disable rd_count;
    print_bw("读", "AXI R 口", BYTES);
endtask
