"""生成《AXI2FLIT 转接桥 RTL 设计文档》docx。

用法：python3 build_docx.py <图片目录> <规范截图目录> <输出 docx>
波形相关的时刻取自 <图片目录>/wave_marks.json（figs_wave.py 由 VCD 生成），
回归统计取自同目录的 results.json（collect_results.py 由仿真日志生成），保证图文与实测一致。
"""
import json
import os
import sys
from docxkit import C, h1, h1n, h2, h3, p, li, code, fig, tab, render

FIG_DIR, SPEC_DIR, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
M = json.load(open(f"{FIG_DIR}/wave_marks.json"))
R = json.load(open(f"{FIG_DIR}/results.json"))
FL_R, FL_W = M["fl"]["read"], M["fl"]["write"]
SR, SW = FL_R["seg"], FL_W["seg"]
ns = lambda v: f"{v:g}ns"
P_NOTE = "方向 I 为输入，O 为输出。"
IO_W = [4.6, 1.4, 2.8, 6.7]

# =====================================================================
h1("概述")
h2("设计目标")
p("AXI2FLIT 转接桥用于 Chiplet 系统中 SoC 与堆叠存储之间的协议转换。SoC 通过 AXI4 访问存储，Die 间采用 UCIe 互联，"
  "链路上传输 AXI over UCIe（AoU，v0.8）协议定义的流式 Flit。转接桥由两个顶层组成：")
li("（1）axi2flit_soc（SoC 侧）：AXI4 从机。把 AXI 突发编码成 AoU 消息装入 Flit，把收到的读数据、写响应还原为 R、B。")
li("（2）flit2hif_target（存储侧）：HIF 主机。把 Flit 中的读写请求转换为存储控制器（MC）的 HIF 命令，"
   "把 HIF 读数据和写完成转换为 AoU 响应发回 SoC 侧。")
p("两端共用同一套组帧、解帧、接收缓冲和 credit 流控逻辑（aou_transport）。主要规格见{表:spec}。")
tab("spec", "主要规格", ["项目", "规格"], [
    ["SoC 侧接口", "AXI4 从机；数据 256 / 512 / 1024 位可配；ID、地址、USER 宽度可配（不超过 10 / 64 / 16 位）"],
    ["突发", "INCR，1～256 拍，地址按 SIZE 对齐、不跨 4KB；支持窄访问与任意 WSTRB"],
    ["链路侧接口", "250B 协议层包（PLP），2000 位 valid/ready，对应 UCIe FDI，两端相同"],
    ["存储侧接口", "MC 的 HIF 主机：读写共用命令口，读数据按 token 返回，写数据由控制器按指针拉取，"
                   "lpr / hpr / wr 三类 credit；控制器数据宽度、burst 长度、各字段宽度可配"],
    ["资源平面 RP", "默认 1 个（一个 AXI 端口对应一个 MC）；参数可设为 1～4，各 RP 独立排队与 credit，供后续扩展"],
    ["时钟", "单时钟域，桥与 D2D Adapter、存储控制器同频"],
    ["桥接延迟", f"空载、2ns 时钟：SoC 侧发送 + 接收 {R['lat']['sa_soc_tx'] + R['lat']['sa_soc_rx']}ns，"
                 f"存储侧请求 + 返回 {R['lat']['sa_req'] + R['lat']['sa_ret']}ns，见 8.1 节"],
    ["带宽", "SoC 侧与链路侧每周期一条消息（1024 位时 64GB/s @ 500MHz）；存储侧受 HIF 数据口限制"
             "（CORE_DATA_WIDTH × 频率，256 位时 16GB/s），见 8.2 节"],
], [3.0, 12.5])

h2("系统位置")
fig("system", "f_system.png", "转接桥在系统中的位置（粗框为本设计）")
p("如{图:system}，axi2flit_soc 与 flit2hif_target 分别经所在 Die 的 D2D Adapter 接入 UCIe 链路，桥与 Adapter 之间在 FDI "
  "上交换 250B 的 PLP，Flit 头、CRC 与链路重传由 Adapter 负责。flit2hif_target 之后是存储控制器，DRAM 调度、刷新与 DFI "
  "时序由控制器完成。链路按 8 通道、24GT/s、PAM4 计算，单向原始带宽 48GB/s，扣除 Flit 头、CRC 与协议头后消息区 45GB/s。")

h2("使用约束")
li("（1）只支持 INCR 突发；FIXED、WRAP 判为非法。地址按 2^AxSIZE 对齐，每拍不超过总线宽度，突发不跨 4KB。")
li("（2）独占访问不实现：AxLOCK 透传到链路，存储侧按普通访问处理并返回 OKAY（AXI 规定不支持独占的从机返回 OKAY）。")
li("（3）单时钟域。桥与 D2D Adapter、存储控制器时钟不同时，需在外部加异步 FIFO。")
li("（4）rst_n 低有效异步复位，两端须协同复位。link_up 为链路就绪，拉低时暂停协议处理，不清除内部状态。")
li("（5）存储侧访问一个地址窗口 [ADDR_BASE, ADDR_BASE + MEM_BYTES)，窗口外的请求由桥直接返回 DECERR。")

h2("术语")
tab("terms", "术语", ["术语", "含义"], [
    ["Flit / 帧", "UCIe 256B Flit；本文的“帧”指其中协议层使用的 250B（PLP）"],
    ["PH", "协议头，PLP 前 10 字节，含消息起点位图与 credit 授信"],
    ["粒度", "5 字节，AoU 消息长度与链路 credit 的单位；一帧消息区 48 个粒度"],
    ["消息", "WREQ、RREQ、WDATA、RDATA、WRESP 等 AoU 协议对象，一条最多跨两帧"],
    ["RP", "资源平面，由 AxQOS mod RP_COUNT 选取"],
    ["行", "一条 HIF 命令访问的数据块，即一个 DRAM burst：BL × DRAM 数据宽度 / 8 字节，按行对齐"],
    ["HIF 字", "HIF 数据口一拍的数据，CORE_DATA_WIDTH 位；一行为 LINE_WORDS 个字"],
    ["链路 credit / HIF credit", "前者由对端桥授予，保护对端接收缓冲；后者由存储控制器授予，保护控制器命令队列"],
], [3.4, 12.1])

# =====================================================================
h1("接口")
fig("io", "f_io.png", "两个顶层的接口分组")
p("{图:io}是两个顶层的接口。每个顶层有三组信号：应用侧（AXI 从机或 HIF 主机）、链路侧（2000 位 PLP 收发）、"
  "公共信号（clk、rst_n、link_up、protocol_error）。所有握手在 clk 上升沿采样。")

h2("AXI4 从机接口（axi2flit_soc）")
tab("axi_io", "AXI4 从机接口", ["信号", "方向", "位宽", "说明"], [
    ["s_axi_awvalid / awready", "I / O", "1", "写地址握手"],
    ["s_axi_awaddr", "I", "AXI_ADDR_W", "起始字节地址，按 SIZE 对齐"],
    ["s_axi_awid", "I", "AXI_ID_W", "事务 ID"],
    ["s_axi_awlen / awsize / awburst", "I", "8 / 3 / 2", "拍数减 1、每拍字节数 log2、突发类型（只接受 INCR）"],
    ["s_axi_awprot / awcache / awlock", "I", "3 / 4 / 1", "透传到存储侧"],
    ["s_axi_awqos", "I", "4", "选择 RP（QOS mod RP_COUNT）；存储侧读按 QOS 选择 HPR"],
    ["s_axi_awuser", "I", "AXI_USER_W", "透传"],
    ["s_axi_wvalid / wready", "I / O", "1", "写数据握手"],
    ["s_axi_wdata / wstrb", "I", "DATA_WIDTH / DATA_WIDTH/8", "写数据与字节选通"],
    ["s_axi_wlast / wuser", "I", "1 / AXI_USER_W", "末拍（须与 AWLEN 一致）/ 透传"],
    ["s_axi_ar*", "I / O", "同 AW", "读地址通道，与写地址一一对应"],
    ["s_axi_bvalid / bready", "O / I", "1", "写响应握手"],
    ["s_axi_bid / bresp / buser", "O", "AXI_ID_W / 2 / AXI_USER_W", "写响应"],
    ["s_axi_rvalid / rready", "O / I", "1", "读数据握手"],
    ["s_axi_rdata / rid / rresp / rlast / ruser", "O", "DATA_WIDTH / … ", "读数据；窄传输复制到整条总线"],
], [4.6, 1.4, 1.8, 7.7], note=P_NOTE)
p("请求方向：AW、W、AR 各自独立握手。AXI 允许 W 早于、同拍或晚于对应的 AW，从机可以等 AW 到达后再接受 W；本桥即如此："
  "AW 被接受的下一拍 WREADY 才可能为高，W 早到时 WREADY 保持为低。只有每笔突发的第一拍多等 1 拍，"
  "写路由 FIFO 可存 WR_ROUTE_DEPTH 笔（默认 8），后续突发的 AW 可以提前进入，连续写突发之间不会出现空拍。"
  "响应方向：同一 ID 的响应保持发出顺序；VALID 拉高后在握手完成前输出不变。BRESP / RRESP 取值："
  "OKAY；地址落在存储窗口外或控制器报地址错误时为 DECERR；读数据有不可纠正 ECC 错误、或写选通超出本拍字节范围时为 SLVERR。")

h2("链路接口（两端相同）")
tab("flit_io", "链路接口", ["信号", "方向", "位宽", "说明"], [
    ["flit_tx_valid / flit_tx_ready", "O / I", "1", "发送一帧；ready 为 Adapter 可接收（对应 FDI pl_trdy）"],
    ["flit_tx_data", "O", "2000", "发送 PLP：[1999:1920] 为 PH B0～B9，[1919:0] 为 48 个粒度，G0 在高位"],
    ["flit_rx_valid / flit_rx_ready", "I / O", "1", "接收一帧；ready 为桥可接收"],
    ["flit_rx_data", "I", "2000", "接收 PLP，格式同上"],
    ["link_up", "I", "1", "链路就绪；为低时不收发帧、不接收 AXI 请求、不发 HIF 命令"],
    ["protocol_error", "O", "1", "检测到协议错误，保持到复位"],
], IO_W, note=P_NOTE)
p("Flit 头、CRC 的插入与校验，以及 PH 字节与粒度在 256B Flit 中的交错排列，都由 D2D Adapter 完成，桥只处理 PLP。"
  "桥在没有业务时也会发只含 PH 的帧，用于归还 credit，因此 link_up 之后链路上始终有低速率的 credit 帧。")

