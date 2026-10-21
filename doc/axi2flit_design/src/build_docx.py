"""生成《AXI2FLIT 转接桥 RTL 设计文档》docx。

用法：python3 build_docx.py <图片目录> <规范截图目录> <输出 docx>
"""
import re
import sys
from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

FIG_DIR, SPEC_DIR, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

# ---------------------------------------------------------------- 内容
# 每项为 (类型, ...)。正文中 {图:key} / {表:key} 在生成时替换为编号。
C = []
h1 = lambda t: C.append(("h1", t))
h2 = lambda t: C.append(("h2", t))
h3 = lambda t: C.append(("h3", t))
p = lambda t: C.append(("p", t))
li = lambda t: C.append(("li", t))
code = lambda t: C.append(("code", t))


def fig(key, file, cap, width=15.5, spec=False):
    C.append(("fig", key, file, cap, width, spec))


def tab(key, cap, head, rows, widths, note=None):
    C.append(("tab", key, cap, head, rows, widths, note))


# 1 概述 --------------------------------------------------------------
h1("概述")
h2("设计目标")
p("AXI2FLIT 转接桥用于 Chiplet 系统中 SoC 与定制堆叠存储器之间的协议转换。SoC 一侧通过 AXI4 总线访问存储，"
  "Die 间采用 UCIe 互联，链路上传输的是 AXI over UCIe（AoU）协议定义的流式 Flit。转接桥把 AXI 突发请求编码成 "
  "AoU 消息并装入 Flit；在存储侧把 Flit 还原为逐拍的存储控制器（MC）命令，再把 MC 的完成结果送回 AXI 的 R、B 通道。")
p("设计分为两端：SoC 侧的 axi2flit_soc 和存储侧的 flit2mc_target。两端共用同一套组帧、解帧和 credit 流控逻辑"
  "（aou_transport），只在应用侧接口上不同。主要参数和指标见{表:spec}。")
tab("spec", "主要设计参数与指标", ["项目", "规格"], [
    ["AXI 接口", "AXI4 从机；地址 64 位，ID 10 位，USER 16 位；数据位宽 256 / 512 / 1024 位可配"],
    ["突发类型", "INCR，1～256 拍；地址按 SIZE 对齐，不跨 4KB；支持窄访问和任意 WSTRB"],
    ["链路接口", "250B 协议层包（10B 协议头 + 240B 载荷），2000 位并行 ready/valid"],
    ["资源平面（RP）", "1～4 个，各 RP 有独立的消息队列和 credit"],
    ["存储侧接口", "每个 AXI beat 对应一条 MC 命令，带 tag，允许乱序完成"],
    ["处理能力", "发送、接收方向各每周期一条消息"],
    ["转换延迟", "空载、2ns 时钟下：SoC 侧发送 / 接收各 6ns，存储侧请求 / 返回各 8ns"],
    ["持续吞吐", "1024 位、48GB/s 链路：读 42.67GB/s，写 42.37GB/s，达到协议格式上限"],
], [3.2, 12.3])

h2("系统位置")
p("{图:system}给出转接桥在系统中的位置。axi2flit_soc 和 flit2mc_target 分别通过所在 Die 的 D2D Adapter 接入 "
  "UCIe 链路，桥与 Adapter 之间交换 250B 的协议层包，Flit 头、CRC 和链路重传由 Adapter 负责。flit2mc_target "
  "之后接存储控制器，DRAM 命令调度、bank 管理和 DFI 时序由 MC 完成。")
fig("system", "f_system.png", "转接桥在系统中的位置（粗框为本设计，灰色为外部模块）")

h2("适用范围与约束")
li("（1）只支持 INCR 突发。AxBURST 不在链路上传输，接收端一律按 INCR 处理；FIXED、WRAP 请求判为非法。")
li("（2）地址须按 2^AxSIZE 对齐，每拍字节数不超过总线宽度，整个突发不能跨越 4KB 边界。")
li("（3）AxLOCK 作为字段透传，桥内不实现独占访问监视。")
li("（4）全设计为单时钟域，链路侧不含跨时钟域逻辑；与 Adapter 处于不同时钟时需要在外部加异步 FIFO。")
li("（5）rst_n 为低有效异步复位。link_up 为链路就绪信号，拉低只暂停协议处理，不清除内部状态。")

h2("术语")
tab("terms", "术语", ["术语", "含义"], [
    ["Flit", "UCIe 链路层传输单位，256B。本文的“帧”指其中由协议层使用的 250B 部分（PLP）"],
    ["PH", "Protocol Header，PLP 的前 10 字节，包含消息起点位图和 credit 授信"],
    ["粒度（granule）", "5 字节，载荷和 credit 的计量单位；一帧载荷共 48 个粒度"],
    ["消息", "WREQ、RREQ、WDATA、RDATA、WRESP 等 AoU 协议对象。一帧可装多条消息，一条消息可跨两帧"],
    ["RP", "Resource Plane，资源平面。本设计由 AxQOS mod RP_COUNT 选取"],
    ["credit", "接收方预先授予发送方的接收容量，以粒度计"],
    ["beat", "AXI 数据通道上的一次握手传输"],
], [3.2, 12.3])

# 2 协议格式 ------------------------------------------------------------
h1("协议格式")
h2("Flit 与协议层包")
p("AoU 使用 UCIe 的 256B 延迟优化 Flit 格式，如{图:spec_flit}。256 字节中，FH B0、FH B1 为 Flit 头，C0、C1 "
  "共 4 字节为 CRC，由 D2D Adapter 生成和检查；其余 250 字节构成协议层包（PLP），包括 10 字节协议头 PH B0～B9 "
  "和 48 个 5 字节粒度 G0～G47。")
fig("spec_flit", "spec_flit.png", "256B Flit 中的协议层包布局（引自 AoU 规范 v0.8 Figure 4）", spec=True)
p("本设计的链路端口只处理 PLP，2000 位向量的位分配见{表:plp}。PH 字节和粒度在 256B Flit 中是交错存放的，"
  "这一重排连同 FH、CRC 的插入和去除都由 Adapter 完成。")
tab("plp", "PLP 向量位分配", ["位段", "内容"], [
    ["[1999:1920]", "PH B0～B9，B0 位于最高字节"],
    ["[1919:1880]", "G0"],
    ["[1879:1840]", "G1"],
    ["……", "依次排列"],
    ["[39:0]", "G47"],
], [4.0, 11.5])
p("消息内部同样高位在前：消息的第 0 字节放在消息向量的最高字节。AXI 数据中 data[7:0] 是最低地址字节，"
  "编码时按高字节 lane 在前的顺序放入消息，解码时做反变换。")

h2("协议头")
fig("spec_ph", "spec_ph.png", "协议头格式（引自 AoU 规范 v0.8 Figure 5）", spec=True)
p("协议头承载两类信息。MsgStart[47:0] 是消息起点位图，第 i 位为 1 表示第 i 个粒度开始一条新消息，"
  "跨帧消息的续片不置位。MsgCredit[15:0] 用来向对端归还接收容量，本设计的编码见{表:credit}。FDId 固定为 0，"
  "保留位必须为 0，接收端发现非零即报错。")
tab("credit", "MsgCredit 编码", ["位段", "含义"], [
    ["[15:14]", "本次授信所属的 RP"],
    ["[13:12]", "WRESP credit，2 位编码"],
    ["[11:9]", "RDATA credit，3 位编码"],
    ["[8:6]", "WDATA credit，3 位编码"],
    ["[5:3]", "RREQ credit，3 位编码"],
    ["[2:0]", "WREQ credit，3 位编码"],
], [4.0, 11.5])
p("3 位编码 0～7 依次对应 0、1、4、8、16、32、64、128 个粒度，2 位编码对应 0、1、4、8 个粒度。每帧 PH 只为一个 "
  "RP 授信，发送端从待归还量中选取不超过它的最大编码，剩余部分在后续帧中继续归还。")

