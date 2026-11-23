// ============================================================================
// SV 定向测试平台顶层
//
//   AXI 主机任务 ──AXI──► axi2flit_soc ──Flit──► 链路 FIFO ──► flit2hif_target ──HIF──► hif_mc_model
//   （axi_tasks.svh）  ◄──R/B──               ◄── 链路 FIFO ◄──                 ◄──      （HIF 控制器模型）
//
// 本测试平台全部用 SystemVerilog 编写，VCS 与 Verilator 均可运行（命令见 sv_tb/README.md）：
//   make -C sim sv-vcs  WIDTH=256 [TEST=tc_narrow]                     VCS
//   make -C sim -f Makefile.verilator run WIDTH=256 [TEST=tc_narrow]   Verilator
//
// 文件分工：
//   tb_top.sv      本文件：参数、时钟复位、待测设计连线、背压开关、错误监视、用例调度
//   axi_tasks.svh  AXI 主机：发送队列与驱动器、等待完成、记分板（参考存储、逐拍核对 R、B）
//   tests.svh      测试用例：每个用例一个 task，开头注释写明测什么、怎么测、波形里看什么
// ============================================================================
`timescale 1ns/1ps

module tb_top #(
    parameter int DATA_WIDTH  = 256,        // AXI 数据位宽：256 / 512 / 1024
    // 存储控制器（MC）配置：决定 HIF 数据宽度 = DRAM 位宽 × 频率比 × 2，一行 = BL × DRAM 位宽 / 8 字节
    parameter int HIF_DRAM_W  = 32,
    parameter int HIF_RATIO   = 4,
    parameter int HIF_BL      = 16,
    parameter int HIF_LATENCY = 8,          // 控制器模型的读延迟（拍）
    parameter int MEM_BYTES   = 64 * 1024,  // 控制器模型的存储容量（字节）
    parameter int LINK_DEPTH  = 8           // 两个方向链路 FIFO 的深度（帧）
);
    import aou_pkg::*;

    // ------------------------------------------------------------------
    // 常量
    // ------------------------------------------------------------------
    localparam int BYTES      = DATA_WIDTH / 8;               // AXI 一拍的字节数
    localparam int HIF_W      = HIF_DRAM_W * HIF_RATIO * 2;   // HIF 数据宽度
    localparam int LINE_WORDS = HIF_BL * HIF_DRAM_W / HIF_W;  // 一条 HIF 命令的数据拍数
    // 地址映射：桥的地址窗口为 [0, WINDOW)。
    //   [0, MEM_BYTES)          正常访问
    //   [MEM_BYTES, WINDOW)     在窗口内但超出控制器容量：控制器报 addr_err，桥回 DECERR
    //   [WINDOW, ...)           在窗口外：桥直接回 DECERR，不发 HIF 命令
    localparam longint WINDOW = 2 * longint'(MEM_BYTES);
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;

    // ------------------------------------------------------------------
    // 时钟与复位：时钟周期 2ns（500MHz）
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic link_up = 1'b0;
    always #1 clk = ~clk;

    longint cycle = 0;                       // 周期计数，用于测时长与吞吐
    always @(posedge clk) cycle <= cycle + 1;

    // ------------------------------------------------------------------
    // AXI 信号（由 axi_tasks.svh 中的任务驱动）
    // ------------------------------------------------------------------
    logic                  s_axi_awvalid, s_axi_awready;
    logic [63:0]           s_axi_awaddr;
    logic [9:0]            s_axi_awid;
    logic [7:0]            s_axi_awlen;
    logic [2:0]            s_axi_awsize, s_axi_awprot;
    logic [1:0]            s_axi_awburst;
    logic [3:0]            s_axi_awcache, s_axi_awqos;
    logic                  s_axi_awlock;
    logic [15:0]           s_axi_awuser;

    logic                  s_axi_wvalid, s_axi_wready, s_axi_wlast;
    logic [DATA_WIDTH-1:0] s_axi_wdata;
    logic [BYTES-1:0]      s_axi_wstrb;
    logic [15:0]           s_axi_wuser;

    logic                  s_axi_arvalid, s_axi_arready;
    logic [63:0]           s_axi_araddr;
    logic [9:0]            s_axi_arid;
    logic [7:0]            s_axi_arlen;
    logic [2:0]            s_axi_arsize, s_axi_arprot;
    logic [1:0]            s_axi_arburst;
    logic [3:0]            s_axi_arcache, s_axi_arqos;
    logic                  s_axi_arlock;
    logic [15:0]           s_axi_aruser;

    logic                  s_axi_bvalid, s_axi_bready;
    logic [9:0]            s_axi_bid;
    logic [1:0]            s_axi_bresp;
    logic [15:0]           s_axi_buser;

    logic                  s_axi_rvalid, s_axi_rready, s_axi_rlast;
    logic [DATA_WIDTH-1:0] s_axi_rdata;
    logic [9:0]            s_axi_rid;
    logic [1:0]            s_axi_rresp;
    logic [15:0]           s_axi_ruser;

    // ------------------------------------------------------------------
    // 背压与停顿开关：用例中直接赋值即可，例如 r_hold = 1 使主机暂停接收 R
    // ------------------------------------------------------------------
    logic r_hold    = 1'b0;   // 1：RREADY 保持为低
    logic b_hold    = 1'b0;   // 1：BREADY 保持为低
    logic rand_ready = 1'b0;  // 1：RREADY / BREADY 随机拉低（约 1/4 的周期）
    logic link_stop = 1'b0;   // 1：两个方向的链路暂停投递帧
    logic mc_block  = 1'b0;   // 1：控制器模型停止接收命令、停止返回数据
    logic mc_stress = 1'b0;   // 1：控制器模型乱序、交织返回读数据并随机 stall

    always @(posedge clk) begin
        s_axi_rready <= !r_hold && (!rand_ready || $urandom_range(0, 3) != 0);
        s_axi_bready <= !b_hold && (!rand_ready || $urandom_range(0, 3) != 0);
    end

    // ------------------------------------------------------------------
    // SoC 侧桥
    // ------------------------------------------------------------------
    logic  soc_tx_valid, soc_tx_ready, soc_rx_valid, soc_rx_ready;
    flit_t soc_tx_data, soc_rx_data;
    logic  soc_error;

    axi2flit_soc #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_soc (
        .flit_tx_valid(soc_tx_valid), .flit_tx_ready(soc_tx_ready), .flit_tx_data(soc_tx_data),
        .flit_rx_valid(soc_rx_valid), .flit_rx_ready(soc_rx_ready), .flit_rx_data(soc_rx_data),
        .protocol_error(soc_error),
        .*                                   // clk、rst_n、link_up 与全部 s_axi_* 按同名连接
    );

    // ------------------------------------------------------------------
    // 链路：两个方向各一个 FIFO，代替 UCIe 链路；link_stop 时暂停投递
    // ------------------------------------------------------------------
    logic  tgt_tx_valid, tgt_tx_ready, tgt_rx_valid, tgt_rx_ready;
    flit_t tgt_tx_data, tgt_rx_data;
    logic  fwd_full, fwd_empty, rev_full, rev_empty;

    aou_sync_fifo #(.WIDTH(FLIT_BITS), .DEPTH(LINK_DEPTH)) u_link_fwd (   // SoC → 存储
        .clk, .rst_n,
        .wr_en(soc_tx_valid && soc_tx_ready), .wr_data(soc_tx_data), .full(fwd_full),
        .rd_en(tgt_rx_valid && tgt_rx_ready), .rd_data(tgt_rx_data), .empty(fwd_empty), .level()
    );
    assign soc_tx_ready = !fwd_full;
    assign tgt_rx_valid = !fwd_empty && !link_stop;

    aou_sync_fifo #(.WIDTH(FLIT_BITS), .DEPTH(LINK_DEPTH)) u_link_rev (   // 存储 → SoC
        .clk, .rst_n,
        .wr_en(tgt_tx_valid && tgt_tx_ready), .wr_data(tgt_tx_data), .full(rev_full),
        .rd_en(soc_rx_valid && soc_rx_ready), .rd_data(soc_rx_data), .empty(rev_empty), .level()
    );
    assign tgt_tx_ready = !rev_full;
    assign soc_rx_valid = !rev_empty && !link_stop;

    // ------------------------------------------------------------------
    // 存储侧桥 + HIF 控制器模型
    // ------------------------------------------------------------------
    logic        hif_cmd_valid, hif_cmd_stall, hif_cmd_autopre;
    logic [1:0]  hif_cmd_type, hif_cmd_pri, hif_cmd_length, hif_wrecc_credit;
    logic [39:0] hif_cmd_addr;
    logic [52:0] hif_cmd_token, hif_rdata_token;
    logic [18:0] hif_cmd_wdata_ptr, hif_wdata_ptr;
    logic [10:0] hif_cmd_latency;
    logic        hif_lpr_credit, hif_hpr_credit, hif_wr_credit;
    logic        hif_rdata_valid, hif_rdata_end;
    logic        hif_rdata_uncorr_ecc_err, hif_rdata_addr_err, hif_rdata_crc_err;
    logic [HIF_W-1:0]   hif_rdata, hif_wdata;
    logic [HIF_W/8-1:0] hif_wdata_mask;
    logic        hif_wdata_valid, hif_wdata_end, hif_wdata_stall;
    logic        hif_wdata_ptr_valid, hif_wdata_ptr_addr_err;
    logic        hif_go2critical_lpr, hif_go2critical_hpr, hif_go2critical_wr;
    logic        target_error, mc_error;
    logic [31:0] mc_stat_ooo, mc_stat_interleave;

    flit2hif_target #(
        .DATA_WIDTH(DATA_WIDTH),
        .MEMC_DRAM_DATA_WIDTH(HIF_DRAM_W),
        .MEMC_FREQ_RATIO(HIF_RATIO),
        .MEMC_BURST_LENGTH(HIF_BL),
        .ADDR_BASE(64'h0),
        .MEM_BYTES(64'(WINDOW))
    ) u_target (
        .flit_tx_valid(tgt_tx_valid), .flit_tx_ready(tgt_tx_ready), .flit_tx_data(tgt_tx_data),
        .flit_rx_valid(tgt_rx_valid), .flit_rx_ready(tgt_rx_ready), .flit_rx_data(tgt_rx_data),
        .protocol_error(target_error),
        .*                                   // clk、rst_n、link_up 与全部 hif_* 按同名连接
    );

    hif_mc_model #(
        .CORE_DATA_WIDTH(HIF_W),
        .LINE_WORDS(LINE_WORDS),
        .WORD_BYTES(HIF_DRAM_W / 8),
        .MEM_BYTES(MEM_BYTES),
        .LATENCY(HIF_LATENCY)
    ) u_mc (
        .block(mc_block), .stress(mc_stress), .inject_bad_token(1'b0),
        .model_error(mc_error),
        .stat_rd(), .stat_wr(), .stat_ooo(mc_stat_ooo), .stat_interleave(mc_stat_interleave), .stat_stall(),
        .*                                   // clk、rst_n 与全部 hif_* 按同名连接
    );

    // ------------------------------------------------------------------
    // 主机任务、记分板与测试用例
    // ------------------------------------------------------------------
    `include "axi_tasks.svh"
    `include "tests.svh"

    // 任何时刻出现协议错误或 HIF 协议违规都记为失败（每种只报一次）
    bit soc_err_seen, tgt_err_seen, mc_err_seen;
    always @(posedge clk) begin
        if (soc_error && !soc_err_seen)    begin soc_err_seen = 1; fail("SoC 侧桥置起 protocol_error"); end
        if (target_error && !tgt_err_seen) begin tgt_err_seen = 1; fail("存储侧桥置起 protocol_error"); end
        if (mc_error && !mc_err_seen)      begin mc_err_seen = 1;  fail("HIF 控制器模型发现桥违反 HIF 约定"); end
    end

    // AXI 握手保持：桥输出的 RVALID / BVALID 拉高后，握手前不得撤销，所带的数据与 ID 不得改变
    logic                  r_wait, b_wait;
    logic [DATA_WIDTH-1:0] r_data_q;
    logic [9:0]            r_id_q, b_id_q;
    logic [1:0]            r_resp_q, b_resp_q;
    logic                  r_last_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            r_wait <= 0; b_wait <= 0;
        end else begin
            if (r_wait && (!s_axi_rvalid || s_axi_rdata !== r_data_q || s_axi_rid !== r_id_q ||
                           s_axi_rresp !== r_resp_q || s_axi_rlast !== r_last_q))
                fail("RVALID 拉高后未握手即撤销或改变了 R 通道内容");
            if (b_wait && (!s_axi_bvalid || s_axi_bid !== b_id_q || s_axi_bresp !== b_resp_q))
                fail("BVALID 拉高后未握手即撤销或改变了 B 通道内容");
            r_wait <= s_axi_rvalid && !s_axi_rready;
            b_wait <= s_axi_bvalid && !s_axi_bready;
            r_data_q <= s_axi_rdata; r_id_q <= s_axi_rid; r_resp_q <= s_axi_rresp; r_last_q <= s_axi_rlast;
            b_id_q <= s_axi_bid; b_resp_q <= s_axi_bresp;
        end
    end

    // HIF 命令保持：hif_cmd_valid 拉高且被 stall 时，下一拍必须仍为高、命令内容不变
    logic        cmd_wait;
    logic [1:0]  cmd_type_q;
    logic [39:0] cmd_addr_q;
    logic [52:0] cmd_token_q;
    logic [18:0] cmd_ptr_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_wait <= 0;
        end else begin
            if (cmd_wait && (!hif_cmd_valid || hif_cmd_type !== cmd_type_q || hif_cmd_addr !== cmd_addr_q ||
                             hif_cmd_token !== cmd_token_q || hif_cmd_wdata_ptr !== cmd_ptr_q))
                fail("hif_cmd_valid 被 stall 时撤销或改变了命令内容");
            cmd_wait <= hif_cmd_valid && hif_cmd_stall;
            cmd_type_q <= hif_cmd_type; cmd_addr_q <= hif_cmd_addr;
            cmd_token_q <= hif_cmd_token; cmd_ptr_q <= hif_cmd_wdata_ptr;
        end
    end

    // ------------------------------------------------------------------
    // 用例调度：+TEST=all（默认）依次运行全部用例；+TEST=用例名 只运行一个
    // ------------------------------------------------------------------
    initial begin
        string test = "all";
        int    seed = 1;
        void'($value$plusargs("TEST=%s", test));
        void'($value$plusargs("SEED=%d", seed));
        void'($urandom(seed));
        $timeformat(-9, 0, " ns", 0);          // %t 按 ns 显示
        $display("\n================ SV 测试平台  DATA_WIDTH=%0d  HIF %0d 位、每行 %0dB  TEST=%s ================",
                 DATA_WIDTH, HIF_W, LINE_WORDS * HIF_W / 8, test);
        reset_dut();
        if (test == "all") begin
            foreach (ALL_TESTS[i]) run_test(ALL_TESTS[i]);
        end else begin
            run_test(test);
        end
        report();
        $finish;
    end

`ifdef FSDB                                  // VCS：make sv-vcs 定义，生成 FSDB 供 Verdi 查看
    initial begin
        $fsdbDumpfile(`FSDB);
        $fsdbDumpvars(0, tb_top, "+all");
    end
`endif
`ifdef VCD                                   // 用 Verilator 且 WAVE=1 时由 Makefile.verilator 定义，生成 VCD
    initial begin
        string vcd = "tb_top.vcd";
        void'($value$plusargs("VCD=%s", vcd));
        $dumpfile(vcd);
        $dumpvars(0, tb_top);
    end
`endif
endmodule