h2("HIF 主机接口（flit2hif_target）")
p("HIF（Host Interface）是存储控制器 MC 面向主机的接口，桥在这里是主机。HIF 与具体存储类型无关，后端可以是 DDR、"
  "HBM 或其他堆叠存储的控制器；桥只依赖下面四组信号，各宽度与 MC 的同名配置参数一致（见第 7 章）。")
li("（1）命令：hif_cmd_*。读、写共用一个命令口，一条命令访问一“行”（一个存储 burst，见 5.2.1 节）。"
   "MC 用 hif_cmd_stall 反压。")
li("（2）读数据：hif_rdata_*。MC 带着发命令时给的 token 返回该行的数据，一行分 LINE_WORDS 拍，最后一拍 end = 1。")
li("（3）写数据：hif_wdata_*。桥发写命令时附带一个写指针（槽号），MC 准备好后通过 hif_wdata_ptr 把指针送回，"
   "桥再送出这一行的数据与字节掩码，MC 用 hif_wdata_stall 反压。")
li("（4）credit：hif_lpr_credit / hif_hpr_credit / hif_wr_credit。MC 内部有三个命令队列：低优先级读（LPR）、"
   "高优先级读（HPR）、写（WR），每个 credit 代表队列中的一个空位。桥为三类各维护一个计数器，初值等于队列深度，"
   "发命令时减 1，MC 把命令从队列发往存储后用脉冲归还 1 个；计数为 0 时桥不再发该类命令，保证 MC 的队列不会溢出。")
fig("hif_seq", "f_hif_seq.png", "桥与 MC 读、写一行的交互顺序（实线为数据与命令，虚线为流控）", width=15.0)
tab("hif_io", "HIF 接口", ["信号", "方向", "位宽", "说明"], [
    ["hif_cmd_valid", "O", "1", "命令有效"],
    ["hif_cmd_stall", "I", "1", "控制器反压；valid && !stall 的上升沿命令被接收"],
    ["hif_cmd_type", "O", "2", "00 写，01 读，10 RMW（ECC_RMW = 1 时用于部分写）"],
    ["hif_cmd_addr", "O", "CORE_ADDR_WIDTH", "字地址（单位 MEMC_DRAM_DATA_WIDTH/8 字节），按行对齐"],
    ["hif_cmd_pri", "O", "HIF_PRI_BITS", "读优先级：LPR 为 0，HPR 为 1（VPRW_EN 时为 2'b10）；写为 0"],
    ["hif_cmd_token", "O", "CORE_TAG_WIDTH", "读命令的 token，等于读 ROB 槽号，读数据带回"],
    ["hif_cmd_length", "O", "CMD_LEN_BITS", "恒为 0，读整行"],
    ["hif_cmd_wdata_ptr", "O", "WDATA_PTR_BITS", "写命令的数据指针，等于写缓冲槽号"],
    ["hif_cmd_autopre / hif_cmd_latency", "O", "1 / RD_LATENCY_BITS", "恒为 0"],
    ["hif_lpr_credit / hif_hpr_credit", "I", "HIF_CREDIT_BITS", "低 / 高优先级读 credit 归还脉冲，每位 1 个"],
    ["hif_wr_credit", "I", "1", "写 credit 归还脉冲"],
    ["hif_wrecc_credit", "I", "2", "Inline ECC 写 credit，不使用"],
    ["hif_rdata_valid / hif_rdata_end", "I", "1", "读数据有效 / 该命令的最后一拍"],
    ["hif_rdata_token", "I", "CORE_TAG_WIDTH", "读数据所属命令的 token"],
    ["hif_rdata", "I", "CORE_DATA_WIDTH", "读数据，一拍一个 HIF 字"],
    ["hif_rdata_addr_err / uncorr_ecc_err / crc_err", "I", "1", "读错误，分别映射为 DECERR / SLVERR / SLVERR"],
    ["hif_wdata_ptr_valid / hif_wdata_ptr", "I", "1 / WDATA_PTR_BITS", "控制器回送写指针，表示可以送该命令的数据"],
    ["hif_wdata_ptr_addr_err", "I", "1", "该写命令地址无效，映射为 DECERR"],
    ["hif_wdata_valid / hif_wdata_stall", "O / I", "1", "写数据握手：valid && !stall 时被接收"],
    ["hif_wdata / hif_wdata_mask / hif_wdata_end", "O", "CORE_DATA_WIDTH / CORE_MASK_WIDTH / 1",
     "写数据、字节掩码（1 表示写入）、最后一拍"],
    ["hif_go2critical_lpr / hpr / wr", "O", "1", "恒为 0，含义见下文"],
], IO_W, note=P_NOTE)
p("hif_go2critical_lpr / hpr / wr 是控制器的紧急调度请求：置 1 表示主机侧对应队列（低 / 高优先级读、写）有请求等待过久，"
  "要求控制器优先服务该队列，例如从写切换到读。它通常由带 QoS 超时计数的多端口主机驱动。本桥只有一个请求来源，"
  "命令按到达顺序发出，不做超时计数，读写之间的切换与防饥饿交给控制器自身的调度策略，因此三个信号接 0。"
  "hif_cmd_autopre（命令后自动预充电）、hif_cmd_latency（读延迟提示）、hif_cmd_length（部分行访问）同样使用控制器默认行为，接 0。")
p("桥对 HIF 的约定：读命令占用 1 个 LPR 或 HPR credit（AxQOS ≥ HPR_QOS 的读走 HPR），写命令占用 1 个 WR credit，"
  "RMW 同时占用 LPR 和 WR；被 stall 时命令内容保持不变。不同 token 的读数据可以乱序、也可以交织，同一 token 的各拍按地址"
  "顺序。写数据按指针回送的顺序发出。{图:w_fl_read}、{图:w_fl_write}（9.4 节）是全链路仿真中的实际时序。")

# =====================================================================
h1("协议格式")
h2("Flit 与协议层包")
fig("spec_flit", "spec_flit.png", "256B Flit 中的协议层包布局", spec=True)
p("AoU 使用 UCIe 256B 延迟优化 Flit，如{图:spec_flit}。FH 与 CRC 由 D2D Adapter 处理；其余 250 字节构成 PLP："
  "10 字节协议头 PH B0～B9 和 48 个 5 字节粒度 G0～G47。消息内部高位在前，消息第 0 字节位于消息向量最高字节；"
  "AXI 数据 data[7:0] 是最低地址字节，编码时高字节 lane 在前，解码做反变换。")
h2("协议头")
fig("spec_ph", "spec_ph.png", "协议头格式", spec=True)
p("MsgStart[47:0] 为消息起点位图，第 i 位为 1 表示第 i 个粒度开始一条新消息，跨帧续片不置位。MsgCredit[15:0] 归还接收容量，"
  "编码见{表:credit}。保留位必须为 0。")
tab("credit", "MsgCredit 编码", ["位段", "含义"], [
    ["[15:14]", "本次授信所属的 RP"],
    ["[13:12]", "WRESP，2 位编码：0、1、4、8 个粒度"],
    ["[11:9] / [8:6] / [5:3] / [2:0]", "RDATA / WDATA / RREQ / WREQ，3 位编码：0、1、4、8、16、32、64、128 个粒度"],
], [4.6, 10.9])
p("每帧 PH 为一个 RP 授信，发送端取不超过待归还量的最大编码，余量在后续帧继续归还。规范另有 Misc 类型的 CrdtGrant "
  "消息，可在一条消息中为所有 RP 授信。本设计只用 PH 授信，从不发送 CrdtGrant：单 RP 时每帧 PH 都能为该 RP 授信，"
  "一帧最多归还 128 个粒度，已足够；接收端仍按规范解析 CrdtGrant 并更新 credit，以便与会发送它的对端互通。")
h2("消息类型与长度")
tab("msgs", "消息类型与长度（粒度）", ["类型码", "消息", "方向", "256 位", "512 位", "1024 位"], [
    ["1 / 2", "WREQ / RREQ 读写请求", "SoC→存储", "3", "3", "3"],
    ["3", "WDATA 写数据（含 WSTRB）", "SoC→存储", "8", "15", "30"],
    ["6", "WDATAFULL 全选通写数据", "SoC→存储", "7", "14", "27"],
    ["4", "RDATA 读数据", "存储→SoC", "8", "14", "27"],
    ["5", "WRESP 写响应", "存储→SoC", "1", "1", "1"],
    ["0", "Misc（CrdtGrant）", "只接收", "2", "2", "2"],
], [1.5, 4.8, 2.2, 2.3, 2.3, 2.4], note="一个粒度 5 字节；256 / 512 / 1024 位对应 DLENGTH 编码 0 / 1 / 2。")
p("数据消息宽度由每拍传输大小决定（规范 5.7 节）：每拍不超过 32B 用 256 位消息，64B 用 512 位，128B 用 1024 位，"
  "消息只携带本拍所在的字节通道组。一拍的选通全为 1 时自动使用省略 WSTRB 的 WDATAFULL。最长消息 30 个粒度，"
  "小于一帧的 48 个粒度，任何消息最多跨两帧。")