h2("消息类型与长度")
tab("msgs", "消息类型与长度", ["类型码", "消息", "方向", "256 位", "512 位", "1024 位"], [
    ["1", "WREQ 写请求", "SoC→存储", "3（15B）", "3（15B）", "3（15B）"],
    ["2", "RREQ 读请求", "SoC→存储", "3（15B）", "3（15B）", "3（15B）"],
    ["3", "WDATA 写数据（含 WSTRB）", "SoC→存储", "8（40B）", "15（75B）", "30（150B）"],
    ["6", "WDATAFULL 全选通写数据", "SoC→存储", "7（35B）", "14（70B）", "27（135B）"],
    ["4", "RDATA 读数据", "存储→SoC", "8（40B）", "14（70B）", "27（135B）"],
    ["5", "WRESP 写响应", "存储→SoC", "1（5B）", "1（5B）", "1（5B）"],
    ["0", "Misc（CrdtGrant）", "双向", "2（10B）", "2（10B）", "2（10B）"],
], [1.5, 4.5, 2.3, 2.4, 2.4, 2.4], note="长度单位为粒度，括号内为字节数。")
p("一拍 W 数据如果全部字节都有效，发送端自动改用省略 WSTRB 的 WDATAFULL 格式，1024 位时每拍省 15B。"
  "两种写数据在接收端进入同一个队列。最长的消息是 1024 位带掩码写数据，30 个粒度，小于一帧的 48 个粒度，"
  "所以任何消息最多跨两帧。")

h2("消息字段")
p("{图:spec_wreq}～{图:spec_wresp}给出主要消息的字段布局，数据宽度以 256 位为例，512、1024 位只是数据字段加长。"
  "FLEX[15:0] 字段在本设计中承载 AXI 的 USER 信号：请求消息放 AxUSER，写数据放 WUSER，读数据放 RUSER，"
  "写响应放 BUSER。")
fig("spec_wreq", "spec_wreq.png", "WriteReq 字段（ReadReq 相同，引自 AoU 规范 v0.8 Figure 6）", spec=True)
fig("spec_wdata", "spec_wdata256.png", "WriteData 字段，256 位（引自 AoU 规范 v0.8 Figure 8）", spec=True)
fig("spec_rdata", "spec_rdata256.png", "ReadData 字段，256 位（引自 AoU 规范 v0.8 Figure 14）", spec=True)
fig("spec_wresp", "spec_wresp.png", "WriteResp 字段（引自 AoU 规范 v0.8 Figure 17）", spec=True)
p("请求消息中没有 BURST 字段，起始地址、AxLEN 和 AxSIZE 已足以恢复 INCR 突发。写数据也不带 WLAST，"
  "存储侧按 WREQ 的 LEN 计数确定突发边界。读数据每拍一条消息，RLAST 随消息传送。")

h2("打包规则")
fig("spec_pack", "spec_pack.png", "多条消息打包示例（引自 AoU 规范 v0.8 Figure 22）", spec=True)
p("一帧内的消息按粒度紧密排列，不同 RP、不同类型的消息可以混装，帧没填满也可以发出，空粒度内容没有意义。"
  "消息放不下时，剩余部分接在下一帧开头，下一帧不为续片置 MsgStart。{图:packing}是 1024 位连续读返回的情形："
  "每条 RDATA 27 个粒度，一笔 16 拍突发正好占满 9 帧。")
fig("packing", "f_packing.png", "跨帧消息示意（黑色三角为 MsgStart 置位处，数字为粒度数）", width=15.0)

# 3 总体设计 ------------------------------------------------------------
h1("总体设计")
h2("模块划分")
p("RTL 由 7 个文件组成，例化层次如{图:hierarchy}。aou_pkg 是 SystemVerilog 包，定义数据类型和编解码函数，"
  "各模块直接引用，不单独例化。各模块的功能见{表:modules}。")
fig("hierarchy", "f_hierarchy.png", "模块层次（灰底为 FIFO 实例，×RP 表示按资源平面数重复例化）", width=13.5)
tab("modules", "模块功能", ["模块", "功能"], [
    ["axi2flit_soc", "SoC 侧顶层：AXI4 从机接口、请求检查与编码、写数据路由、响应仲裁、同 ID 保序"],
    ["flit2mc_target", "存储侧顶层：消息还原为逐拍 MC 命令，重排缓冲接收乱序完成，生成 RDATA / WRESP"],
    ["aou_transport", "两端共用的传输层：组帧、解帧、消息检查与分类、接收队列、credit 计数"],
    ["aou_flit_tx", "组帧器：消息仲裁、跨帧续片、PH 授信编码"],
    ["aou_flit_rx", "解帧器：帧缓冲、消息起点扫描、跨帧拼接"],
    ["aou_sync_fifo", "同步 FIFO，深度任意，可选 FWFT"],
    ["aou_pkg", "类型定义，以及消息、PH、credit 相关的组合函数"],
], [3.2, 12.3])

h2("数据通路")
p("写操作：AW 握手后生成一条 WREQ，之后每个 W beat 生成一条 WDATA，两者进入所选 RP 的发送队列，由组帧器装帧发出。"
  "存储侧解帧后，WREQ 和 WDATA 进入各自的接收队列；请求选择逻辑每拍取一条 WDATA，结合 WREQ 中的地址生成一条写命令发给 "
  "MC。MC 对每条命令返回一次完成，最后一拍完成后合成一条 WRESP 发回 SoC 侧，变成 B 通道响应。")
p("读操作：一条 RREQ 在存储侧展开为 LEN+1 条读命令。MC 每完成一条，重排缓冲按命令发出顺序生成一条 RDATA，"
  "SoC 侧收到后逐条变成 R beat。")
p("两个方向都靠 credit 流控：只有对端事先授予了足够容量，发送端才会发出消息，所以接收队列不会溢出。credit 随反方向帧的 "
  "PH 归还；没有反向业务时，组帧器会发只含 PH 的帧。")

h2("时钟、复位与使能")
p("所有模块工作在同一个 clk 的上升沿，rst_n 为低有效异步复位。复位清除队列指针、计数器、在途表和错误标志，"
  "存储阵列内容不复位。复位后 credit 计数恢复初值：每个接收队列按“深度 × 该类消息最短长度”计入待归还量，"
  "link_up 拉高后由组帧器通过 PH 逐步通告对端。")
p("link_up 为低时，两端不接收 AXI 请求，也不收发帧。一旦检测到协议错误，错误标志保持，模块停止处理，"
  "只能由两端协同复位恢复。")

# 4 模块设计 ------------------------------------------------------------
h1("模块设计")
P_NOTE = "方向 I 为输入，O 为输出。"
h2("axi2flit_soc")
h3("参数")
tab("soc_par", "axi2flit_soc 参数", ["参数", "默认值", "说明"], [
    ["DATA_WIDTH", "256", "AXI 数据位宽，256 / 512 / 1024"],
    ["RP_COUNT", "1", "资源平面数，1～4"],
    ["TX_DEPTH", "8", "每个 RP 的 WREQ、RREQ、WDATA 发送队列深度"],
    ["RX_DEPTH", "32", "每个 RP 的 RDATA、WRESP 接收队列深度"],
], [3.2, 2.0, 10.3])
h3("接口")
tab("soc_io", "axi2flit_soc 端口", ["信号", "方向", "位宽", "说明"], [
    ["clk", "I", "1", "时钟"],
    ["rst_n", "I", "1", "异步复位，低有效"],
    ["link_up", "I", "1", "链路就绪"],
    ["s_axi_awvalid / awready", "I / O", "1", "写地址握手"],
    ["s_axi_awaddr", "I", "64", "写起始地址"],
    ["s_axi_awid", "I", "10", "写事务 ID"],
    ["s_axi_awlen", "I", "8", "突发拍数减 1"],
    ["s_axi_awsize", "I", "3", "每拍字节数 = 2^SIZE"],
    ["s_axi_awburst", "I", "2", "只接受 INCR（2'b01）"],
    ["s_axi_awprot / awcache", "I", "3 / 4", "透传"],
    ["s_axi_awqos", "I", "4", "透传；同时用于选择 RP（QOS mod RP_COUNT）"],
    ["s_axi_awlock", "I", "1", "透传"],
    ["s_axi_awuser", "I", "16", "透传"],
    ["s_axi_wvalid / wready", "I / O", "1", "写数据握手"],
    ["s_axi_wdata", "I", "DATA_WIDTH", "写数据"],
    ["s_axi_wstrb", "I", "DATA_WIDTH/8", "字节选通"],
    ["s_axi_wlast", "I", "1", "末拍标志，须与 AWLEN 一致"],
    ["s_axi_wuser", "I", "16", "透传"],
    ["s_axi_ar*", "I / O", "同 AW", "读地址通道，信号与写地址通道一一对应"],
    ["s_axi_bvalid / bready", "O / I", "1", "写响应握手"],
    ["s_axi_bid / bresp / buser", "O", "10 / 2 / 16", "写响应字段"],
    ["s_axi_rvalid / rready", "O / I", "1", "读数据握手"],
    ["s_axi_rdata", "O", "DATA_WIDTH", "读数据"],
    ["s_axi_rid / rresp / rlast / ruser", "O", "10 / 2 / 1 / 16", "读数据字段"],
    ["flit_tx_valid / flit_tx_ready", "O / I", "1", "发送帧握手"],
    ["flit_tx_data", "O", "2000", "发送 PLP"],
    ["flit_rx_valid / flit_rx_ready", "I / O", "1", "接收帧握手"],
    ["flit_rx_data", "I", "2000", "接收 PLP"],
    ["protocol_error", "O", "1", "协议错误，保持到复位"],
], [4.6, 1.4, 2.6, 6.9], note=P_NOTE)
h3("微架构")
fig("soc", "f_soc.png", "axi2flit_soc 微架构（实线为数据，蓝色虚线为控制，层叠框表示每个 RP 一份）")
p("请求方向分三路。AW、AR 先经合法性检查：SIZE 不超过总线宽度、地址对齐、不跨 4KB，并且 BURST 为 INCR。"
  "通过后由 make_req 编码成 15B 请求消息，写入由 QOS 选定的 RP 发送队列。")
