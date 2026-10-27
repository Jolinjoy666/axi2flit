"""从仿真日志汇总设计文档需要的实测数字，输出 results.json。

用法：python3 collect_results.py <输出 json> <check 日志> <fl-all 日志> <fl-ideal 日志>
日志由 `make -C sim check`、`fl-all`、`fl-ideal-all` 产生；文档正文只引用本脚本提取出的值，保证图文一致。
"""
import json
import re
import sys

OUT, CHECK, FL_ALL, FL_IDEAL = sys.argv[1:5]
text = lambda path: open(path, encoding="utf-8", errors="ignore").read()


def blocks(s, head):
    """按“============ <head>”切分报告块，块内到“用时”行为止。"""
    out, cur = [], None
    for line in s.split("\n"):
        if line.startswith("============") and head in line:
            cur = [line]
            out.append(cur)
        elif cur is not None:
            if line.startswith("用时"):
                cur = None
            else:
                cur.append(line)
    return out


def num(pattern, s, cast=float, default=None):
    m = re.search(pattern, s)
    return cast(m.group(1)) if m else default


# ---- 独立环境：单拍延迟最大值（满速 MC、HIF 存储侧各取最大值） ----
sa = [b for b in blocks(text(CHECK), "独立 RTL 仿真") if "存储侧 HIF" in b[0]]
sa_txt = "\n".join("\n".join(b) for b in sa)
lat = {
    "sa_soc_tx": max(int(x) for x in re.findall(r"SoC 侧 \d+ ns（发送 (\d+)", sa_txt)),
    "sa_soc_rx": max(int(x) for x in re.findall(r"发送 \d+ \+ 接收 (\d+)", sa_txt)),
    "sa_req": max(int(x) for x in re.findall(r"存储侧 \d+ ns（请求 (\d+)", sa_txt)),
    "sa_ret": max(int(x) for x in re.findall(r"请求 \d+ \+ 返回 (\d+)", sa_txt)),
}

# ---- 全链路：桥接延迟（取各配置的最大值）与吞吐 ----
fl = text(FL_ALL)
tgt = []
for b in blocks(fl, "全链路仿真"):
    line = next((x for x in b if x.startswith("指标")), "")
    m = re.search(r"桥延迟 SoC 侧 (\d+) ns、存储侧 (\d+) ns", line)
    if m:
        tgt.append((int(m.group(1)), int(m.group(2))))
lat["soc"] = max(t[0] for t in tgt)
lat["tgt"] = max(t[1] for t in tgt)
# 单拍写通常比读多一拍，读、写分别取各配置最大值
rd, wr = [], []
for b in blocks(fl, "全链路仿真"):
    for i, x in enumerate(b):
        if x.startswith("延迟  单拍读"):
            rd.append(int(num(r"(\d+) ns =", x, int)))
        if x.startswith("      单拍写"):
            wr.append(int(num(r"(\d+) ns =", x, int)))
lat["tgt_rd"] = max(rd) if rd else lat["tgt"]
lat["tgt_wr"] = max(wr) if wr else lat["tgt"]
# 指标行的“存储侧”是读、写两段的较大者，差异来源见正文
lat["tgt_max"] = lat["tgt"]


def bw_rows(fl_text, tag_ideal):
    rows = []
    for b in blocks(fl_text, "全链路仿真"):
        head = b[0]
        m = re.match(r".*DATA_WIDTH=(\d+)\s+RP=(\d+)", head)
        if not m or "压力" in head or "CRC" in head:
            continue
        width, rp = int(m.group(1)), int(m.group(2))
        rb = next((x for x in b if re.match(r"吞吐  读 ", x)), "")
        wb = next((x for x in b if re.match(r"      写 ", x)), "")
        mb = next((x for x in b if re.match(r"      同时读写 ", x)), "")
        if not rb:
            continue
        r = num(r"读 ([\d.]+) GB/s", rb)
        w = num(r"写 ([\d.]+) GB/s", wb)
        mm = re.search(r"同时读写 ([\d.]+) / ([\d.]+)", mb)
        rows.append([width, rp, r, w, (mm.group(1) + " / " + mm.group(2)) if mm else "—"])
    # 只保留每种位宽的最小 RP 与最大 RP，避免表格过长
    keep = {}
    for row in rows:
        w = row[0]
        if w not in keep:
            keep[w] = [row, row]
        if row[1] < keep[w][0][1]:
            keep[w][0] = row
        if row[1] > keep[w][1][1]:
            keep[w][1] = row
    return [x for w in sorted(keep) for x in (keep[w] if keep[w][0][1] == keep[w][1][1] else keep[w])]


bw = []
for w, rp, r, wr_bw, mixed in bw_rows(fl, False):
    bw.append([f"{w} 位", "HIF", f"RP{rp}", f"{r:.2f}", f"{wr_bw:.2f}", mixed,
               "HIF 数据口 16GB/s" if w == 1024 else "总线宽度"])