fig("spec_wreq", "spec_wreq.png", "WriteReq 字段（ReadReq 相同）", spec=True)
fig("spec_wdata", "spec_wdata256.png", "WriteData 字段，256 位（WDATAFULL 去掉末尾 WSTRB 粒度）", spec=True)
fig("spec_rdata", "spec_rdata256.png", "ReadData 字段，256 位", spec=True)
fig("spec_wresp", "spec_wresp.png", "WriteResp 字段", spec=True)
p("{图:spec_wreq}～{图:spec_wresp}是四类消息的字段，512、1024 位数据消息只是数据与 WSTRB 字段按比例加长。"
  "FLEX[15:0] 承载 AXI USER：请求放 AxUSER，写数据放 WUSER，读数据放 RUSER，写响应放 BUSER。请求消息没有 BURST 字段，"
  "接收端按 INCR 处理；写数据不带 WLAST，存储侧按 WREQ 的 LEN 计数。")
h2("打包规则")
p("一帧内消息按粒度紧密排列，不同 RP、不同类型可混装；帧未填满也可发出。消息放不下时剩余部分接在下一帧开头，"
  "下一帧不为续片置 MsgStart。{图:packing}是 1024 位连续读返回的情形，每条 RDATA 27 个粒度。")
fig("packing", "f_packing.png", "跨帧消息示意（黑色三角为 MsgStart 置位处，数字为粒度数）", width=15.0)

# =====================================================================
h1("总体设计")
h2("文件与模块层次")
fig("hierarchy", "f_hierarchy.png", "模块例化层次（灰底为缓冲实例，×RP 表示按 RP 数重复）", width=14.5)
tab("modules", "RTL 文件与模块", ["文件 / 模块", "所属", "功能"], [
    ["axi2flit_soc", "SoC 侧顶层", "AXI 请求检查与编码、写数据路由、响应仲裁、同 ID 保序"],
    ["flit2hif_target", "存储侧顶层", "请求按行切成 HIF 命令；读 ROB、写缓冲、命令仲裁、HIF credit；生成 RDATA / WRESP"],
    ["aou_target_core", "存储侧", "存储侧公共部分：aou_transport 与读数据、写响应发送队列"],
    ["aou_transport", "两端共用", "组帧、解帧、消息检查与分类、接收缓冲、链路 credit 计数"],
    ["aou_flit_tx", "两端共用", "组帧器：消息仲裁、跨帧续片、PH 授信编码"],
    ["aou_flit_rx", "两端共用", "解帧器：帧缓冲、起点扫描、跨帧拼接"],
    ["aou_chunk_fifo", "两端共用", "数据消息接收缓冲：按 8 粒度分块、多 bank 交错"],
    ["aou_sync_fifo", "两端共用", "同步 FIFO，深度任意，FWFT / 标准两种读出"],
    ["aou_pkg", "包", "协议常量、消息结构体、编解码函数，各模块 import"],
], [3.3, 2.3, 9.9])
p("编译顺序：aou_pkg → aou_sync_fifo、aou_chunk_fifo、aou_flit_tx、aou_flit_rx → aou_transport → aou_target_core → "
  "axi2flit_soc、flit2hif_target。协议规定的线上格式（帧、粒度、字段位置、编码）是 aou_pkg 中的常量，两端必须一致；"
  "其余均为模块参数，见第 7 章。")

h2("数据通路")
p("写：AW 握手生成一条 WREQ，每个 W beat 生成一条 WDATA，进入所选 RP 的发送队列，由组帧器装帧发出。存储侧解帧后，"
  "写组装逻辑把一笔突发的数据按行合并，每行写满时发一条 HIF 写命令；控制器回送写指针后桥送出该行数据。"
  "一笔突发的所有行都交给控制器后，桥生成一条 WRESP 发回 SoC 侧，成为 B 响应。")
p("读：一条 RREQ 在存储侧按行展开为若干条 HIF 读命令。控制器按 token 返回各行数据，读 ROB 收齐后按 AXI 拍切分，"
  "每拍生成一条 RDATA，SoC 侧收到后逐条成为 R beat。")
p("两个方向之间（两端桥之间）由链路 credit 流控，存储侧与控制器之间由 HIF credit 与 stall 流控，片内各级由 ready/valid "
  "反压，任何一级都不会溢出，见第 6 章。")
h2("时钟、复位与使能")
p("所有模块在 clk 上升沿工作，rst_n 低有效异步复位。复位清除指针、计数器、在途表与错误标志，存储阵列内容不复位；"
  "链路 credit 计数清零，HIF credit 计数恢复为初值。link_up 拉高后，组帧器用只含 PH 的帧把接收容量通告给对端。"
  "检测到协议错误后错误标志保持、模块停止处理，只能由两端协同复位恢复。")

# =====================================================================
h1("模块设计")
h2("axi2flit_soc")
fig("soc", "f_soc.png", "axi2flit_soc 微架构（实线为数据，蓝色虚线为控制，层叠框表示每个 RP 一份）")
p("请求检查：AW、AR 检查 SIZE 不超过总线宽度、地址对齐、不跨 4KB、BURST 为 INCR，不满足即置 protocol_error。"
  "通过后由 make_req 编码成 15B 请求消息，写入由 QOS 选定的 RP 发送队列（每类 TX_DEPTH 项，只存该类消息所需位数）。"
  "发送队列只做组帧器前的解耦：组帧器每拍取一条，深度 2 即可满速；组帧器等 credit 或等链路时队列很快填满，"
  "直接拉低 AWREADY / WREADY / ARREADY 反压主机。AXI 侧的 READY 只看寄存器状态（发送队列、写路由 FIFO、在途表是否已满）"
  "和本拍输入，不经过组帧器的选择逻辑，接主机时时序独立。")
p("写数据路由：W 通道不带 ID，AW 握手时把 {RP, AWLEN, AWSIZE, 起始地址低位} 写入写路由 FIFO，W beat 按队首确定所属突发。"
  "w_index 对突发内 beat 计数，WLAST 与“w_index == AWLEN”不一致即报错；本拍字节通道由起始地址与 w_index × 2^SIZE 算出，"
  "make_wdata 按传输大小只取本组字节。")
p("响应：R、B 各有一个 RP 轮询选择器。VALID 拉高而 READY 为低时锁定当前 RP（r_locked / b_locked），等待期间输出不变。"
  "读数据取出后复制到整条总线。")
p("在途表与同 ID 保序：读、写各有一张在途表（RD_OUTSTANDING / WR_OUTSTANDING 项），每笔已握手、未完成的事务占一项"
  "{有效, ID, RP}；AR / AW 握手时占用最低空闲项，RLAST / B 握手时释放一项同 ID、同 RP 的表项。表满时拉低 ARREADY / AWREADY，"
  "所以表项数就是该方向的最大在途事务数。同一 ID 还有在途事务时，新请求必须落在同一 RP，否则背压，保证同 ID 响应不因分属"
  "不同 RP 而乱序。收到的 R / B 在表中找不到同 ID、同 RP 的表项时不交给主机，置 protocol_error。"
  "表按在途笔数而不是按 ID 取值开设，面积与 AXI ID 位宽基本无关。")

h2("flit2hif_target")
fig("hif_target", "f_hif_target.png", "flit2hif_target 微架构（实线为数据，蓝色虚线为控制）")
p("{图:hif_target}中，左侧 aou_target_core 提供按 RP 排队的 WREQ、RREQ、WDATA 接收缓冲和 RDATA、WRESP 发送队列；"
  "其余为 HIF 后端，分读发起、读 ROB 与退休、写组装、写缓冲与数据发送、写上下文、命令仲裁与 credit 几部分。")
h3("行与地址")
code("LINE_BYTES  = MEMC_BURST_LENGTH × MEMC_DRAM_DATA_WIDTH / 8      一条命令的字节数（默认 16 × 32 / 8 = 64）\n"
     "LINE_WORDS  = LINE_BYTES / (CORE_DATA_WIDTH / 8)                一条命令的数据拍数（默认 2）\n"
     "hif_cmd_addr = (AXI 地址 − ADDR_BASE) >> log2(MEMC_DRAM_DATA_WIDTH / 8)   按行对齐的字地址")
p("为什么要按行：MC 一条命令访问的是一个存储 burst（例如 32 位 DRAM、BL16 时为 64 字节），地址按 burst 对齐；"
  "而 AXI 一拍的字节数由总线宽度与 AxSIZE 决定，可能大于、等于或小于一个 burst。桥因此以“行”（= 一个 burst）为单位"
  "重新组织数据，{图:lines}是三种典型情况。")
fig("lines", "f_lines.png", "AXI 突发按行切分为 HIF 命令（一行 64B）", width=15.5)
p("一笔 AXI 突发是一段连续字节 [A, A + (LEN+1) × 2^SIZE)，桥按行切分：覆盖的每一行发一条命令。一拍不小于一行时，"
  "一拍对应 2^SIZE / LINE_BYTES 行（1024 位、64B 行时为 2 行）；一拍小于一行时，相邻若干拍共用一行（256 位、64B 行时"
  "2 拍一行），命令数与 AXI 位宽无关，只由突发字节数决定。突发不跨 4KB、窗口按 4KB 对齐，所以一笔突发要么整体在窗口内，"
  "要么整体在窗口外；窗口外的突发不发命令，直接返回 DECERR。")
h3("读通路")
p("读发起：在 RP 之间轮询选取一个 RREQ，出队并把突发信息记入读上下文队列（RD_BURSTS 项），然后逐行发读命令，"
  "每拍最多一条。发命令需要读 ROB 有空位，且有 LPR credit（AxQOS ≥ HPR_QOS 时为 HPR credit）；token 取 ROB 尾指针。"
  "一笔突发的行全部发出后才处理下一笔。")
p("读 ROB：RD_LINES 行的环形队列，按发出顺序分配。HIF 读数据按 token 写入对应行的第 k 拍（k 为该行已收拍数），"
  "因此不同 token 的数据可以任意乱序和交织；end = 1 的一拍到达后该行完成。各拍的错误标志并入该行状态。")
p("读退休：队首突发逐拍输出。一拍需要的行（ROB 头部 1～LPB 行）都完成后，按字节地址把行数据拼到总线上，"
  "本拍字节范围以外清零，生成一条 RDATA 写入该 RP 的发送队列，每拍一条。行内最后一拍退休后该行释放。"
  "RRESP 取所涉及行中最严重的错误，出错的拍不返回数据。")