p("AW 握手的同时把 {RP, AWLEN} 写入写路由 FIFO（深度 TX_DEPTH×RP_COUNT，宽 10 位）。W 通道不带 ID，"
  "每个 W beat 属于哪笔写由路由 FIFO 队首决定；w_index 对当前突发的 beat 计数，WLAST 与 “w_index == AWLEN” "
  "不一致即判为错误。最后一拍 W 握手后路由项出队。路由 FIFO 为空时 WREADY 为低，所以 W 先于 AW 到达时桥会等待。")
p("响应方向，aou_transport 把收到的 RDATA、WRESP 放进每个 RP 的接收队列。R、B 通道各有一个轮询选择器，"
  "在有数据的 RP 之间轮转。VALID 已拉高而 READY 为低时，锁定寄存器（r_locked / b_locked）记住当前 RP，"
  "保证等待期间输出不变。")
p("ID 在途表为每个 AXI ID 分别保存读、写的未完成计数（16 位）和所属 RP。同一 ID 还有未完成事务时，新请求必须落在同一个 "
  "RP，否则 AWREADY / ARREADY 拉低，直到旧事务完成，这样同 ID 的响应不会因为分属不同 RP 而乱序。收到的 R / B 如果 ID "
  "没有在途事务或 RP 不符，不交给主机，并置 protocol_error。")

h2("flit2mc_target")
h3("参数")
tab("tgt_par", "flit2mc_target 参数", ["参数", "默认值", "说明"], [
    ["DATA_WIDTH", "256", "数据位宽，须与 SoC 侧一致"],
    ["RP_COUNT", "1", "资源平面数，须与 SoC 侧一致"],
    ["REQUEST_DEPTH", "4", "每个 RP 的 WREQ、RREQ 接收队列深度"],
    ["WDATA_DEPTH", "32", "每个 RP 的 WDATA 接收队列深度"],
    ["RESPONSE_DEPTH", "8", "每个 RP 的 RDATA、WRESP 发送队列深度"],
    ["MC_SLOTS", "16", "重排缓冲项数，即 MC 最大在途命令数"],
    ["TAG_WIDTH", "log2(MC_SLOTS)", "tag 位宽，自动计算"],
], [3.2, 2.6, 9.7])
h3("接口")
tab("tgt_io", "flit2mc_target 端口", ["信号", "方向", "位宽", "说明"], [
    ["clk / rst_n / link_up", "I", "1", "同 axi2flit_soc"],
    ["flit_rx_valid / flit_rx_ready", "I / O", "1", "接收帧握手"],
    ["flit_rx_data", "I", "2000", "接收 PLP"],
    ["flit_tx_valid / flit_tx_ready", "O / I", "1", "发送帧握手"],
    ["flit_tx_data", "O", "2000", "发送 PLP"],
    ["mc_req_valid / mc_req_ready", "O / I", "1", "命令握手"],
    ["mc_req_write", "O", "1", "1 为写，0 为读"],
    ["mc_req_tag", "O", "TAG_WIDTH", "命令编号，完成时原样返回"],
    ["mc_req_rp / mc_req_id", "O", "2 / 10", "所属 RP、AXI ID"],
    ["mc_req_addr", "O", "64", "本拍字节地址 = 起始地址 + beat × 2^SIZE"],
    ["mc_req_size", "O", "3", "本拍访问大小"],
    ["mc_req_len / mc_req_beat", "O", "8 / 8", "突发拍数减 1、当前拍序号"],
    ["mc_req_first / mc_req_last", "O", "1", "突发首拍、末拍"],
    ["mc_req_prot / cache / qos / lock", "O", "3 / 4 / 4 / 1", "请求属性，透传"],
    ["mc_req_auser / mc_req_wuser", "O", "16 / 16", "请求 USER、写数据 USER"],
    ["mc_req_wdata", "O", "DATA_WIDTH", "写数据，保持 AXI lane 位置"],
    ["mc_req_wstrb", "O", "DATA_WIDTH/8", "字节选通"],
    ["mc_rsp_valid / mc_rsp_ready", "I / O", "1", "完成握手"],
    ["mc_rsp_tag", "I", "TAG_WIDTH", "对应命令的 tag"],
    ["mc_rsp_rdata", "I", "DATA_WIDTH", "读数据，写命令时忽略"],
    ["mc_rsp_resp", "I", "2", "完成状态，编码同 AXI RESP"],
    ["protocol_error", "O", "1", "协议错误，保持到复位"],
], [4.6, 1.4, 2.6, 6.9], note=P_NOTE)
p("MC 侧需要遵守两条约定：每条命令必须返回且只返回一次完成，写命令也不例外，完成顺序不限；"
  "mc_req_valid 等待 ready 期间命令内容保持不变。")
h3("微架构")
fig("target", "f_target.png", "flit2mc_target 微架构")
p("请求选择在 RP×2 个候选之间轮转：每个 RP 有一个读候选（RREQ 队列非空）和一个写候选（WREQ 与 WDATA 队列都非空）。"
  "命令被 MC 背压时选择结果锁定，不会换成别的请求。每个 RP 各有读、写 beat 计数器，命令地址按 "
  "addr + (beat << SIZE) 计算。写命令每拍消耗一条 WDATA，到最后一拍（beat == LEN）才弹出对应的 WREQ 或 RREQ。")
p("重排缓冲（ROB）是 MC_SLOTS 项的环形表。命令发出时在 tail 处分配一项，项号就是 tag。MC 的完成按 tag 写回数据和状态，"
  "顺序任意；退休只发生在 head，因此读数据按命令发出顺序返回。读命令退休时生成一条 RDATA（带 RLAST）；写命令的非末拍退休时，"
  "只把状态并入该 RP 的写状态寄存器（保留更严重的 RESP），末拍退休时生成 WRESP。ROB 满时 mc_req_valid 拉低。"
  "tag 越界、对空项或已完成项再次返回完成，都会置 protocol_error。")
p("这样，一笔 AXI 突发对应 LEN+1 条 MC 命令；读返回 LEN+1 条 RDATA，写只返回一条 WRESP。")

h2("aou_transport")
h3("参数与接口")
tab("tr_par", "aou_transport 参数", ["参数", "默认值", "说明"], [
    ["DATA_WIDTH / RP_COUNT", "256 / 1", "同顶层"],
    ["RX_DEPTH0～RX_DEPTH4", "0, 0, 0, 32, 32", "依次为 WREQ、RREQ、WDATA、RDATA、WRESP 每个 RP 的接收队列深度，0 表示不接收该类"],
], [4.2, 2.8, 8.5])
p("SoC 侧启用 RDATA、WRESP 两类接收，存储侧启用 WREQ、RREQ、WDATA 三类。")
tab("tr_io", "aou_transport 端口", ["信号", "方向", "位宽", "说明"], [
    ["clk / rst_n / link_up", "I", "1", "时钟、复位、链路就绪"],
    ["tx_valid / tx_ready", "I / O", "[RP][5]", "待发送消息握手"],
    ["tx_data", "I", "[RP][5] × 1200", "待发送消息"],
    ["rx_valid / rx_ready", "O / I", "[RP][5]", "已接收消息握手"],
    ["rx_data", "O", "[RP][5] × 1200", "已接收消息"],
    ["flit_tx_*", "O / I", "1 / 1 / 2000", "发送帧"],
    ["flit_rx_*", "I / O", "1 / 1 / 2000", "接收帧"],
    ["fault", "O", "1", "传输层或解帧错误"],
], [4.0, 1.6, 3.2, 6.7], note=P_NOTE)
p("消息接口按 [RP][类型] 组织，类型下标 0～4 依次是 WREQ、RREQ、WDATA、RDATA、WRESP。消息统一用 1200 位向量传递，"
  "短消息放在高位，低位补零。")