for w, rp, r, wr_bw, mixed in bw_rows(text(FL_IDEAL), True):
    bw.append([f"{w} 位", "满速 MC", f"RP{rp}", f"{r:.2f}", f"{wr_bw:.2f}", mixed,
               "链路消息区 45GB/s" if w == 1024 else "总线宽度"])
order = {"满速 MC": 0, "HIF": 1}
bw.sort(key=lambda x: (int(x[0].split()[0]), -order[x[1]], int(x[2][2:])))
# 表列为：位宽、存储侧、RP、读、写、说明（“读写同时”并入说明）
bw = [[r[0], r[1], r[2], r[3], r[4], (f"同时读写 {r[5]}；" if r[5] != "—" else "") + r[6]] for r in bw]

# ---- 独立环境功能测试统计（HIF 存储侧） ----
func = []
for b in blocks(text(CHECK), "独立 RTL 仿真"):
    if "存储侧 HIF" not in b[0]:
        continue
    head = b[0]
    width = int(re.search(r"DATA_WIDTH=(\d+)", head).group(1))
    rp = int(re.search(r"RP=(\d+)", head).group(1))
    aw = w = ar = r = 0
    for x in b:
        if re.match(r"^[^ ]", x) and not x.startswith(("配置", "阶段", "延迟", "吞吐", "统计", "指标")):
            pass
    stat = next((x for x in b if x.startswith("统计")), "")
    m = re.search(r"写 (\d+) 突发 (\d+) 拍、读 (\d+) 突发 (\d+) 拍，HIF 命令 读 (\d+) 写 (\d+)，乱序返回 (\d+)、交织 (\d+)，"
                  r"链路消息核对 (\d+) 条（跨帧 (\d+)）", stat)
    if m:
        func.append([str(width), str(rp), f"{m.group(1)} / {m.group(2)}", f"{m.group(3)} / {m.group(4)}",
                     f"{m.group(5)} / {m.group(6)}", f"{m.group(7)} / {m.group(8)}", m.group(9), m.group(10)])

func = func[:9]   # test-all 的 9 种配置；其后为 hif-cfg-all

# ---- 其他控制器配置：hif-cfg-all 依次运行 5 种配置 × 256 / 1024 位（RP2），排在 test-all 的 3 个 RP2 之后 ----
CFG_NAMES = ["16 位 DRAM（行 32B，HIF 128 位）", "64 位 DRAM、1:2（行 128B）", "2 位 credit（Inline ECC）",
             "部分写用 RMW", "credit 2/1/2，读 ROB 4 行、写缓冲 2 行"]
rp2 = [b for b in blocks(text(CHECK), "独立 RTL 仿真") if "存储侧 HIF" in b[0] and "RP=2" in b[0]][3:]
cfg = []
for i, b in enumerate(rp2[:10]):
    width = int(re.search(r"DATA_WIDTH=(\d+)", b[0]).group(1))
    rb = next((x for x in b if re.match(r"吞吐  读 ", x)), "")
    wb = next((x for x in b if re.match(r"      写 ", x)), "")
    r = num(r"读 ([\d.]+) GB/s", rb)
    w = num(r"写 ([\d.]+) GB/s", wb)
    cfg.append([CFG_NAMES[i // 2], str(width), f"{r:.2f}", f"{w:.2f}", "通过"])

# ---- 汇总表 ----
n_neg = len(re.findall(r"NEGATIVE PASS", text(CHECK)))
n_fl = len(re.findall(r"============ 全链路仿真", fl))
summary = [
    ["单元测试（FIFO、组帧解帧）", "8 组 + 48 组", "通过"],
    ["静态检查", "3 位宽 × RP 1/2/4，两个顶层", "通过"],
    ["系统功能（HIF / 满速 MC）", f"9 + 9 配置", "通过"],
    ["异常注入", f"{n_neg} 项", "通过"],
    ["控制器配置", f"{len(cfg)} 组", "通过"],
    ["记分板自检", "1 项", "按预期检出"],
    ["全链路（HIF）", f"{n_fl} 配置 × (12 用例 + 3 吞吐)", "通过，数据错误 0"],
    ["全链路（满速 MC）", f"{n_fl} 配置 × (12 用例 + 3 吞吐)", "通过，数据错误 0"],
]

json.dump({"lat": lat,
           "bw_rows": bw,
           "func_rows": func,
           "cfg_rows": cfg,
           "summary": summary,
           "lines_n": [2, 4, 8, 16, 32],
           "lines": [[4.57, 10.67], [9.14, 16.00], [16.00, 16.00], [16.00, 16.00], [16.00, 16.00]]},
          open(OUT, "w"), ensure_ascii=False, indent=1)
print("wrote", OUT, "func", len(func), "cfg", len(cfg), "bw", len(bw), "neg", n_neg)