h3("写通路")
p("写组装：在 RP 之间轮询选取一个 WREQ，出队后逐拍消耗该 RP 的 WDATA。每拍按行切成部分：大于一行的拍逐行发命令；"
  "小于一行的拍先并入行合并寄存器（数据按选通覆盖、掩码按位或），当本拍写到行尾或是突发末拍时发命令。"
  "选通落在本拍字节范围之外的拍不写入（掩码清零），该突发的 B 为 SLVERR。")
p("写缓冲：WR_LINES 行，空闲槽号存在空闲队列中。发写命令时从队首取一个槽，写入整行数据与掩码，槽号作为 wdata_ptr。"
  "发命令需要空闲槽和 WR credit；ECC_RMW = 1 且掩码不全为 1 时改发 RMW，另需 LPR credit。")
p("写数据发送：控制器回送的指针依次进入回送队列。发送逻辑从队首槽逐拍读出 LINE_WORDS 个字及掩码，"
  "被 stall 时保持；最后一拍被接收后该槽回到空闲队列。")
p("写上下文：每笔写突发一项（WR_BURSTS 项），记录未交出数据的行数与状态。发写命令时加一，该行数据送完时减一；"
  "突发组装完成且计数为 0 时生成 WRESP。状态取最严重者：选通越界为 SLVERR，回送指针带 addr_err 为 DECERR。")
h3("命令仲裁与 credit")
p("读写共用一个命令口。两者都有命令时轮流发出；被 stall 时锁定本次选择，命令内容不变。三个 credit 计数器复位为 "
  "LPR_CREDITS / HPR_CREDITS / WR_CREDITS，每拍更新：")
code("credit_next = credit + 本拍归还脉冲数（各位之和） − 本拍被接收的命令占用数")
p("归还使计数超过初值时说明控制器行为与配置不符，置 protocol_error。HIF_CREDIT_BITS = 2（Inline ECC）时两位同时为 1 "
  "计 2 个。")
h3("错误处理")
tab("hif_err", "存储侧错误映射", ["来源", "AXI 响应", "说明"], [
    ["地址在窗口外", "DECERR", "不发命令"],
    ["hif_rdata_addr_err", "DECERR", "该拍数据清零"],
    ["hif_rdata_uncorr_ecc_err / crc_err", "SLVERR", "该拍数据清零"],
    ["hif_wdata_ptr_addr_err", "DECERR", "该行数据仍按约定送出"],
    ["写选通超出本拍字节范围", "SLVERR", "该拍不写入"],
    ["未分配 / 已完成的 token、end 位置不符、非法写指针、credit 归还超过初值", "—", "置 protocol_error"],
], [5.4, 2.0, 8.1])

h2("aou_target_core")
p("存储侧公共部分：例化 aou_transport（只启用 WREQ、RREQ、WDATA 三类接收），以及每个 RP 的 RDATA、WRESP 发送队列"
  "（RESPONSE_DEPTH 项，默认 2，满时反压读退休与写响应生成；reply_ready 只看队列是否已满，组帧器的选择逻辑不串入后端）。对后端提供 rx_*（接收消息，ready/valid）与 reply_*（发送消息）两组按 [RP][类型] 组织的接口，"
  "后端的 local_error 置位时停止收发。")

h2("aou_transport")
fig("transport", "f_transport.png", "aou_transport 微架构（编号对应 credit 计数的更新来源）")
p("接收：解帧器输出的消息先检查 RP、类型、长度、DLENGTH、保留位与请求合法性，再检查长度不超过已公布的 credit；"
  "合法消息写入 [RP][类型] 接收缓冲，CrdtGrant 只更新 credit。请求与写响应用 aou_sync_fifo（只存所需位数），"
  "数据消息用 aou_chunk_fifo 分块存放。参数 RX_DEPTH0～4 依次为五类消息的接收深度，0 表示不接收。")
p("链路 credit 按 RP、消息类型各一组，见 6.1 节：")
code("available_next = min(available + 收到的授信 − 本拍发送消耗, 4095)    （①、②）\n"
     "promised_next  = promised + 本拍 PH 授出 − 本拍收到的消息           （②、③）\n"
     "pending        = 可公布容量(空闲存储) − promised                    （④，组合）")

h2("aou_flit_tx")
fig("tx", "f_tx.png", "aou_flit_tx 微架构")
p("组帧策略：每拍最多接受一条新消息。轮询仲裁在 RP×5 个候选中选第一个 valid 且 available 足够的消息，"
  "上一次选中的候选在下一拍排到最后，整条消息的 credit 一次扣除；"
  "仲裁只看寄存器中的 available，本拍收到的授信下一拍生效。在建帧由 payload、starts、used 三个寄存器组成，"
  "放不下的部分存入 spill，下一帧先写续片、同拍接着追加新消息。帧满、帧非空但本拍没有追加、或帧空但有待归还 credit 时提交，"
  "提交时轮流选一个有待归还量的 RP 写入 PH。输出寄存器被背压时在建帧仍可装填。")
p("WREQ 与 WDATA 是两个独立队列，组帧器不要求两者的先后，只按轮询与 credit 选择。顺序由上游保证：axi2flit_soc 先接受 AW，"
  "把路由信息写入写路由 FIFO，W 才能被接受，所以 WREQ 总是先于本突发的 WDATA 进入发送队列。单 RP 写突发时，"
  "轮询在有消息的候选间交替：WREQ 队列有下一笔突发的请求时与 WDATA 轮流，为空时每拍都选 WDATA；读写同时进行时 RREQ 也参与轮流。"
  "存储侧对两类消息分别缓冲，写组装取出 WREQ 后再按其 LEN 消耗 WDATA，即使两者在链路上次序颠倒也不会出错。")

h2("aou_flit_rx")
fig("rx", "f_rx.png", "aou_flit_rx 微架构（红色虚线为错误检测）")
p("帧进入时检查 PH 保留位，合法帧写入帧缓冲（FRAME_DEPTH ≥ 2），同时把 MsgCredit 交给 transport（每帧只计一次）。"
  "解析器同时看当前帧与下一帧：从 cursor 开始找第一个 MsgStart，由首字节得到长度，从当前帧（必要时连同下一帧开头）"
  "取出完整消息写入输出寄存器。跨帧消息在下一帧到齐前等待。消息范围内又出现 MsgStart 或长度非法时置 fault。"
  "稳态下每拍输出一条完整消息。")

h2("aou_chunk_fifo")
fig("chunk", "f_chunk.png", "aou_chunk_fifo 微架构（以 BANKS = 4 为例）")
p("为什么数据消息不用普通 FIFO：链路 credit 以粒度计，而数据消息长度随传输大小变化，1024 位配置下读数据可为 8、14 或 "
  "27 个粒度。普通 FIFO 每项按最长消息开宽度，一项可能只装一条 8 粒度的短消息，为保证不溢出，每项只能公布 8 个粒度；"
  "全宽 27 粒度消息时只用到约 30% 的存储，要达到同样带宽深度须放大约 3.4 倍。chunk FIFO 以 8 粒度为一块，"
  "一条消息只占 ⌈粒度数 / 8⌉ 块，存储占用与粒度数基本成正比，每块可公布 27 / 4 ≈ 6.75 个粒度（各种消息中“粒度数 / 块数”"
  "的最小值，见 6.1 节），全宽与窄传输都能用上大部分存储。多 bank 交错使一条最长 4 块的消息在一拍内写入、同拍另一条读出，"
  "保持每拍一条消息的吞吐。请求与写响应长度固定，仍用 aou_sync_fifo。")
p("按 8 粒度（320 位）一块组织，BANKS（DATA_WIDTH/256）个 bank 交错，第 s 块位于 bank s mod BANKS。一条消息占 "
  "⌈粒度数 / 8⌉ 个连续块，入队、出队各按起始 bank 旋转，每个 bank 每拍只读写一行，所以每拍可同时入队、出队一条。"
  "level 以块计，满且同拍出队时按释放的块数判断能否入队。")

h2("aou_sync_fifo")
fig("fifo", "f_fifo.png", "aou_sync_fifo 微架构")
p("深度可为 1 或非 2 的幂。FWFT = 1 时队首直接出现在 rd_data，rd_en 同拍取走；FWFT = 0 时 rd_en 后下一拍输出。"
  "满且同拍出队时可以入队。桥内实例都用 FWFT = 1、valid = !empty；SoC 侧发送队列、写路由 FIFO 和存储侧响应队列取 ready = !full，"
  "其余取 ready = !full || (rd_en && !empty)。")

h2("aou_pkg")
p("包含三类内容：协议常量（帧 2000 位、粒度 40 位、48 粒度、类型码、MsgCredit 编码等）；四种消息头的结构体"
  "（req_hdr_t、wdata_hdr_t、rdata_hdr_t、wresp_hdr_t），字段位置由结构体给出；组合函数（make_req / make_wdata / "
  "make_rdata / make_b 编码，get_req / get_data / get_strb 解码，granules 等长度与 credit 换算，make_flit / get_starts "
  "等 PH 处理）。消息长度与 credit 比例按公式由位宽算出，不需手工维护表格。")

# =====================================================================
h1("流控、缓冲与异常处理")
h2("链路 credit")
fig("loop", "f_credit_loop.png", "链路 credit 闭环", width=14.5)
p("每个 RP、每类消息各有一本账，单位为粒度。① 发送端只在 available 不小于消息长度时发送并扣减；② 消息进入接收缓冲，"
  "接收端核对长度不超过 promised，否则判对端超发；③ 上层取走消息，空出的存储折算为 pending；④ pending 编码进反方向帧的 "
  "PH 归还，发送端 available 增加。空闲存储折算 credit 时按最不利的消息长度：")