h3("微架构")
fig("transport", "f_transport.png", "aou_transport 微架构（编号对应 credit 计数的更新来源）")
p("解帧器输出的每条消息先经过检查：RP 小于 RP_COUNT，本端启用了该类接收，长度合法；请求消息的保留位为 0 且地址合法；"
  "数据消息的 DLENGTH 与本端位宽一致。合法的业务消息写入对应 [RP][类型] 的接收队列；CrdtGrant 只更新 credit，不入队。"
  "检查不通过即置 fault。")
p("credit 计数按 RP 和消息类型各一组，共三张表，每项 12 位。各表的更新关系如下，括号内为{图:transport}中的编号：")
code("available_next = available + 收到的授信 − 本拍发送消耗      （①、②）\n"
     "pending_next   = pending   + 上层取走后释放 − 本拍 PH 授出  （④、②）\n"
     "promised_next  = promised  + 本拍 PH 授出 − 本拍收到的消息  （②、③）")
p("available 是对端允许本端发送的量，组帧器只在 available 不小于消息长度时才选这条消息。pending 是本端已经空出、"
  "还没告诉对端的容量。promised 是已经告诉对端、对应消息还没到的容量，用来发现对端超发。任何计数越界（小于 0 或超过上限）"
  "都判为协议错误，计数不做饱和。")
p("写数据有带掩码和全选通两种长度，而接收队列按条数分配，所以 WDATA 的初始授信按较短的全选通长度计算，"
  "保证队列不会按条数溢出。")

h2("aou_flit_tx")
tab("tx_io", "aou_flit_tx 端口", ["信号", "方向", "位宽", "说明"], [
    ["RP_COUNT", "参数", "—", "资源平面数"],
    ["clk / rst_n / enable", "I", "1", "时钟、复位、组帧使能"],
    ["msg_valid / msg_ready", "I / O", "[RP] × 5", "每类消息独立握手"],
    ["msg_data", "I", "[RP][5] × 1200", "候选消息"],
    ["available", "I", "[RP][5] × 12", "对端授予的可发量"],
    ["pending", "I", "[RP][5] × 12", "本端待归还量"],
    ["consumed", "O", "[RP][5] × 8", "本拍发送消耗的粒度数"],
    ["granted", "O", "[RP][5] × 8", "本拍 PH 授出的粒度数"],
    ["flit_valid / flit_ready", "O / I", "1", "帧握手"],
    ["flit_data", "O", "2000", "PLP 输出"],
], [4.0, 1.6, 3.2, 6.7], note=P_NOTE)
fig("tx", "f_tx.png", "aou_flit_tx 微架构")
p("组帧器每拍最多接受一条新消息。轮询仲裁器从上次选中位置的下一个开始，在 RP×5 个候选里找第一个 VALID 有效且 "
  "available 足够的消息，整条消息的 credit 在被接受时一次扣除。仲裁只看寄存器中的 available，本拍收到的授信下一拍才生效，"
  "避免组合反馈。")
p("在建帧由 payload（48 个粒度）、starts（起点位图）和 used（已用粒度数）三个寄存器组成。选中的消息从 used 位置开始写入，"
  "放不下的部分存进 spill 寄存器；下一帧开始时先写续片，同一拍还可以接着追加新消息。")
p("满足以下任一条件时提交当前帧：帧已满；帧非空但本拍没有追加消息；帧为空但有待归还的 credit（此时发只含 PH 的帧）。"
  "第二条保证低负载时请求不会一直等着凑满帧，最多多等一拍。提交时从有待归还量的 RP 中轮流选一个，把它五类 credit 的编码写进 "
  "PH。输出寄存器被背压时保持不变，在建帧仍可继续装填。")

h2("aou_flit_rx")
tab("rx_io", "aou_flit_rx 端口", ["信号", "方向", "位宽", "说明"], [
    ["FRAME_DEPTH", "参数", "—", "帧 FIFO 深度，默认 2，不小于 2"],
    ["clk / rst_n / enable", "I", "1", "时钟、复位、解帧使能"],
    ["flit_valid / flit_ready", "I / O", "1", "帧握手"],
    ["flit_data", "I", "2000", "PLP 输入"],
    ["msg_valid / msg_ready", "O / I", "1", "消息握手"],
    ["msg_data", "O", "1200", "完整消息"],
    ["header_valid", "O", "1", "本拍收到合法 PH"],
    ["header_credit", "O", "16", "PH 中的 MsgCredit"],
    ["fault", "O", "1", "解帧错误"],
], [4.0, 1.6, 3.2, 6.7], note=P_NOTE)
fig("rx", "f_rx.png", "aou_flit_rx 微架构（红色虚线为错误检测）")
p("帧进入时先检查 PH 保留位，合法帧写入帧 FIFO，同时通过 header_valid / header_credit 把 MsgCredit 交给 transport。"
  "授信只在帧进入时处理一次，帧在内部出队不会重复计入。")
p("解析器同时看 FIFO 中的当前帧和下一帧。cursor 记录当前帧已解析到的粒度位置，扫描逻辑从 cursor 开始找第一个 MsgStart "
  "置位的粒度，由消息首字节解出长度，再由拼接选择器从当前帧（必要时连同下一帧开头）取出完整消息，写入输出寄存器。"
  "消息跨帧而下一帧还没到时，解析器等待，不会输出半条消息。消息恰好用完当前帧，或当前帧中再找不到起点时，当前帧出队，"
  "cursor 换算成下一帧中的位置。")
p("消息覆盖的范围内如果又出现 MsgStart，或者长度编码非法，解析器置 fault 并停止。帧 FIFO 满时，只要本拍有帧出队，"
  "仍可同时接收新帧。稳态下每拍输出一条完整消息，跨帧消息也只占一拍。")

h2("aou_sync_fifo")
tab("fifo_io", "aou_sync_fifo 端口", ["信号", "方向", "位宽", "说明"], [
    ["WIDTH / DEPTH / FWFT", "参数", "—", "默认 32 / 8 / 0"],
    ["clk / rst_n", "I", "1", "时钟、异步复位"],
    ["s_valid / s_ready", "I / O", "1", "写入握手"],
    ["s_data", "I", "WIDTH", "写入数据"],
    ["m_valid / m_ready", "O / I", "1", "读出握手"],
    ["m_data", "O", "WIDTH", "队首数据"],
    ["level", "O", "log2(DEPTH+1)", "当前占用项数"],
], [4.0, 1.6, 3.2, 6.7], note=P_NOTE)
fig("fifo", "f_fifo.png", "aou_sync_fifo 微架构")
p("存储阵列配读、写指针，指针到 DEPTH−1 后回到 0，所以深度可以是 1 或非 2 的幂。队列满时，如果同一拍有出队，仍可入队。"
  "FWFT=1 时，空队列可以把输入直接送到输出，同拍握手不占存储；桥内所有实例都用 FWFT=0，数据入队后下一拍才出现在输出端，"
  "以切断 valid/ready 之间的组合路径。")

h2("aou_pkg")
tab("pkg", "aou_pkg 主要函数", ["函数", "作用"], [
    ["msg_kind / msg_rp / granules", "由消息首字节得到队列类型、RP 和长度"],
    ["make_req / get_req / legal_req", "请求消息编解码及合法性检查"],
    ["make_wdata / make_rdata / make_b", "生成写数据、读数据、写响应消息"],
    ["get_data / get_strb", "从数据消息中取出数据和选通"],
    ["make_flit / get_starts / legal_ph", "PLP 组装、MsgStart 提取、PH 检查"],
    ["min_granules / credit_amount / credit_encode", "credit 初值计算和编码"],
], [6.0, 9.5])
p("这些函数都是组合逻辑，在调用处展开，不引入额外的流水级。")

# 5 流控与异常 ----------------------------------------------------------
h1("流控、缓冲与异常处理")
h2("credit 闭环")
fig("loop", "f_credit_loop.png", "credit 闭环", width=14.5)
p("一份接收容量的周转过程如{图:loop}：① 发送端扣减 available 后发出消息；② 消息到达接收端，进入接收 FIFO；"
  "③ 上层取走消息，空出的容量计入 pending；④ pending 随反方向帧的 PH 归还，发送端 available 增加。"
  "从①开始到④完成所用的时间记为 credit 周转时间 T_reuse。要让某类消息以速率 λ 持续发送，接收队列深度至少为：")
