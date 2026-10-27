// AoU v0.8 线上格式与公共函数。
// 线上逻辑帧为 250B：10B 协议头 PH + 48 个 5B 消息粒度，共 2000 位。
// 单条消息最多 30 粒度（150B、1200 位）；消息 byte0 位于向量最高字节。
// AXI data[7:0] 为最低地址字节，线上数据按高 byte lane 到低 byte lane 排列。
// 本包中的常量都是协议规定的线上格式，两端必须一致，不作为可配置参数；
// 可配置项（数据位宽、RP 数、各级深度、AXI 侧字段宽度等）由各模块的 parameter 给出。
package aou_pkg;
    // ---------------- 帧与粒度 ----------------
    localparam int GRANULE_BITS = 40;                              // 每粒度 5B
    localparam int FLIT_GRANULES = 48;                             // 每帧 48 粒度（240B）
    localparam int PH_BYTES = 10;                                  // 协议头 PH
    localparam int PAYLOAD_BITS = FLIT_GRANULES * GRANULE_BITS;    // 1920
    localparam int FLIT_BITS = PH_BYTES * 8 + PAYLOAD_BITS;        // 2000，逻辑 FDI 宽度
    localparam int PAYLOAD_TOP = PAYLOAD_BITS - 1;                 // 载荷第 0 粒度的最高位
    localparam int MSG_MAX_GRANULES = 30;                          // 最大消息：带 STRB 的 1024 位写数据
    localparam int MSG_BITS = MSG_MAX_GRANULES * GRANULE_BITS;     // 1200
    localparam int MSG_TOP = MSG_BITS - 1;                         // 消息 byte0 的最高位
    localparam int GRANULE_IDX_W = $clog2(FLIT_GRANULES + 1);      // 帧内粒度位置/计数位宽

    // ---------------- 线上字段宽度 ----------------
    // AXI 侧可以更窄（由模块参数决定），上线时高位补零。
    localparam int WIRE_ID_W = 10;
    localparam int WIRE_ADDR_W = 64;
    localparam int WIRE_USER_W = 16;
    localparam int RP_W = 2;                                       // 消息与 PH 中的 RP 字段
    localparam int MAX_RP = 1 << RP_W;
    localparam int AXI_ID_COUNT = 1 << WIRE_ID_W;
    // 数据消息宽度由 2 位 DLENGTH 表示：0/1/2 对应 256/512/1024 位，3 非法。
    localparam int MIN_DATA_W = 256;
    localparam int MAX_DATA_W = 1024;
    localparam int MAX_DATA_BYTES = MAX_DATA_W / 8;                // 128
    localparam int MAX_STRB_W = MAX_DATA_BYTES;
    localparam int LANE_W = $clog2(MAX_DATA_BYTES);                // 字节通道号位宽

    // ---------------- 消息类型 ----------------
    // 首字节 bit7:4 为类型。类型 0 为 Misc（此处仅接收 CrdtGrant）。
    localparam logic [3:0] MT_MISC = 4'd0;
    localparam logic [3:0] MT_WREQ = 4'd1;
    localparam logic [3:0] MT_RREQ = 4'd2;
    localparam logic [3:0] MT_WDATA = 4'd3;                        // 带掩码写数据
    localparam logic [3:0] MT_RDATA = 4'd4;
    localparam logic [3:0] MT_WRESP = 4'd5;
    localparam logic [3:0] MT_WDATAF = 4'd6;                       // 全掩码写数据（省略 STRB）
    localparam logic [2:0] MISC_CRDTGRANT = 3'b100;                // Misc 操作码（首字节 bit3:1）

    // 五类队列：类型 3 和 6 合并为写数据类；未知类型返回 MSG_KIND_COUNT。
    localparam int K_WREQ = 0;
    localparam int K_RREQ = 1;
    localparam int K_WDATA = 2;
    localparam int K_RDATA = 3;
    localparam int K_WRESP = 4;
    localparam int MSG_KIND_COUNT = 5;
    localparam int K_MISC = MSG_KIND_COUNT;

    // 各消息头部长度（字节）；数据紧跟其后。
    localparam int WDATA_HDR_BYTES = 3;
    localparam int RDATA_HDR_BYTES = 5;

    // ---------------- 类型定义 ----------------
    // msg_t 保存最多 150B 消息；flit_t 保存 PH byte0～9 和载荷 byte0～239。
    typedef logic [MSG_BITS-1:0] msg_t;
    typedef logic [FLIT_BITS-1:0] flit_t;
    // ax_t 对应请求消息的 ID、地址及 AXI 控制字段（线上宽度）。
    typedef struct packed {
        logic [WIRE_ID_W-1:0] id;
        logic [WIRE_ADDR_W-1:0] addr;
        logic [7:0] len;
        logic [2:0] size, prot;
        logic [3:0] cache, qos;
        logic lock;
        logic [WIRE_USER_W-1:0] user;
    } ax_t;

    // 写/读请求各占 15B（3 粒度）。BURST 不上线，接收侧按 INCR 处理；
    // 地址需按拍大小对齐且不能跨 4KB 边界。
    typedef struct packed {
        logic [3:0] mtype;
        logic [RP_W-1:0] rp;
        logic rsvd;
        logic lock;
        logic [WIRE_USER_W-1:0] user;
        logic [WIRE_ID_W-1:0] id;
        logic [2:0] size, prot;
        logic [7:0] len;
        logic [3:0] cache, qos;
        logic [WIRE_ADDR_W-1:0] addr;
    } req_hdr_t;
    // 写数据头 3B：类型/RP/DLENGTH/USER，随后是 DATA，非全掩码时再跟 STRB 位图。
    typedef struct packed {
        logic [3:0] mtype;
        logic [RP_W-1:0] rp;
        logic [1:0] dl;
        logic [WIRE_USER_W-1:0] user;
    } wdata_hdr_t;
    // 读数据头 5B：类型/RP/DLENGTH/USER、ID、RESP、LAST、保留，再跟 DATA。
    typedef struct packed {
        logic [3:0] mtype;
        logic [RP_W-1:0] rp;
        logic [1:0] dl;
        logic [WIRE_USER_W-1:0] user;
        logic [WIRE_ID_W-1:0] id;
        logic [1:0] resp;
        logic last;
        logic [2:0] rsvd;
    } rdata_hdr_t;
    // 写响应 5B：类型/RP/保留、USER、ID、RESP、保留。
    typedef struct packed {
        logic [3:0] mtype;
        logic [RP_W-1:0] rp;
        logic [1:0] rsvd0;
        logic [WIRE_USER_W-1:0] user;
        logic [WIRE_ID_W-1:0] id;
        logic [1:0] resp;
        logic [3:0] rsvd1;
    } wresp_hdr_t;
    localparam int REQ_GRANULES = $bits(req_hdr_t) / GRANULE_BITS;     // 3
    localparam int WRESP_GRANULES = $bits(wresp_hdr_t) / GRANULE_BITS; // 1
    localparam int CRDTGRANT_GRANULES = 2;

    // CrdtGrant（2 粒度）：首字节为类型 0 + 操作码，随后 16 个 3 位 credit（按类型、RP 排列），
    // 再 4 个 2 位写响应 credit（按 RP），其余 17 位保留。
    localparam int CG_C3_TOP = MSG_TOP - 7;
    localparam int CG_C2_TOP = CG_C3_TOP - 4 * MAX_RP * 3;
    localparam int CG_RSVD_TOP = CG_C2_TOP - MAX_RP * 2;
    localparam int CG_RSVD_BITS = CRDTGRANT_GRANULES * GRANULE_BITS - (MSG_TOP - CG_RSVD_TOP);

    // ---------------- credit ----------------
    // 三位编码 0～7 对应 0、1、4、8、16、32、64、128；写响应只用两位编码 0～3。
    localparam int CREDIT_CNT_W = 12;                              // available/promised 计数位宽
    localparam int CREDIT_CNT_MAX = (1 << CREDIT_CNT_W) - 1;
    localparam int MAX_GRANT = 128;                                // 单个编码的最大授信量
    localparam int GRANT_W = $clog2(MAX_GRANT + 1);                // 每拍扣减/授出量位宽
    localparam int UPDATE_W = $clog2(2 * MAX_GRANT + 1);           // PH 与 CrdtGrant 同拍相加
    // PH 中 MsgCredit[15:14] 为 RP，[13:12] 为写响应编码，[11:0] 每三位依次为
    // 读数据、写数据、读请求、写请求编码（从高位到低位）。
    localparam int PH_CREDIT_W = 16;

    // ---------------- 接收存储 ----------------
    // 数据消息按 CHUNK_GRANULES 粒度一块分块存放；一条消息最多 MAX_MSG_CHUNKS 块。
    localparam int CHUNK_GRANULES = 8;
    localparam int CHUNK_BITS = CHUNK_GRANULES * GRANULE_BITS;
    localparam int MAX_MSG_CHUNKS = (MSG_MAX_GRANULES + CHUNK_GRANULES - 1) / CHUNK_GRANULES;

    // ---------------- 消息字段访问 ----------------
    function automatic logic [7:0] msg_head(input msg_t m);
        return m[MSG_TOP -: 8];
    endfunction
    function automatic logic [3:0] msg_type(input msg_t m);
        return m[MSG_TOP -: 4];
    endfunction
    function automatic int msg_rp(input msg_t m);
        return int'(m[MSG_TOP-4 -: RP_W]);
    endfunction
    function automatic int msg_dl(input msg_t m);
        return int'(m[MSG_TOP-6 -: 2]);
    endfunction
    function automatic req_hdr_t req_hdr(input msg_t m);
        return m[MSG_TOP -: $bits(req_hdr_t)];
    endfunction
    function automatic wdata_hdr_t wdata_hdr(input msg_t m);
        return m[MSG_TOP -: $bits(wdata_hdr_t)];
    endfunction
    function automatic rdata_hdr_t rdata_hdr(input msg_t m);
        return m[MSG_TOP -: $bits(rdata_hdr_t)];
    endfunction
    function automatic wresp_hdr_t wresp_hdr(input msg_t m);
        return m[MSG_TOP -: $bits(wresp_hdr_t)];
    endfunction
    // CrdtGrant 中第 i 个三位 credit（i = 类型 × 4 + RP）与第 p 个两位写响应 credit。
    function automatic int cg_credit3(input msg_t m, input int i);
        return int'(m[CG_C3_TOP-i*3 -: 3]);
    endfunction
    function automatic int cg_credit2(input msg_t m, input int p);
        return int'(m[CG_C2_TOP-p*2 -: 2]);
    endfunction
    function automatic logic legal_crdtgrant(input msg_t m);
        return m[MSG_TOP -: 4] == MT_MISC && m[MSG_TOP-4 -: 3] == MISC_CRDTGRANT &&
               m[CG_RSVD_TOP -: CG_RSVD_BITS] == 0;
    endfunction

    // ---------------- 数据宽度与长度 ----------------
    // DLENGTH=0/1/2 分别表示 256/512/1024 位。
    function automatic int dl_code(input int width);
        return $clog2(width / MIN_DATA_W);
    endfunction
    // 数据消息宽度随传输大小：每拍不超过 32B 用 256 位消息，64B 用 512 位，128B 用 1024 位
    // （规范读数据的要求；写数据同样处理）。窄数据只携带所在的那一组字节通道。
    function automatic int dl_of_size(input logic [2:0] size);
        return size <= 5 ? 0 : size == 6 ? 1 : 2;
    endfunction
    function automatic int dl_bytes(input int dl);
        return (MIN_DATA_W / 8) << dl;
    endfunction
    function automatic int div_up(input int a, input int b);
        return (a + b - 1) / b;
    endfunction
    // 按首字节求消息粒度数；数据消息 = ⌈(头部 + DATA [+ STRB]) / 5B⌉，非法编码返回 0。
    function automatic int granules(input logic [7:0] b);
        int dl, n;
        dl = int'(b[1:0]);
        n = dl_bytes(dl);
        case (b[7:4])
            MT_WREQ, MT_RREQ: return REQ_GRANULES;
            MT_WRESP: return WRESP_GRANULES;
            MT_WDATA: return dl < 3 ? div_up(WDATA_HDR_BYTES + n + n / 8, GRANULE_BITS / 8) : 0;
            MT_RDATA: return dl < 3 ? div_up(RDATA_HDR_BYTES + n, GRANULE_BITS / 8) : 0;
            MT_WDATAF: return dl < 3 ? div_up(WDATA_HDR_BYTES + n, GRANULE_BITS / 8) : 0;
            MT_MISC: return b[3:1] == MISC_CRDTGRANT ? CRDTGRANT_GRANULES : 0;
            default: return 0;
        endcase
    endfunction
    function automatic int msg_granules(input msg_t m);
        return granules(msg_head(m));
    endfunction
    function automatic int msg_kind(input msg_t m);
        case (msg_type(m))
            MT_WREQ: return K_WREQ;
            MT_RREQ: return K_RREQ;
            MT_WDATA, MT_WDATAF: return K_WDATA;
            MT_RDATA: return K_RDATA;
            MT_WRESP: return K_WRESP;
            default: return K_MISC;
        endcase
    endfunction
    function automatic logic is_data_kind(input int k);
        return k == K_WDATA || k == K_RDATA;
    endfunction
    // 第 k 类消息在 DLENGTH=dl 下可能出现的各类型粒度数（写数据类有带掩码与全掩码两种）。
    function automatic int kind_granules(input int k, input int dl, input logic full);
        case (k)
            K_WREQ: return granules({MT_WREQ, 4'b0});
            K_RREQ: return granules({MT_RREQ, 4'b0});
            K_WDATA: return granules({full ? MT_WDATAF : MT_WDATA, 2'b0, 2'(dl)});
            K_RDATA: return granules({MT_RDATA, 2'b0, 2'(dl)});
            default: return granules({MT_WRESP, 4'b0});
        endcase
    endfunction
    // 各类消息在本端位宽下的最大粒度数与位数，用于确定队列存储宽度。
    function automatic int max_granules(input int k, input int width);
        int g;
        g = 0;
        for (int dl = 0; dl < 3; dl++) begin
            for (int f = 0; f < 2; f++) begin
                if (dl <= dl_code(width) && kind_granules(k, dl, f != 0) > g) begin
                    g = kind_granules(k, dl, f != 0);
                end
            end
        end
        return g;
    endfunction
    function automatic int msg_bits(input int k, input int width);
        return GRANULE_BITS * max_granules(k, width);
    endfunction

    // ---------------- 接收存储与 credit 换算 ----------------
    // 接收存储以“单元”计：请求、写响应每条一个单元；数据消息按 CHUNK_GRANULES 分块存放，
    // 全宽消息占 unit_count 块。credit 每单位代表一个 5B 粒度（规范 6.1 节）。
    // 空闲单元可公布的 credit = floor(空闲单元 × credit_gran / credit_units)，比例取本端可能
    // 收到的各长度消息中“粒度数/块数”的最小值，保证任意长度组合都不会超出存储。
    function automatic int chunk_count(input int g);
        return div_up(g, CHUNK_GRANULES);
    endfunction
    function automatic int unit_count(input int k, input int width);
        return is_data_kind(k) ? chunk_count(max_granules(k, width)) : 1;
    endfunction
    function automatic int gcd(input int a, input int b);
        int x, y, t;
        x = a;
        y = b;
        for (int i = 0; i < 32; i++) begin
            if (y != 0) begin
                t = x % y;
                x = y;
                y = t;
            end
        end
        return x;
    endfunction
    // 返回最小比例（已约分）的 {粒度数, 块数}；非数据类为 {每条粒度数, 1}。
    function automatic int credit_ratio(input int k, input int width, input logic want_units);
        int g, c, gi, ci, d;
        g = kind_granules(k, 0, 1'b0);
        c = 1;
        if (is_data_kind(k)) begin
            g = 0;
            for (int dl = 0; dl < 3; dl++) begin
                for (int f = 0; f < 2; f++) begin
                    gi = kind_granules(k, dl, f != 0);
                    ci = chunk_count(gi);
                    if (dl <= dl_code(width) && (g == 0 || gi * c < g * ci)) begin
                        g = gi;
                        c = ci;
                    end
                end
            end
            d = gcd(g, c);
            g = g / d;
            c = c / d;
        end
        return want_units ? c : g;
    endfunction
    function automatic int credit_gran(input int k, input int width);
        return credit_ratio(k, width, 1'b0);
    endfunction
    function automatic int credit_units(input int k, input int width);
        return credit_ratio(k, width, 1'b1);
    endfunction

    function automatic int credit_amount(input int enc);
        case (enc)
            0: return 0;
            1: return 1;
            2: return 4;
            3: return 8;
            4: return 16;
            5: return 32;
            6: return 64;
            default: return MAX_GRANT;
        endcase
    endfunction
    function automatic logic [2:0] credit_encode(input int amount, input int k);
        logic [2:0] result;
        result = 0;
        for (int e = 0; e < 8; e++) begin
            if ((k != K_WRESP || e < 4) && credit_amount(e) <= amount) begin
                result = 3'(e);
            end
        end
        return result;
    endfunction

    // ---------------- 请求消息 ----------------
    function automatic msg_t make_req(input ax_t a, input logic wr, input int rp);
        req_hdr_t h;
        msg_t m;
        h = '{mtype: wr ? MT_WREQ : MT_RREQ, rp: RP_W'(rp), rsvd: 1'b0, lock: a.lock, user: a.user,
              id: a.id, size: a.size, prot: a.prot, len: a.len, cache: a.cache, qos: a.qos, addr: a.addr};
        m = '0;
        m[MSG_TOP -: $bits(req_hdr_t)] = h;
        return m;
    endfunction
    function automatic ax_t get_req(input msg_t m);
        req_hdr_t h;
        ax_t a;
        h = req_hdr(m);
        a.lock = h.lock;
        a.user = h.user;
        a.id = h.id;
        a.size = h.size;
        a.prot = h.prot;
        a.len = h.len;
        a.cache = h.cache;
        a.qos = h.qos;
        a.addr = h.addr;
        return a;
    endfunction
    function automatic logic legal_req(input ax_t a, input int width);
        logic [63:0] bytes_per_beat, total;
        bytes_per_beat = 64'd1 << a.size;
        total = (64'(a.len)+1)*bytes_per_beat;
        return bytes_per_beat <= 64'(width/8) &&
               (a.addr & (bytes_per_beat-1)) == 0 &&
               (64'(a.addr[11:0])+total <= 4096);
    endfunction

    // ---------------- 数据与响应消息 ----------------
    // DATA 取本拍所在的 dl_bytes 字节通道组（lane 为本拍字节地址对总线宽度取模），
    // 先放高 byte lane；该组选通全为 1 时用全掩码格式省略 STRB。
    // 以下函数按最大宽度（1024 位）处理，模块内再截取 DATA_WIDTH。
    function automatic msg_t make_wdata(input logic [MAX_DATA_W-1:0] data,
                                        input logic [MAX_STRB_W-1:0] strb,
                                        input logic [WIRE_USER_W-1:0] user, input int rp,
                                        input logic [2:0] size, input logic [LANE_W-1:0] lane);
        msg_t m;
        logic full;
        int dl, n, base;
        dl = dl_of_size(size);
        n = dl_bytes(dl);
        base = (int'(lane) / n) * n;
        full = 1;
        for (int j = 0; j < MAX_DATA_BYTES; j++) begin
            if (j < n && !strb[base+j]) begin
                full = 0;
            end
        end
        m = '0;
        m[MSG_TOP -: $bits(wdata_hdr_t)] = wdata_hdr_t'{mtype: full ? MT_WDATAF : MT_WDATA, rp: RP_W'(rp),
                                                        dl: 2'(dl), user: user};
        for (int j = 0; j < MAX_DATA_BYTES; j++) begin
            if (j < n) begin
                m[MSG_TOP-(WDATA_HDR_BYTES+j)*8 -: 8] = data[(base+n-1-j)*8 +: 8];
            end
        end
        for (int j = 0; j < MAX_STRB_W / 8; j++) begin
            if (!full && j < n/8) begin
                m[MSG_TOP-(WDATA_HDR_BYTES+n+j)*8 -: 8] = strb[base+(n/8-1-j)*8 +: 8];
            end
        end
        return m;
    endfunction
    function automatic msg_t make_rdata(input logic [MAX_DATA_W-1:0] data,
                                        input logic [WIRE_ID_W-1:0] id, input logic [WIRE_USER_W-1:0] user,
                                        input logic [1:0] resp, input logic last,
                                        input int rp, input logic [2:0] size, input logic [LANE_W-1:0] lane);
        msg_t m;
        int dl, n, base;
        dl = dl_of_size(size);
        n = dl_bytes(dl);
        base = (int'(lane) / n) * n;
        m = '0;
        m[MSG_TOP -: $bits(rdata_hdr_t)] = rdata_hdr_t'{mtype: MT_RDATA, rp: RP_W'(rp), dl: 2'(dl), user: user,
                                                        id: id, resp: resp, last: last, rsvd: 3'b0};
        for (int j = 0; j < MAX_DATA_BYTES; j++) begin
            if (j < n) begin
                m[MSG_TOP-(RDATA_HDR_BYTES+j)*8 -: 8] = data[(base+n-1-j)*8 +: 8];
            end
        end
        return m;
    endfunction
    function automatic msg_t make_b(input logic [WIRE_ID_W-1:0] id, input logic [WIRE_USER_W-1:0] user,
                                    input logic [1:0] resp, input int rp);
        msg_t m;
        m = '0;
        m[MSG_TOP -: $bits(wresp_hdr_t)] = wresp_hdr_t'{mtype: MT_WRESP, rp: RP_W'(rp), rsvd0: 2'b0, user: user,
                                                        id: id, resp: resp, rsvd1: 4'b0};
        return m;
    endfunction
    // 取出数据并复制到整条总线：各字节通道组得到同一份数据，窄传输的有效通道因而正确，
    // 非活跃通道的取值按 AXI 规则无意义。
    function automatic logic [MAX_DATA_W-1:0] get_data(input msg_t m, input int width);
        logic [MAX_DATA_W-1:0] data;
        int start, n;
        start = msg_type(m) == MT_RDATA ? RDATA_HDR_BYTES : WDATA_HDR_BYTES;
        n = dl_bytes(msg_dl(m));
        data = '0;
        for (int j = 0; j < MAX_DATA_BYTES; j++) begin
            if (j < width/8) begin
                data[j*8 +: 8] = m[MSG_TOP-(start+n-1-(j%n))*8 -: 8];
            end
        end
        return data;
    endfunction
    // 选通只放在本拍所在的通道组，其余通道为 0。
    function automatic logic [MAX_STRB_W-1:0] get_strb(input msg_t m, input logic [LANE_W-1:0] lane);
        logic [MAX_STRB_W-1:0] strb;
        int n, base;
        n = dl_bytes(msg_dl(m));
        base = (int'(lane) / n) * n;
        strb = '0;
        for (int j = 0; j < MAX_DATA_BYTES; j++) begin
            if (j < n && msg_type(m) == MT_WDATAF) begin
                strb[base+j] = 1;
            end
        end
        for (int j = 0; j < MAX_STRB_W / 8; j++) begin
            if (j < n/8 && msg_type(m) == MT_WDATA) begin
                strb[base+(n/8-1-j)*8 +: 8] = m[MSG_TOP-(WDATA_HDR_BYTES+n+j)*8 -: 8];
            end
        end
        return strb;
    endfunction

    // ---------------- 协议头 PH ----------------
    // PH byte0～9：B0 高四位是 MsgStart[3:0]、低两位 FDId 固定为 0；
    // B1/B2 高四位/B3 对应 MsgStart[11:4]/[15:12]/[23:16]；
    // B4/B5 分别是 MsgCredit[7:0]/[15:8]；B6 高四位/B7/B8 高四位/B9
    // 对应 MsgStart[27:24]/[35:28]/[39:36]/[47:40]，其余位保留为 0。
    // MsgStart[i]=1 表示载荷第 i 个 5B 粒度开始一条新消息；续片不重复置位。
    function automatic logic [7:0] ph_byte(input flit_t f, input int i);
        return f[FLIT_BITS-1-i*8 -: 8];
    endfunction
    function automatic logic [3:0] ph_hi(input flit_t f, input int i);
        return f[FLIT_BITS-1-i*8 -: 4];
    endfunction
    function automatic logic [3:0] ph_lo(input flit_t f, input int i);
        return f[FLIT_BITS-5-i*8 -: 4];
    endfunction
    function automatic logic [FLIT_GRANULES-1:0] get_starts(input flit_t f);
        logic [FLIT_GRANULES-1:0] s;
        s[3:0] = ph_hi(f, 0);
        s[11:4] = ph_byte(f, 1);
        s[15:12] = ph_hi(f, 2);
        s[23:16] = ph_byte(f, 3);
        s[27:24] = ph_hi(f, 6);
        s[35:28] = ph_byte(f, 7);
        s[39:36] = ph_hi(f, 8);
        s[47:40] = ph_byte(f, 9);
        return s;
    endfunction
    function automatic logic [PH_CREDIT_W-1:0] get_ph_credit(input flit_t f);
        return {ph_byte(f, 5), ph_byte(f, 4)};
    endfunction
    // MsgCredit 字段：RP，以及第 k 类的授信编码（写响应为 2 位，其余 3 位）。
    function automatic int ph_credit_rp(input logic [PH_CREDIT_W-1:0] c);
        return int'(c[PH_CREDIT_W-1 -: RP_W]);
    endfunction
    function automatic int ph_credit_enc(input logic [PH_CREDIT_W-1:0] c, input int k);
        return k == K_WRESP ? int'(c[13:12]) : int'(c[k*3 +: 3]);
    endfunction
    function automatic flit_t make_flit(input logic [PAYLOAD_BITS-1:0] payload,
                                        input logic [FLIT_GRANULES-1:0] s, input logic [PH_CREDIT_W-1:0] c);
        return {s[3:0],4'b0,s[11:4],s[15:12],4'b0,s[23:16],
                c[7:0],c[15:8],s[27:24],4'b0,s[35:28],
                s[39:36],4'b0,s[47:40],payload};
    endfunction
    function automatic logic legal_ph(input flit_t f);
        return ph_lo(f, 0) == 0 && ph_lo(f, 2) == 0 && ph_lo(f, 6) == 0 && ph_lo(f, 8) == 0;
    endfunction
endpackage