code("可公布容量 = floor(空闲单元 × credit_gran / credit_units)        例：1024 位数据消息为 27 / 4 粒度每块")
h3("接收深度的选取")
p("从①到④的时间称为 credit 往返时间 RTT。发送端在一个 RTT 内最多只能发出“接收端已公布的容量”，"
  "而公布的容量不超过接收缓冲的大小，所以接收深度直接决定一类消息能达到的最高吞吐：")
code("吞吐上限 = 接收深度（条） × 每条消息携带的数据字节 / RTT\n"
     "反过来，要以间隔 t_msg 持续发送，所需深度：\n"
     "    N_min  = ceil(RTT / t_msg) + 余量\n"
     "    t_msg  = 每条消息的数据字节 / 目标带宽          （不小于 1 个时钟周期，2ns）\n"
     "    目标带宽 = min(AXI 端口 DATA_WIDTH/8 × f,  链路有效数据带宽,  存储侧带宽)")
p("深度参数的单位是“本端全宽消息条数”：256 位时一条读数据携带 32B，1024 位时携带 128B。同样的带宽，位宽越窄、"
  "每条消息越小，消息越密，需要的条数就越多，这是默认深度随位宽不同的根本原因。")
p("RTT 由仿真实测得到，三条闭环的长度不同：")
li("（1）读数据（RDATA，存储侧 → SoC 侧）：约 53ns。包括 RDATA 所在帧经链路到达 SoC 侧（约 10ns）、解帧入缓冲、"
   "R 握手取走、授信写进反方向帧的 PH、该帧经链路回到存储侧（约 10ns），以及两端等待 FDI 发帧时隙（x8 PAM4 每 5.33ns 一帧）。"
   "实测：深度 24 时读吞吐 14.34GB/s，反推 RTT = 24 × 32B / 14.34GB/s ≈ 53.6ns，与延迟探测得到的 52～55ns 一致。")
li("（2）写数据（WDATA，SoC 侧 → 存储侧）：约 62ns，比读数据多约 9ns。写数据进入存储侧缓冲后，要等写组装把它并入行、"
   "HIF 写命令被接收后才出队，出队之后存储才空出、credit 才能归还。实测：深度 28 时写吞吐 14.34GB/s，反推 RTT ≈ 62.5ns。")
li("（3）读写同时：约 75ns。此时两个方向的帧都装满数据，归还 credit 的 PH 要搭下一个数据帧，而满载时帧的间隔约为"
   "一帧的消息数（256 位读数据约 6 条）个周期，闭环因此再长约 10ns。实测：深度 32 时同时写吞吐 13.55GB/s，反推 RTT ≈ 75ns。")
p("按上式逐个位宽计算（f = 500MHz，x8 · 24GT/s · PAM4 链路的有效数据带宽读 42.67、写 42.37GB/s）：")
tab("depth_calc", "读写数据接收深度的计算", ["AXI 位宽", "目标带宽", "t_msg", "RDATA：RTT / t_msg", "WDATA：RTT / t_msg",
                                           "默认 RDATA / WDATA"], [
    ["256 位", "16GB/s（AXI 端口）", "32B / 16GB/s = 2ns", "53.6 / 2 ≈ 27", "单向 62.5 / 2.1 ≈ 30；同时 75 / 2.3 ≈ 33",
     "32 / 36"],
    ["512 位", "32GB/s（AXI 端口）", "64B / 32GB/s = 2ns", "≈ 27", "≈ 30；同时 ≈ 33", "32 / 36"],
    ["1024 位", "42.7GB/s（链路）", "135B / 45GB/s = 3ns", "53.6 / 3 ≈ 18", "62.5 / 3.2 ≈ 20", "24 / 24"],
], [1.6, 2.6, 3.0, 2.6, 3.6, 2.1],
    note="256、512 位时消息间隔被时钟周期限制在 2ns，所以两者需要的条数相同；1024 位时一条消息 135B，链路每 3ns 才能送完一条。"
         "默认值在计算值上留 10%～20% 余量。写数据比读数据多取 4 条，对应写闭环更长以及读写同时时帧搭载带来的额外延迟。")
p("实测验证（全链路，16 拍突发）。256 位、HIF 存储侧时改变两个深度：")
tab("depth_meas", "256 位接收深度与满载吞吐（全链路，HIF 存储侧，GB/s）",
    ["RDATA / WDATA 深度", "读", "写", "读写同时"], [
    ["24 / 24（原默认）", "14.34", "12.80", "12.73 / 12.12"],
    ["28 / 28", "16.00", "14.34", "14.08 / 13.12"],
    ["32 / 32", "16.00", "15.06", "15.06 / 13.55"],
    ["32 / 36（默认）", "16.00", "15.06", "15.09 / 14.17"],
    ["36 / 36 及以上", "16.00", "15.06", "15.11 / 14.17"],
], [4.4, 2.6, 2.6, 5.9],
    note="读 16.00 为 AXI 端口与 HIF 数据口上限；写 15.06 = 16 × 16/17，每笔 16 拍突发另有一条 WREQ 占用组帧器一拍；"
         "读写同时 15.11 / 14.17 是两端组帧器每拍一条消息的结构上限（SoC 侧 w × 17/16 + r/16 ≤ 1，存储侧 r + w/16 ≤ 1），"
         "再加深度不会提高。")
p("512 位、满速 MC 模型（存储侧不限速）时，深度 24 / 24 只有读 28.80、写 27.83GB/s，32 / 36 达到读 32.00、写 30.12GB/s，"
  "即 AXI 端口上限。1024 位时的扫描见{图:sweep}：满速 MC 模型下深度 20 达到链路上限，默认 24 留约 20% 余量。")
fig("sweep", "f_sweep.png", "满载带宽随接收深度的变化（1024 位，x8 · 24GT/s · PAM4，满速 MC 模型）", width=14.0)
p("存储侧比 AXI 端口窄时，目标带宽取存储侧带宽，所需深度相应减小。例如 HIF 固定 256 位（16GB/s）：512 位 AXI 时"
  "t_msg = 64B / 16GB/s = 4ns，约 14 条即可（实测 12 条读 14.66GB/s、16 条满速）；1024 位 AXI 时 t_msg = 8ns，约 7 条即可"
  "（实测 8 条满速）。默认值没有按 HIF 宽度缩小，是为了加宽 HIF 或接满速存储时仍能跑满 AXI 端口或链路；HIF 宽度确定后，"
  "可按上式减小深度以节省面积（1024 位时每条读数据占 4 个 320 位的块）。")
p("其余几类深度：请求与写响应消息很小（3 和 1 个粒度），16 拍突发时每 16 拍才一条，默认值远超需要。最坏情况是单拍突发："
  "读请求每 2ns 一条，需要约 27 条，RREQ_DEPTH 取 32；单拍写时组帧器每拍数据还要多发一条 WREQ，写请求约每 4ns 一条，"
  "约 14 条，WREQ_DEPTH、WRESP_DEPTH 取 24。RP ≥ 2 时各 RP 的 credit 独立，每个 RP 各有一份深度。")
h2("HIF credit 与缓冲")
p("HIF credit 保护控制器的命令队列：初值等于控制器 CAM 中 LPR、HPR、写三部分的表项数，命令被接收时扣减，控制器把命令"
  "发往 DFI 后以脉冲归还。链路 credit 保证“消息能进来”，HIF credit 与缓冲行数保证“命令能出去”，两者都要够。")
p(f"读 ROB（RD_LINES）与写缓冲（WR_LINES）决定可同时在途的行数。{{表:lines}}是 1024 位、控制器延迟 8 拍、x8 PAM4 链路下的"
  f"全链路实测：读 ROB 少于 8 行时吞吐与行数成正比（每行 64B、一行约 2.3ns，即受“行数 × 行字节 / 往返时间”限制），"
  f"8 行即达到 HIF 数据口上限 {max(R['lines'])[0]:.2f}GB/s；写缓冲 4 行即足够，因为写数据由控制器的回送指针节流，"
  f"在途行数本来就少。默认取 32 / 16，留有余量。")
tab("lines", "读 ROB / 写缓冲行数与 HIF 吞吐（全链路，1024 位，GB/s）",
    ["行数", "读（RD_LINES）", "写（WR_LINES）"],
    [[str(n), f"{r:.2f}", f"{w:.2f}"] for n, (r, w) in zip(R["lines_n"], R["lines"])],
    [3.6, 5.4, 5.4])
h2("背压")
p("所有片内接口为 ready/valid，VALID 拉高后在握手前保持。下游停顿时背压逐级上传：例如控制器持续 stall，存储侧接收缓冲填满，"
  "链路 credit 停止归还，SoC 侧组帧器停发，最终 AXI READY 拉低；停顿解除后自动恢复，不丢数据。")
h2("异常检测")
tab("errs", "异常检测", ["位置", "条件", "处理"], [
    ["axi2flit_soc", "非 INCR、未对齐、SIZE 超宽、跨 4KB；WLAST 与 AWLEN 不符", "置 protocol_error，不生成消息"],
    ["axi2flit_soc", "R / B 的 ID 无在途事务或 RP 不符", "不交给主机，置 protocol_error"],
    ["aou_flit_rx", "PH 保留位非零、长度编码非法、起点重叠", "置 fault，停止接收"],
    ["aou_transport", "未知类型、RP 越界、DLENGTH 超宽、请求非法、超出已公布 credit", "置 fault"],
    ["aou_transport", "对端授信使 available 超过 4095", "饱和，不报错（规范 6.4 节）"],
    ["flit2hif_target", "控制器返回的错误、窗口外访问、HIF 协议违规（见 5.2.5 节）", "错误响应或置 protocol_error"],
], [3.0, 7.6, 4.9])
p("protocol_error 保持到复位，应接到中断或状态寄存器，由软件组织两端协同复位。")