code("N_slots ≥ ceil(λ × T_reuse) + N_margin")
p("以 1024 位读返回为例：链路上限 42.67GB/s，每条 RDATA 带 128B 数据，λ ≈ 0.333 条/ns；取 T_reuse = 64ns"
  "（32 个周期），余量 2 条，需要 24 项。默认 RX_DEPTH = 32（864 个粒度），满足要求。不同 RP 的 credit 相互独立，"
  "不能互借。所有深度还须满足“深度 × 最短消息粒度数 ≤ 4095”，即不超出 12 位计数范围。")

h2("背压")
p("所有接口都使用 ready/valid 握手，VALID 拉高后，在握手完成前数据保持不变。下游停顿时，背压沿队列逐级上传：例如 MC "
  "不接收命令时，存储侧接收队列逐渐填满，credit 停止归还，SoC 侧组帧器因 available 不足而停发，最终 AXI 的 READY 拉低。"
  "停顿解除后传输自动恢复，不丢数据。")

h2("异常处理")
tab("errs", "异常检测", ["检测位置", "条件", "处理"], [
    ["axi2flit_soc", "非 INCR、地址未对齐、SIZE 超过总线宽度、跨 4KB", "置 protocol_error，不生成消息"],
    ["axi2flit_soc", "WLAST 与 AWLEN 不一致", "置 protocol_error"],
    ["axi2flit_soc", "R / B 的 ID 无在途事务或 RP 不符", "不交给主机，置 protocol_error"],
    ["aou_flit_rx", "PH 保留位非零、长度编码非法、起点重叠", "置 fault，停止接收"],
    ["aou_transport", "未知类型、RP 越界、DLENGTH 与位宽不符、请求非法", "置 fault"],
    ["aou_transport", "credit 计数越界（对端超发或重复授信）", "置 fault"],
    ["flit2mc_target", "mc_rsp_tag 越界，或对空项、已完成项再次返回", "置 protocol_error"],
], [3.0, 7.5, 5.0])
p("错误标志置位后保持到复位。桥不会对非法请求自动回 SLVERR 或 DECERR；系统应把 protocol_error 接到中断或状态寄存器，"
  "由软件组织两端复位。MC 返回的 SLVERR 等错误状态属于正常响应，会原样送回 AXI 主机。")

# 6 验证 ----------------------------------------------------------------
h1("验证")
h2("验证环境")
p("验证使用 Verilator 5.052 把 RTL 编译成 C++ 模型，测试平台用 C++17 编写，消息编码参考库链接 SystemC 2.3.4。"
  "相关文件见{表:tbfiles}。")
tab("tbfiles", "验证文件", ["文件", "内容"], [
    ["sim/tb/tb_rtl_bridge.sv", "系统级测试顶层：例化 axi2flit_soc、flit2mc_target 和两个有限深度的链路 FIFO；握手保持 SVA 断言；错误注入通道"],
    ["sim/tb/tb_rtl_bridge.cpp", "AXI 激励、MC 字节存储模型（可配延迟与乱序返回）、记分板、性能统计"],
    ["sim/tb/tb_flit_codec.sv / .cpp", "aou_flit_tx、aou_flit_rx 单元测试"],
    ["sim/tb/tb_fifo.cpp", "aou_sync_fifo 单元测试"],
    ["sim/tb/bridge_test_config.h", "性能场景参数"],
    ["sim/Makefile", "编译与回归入口"],
], [4.8, 10.7])
fig("tb", "f_tb.png", "系统级验证环境")
p("系统级测试把两端桥背靠背连接，中间的链路 FIFO 可以按设定带宽限速，也可以插入停顿。记分板独立维护一份按 AXI 握手更新的字节存储，"
  "读数据逐字节比对；链路上的每条消息都与参考编码库生成的字节逐一比较；MC 收到的每条命令也单独核对地址、数据和选通。"
  "判断只依据接口握手，不读取 DUT 内部状态。")

h2("测试项与步骤")
tab("tests", "测试项", ["编号", "测试项", "被测模块", "命令（在工程根目录执行）", "内容与判据"], [
    ["T1", "FIFO 单元", "aou_sync_fifo", "make -C sim fifo-all",
     "深度 1 / 3 / 8 × FWFT 0 / 1 共 6 组；随机出入队与 std::deque 参考比对，覆盖满时同拍替换、空旁路、指针回绕"],
    ["T2", "编解码单元", "aou_flit_tx\naou_flit_rx", "make -C sim codec-all",
     "3 种位宽 × 6 种消息 × 有 / 无停顿，另加 1024 位 FRAME_DEPTH=3；TX 输出与参考字节比对，参考帧送入 RX 比对输出；无停顿时 96 条消息须在 96 周期内完成；另有延迟续帧、起点重叠、半条消息时复位 4 项边界测试"],
    ["T3", "静态检查", "两个顶层", "make -C sim lint", "Verilator lint 无告警"],
    ["T4", "系统功能", "全部", "make -C sim run WIDTH=… RP=…", "见下文步骤"],
    ["T5", "异常注入", "全部", "make -C sim negative", "11 类非法输入，要求指定一端在 100 周期内置错误"],
    ["T6", "记分板自检", "测试平台", "make -C sim checker-negative", "篡改期望读数据，测试须以数据不一致失败"],
    ["T7", "吞吐", "全部", "make -C sim perf-all\nmake -C sim scenario …", "持续读、写吞吐，见第 7 章"],
], [1.1, 1.9, 2.4, 4.2, 5.9])
p("T3～T5 由 make -C sim test-all 在 256 / 512 / 1024 位 × RP = 1 / 2 / 4 共 9 种配置下执行；make -C sim check "
  "一次运行 T1～T7。")
p("T4 系统功能测试的步骤如下（tb_rtl_bridge.cpp 中的 functional 函数）：")
li("（1）空载单拍：两次单拍读、一次单拍写，记录各段转换延迟，要求每端合计不超过 20ns。")
li("（2）突发与掩码：2、4、16 拍以及一整个 4KB 页的突发写后读；部分选通、全零选通；SIZE=2 的 16 拍和 256 拍窄访问。")
li("（3）错误响应：访问超出存储模型范围的地址、LOCK 访问、突发中间某拍返回错误，检查 RESP 正确回传。")
li("（4）并发与乱序：4 笔分属不同 RP 的写突发同时在途，MC 乱序完成；同一 ID 连续三笔读；读写交错。")
li("（5）长时间背压：分别拉低 AXI READY 400 周期、MC ready 60 周期、链路 60 周期，然后排空并检查数据。")
li("（6）同 ID 跨 RP（RP>1 时）：前一笔未完成时向另一 RP 发同 ID 请求，确认 60 周期内一直被背压。")
li("（7）在途复位：读事务未完成时两端协同复位，复位后重新授信并完成新的读写。")
p("通过条件：所有数据和响应字段与参考一致；全部事务完成、队列排空；SVA 断言无失败；跨帧消息数、MC 乱序次数、"
  "停顿周期数三项统计均大于零，确保压力场景确实发生。")
p("T5 的 11 类异常注入见{表:neg}。")
tab("neg", "异常注入用例", ["用例", "注入方式", "期望报错端"], [
    ["aw_fixed", "AW 发 FIXED 突发", "SoC 侧"],
    ["ar_4k", "AR 突发跨 4KB", "SoC 侧"],
    ["unaligned", "地址未按 SIZE 对齐", "SoC 侧"],
    ["size", "SIZE 超过总线宽度（1024 位不适用）", "SoC 侧"],
    ["wlast", "2 拍突发的第 1 拍给出 WLAST", "SoC 侧"],
    ["unsolicited_r", "向 SoC 侧注入无对应请求的 RDATA", "SoC 侧"],
    ["bad_ph", "PH 保留位非零", "存储侧"],
    ["bad_length", "消息长度编码非法", "存储侧"],
    ["overlap", "消息范围内出现第二个 MsgStart", "存储侧"],
    ["bad_mc_tag", "MC 返回未分配的 tag", "存储侧"],
    ["credit_overflow", "反复授信使 credit 计数越界", "存储侧"],
], [3.2, 8.8, 3.5])

h2("测试结果")
p("在 Verilator 5.052 下运行 make -C sim check，全部测试项通过，汇总见{表:summary}。")
tab("summary", "回归结果汇总", ["测试项", "规模", "结果"], [
    ["T1 FIFO 单元", "6 组", "通过"],
    ["T2 编解码单元", "48 组 + 4 项边界", "通过"],
    ["T3 静态检查", "9 配置 × 2 个顶层", "通过"],
    ["T4 系统功能", "9 配置", "通过"],
    ["T4 在途复位", "9 配置", "通过"],
    ["T5 异常注入", "96 项（256、512 位每配置 11 项，1024 位 10 项）", "通过"],
    ["T6 记分板自检", "1 项", "按预期检出数据错误"],
    ["T7 吞吐", "3 种位宽 + 满载 + 理想", "1024 位满载通过 90% 门限"],
], [3.8, 7.2, 4.5])
p("{表:fifo_res}是 FIFO 单元测试的统计。深度 1 时几乎每次入队都发生在满状态，同拍替换路径得到充分覆盖。")
tab("fifo_res", "FIFO 单元测试统计", ["DEPTH", "FWFT", "入队次数", "出队次数", "满时同拍替换", "空队列旁路"], [
    ["1", "0", "4224", "4224", "3092", "0"],
    ["3", "0", "4453", "4452", "106", "0"],
    ["8", "0", "4458", "4457", "106", "0"],
    ["1", "1", "4405", "4405", "827", "3081"],
    ["3", "1", "4453", "4452", "106", "2938"],
    ["8", "1", "4458", "4457", "106", "2911"],
], [1.8, 1.8, 2.8, 2.8, 3.2, 3.1])
p("{表:codec_res}是 1024 位编解码单元测试的结果。无停顿时 TX、RX 处理 96 条消息都正好用 96 个周期，"
  "即每周期一条消息，跨帧不产生气泡；有停顿时的周期数包含了测试注入的停顿。")
tab("codec_res", "1024 位编解码单元测试", ["消息", "条数", "帧数", "TX 周期（无 / 有停顿）", "RX 周期（无 / 有停顿）"], [
    ["WREQ", "96", "6", "96 / 96", "96 / 176"],
    ["RREQ", "96", "6", "96 / 96", "96 / 176"],
    ["WDATAFULL", "96", "54", "96 / 131", "96 / 176"],
    ["RDATA", "96", "54", "96 / 131", "96 / 176"],
    ["WRESP", "96", "2", "96 / 96", "96 / 176"],
    ["WDATA（带掩码）", "96", "60", "96 / 141", "96 / 171"],
], [3.3, 1.6, 1.6, 4.5, 4.5])
p("{表:func_res}是系统功能测试在 9 种配置下的统计，每种配置运行一次。")
tab("func_res", "系统功能测试统计", ["位宽", "RP", "AW", "AR", "MC 命令", "逐字节核对消息", "跨帧消息", "MC 乱序", "停顿周期"], [
    ["256", "1", "17", "23", "1399", "1456", "75", "276", "906"],
    ["256", "2", "17", "25", "1407", "1466", "75", "278", "957"],
    ["256", "4", "17", "25", "1407", "1466", "75", "278", "957"],
    ["512", "1", "17", "23", "1271", "1328", "280", "276", "916"],
    ["512", "2", "17", "25", "1279", "1338", "280", "278", "961"],
    ["512", "4", "17", "25", "1279", "1338", "280", "278", "963"],
    ["1024", "1", "17", "23", "1207", "1264", "596", "280", "909"],
    ["1024", "2", "17", "25", "1215", "1274", "599", "284", "945"],
    ["1024", "4", "17", "25", "1215", "1274", "599", "284", "945"],
], [1.3, 1.0, 1.1, 1.1, 1.9, 2.8, 2.0, 1.9, 2.4])

h2("波形分析")
p("以下波形取自 1024 位、RP=1 的系统功能测试，时钟周期 2ns，竖向细线为时钟上升沿，蓝色虚线标出正文引用的时刻。")
h3("单拍读")
fig("w_read", "w_read.png", "单拍读波形")
p("① 176ns AR 握手；② 182ns 含 RREQ 的帧离开 SoC 侧；③ 190ns 存储侧向 MC 发出读命令；④ 194ns MC 返回完成；"
  "⑤ 204ns 含 RDATA 的帧进入 SoC 侧；⑥ 210ns R 通道握手，RLAST=1。SoC 侧发送、接收各用 6ns。SoC flit_rx_valid 的第一段是存储侧归还 credit 的帧，"
  "第二段才携带 RDATA。AR 到 R 共 34ns，其中包括测试平台链路 FIFO 和 MC 模型的时间。")
h3("单拍写")
fig("w_write", "w_write.png", "单拍写波形")
p("① 212ns AW 握手；② 214ns W 握手，WLAST=1；③ 220ns 含 WDATA 的帧发出；④ 230ns 存储侧发出写命令"
  "（mc_req_write=1）；⑤ 250ns B 通道握手。WREQ 和 WDATA 是两条独立消息，存储侧等两者都到齐才发命令。")
h3("组帧")
fig("w_tx", "w_tx.png", "16 拍全选通写突发的组帧波形")
p("每拍一条 27 粒度的 WDATAFULL，“WDATA 出队”持续为高，说明组帧器每周期都接受一条消息。帧内已有 WREQ（3）和一条 WDATA"
  "（27）后，used=30，下一条只能放下 18 个粒度：① 466ns 该帧提交，spill_offset=18 记录已放入的部分；② 468ns 新帧先写入剩余的 "
  "9 个粒度，再接上下一条消息，used=36。帧提交的节奏随消息长度与 48 的关系变化，但消息接受没有中断。")
h3("解帧")
fig("w_rx", "w_rx.png", "连续读返回的解帧波形")
p("每条 RDATA 27 个粒度。① 560ns 输出第一条消息，cursor 前进到 27；下一条从第 27 粒度开始，需要跨到下一帧。下一帧到达后"
  "（frame_count=2），② 564ns 拼接完成并输出，cursor=6，即新帧中被续片占用的粒度数。此后 msg_valid 持续为高，"
  "每拍输出一条完整消息。")
h3("credit 初始化")
fig("w_credit", "w_credit.png", "复位后的 credit 初始化波形")
p("复位释放后 SoC 侧 RDATA 的 pending 为 32 × 27 = 864。① 16ns link_up 之后组帧器开始发只含 PH 的帧，每帧授出 128 个粒度，"
  "pending 递减、promised 递增，30ns 时全部授出。② 20ns 收到存储侧的 PH，RREQ 的 available 从 0 变为 8，随后为 12"
  "（存储侧 REQUEST_DEPTH 4 × 3 粒度），读请求从此具备发送条件。整个过程不需要任何 AXI 事务。")
h3("R 通道背压")
fig("w_stall", "w_stall.png", "R 通道背压波形")
p("① 2972ns RVALID=1 而 RREADY=0，r_locked 置位，RID、RDATA 保持不变；② 2980ns RREADY 恢复，握手完成后 r_locked 清除，"
  "后续 beat 每拍一条。")

# 7 性能 ----------------------------------------------------------------
h1("性能分析")
h2("转换延迟")
p("转换延迟以接口握手时刻计算，不用 VALID 首次拉高的时刻。四段的定义如下：")
code("SoC 发送    = 请求消息所在帧离开 SoC 侧 − AR 握手（写操作取最后一个 W 握手）\n"
     "SoC 接收    = R / B 握手 − 响应消息所在帧进入 SoC 侧\n"
     "存储侧请求  = MC 命令握手 − 所需消息全部进入存储侧（写取 WREQ、WDATA 中较晚者）\n"
     "存储侧返回  = 响应消息所在帧离开存储侧 − MC 完成握手")
fig("lat", "f_latency.png", "转换延迟的测量边界（虚线框为链路和 MC，不计入转换延迟）", width=15.0)
tab("lat_res", "空载单拍转换延迟（2ns 时钟）", ["位宽", "SoC 发送", "SoC 接收", "存储侧请求", "存储侧返回"], [
    ["256", "6ns", "6ns", "8ns", "8ns"],
    ["512", "6ns", "6ns", "8ns", "8ns"],
    ["1024", "6ns", "6ns", "8ns", "8ns"],
], [2.5, 3.25, 3.25, 3.25, 3.25], note="RP = 1、2、4 时结果相同。")
p("SoC 侧发送的 3 个周期依次是：消息写入发送队列、组帧器接受消息、帧提交到输出寄存器并完成握手。接收的 3 个周期是：帧写入帧 FIFO、"
  "解析出消息、经接收队列交给 AXI。")
p("SoC 侧发送加接收为 12ns，存储侧请求加返回为 16ns，各自都在 20ns 以内；两端四段相加为 28ns。以上为空载数据，"
  "出现排队、credit 不足或下游背压时延迟会增大。2ns 时钟周期是仿真设定，实际可达频率需由综合确认。")

h2("持续吞吐")
p("吞吐测试由 tb_rtl_bridge.cpp 的 performance 函数完成：读、写分开运行，16 拍全宽全选通突发，RP=1。链路 FIFO 按单向 48GB/s "
  "限速（x16、24GT/s），每帧按 256B 计。预热后统计测量窗口内完成的数据量：读按 R 握手字节计，写按收到 B 响应的突发计。"
  "按当前消息格式，各项上限为：")