# =====================================================================
h1("可配置参数")
p("参数分为三类：两端必须一致的、各端独立的、以及与存储控制器一致的。协议线上格式由 aou_pkg 常量固定，不可配置。")
h2("两端一致")
tab("par_both", "两端一致的参数", ["参数", "默认", "取值", "说明"], [
    ["DATA_WIDTH", "256", "256 / 512 / 1024", "AXI 数据位宽；决定数据消息最大宽度与接收缓冲 bank 数"],
    ["RP_COUNT", "1", "1～4", "资源平面数"],
], [3.2, 1.6, 3.0, 7.7])
h2("axi2flit_soc")
tab("par_soc", "axi2flit_soc 参数", ["参数", "默认", "说明"], [
    ["TX_DEPTH", "2", "每个 RP 的 WREQ、RREQ、WDATA 发送队列深度；≥ 2，2 即可满速，满时反压 AXI"],
    ["WR_ROUTE_DEPTH", "8", "写路由 FIFO 深度：AW 最多可领先 W 的突发数（所有 RP 共用）"],
    ["RDATA_DEPTH / WRESP_DEPTH", "32 / 24", "每个 RP 的接收深度（全宽消息条数），决定公布给存储侧的 credit；"
     "RDATA 1024 位时默认 24，推导见 6.1.1 节"],
    ["RD_OUTSTANDING / WR_OUTSTANDING", "32 / 32", "读、写最大在途事务数（在途表项数），表满时背压 ARREADY / AWREADY"],
    ["AXI_ID_W / AXI_ADDR_W / AXI_USER_W", "10 / 64 / 16", "AXI 侧字段宽度，不超过线上宽度，上线时高位补零"],
], [5.2, 2.2, 8.1])
h2("flit2hif_target")
tab("par_tgt", "flit2hif_target 桥侧参数", ["参数", "默认", "说明"], [
    ["WREQ_DEPTH / RREQ_DEPTH / WDATA_DEPTH", "24 / 32 / 36", "每个 RP 的接收深度；WDATA 1024 位时默认 24，推导见 6.1.1 节"],
    ["RESPONSE_DEPTH", "2", "每个 RP 的 RDATA、WRESP 发送队列深度；≥ 2，2 即可满速，满时反压后端"],
    ["ADDR_BASE / MEM_BYTES", "0 / 4GB", "存储窗口；4KB 对齐，MEM_BYTES / 字宽不超过 2^CORE_ADDR_WIDTH"],
    ["RD_LINES / WR_LINES", "32 / 16", "读 ROB 行数、写缓冲行数（同时在途的 HIF 命令）"],
    ["RD_BURSTS / WR_BURSTS", "16 / 16", "已接收未退休的读、写突发数"],
    ["HPR_QOS", "16", "AxQOS ≥ 该值的读走 HPR；16 表示不用 HPR"],
    ["ECC_RMW", "0", "1：非全掩码写用 RMW 命令"],
], [5.6, 2.4, 7.5])
tab("par_hif", "flit2hif_target 控制器配置参数（与 MC 一致）", ["参数", "默认", "说明"], [
    ["MEMC_DRAM_DATA_WIDTH", "32", "DRAM 数据宽度；HIF 字地址单位为其 / 8 字节"],
    ["MEMC_FREQ_RATIO", "4", "控制器与 DRAM 频率比"],
    ["MEMC_BURST_LENGTH", "16", "DRAM burst 长度；行 = BL × DRAM 宽度 / 8 字节"],
    ["CORE_DATA_WIDTH", "DRAM 宽度 × 比 × 2", "HIF 数据宽度（默认 256），须等于左式"],
    ["CORE_MASK_WIDTH", "CORE_DATA_WIDTH / 8", "写掩码宽度"],
    ["CORE_ADDR_WIDTH", "40", "hif_cmd_addr 宽度"],
    ["CORE_TAG_WIDTH", "53", "token 宽度，不小于 log2(RD_LINES)"],
    ["WDATA_PTR_BITS", "19", "写指针宽度，不小于 log2(WR_LINES)"],
    ["CMD_LEN_BITS / RD_LATENCY_BITS", "2 / 11", "hif_cmd_length / hif_cmd_latency 宽度"],
    ["HIF_PRI_BITS / VPRW_EN", "2 / 0", "优先级宽度；VPRW_EN = 1 时 HPR 编码为 2'b10"],
    ["HIF_CREDIT_BITS", "1", "lpr / hpr credit 宽度，Inline ECC 为 2"],
    ["LPR_CREDITS / HPR_CREDITS / WR_CREDITS", "24 / 8 / 32", "三类 credit 初值，等于控制器 CAM 配置"],
], [5.6, 3.4, 6.5])
h2("协议常量（不可配置）")
tab("consts", "aou_pkg 主要常量", ["常量", "值", "说明"], [
    ["FLIT_BITS / PAYLOAD_BITS", "2000 / 1920", "PLP 与消息区位数"],
    ["FLIT_GRANULES / GRANULE_BITS", "48 / 40", "每帧粒度数、粒度位数"],
    ["MSG_MAX_GRANULES", "30", "最长消息（1024 位带掩码写数据）"],
    ["WIRE_ID_W / WIRE_ADDR_W / WIRE_USER_W", "10 / 64 / 16", "消息中的字段宽度"],
    ["CREDIT_CNT_W", "12", "链路 credit 计数位宽，深度 × 每条粒度数须 ≤ 4095"],
], [5.6, 2.6, 7.3])
h2("仿真中的设置方式")
p("sim/Makefile 的变量与参数一一对应，命令行修改后自动重新编译，例如：")
code("make -C sim run WIDTH=1024 RP=2 RDATA_DEPTH=32 HIF_DRAM_W=64 HIF_RATIO=2 HIF_LPR=32 HIF_RD_LINES=16\n"
     "    WIDTH / RP / *_DEPTH       → DATA_WIDTH / RP_COUNT / 各深度\n"
     "    HIF_DRAM_W / RATIO / BL    → MEMC_DRAM_DATA_WIDTH / MEMC_FREQ_RATIO / MEMC_BURST_LENGTH\n"
     "    HIF_LPR / HPR / WR         → LPR_CREDITS / HPR_CREDITS / WR_CREDITS\n"
     "    HIF_RD_LINES / WR_LINES    → RD_LINES / WR_LINES\n"
     "    HIF_CREDIT_BITS / ECC_RMW  → HIF_CREDIT_BITS / ECC_RMW\n"
     "    LINK_LANES / LINK_BPS      → 链路模型的通道数、每符号比特数（PAM4 为 2）")

# =====================================================================
h1("性能")
h2("桥接延迟")
p("桥接延迟按接口握手时刻计算，空载、2ns 时钟。四段定义：")
code("SoC 发送    = 请求所在帧离开 SoC 侧 − AR 握手（写为最后一个 W 握手）\n"
     "SoC 接收    = R / B 握手 − 响应所在帧进入 SoC 侧\n"
     "存储侧请求  = 第一条 HIF 命令被接收 − 请求所在帧进入存储侧（写取 WREQ、WDATA 中较晚者）\n"
     "存储侧返回  = 响应所在帧离开存储侧 − 最后一行数据的最后一拍（读为 hif_rdata，写为 hif_wdata 被接收）")
fig("lat", "f_latency.png", "全链路空载单拍读的延迟分解（灰底为桥，虚线框为链路与控制器）", width=15.0)
tab("lat_res", "空载转换延迟（ns）", ["环境", "SoC 发送", "SoC 接收", "存储侧请求", "存储侧返回"], [
    ["独立环境（最大值）", str(R["lat"]["sa_soc_tx"]), str(R["lat"]["sa_soc_rx"]), str(R["lat"]["sa_req"]),
     str(R["lat"]["sa_ret"])],
    ["全链路单拍读", str(SR[0]), str(SR[6]), str(SR[2]), str(SR[4])],
    ["全链路单拍写", str(SW[0]), str(SW[6]), str(SW[2]), str(SW[4])],
], [4.7, 2.7, 2.7, 2.7, 2.7], note="独立环境为三种位宽、RP = 1～4 的最大值；全链路两行为 1024 位、RP = 1。")
p("各段经过的寄存器级：")
li("（1）SoC 发送 3 拍：消息写入发送队列 → 组帧器接受 → 帧提交到输出寄存器并握手。")
li("（2）SoC 接收 3 拍：帧写入帧缓冲 → 解析出消息写入接收缓冲 → 交给 AXI R / B。")
li("（3）存储侧请求：读 4 拍——帧写入帧缓冲 → 消息写入接收缓冲 → 读发起出队并锁存突发 → 发出第一条命令；"
   "写 3 拍——WREQ 已先行出队时，WDATA 进入接收缓冲后写组装同拍即可发命令；WREQ 与 WDATA 装在同一帧时，"
   "解帧器逐拍输出两条消息，再多 1 拍。")
li("（4）存储侧返回 4 拍：最后一行的最后一拍数据写入读 ROB（写为最后一拍写数据被接收、写上下文计数归零）→ "
   "下一拍退休，生成 RDATA / WRESP 写入发送队列 → 组帧器接受 → 帧提交。读、写相同。")
p(f"桥本身：SoC 侧 {R['lat']['sa_soc_tx'] + R['lat']['sa_soc_rx']}ns，存储侧 {R['lat']['sa_req'] + R['lat']['sa_ret']}ns"
  f"（独立环境三种位宽、RP = 1～4 的最大值），均不超过 20ns。全链路单拍写的“存储侧返回”为 {SW[4]}ns，比桥内 4 拍多出"
  f"的部分是 WRESP 所在帧排在只含 credit 的帧之后，等待 FDI 接收（x8 PAM4 每 5.33ns 发一帧），属于链路发送排队，"
  f"不在桥内；256、512 位时为 14ns，原因相同。全链路空载单拍读端到端 {FL_R['total']}ns，其中链路往返 {SR[1] + SR[5]}ns、"
  f"HIF 控制器 {SR[3]}ns（第一条命令到最后一行数据，1024 位一拍对应 2 行）。排队、credit 不足或下游背压时延迟增大；"
  "2ns 时钟为仿真设定，实际频率以综合为准。")