code("链路载荷带宽 = 48 × 240 / 256 = 45 GB/s\n"
     "读上限       = 45 × 128 / 135 = 42.67 GB/s            每条 RDATA 135B 携带 128B 数据\n"
     "写上限       = 45 × 2048 / (15 + 16 × 135) = 42.37 GB/s  每笔突发另有一条 15B 的 WREQ\n"
     "桥处理上限   = 128B / 2ns = 64 GB/s                    每周期一条消息")
tab("thr", "吞吐测试结果", ["场景", "位宽", "读 GB/s", "写 GB/s", "相对 45GB/s（读 / 写）"], [
    ["baseline", "256", "16.00", "15.06", "35.6% / 33.5%"],
    ["baseline", "512", "32.00", "30.12", "71.1% / 66.9%"],
    ["baseline", "1024", "42.67", "42.37", "94.8% / 94.2%"],
    ["saturated（400µs 窗口）", "1024", "42.67", "42.37", "94.8% / 94.2%"],
    ["ideal（不限链路速率）", "1024", "64.00", "60.24", "—"],
], [4.6, 1.6, 2.3, 2.3, 4.7])
fig("thr", "f_throughput.png", "持续吞吐（256、512 位为 baseline，1024 位为 saturated）", width=14.0)
p("256、512 位受总线宽度限制，2ns 时钟下最多 16、32GB/s。1024 位读写都达到了协议上限，数据方向帧的消息区占用率为 100%，"
  "没有空帧。去掉链路限速后，读为 64GB/s，写为 60.24GB/s（64 × 16/17），说明桥本身每周期一条消息的处理能力高于链路，"
  "瓶颈在链路带宽和消息格式开销。")
p("以 45GB/s 链路载荷带宽为基准，1024 位读、写利用率分别为 94.8% 和 94.2%。如果以 48GB/s 原始带宽为基准，"
  "读写上限分别是 88.9% 和 88.3%，由消息头和 PH 开销决定，与实现无关。")

h2("指标对照")
tab("kpi", "指标对照", ["指标", "要求", "结果", "说明"], [
    ["单通道速率", "≥ 24GT/s", "24GT/s", "吞吐测试按 x16、24GT/s 对应的 48GB/s 单向带宽限速；链路物理层不在本设计范围"],
    ["带宽利用率", "≥ 90%", "读 94.8%\n写 94.2%", "1024 位，以 45GB/s 链路载荷带宽为基准"],
    ["桥接延迟", "≤ 20ns", "SoC 侧 12ns\n存储侧 16ns", "空载，2ns 时钟；两端四段合计 28ns"],
], [2.6, 2.2, 3.0, 7.7])

# 8 结论 ----------------------------------------------------------------
h1("总结")
p("本设计实现了 AXI4 突发请求与 AoU 流式 Flit 之间的双向转换，以及 Flit 到逐拍 MC 命令的映射。两端共用的传输层每周期可处理一条消息，"
  "支持跨帧拼接和按 RP、按消息类型的 credit 流控。在 9 种位宽与 RP 组合下，功能、异常、复位和吞吐测试全部通过；"
  "1024 位配置在 48GB/s 链路下读写吞吐达到协议上限，空载转换延迟每端不超过 16ns。")
p("后续工作：")
li("（1）接入实际的 D2D Adapter 和 MC 模型联调，在真实链路时延和 MC 调度下复测延迟与带宽。")
li("（2）完成 28nm 工艺综合与时序分析。ID 在途表按 1024 个 ID 实现，约 3.7 万个触发器，综合时可考虑改用 RAM 或减小计数位宽。")
li("（3）补充多随机种子的长时间回归、AXI VIP 协议检查和关键模块的形式验证。")

# 附录 ------------------------------------------------------------------
C.append(("h1n", "附录 A　复现命令"))
p("以下命令在工程根目录执行，需要 Verilator 5.052、C++17 编译器和 SystemC 2.3.4。")
code("make -C sim check                                  # 全部回归（T1～T7）\n"
     "make -C sim fifo-all codec-all                     # 单元测试\n"
     "make -C sim test-all                               # 9 配置 lint、功能、异常\n"
     "make -C sim run WIDTH=1024 RP=1 ARGS=--trace       # 功能测试并保存 VCD\n"
     "make -C sim perf-all                               # 三种位宽 baseline 吞吐\n"
     "make -C sim scenario WIDTH=1024 RP=1 SCENARIO=saturated \\\n"
     "     ARGS=\"--cycles 200000 --min-efficiency 0.90\"   # 满载吞吐与 90% 门限\n"
     "make -C sim scenario WIDTH=1024 RP=1 SCENARIO=ideal ARGS=\"--cycles 200000\"\n"
     "make -C sim checker-negative WIDTH=256 RP=1        # 记分板自检")


# ---------------------------------------------------------------- 排版
BODY_FONT, HEAD_FONT, MONO = "宋体", "黑体", "Consolas"


def set_font(run, east, latin=None, size=None, bold=None, color=None):
    run.font.name = latin or "Times New Roman"
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.insert(0, rfonts)
    rfonts.set(qn("w:eastAsia"), east)
    rfonts.set(qn("w:ascii"), latin or "Times New Roman")
    rfonts.set(qn("w:hAnsi"), latin or "Times New Roman")
    if size:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if color:
        run.font.color.rgb = RGBColor.from_string(color)


def style_font(style, east, latin, size, bold=False):
    style.font.name = latin
    style.font.size = Pt(size)
    style.font.bold = bold
    style.font.color.rgb = RGBColor(0, 0, 0)
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.insert(0, rfonts)
    for k in ("w:eastAsia",):
        rfonts.set(qn(k), east)
    rfonts.set(qn("w:ascii"), latin)
    rfonts.set(qn("w:hAnsi"), latin)
    for a in ("w:asciiTheme", "w:hAnsiTheme", "w:eastAsiaTheme", "w:cstheme"):
        if rfonts.get(qn(a)) is not None:
            del rfonts.attrib[qn(a)]


doc = Document()
sec = doc.sections[0]
sec.page_height, sec.page_width = Cm(29.7), Cm(21.0)
sec.left_margin = sec.right_margin = Cm(2.5)
sec.top_margin, sec.bottom_margin = Cm(2.5), Cm(2.3)

st = doc.styles
style_font(st["Normal"], BODY_FONT, "Times New Roman", 10.5)
pf = st["Normal"].paragraph_format
pf.line_spacing = 1.3
pf.space_after = Pt(3)
for name, size, before, after in [("Heading 1", 15, 18, 10), ("Heading 2", 13, 12, 6), ("Heading 3", 11.5, 8, 4)]:
    s = st[name]
    style_font(s, HEAD_FONT, "Arial", size, bold=False)
    s.paragraph_format.space_before = Pt(before)
    s.paragraph_format.space_after = Pt(after)
    s.paragraph_format.line_spacing = 1.2
    s.paragraph_format.keep_with_next = True
    s.paragraph_format.first_line_indent = Cm(0)

for lvl, ind in ((1, 0), (2, 0.74)):
    try:
        ts = st[f"toc {lvl}"]
    except KeyError:
        ts = st.add_style(f"toc {lvl}", 1)
        ts.base_style = st["Normal"]
    ts.paragraph_format.line_spacing = 1.15
    ts.paragraph_format.space_after = Pt(2)
    ts.paragraph_format.left_indent = Cm(ind)
    ts.paragraph_format.first_line_indent = Cm(0)

counters = {"h1": 0, "h2": 0, "h3": 0}
labels = {}


def number_items():
    ch, nf, nt = 0, 0, 0
    for it in C:
        if it[0] == "h1":
            ch += 1
            nf = nt = 0
        elif it[0] == "h1n":
            ch = "A"
            nf = nt = 0
        elif it[0] == "fig":
            nf += 1
            labels["图:" + it[1]] = f"图 {ch}-{nf}"
        elif it[0] == "tab":
            nt += 1
            labels["表:" + it[1]] = f"表 {ch}-{nt}"


number_items()


def resolve(t):
    return re.sub(r"\{(图|表):([a-z_0-9]+)\}", lambda m: labels[f"{m.group(1)}:{m.group(2)}"], t)


def para(text, indent=True, align=None, size=None, east=BODY_FONT, space_after=None, keep=False):
    para_ = doc.add_paragraph()
    if indent:
        para_.paragraph_format.first_line_indent = Pt(21)
    if align is not None:
        para_.alignment = align
    if space_after is not None:
        para_.paragraph_format.space_after = Pt(space_after)
    if keep:
        para_.paragraph_format.keep_with_next = True
    r = para_.add_run(resolve(text))
    set_font(r, east, size=size)
    return para_


def shade(cell, color):
    tcpr = cell._element.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), color)
    tcpr.append(shd)


def table_borders(tbl):
    tblpr = tbl._element.tblPr
    b = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement(f"w:{edge}")
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), "8" if edge in ("top", "bottom") else "4")
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), "000000" if edge in ("top", "bottom") else "808080")
        b.append(e)
    tblpr.append(b)


def caption(text):
    c_ = doc.add_paragraph()
    c_.alignment = WD_ALIGN_PARAGRAPH.CENTER
    c_.paragraph_format.first_line_indent = Cm(0)
    c_.paragraph_format.space_before = Pt(3)
    c_.paragraph_format.space_after = Pt(8)
    r = c_.add_run(text)
    set_font(r, HEAD_FONT, latin="Arial", size=9)
    return c_


def add_table(key, cap, head, rows, widths, note):
    tc = caption(f"{labels['表:' + key]}　{cap}")
    tc.paragraph_format.space_after = Pt(3)
    tc.paragraph_format.keep_with_next = True
    tbl = doc.add_table(rows=1 + len(rows), cols=len(head))
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    table_borders(tbl)
    tblpr = tbl._element.tblPr
    lay = OxmlElement("w:tblLayout")
    lay.set(qn("w:type"), "fixed")
    tblpr.append(lay)
    tw = OxmlElement("w:tblW")
    tw.set(qn("w:w"), str(int(sum(widths) * 567)))
    tw.set(qn("w:type"), "dxa")
    for old_tw in tblpr.findall(qn("w:tblW")):
        tblpr.remove(old_tw)
    tblpr.append(tw)
    for c_i, col in enumerate(tbl.columns):
        col.width = Cm(widths[c_i])
    # 整列都是短内容时居中，否则左对齐，避免同列对齐不一致
    centered = [all(len(str(r[c])) <= 10 and "\n" not in str(r[c]) for r in rows) for c in range(len(head))]
    for r_i, row in enumerate([head] + rows):
        for c_i, val in enumerate(row):
            cell = tbl.cell(r_i, c_i)
            cell.width = Cm(widths[c_i])
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            cp = cell.paragraphs[0]
            cp.paragraph_format.first_line_indent = Cm(0)
            cp.paragraph_format.space_after = Pt(0)
            cp.paragraph_format.line_spacing = 1.15
            if r_i == 0 or centered[c_i]:
                cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            run = cp.add_run(str(val))
            set_font(run, HEAD_FONT if r_i == 0 else BODY_FONT, size=9)
            if r_i == 0:
                shade(cell, "E7E6E6")
    for row in tbl.rows:
        trpr = row._tr.get_or_add_trPr()
        cant = OxmlElement("w:cantSplit")
        trpr.append(cant)
    hdr = tbl.rows[0]._tr.get_or_add_trPr()
    th = OxmlElement("w:tblHeader")
    hdr.append(th)
    if note:
        n = doc.add_paragraph()
        n.paragraph_format.first_line_indent = Cm(0)
        n.paragraph_format.space_before = Pt(2)
        r = n.add_run("注：" + note)
        set_font(r, BODY_FONT, size=8.5, color="595959")
    else:
        sp = doc.add_paragraph()
        sp.paragraph_format.space_after = Pt(2)
        sp.paragraph_format.line_spacing = 0.8


def add_fig(key, file, cap, width, spec):
    path = f"{SPEC_DIR if spec else FIG_DIR}/{file}"
    fp = doc.add_paragraph()
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    fp.paragraph_format.first_line_indent = Cm(0)
    fp.paragraph_format.keep_with_next = True
    fp.paragraph_format.space_before = Pt(6)
    fp.paragraph_format.line_spacing = 1.0
    fp.add_run().add_picture(path, width=Cm(width))
    caption(f"{labels['图:' + key]}　{cap}")


def add_code(text):
    for i, line in enumerate(text.split("\n")):
        cp = doc.add_paragraph()
        cp.paragraph_format.first_line_indent = Cm(0)
        cp.paragraph_format.left_indent = Cm(0.6)
        cp.paragraph_format.space_after = Pt(0)
        cp.paragraph_format.space_before = Pt(4) if i == 0 else Pt(0)
        cp.paragraph_format.line_spacing = 1.15
        ppr = cp._element.get_or_add_pPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), "F2F2F2")
        ppr.append(shd)
        r = cp.add_run(line if line else " ")
        set_font(r, BODY_FONT, latin=MONO, size=8.5)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)


def add_field(paragraph, instr):
    r = paragraph.add_run()
    b = OxmlElement("w:fldChar")
    b.set(qn("w:fldCharType"), "begin")
    r._element.append(b)
    r2 = paragraph.add_run()
    it = OxmlElement("w:instrText")
    it.set(qn("xml:space"), "preserve")
    it.text = instr
    r2._element.append(it)
    r3 = paragraph.add_run()
    s = OxmlElement("w:fldChar")
    s.set(qn("w:fldCharType"), "separate")
    r3._element.append(s)
    r4 = paragraph.add_run("1" if "PAGE" in instr else "右键选择“更新域”生成目录")
    set_font(r4, BODY_FONT, size=9)
    r5 = paragraph.add_run()
    e = OxmlElement("w:fldChar")
    e.set(qn("w:fldCharType"), "end")
    r5._element.append(e)


# 封面
for _ in range(7):
    doc.add_paragraph()
t = para("AXI2FLIT 转接桥", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=26, east=HEAD_FONT, space_after=6)
t = para("RTL 设计文档", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=26, east=HEAD_FONT, space_after=30)
para("设计说明 · 接口定义 · 验证报告", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=12, space_after=150)
for k, v in [("版本", "V1.0"), ("日期", "2026 年 10 月")]:
    para(f"{k}：{v}", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=11, space_after=4)
doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

# 目录
tp = para("目　录", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=15, east=HEAD_FONT, space_after=12)
toc = doc.add_paragraph()
add_field(toc, 'TOC \\o "1-2" \\h \\z \\u')

# 正文另起一节，页码从 1 开始
body = doc.add_section(WD_SECTION.NEW_PAGE)
pg = body._sectPr
pn = OxmlElement("w:pgNumType")
pn.set(qn("w:start"), "1")
pg.append(pn)
body.header.is_linked_to_previous = False
body.footer.is_linked_to_previous = False
hp = body.header.paragraphs[0]
hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
hr = hp.add_run("AXI2FLIT 转接桥 RTL 设计文档")
set_font(hr, BODY_FONT, size=8.5, color="7F7F7F")
hppr = hp._element.get_or_add_pPr()
bdr = OxmlElement("w:pBdr")
bot = OxmlElement("w:bottom")
for k, v in (("w:val", "single"), ("w:sz", "4"), ("w:space", "1"), ("w:color", "A6A6A6")):
    bot.set(qn(k), v)
bdr.append(bot)
hppr.append(bdr)
fpar = body.footer.paragraphs[0]
fpar.alignment = WD_ALIGN_PARAGRAPH.CENTER
add_field(fpar, "PAGE")

for it in C:
    kind = it[0]
    if kind == "h1":
        counters["h1"] += 1
        counters["h2"] = counters["h3"] = 0
        doc.add_heading(f"{counters['h1']}　{it[1]}", level=1)
    elif kind == "h1n":
        counters["h2"] = 0
        doc.add_heading(it[1], level=1)
    elif kind == "h2":
        counters["h2"] += 1
        counters["h3"] = 0
        doc.add_heading(f"{counters['h1']}.{counters['h2']}　{it[1]}", level=2)
    elif kind == "h3":
        counters["h3"] += 1
        doc.add_heading(f"{counters['h1']}.{counters['h2']}.{counters['h3']}　{it[1]}", level=3)
    elif kind == "p":
        para(it[1])
    elif kind == "li":
        q = para(it[1], indent=False)
        q.paragraph_format.left_indent = Pt(21)
        q.paragraph_format.space_after = Pt(1)
    elif kind == "code":
        add_code(it[1])
    elif kind == "fig":
        add_fig(*it[1:])
    elif kind == "tab":
        add_table(*it[1:])

# 打开文档时提示更新目录域
settings = doc.settings.element
uf = OxmlElement("w:updateFields")
uf.set(qn("w:val"), "true")
settings.append(uf)

doc.core_properties.title = "AXI2FLIT 转接桥 RTL 设计文档"
doc.core_properties.author = ""
doc.save(OUT)
print("saved", OUT, "figures:", sum(1 for k in labels if k.startswith("图")), "tables:",
      sum(1 for k in labels if k.startswith("表")))