h2("带宽")
p("一条数据通路的带宽是各环节上限中的最小值。f 为时钟频率（仿真取 500MHz），各环节上限如下：")
tab("bw_formula", "各环节带宽上限（单方向）", ["环节", "公式", "1024 位、默认配置"], [
    ["AXI 端口", "DATA_WIDTH / 8 × f", "64 GB/s"],
    ["桥消息处理", "每周期一条消息；写每笔突发另有一条 WREQ：× LEN/(LEN+1)", "读 64，写 60.24 GB/s（16 拍）"],
    ["链路消息区", "通道数 × 速率 × 每符号比特 / 8 × 240/256", "45 GB/s"],
    ["链路有效数据", "消息区 × 数据字节 / 消息字节", "读 42.67，写 42.37 GB/s"],
    ["HIF 数据口", "CORE_DATA_WIDTH / 8 × f，读、写数据线各一组", "16 GB/s"],
    ["HIF 命令口", "每周期一条命令，读写共用：LINE_BYTES × f", "读写合计 32 GB/s"],
], [3.0, 7.7, 4.8])
p(f"默认配置下瓶颈是 HIF 数据口。为了把桥与链路自身的能力和存储侧分开测量，仿真另有一个“满速 MC 模型”"
  f"（sim/model/flit2mc_target.sv，仿真时 MC_IF=ideal 选用，不属于交付 RTL）。它同样例化 aou_target_core，"
  f"但后端不切行、不经 HIF：每个 AXI 拍直接作为一条命令，读、写各有一个与 AXI 等宽的命令口和完成口，每周期各接受一条；"
  f"测试平台中的 C++ 字节存储在固定延迟（全链路 10 拍）后返回，读写互不阻塞。于是存储侧带宽始终不低于 AXI 端口，"
  f"测得的就是“桥 + 链路”的上限。{{图:thr}}对比两种存储侧：满速 MC 模型给出桥与链路的上限，"
  f"HIF 存储侧（交付设计 flit2hif_target 加 HIF 控制器模型）给出接上单通道 HIF 控制器后的系统带宽。")
fig("thr", "f_throughput.png", "全链路满载吞吐（1024 位，16 拍突发，x8 · 24GT/s · PAM4）", width=14.0)
tab("bw_res", "全链路满载吞吐（GB/s）", ["位宽", "存储侧", "RP", "读", "写", "读写同时 / 限制因素"],
    R["bw_rows"], [1.6, 1.5, 1.2, 1.6, 1.6, 8.0],
    note="256 位读写同时的上限由两端组帧器每拍一条消息决定（见 6.1.1 节）；HIF RP4 读写同时中读约 10GB/s 的几项，"
         "是因为测试中 QoS ≥ 2 的读走 HPR，而 HPR credit 只有 8 个：8 行 × 64B / 约 50ns 往返 ≈ 10.24GB/s；读命令按突发顺序发出，"
         "HPR 突发等 credit 时后面的 LPR 突发也被挡住。是否触发取决于请求到达的时序；HPR credit 改为 24 后均为 16.00GB/s。")
p("可配置项对带宽的影响：")
li("（1）DATA_WIDTH 与频率决定 AXI 端口与桥的上限；1024 位在 500MHz 下为 64GB/s，高于 x8 PAM4 链路。")
li("（2）链路通道数与速率决定消息区带宽；x16 PAM4（90GB/s）时瓶颈转到桥（读 64、写 60.2GB/s 实测）。")
li("（3）HIF 数据宽度 CORE_DATA_WIDTH = MEMC_DRAM_DATA_WIDTH × MEMC_FREQ_RATIO × 2 决定存储侧上限，可以调大，"
   "见{表:hifw}。约束：一行的字节数须是 HIF 字的整数倍（BL ≥ 2 × 频率比），行不超过 4KB。")
li("（4）接收深度、RD_LINES / WR_LINES、HIF credit 决定能否达到上述上限：深度不足时带宽与深度成正比，见 6.1、6.2 节。")
li("（5）窄传输：链路上每拍消息按传输大小缩短；存储侧相邻窄拍合并成一行，HIF 命令数只由突发字节数决定。")
tab("hifw", "HIF 数据宽度与带宽（1024 位 AXI，全链路满载，GB/s）",
    ["HIF 配置", "HIF 宽度 / 行", "读", "写", "读写同时", "瓶颈"], [
    ["默认（DRAM 32 位，1:4，BL16）", "256 位 / 64B", "16.00", "16.00", "16.00 / 16.00", "HIF 数据口"],
    ["HIF_DRAM_W = 64", "512 位 / 128B", "32.00", "32.00", "32.00 / 32.00", "HIF 数据口"],
    ["HIF_DRAM_W = 128", "1024 位 / 256B", "42.67", "42.37", "42.57 / 42.08", "链路（与满速 MC 相同）"],
], [4.6, 2.6, 1.4, 1.4, 2.6, 2.9], note="两种加宽配置另在独立环境中通过全部功能与异常用例。")

# =====================================================================
h1("验证")
h2("验证环境")
p("验证分两级，均可选择两种存储侧：HIF 存储侧（交付设计 flit2hif_target 加 HIF 控制器模型）与满速 MC 模型（仿真用，"
  "见 8.2 节，用于测量桥加链路的上限）。")
tab("tbfiles", "验证文件", ["文件", "内容"], [
    ["sim/tb/tb_rtl_bridge.sv / .cpp", "独立环境：两端桥经有限深度链路 FIFO 背靠背连接；AXI 激励、记分板、错误注入、SVA 握手保持断言"],
    ["sim/tb/fl_rtl_top.sv、tb_full_link_rtl.cpp", "全链路环境：两端 RTL 接入 SystemC UCIe 链路模型；延迟分解、吞吐统计、汇总报告"],
    ["sim/model/hif_mc_model.sv", "HIF 控制器模型：命令队列与 credit、写指针回送、按 token 乱序 / 交织返回、随机 stall、"
                                 "地址与 ECC 错误；每拍检查桥是否违反 HIF 约定"],
    ["sim/model/flit2mc_target.sv", "满速 MC 模型（仿真用，见 8.2 节）"],
    ["sim/tb/tb_flit_codec.*、tb_fifo.cpp", "组帧 / 解帧与 FIFO 单元测试"],
    ["sim/Makefile", "编译与回归入口；Verilator 与 VCS 两套流程；MC_IF = hif（默认）/ ideal"],
], [5.4, 10.1])
fig("tb", "f_tb.png", "独立验证环境（HIF 存储侧）")
p("独立环境中链路 FIFO 按链路带宽限速并可插入停顿。记分板按 AXI 握手维护参考存储，每个 R 拍逐字节比对；"
  "链路上每条消息与参考编码库生成的字节逐一比较。HIF 控制器模型发现桥超 credit 发命令、token 或写指针重复使用、"
  "写数据拍数不符等情况时报错。")
fig("fulllink", "f_fulllink.png", "全链路联合仿真环境")
p("全链路环境中，Flit 端口经 FDI 适配接入事务级 UcieLink 模型（两端 D2D Adapter 含 CRC 与重传，PHY 按 x8 · 24GT/s · "
  "PAM4 逐 UI 计时）。同一份测试平台可用 Verilator + GTKWave 或 VCS + Verdi 编译运行。")

h2("测试项")
tab("tests", "测试项", ["编号", "测试项", "命令（工程根目录）", "内容与判据"], [
    ["T1", "单元测试", "make -C sim fifo-all codec-all", "FIFO 8 组；组帧 / 解帧 3 位宽 × 6 种消息，逐字节比对，每周期一条消息"],
    ["T2", "静态检查", "make -C sim lint", "Verilator lint 无告警"],
    ["T3", "系统功能", "make -C sim run", "突发、掩码、窄访问、错误响应、多 RP 并发、乱序与交织、长时间背压、在途复位、短时吞吐"],
    ["T4", "异常注入", "make -C sim negative", "11 类非法输入在 100 周期内被指定一端检出；credit 饱和不报错"],
    ["T5", "控制器配置", "make -C sim hif-cfg-all", "16 位 DRAM、64 位 DRAM 1:2、2 位 credit、RMW、极小 credit 与缓冲"],
    ["T6", "满速 MC 模型", "make -C sim ideal-all", "桥 + 链路上限；1024 位满载 ≥ 90% 门限"],
    ["T7", "记分板自检", "make -C sim checker-negative", "篡改期望数据，必须检出"],
    ["T8", "全链路", "make -C sim fl-all", "空载延迟、12 个功能用例、满载读 / 写 / 读写同时；RP2 压力 + 2% CRC 错误重传"],
    ["T9", "全链路满速 MC", "make -C sim fl-ideal-all", "同 T8，存储侧为满速 MC 模型"],
], [1.1, 2.3, 4.6, 7.5])
p("T2～T4 在 256 / 512 / 1024 位 × RP = 1 / 2 / 4 共 9 种配置下执行（make -C sim test-all）；make -C sim check 运行 T1～T7。"
  "T3 的功能步骤：空载单拍读写并测延迟；2、4、16 拍及整页 4KB 突发；部分与全零选通；SIZE = 2 的 16 拍与 256 拍窄访问；"
  "32B、64B 传输大小；窗口内越界（控制器 addr_err）与窗口外访问；ECC 错误行读取；独占访问；4 笔分属不同 RP 的写并发、"
  "同 ID 连续读、读写交错（控制器乱序与交织返回）；AXI、控制器、链路分别长时间停顿；在途事务时协同复位。")

h2("测试结果")
p(f"在 Verilator 5.052 下全部测试项通过，部分全链路配置在 VCS X-2025.06 下复核，结果一致。汇总见{{表:summary}}。")
tab("summary", "回归结果", ["测试项", "规模", "结果"], R["summary"], [3.6, 5.4, 6.5])
tab("func_res", "系统功能测试统计（HIF 存储侧，独立环境）",
    ["位宽", "RP", "写 突发/拍", "读 突发/拍", "HIF 读/写命令", "乱序 / 交织", "核对消息", "跨帧"],
    R["func_rows"], [1.3, 0.9, 2.0, 2.0, 2.6, 2.4, 2.2, 1.6])
tab("cfg_res", "其他控制器配置（独立环境，RP = 2，含异常注入）", ["配置", "AXI 位宽", "读 GB/s", "写 GB/s", "结果"],
    R["cfg_rows"], [6.6, 2.0, 2.3, 2.3, 2.3],
    note="吞吐为功能测试末尾的短时满载，256 位受总线宽度（16GB/s）限制，1024 位受 HIF 数据口限制；16 位 DRAM 时 HIF 为 "
         "128 位、8GB/s，极小 credit 配置用于检查流控正确性，不追求带宽。")

h2("波形分析")
p("全链路波形取自 1024 位、RP = 1 的空载探测；其余取自独立环境（1024 位、RP = 1）。时钟 2ns，蓝色虚线为正文引用的时刻，"
  "握手类信号画 valid 与 ready 同时为高的周期，脉冲右沿即采样的时钟上升沿，与 GTKWave / Verdi 中的显示一致。"
  "独立环境的 AXI 输入由测试平台在时钟下降沿驱动，所以 WVALID、RREADY 等会在奇数 ns 处跳变。"
  "全链路两张图的行名对应的信号见{表:wave_sig}（均在 fl_rtl_top 下）。")
tab("wave_sig", "全链路波形图的行与信号", ["行", "信号（fl_rtl_top.*）"], [
    ["AR 握手 / R 握手（RLAST）", "s_axi_arvalid && s_axi_arready / s_axi_rvalid && s_axi_rready && s_axi_rlast"],
    ["W 握手（WLAST）/ B 握手", "s_axi_wvalid && s_axi_wready && s_axi_wlast / s_axi_bvalid && s_axi_bready"],
    ["SoC 发出帧 / SoC 收到帧", "soc_flit_tx_valid && soc_flit_tx_ready / soc_flit_rx_valid && soc_flit_rx_ready"],
    ["存储侧收到帧 / 存储侧发出帧", "tgt_flit_rx_valid && tgt_flit_rx_ready / tgt_flit_tx_valid && tgt_flit_tx_ready"],
    ["HIF 命令", "hif_cmd_valid && !hif_cmd_stall（类型见 hif_cmd_type，token 见 hif_cmd_token）"],
    ["HIF 读数据 / 读数据 token", "hif_rdata_valid（末拍 hif_rdata_end）/ hif_rdata_token"],
    ["写指针回送 / HIF 写数据", "hif_wdata_ptr_valid / hif_wdata_valid && !hif_wdata_stall（末拍 hif_wdata_end）"],
], [4.8, 10.7], note="帧握手中包含只携带 credit 的帧；①～⑧ 只标注携带本次请求或响应消息的帧。")
h3("全链路 HIF 读")
fig("w_fl_read", "w_fl_read.png", "全链路单拍读（顶部为相邻标记间的时长，单位 ns）")
t = FL_R["t"]
p(f"① {ns(t[0])} AR 握手；② {ns(t[1])} RREQ 所在帧离开 SoC 侧；③ {ns(t[2])} 到达存储侧；④ {ns(t[3])} 第一条 HIF 读命令"
  f"被接收，下一拍第二条（128B 一拍对应两行，token 分别为 0、1）；⑤ {ns(t[4])} 第二行最后一拍数据到达；"
  f"⑥ {ns(t[5])} RDATA 所在帧离开存储侧；⑦ {ns(t[6])} 到达 SoC 侧；⑧ {ns(t[7])} R 握手。共 {FL_R['total']}ns。")
h3("全链路 HIF 写")
fig("w_fl_write", "w_fl_write.png", "全链路单拍写（写地址提前发出，从最后一拍写数据开始测量）")
t = FL_W["t"]
p(f"① {ns(t[0])} W 握手；② ③ 帧经链路到达存储侧；④ {ns(t[3])} 第一条 HIF 写命令被接收，数据已在写缓冲中；"
  f"控制器至少 2 拍后回送写指针，桥随即送出该行 2 拍数据；⑤ {ns(t[4])} 第二行数据最后一拍被接收；"
  f"⑥ {ns(t[5])} WRESP 所在帧离开存储侧；⑧ {ns(t[7])} B 握手。共 {FL_W['total']}ns。")
h3("组帧")
fig("w_tx", "w_tx.png", "16 拍全选通写突发的组帧")
t = M["tx"]
p(f"每拍一条 27 粒度的 WDATAFULL，组帧器每周期接受一条。帧内已用 {t['used_before']} 个粒度时，下一条只能放下 "
  f"{48 - t['used_before']} 个：① {ns(t['t1'])} 该帧提交，spill_offset = {t['spill']}；② {ns(t['t2'])} 新帧先写剩余 "
  f"{27 - t['spill']} 个粒度，再接下一条，used = {t['used_after']}。消息接受没有中断。")
h3("解帧")
fig("w_rx", "w_rx.png", "连续读返回的解帧")
t = M["rx"]
p(f"每条 RDATA 27 个粒度。① {ns(t['t1'])} 输出一条消息后 cursor = 27，下一条从第 27 粒度开始、需要跨到下一帧；"
  f"② {ns(t['t2'])} 下一帧到齐后（frame_count = 2）一次拼接输出，cursor = {t['cursor2']}，即新帧中被续片占用的粒度数。"
  "下一帧到达后的第一拍即完成拼接，不需要额外的解析周期。")
h3("链路 credit 初始化")
fig("w_credit", "w_credit.png", "复位后的链路 credit 初始化")
t = M["credit"]
p(f"复位后 SoC 侧 RDATA 的 pending 为 {t['pending0']}（24 条 × 27 粒度）。① {ns(t['t1'])} link_up 后发只含 PH 的帧，"
  f"每帧授出 128 个粒度，{ns(t['t_zero'])} 时全部授出；② {ns(t['t2'])} 收到存储侧的 PH，RREQ 的 available 依次为 "
  f"{t['rreq_steps'][1]}、{t['rreq_steps'][2]}。整个过程不需要 AXI 事务。")
h3("R 通道背压")
fig("w_stall", "w_stall.png", "R 通道背压")
t = M["stall"]
p(f"① {ns(t['t1'])} RVALID = 1 而 RREADY = 0，r_locked 置位，RID、RDATA 保持；② {ns(t['t2'])} 握手完成后解除。")

# =====================================================================
h1n("附录 A　仿真使用说明")
p("以下命令在工程根目录执行，需要 Verilator 5、C++17 与 SystemC 2.3.4；全链路需要 reference/ucie-model，"
  "VCS 流程另需 VCS 与 Verdi。所有配置都通过 make 变量修改，修改后自动重新编译。")
h2("运行")
code("make -C sim run WIDTH=1024 RP=1                    # 独立环境：功能 + 短时吞吐（几秒）\n"
     "make -C sim negative WIDTH=1024 RP=1               # 异常注入\n"
     "make -C sim fl WIDTH=1024 RP=1                     # 全链路：延迟分解、12 个用例、满载吞吐（约 10 秒）\n"
     "make -C sim fl WIDTH=1024 TC=13,14,15              # 只跑满载读 / 写 / 读写同时\n"
     "make -C sim run WIDTH=1024 HIF_DRAM_W=64 HIF_LPR=32 # 改 MC 配置：512 位 HIF，LPR credit 32\n"
     "make -C sim run WIDTH=1024 MC_IF=ideal              # 满速 MC 模型，测桥 + 链路上限\n"
     "make -C sim check                                  # 全部独立回归")
h2("判断结果是否正确")
li("（1）仿真结束打印报告；出错时打印“RTL FAIL：原因”（独立环境）或“[FAIL] …”与末行“FAIL  N 处错误”（全链路），"
   "make 返回非零。没有这些字样、统计行中“数据错误 0”即为通过。")
li("（2）检查内容：每个 R 拍的数据、RESP、RLAST 与按 AXI 写入维护的参考存储逐字节比对；链路上每条消息与参考编码逐字节比对；"
   "HIF 控制器模型每拍检查桥是否违反 HIF 约定（超 credit、token 或指针重复、拍数不符等），违反时打印“HIF MODEL ERROR”。")
li("（3）make -C sim checker-negative 故意篡改期望数据，用来确认上述检查确实会报错。")
h2("查看性能")
p("报告中的“延迟”行给出单拍读写的分段延迟，“吞吐”行给出满载带宽，“指标”行给出带宽利用率与桥接延迟。"
  "例如 make -C sim fl WIDTH=1024 TC=13,14,15 的输出：")
code("延迟  单拍读  72 ns = SoC发送 6 + 链路 10 + 存储侧请求 8 + HIF 控制器 24 + 存储侧返回 8 + 链路 10 + SoC接收 6\n"
     "吞吐  读 16.00 GB/s（窗口波动 16.00～16.00）\n"
     "      写 16.00 GB/s ……\n"
     "指标  速率 24 GT/s | 带宽利用率 35.6%（受 16 GB/s HIF 数据口限制） | 桥延迟 SoC 侧 12 ns、存储侧 18 ns")
p("带宽未达预期时，先对照 8.2 节的各环节上限找出瓶颈，再看对应的深度、行数或 credit 参数是否足够（6.1、6.2 节）。")
h2("查看波形")
code("make -C sim run WIDTH=1024 ARGS=--trace           # 独立环境 VCD：sim/results/rtl_1024_rp1.vcd\n"
     "make -C sim fl-wave WIDTH=1024 TC=2               # 全链路 VCD 并用 GTKWave 打开\n"
     "make -C sim fl-vcs WIDTH=1024 TC=2 && make -C sim fl-verdi WIDTH=1024   # VCS + Verdi（FSDB）")
p("全链路波形中 tb_case 信号为当前用例编号（20 为空载延迟测量），RTL 在 fl_rtl_top 下，HIF 信号为 fl_rtl_top.hif_*。")

render(FIG_DIR, SPEC_DIR, OUT, ("AXI2FLIT 转接桥", "RTL 设计文档"), "设计说明 · 接口定义 · 性能与验证",
       [("版本", "V2.0"), ("日期", "2026 年 10 月")])
