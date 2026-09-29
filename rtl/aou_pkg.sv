// 线上逻辑帧为 250B：10B 协议头 PH + 48 个 5B 消息粒度，共 2000 位。
// 单条消息最多 30 粒度（150B、1200 位）；消息 byte0 位于向量最高字节。
// AXI data[7:0] 为最低地址字节，线上数据按高 byte lane 到低 byte lane 排列。
package aou_pkg;
    // 帧、消息、粒度和 10 位 AXI ID 的固定宽度。
    localparam int MSG_BITS = 1200; // 最大 WDATA1024：30 granule × 5B
    localparam int FLIT_BITS = 2000; // 逻辑 FDI：10B PH + 240B payload
    localparam int MSG_KIND_COUNT = 5;
    localparam int FLIT_GRANULES = 48;
    localparam int MSG_MAX_GRANULES = 30;
    localparam int GRANULE_BITS = 40;
    localparam int AXI_ID_COUNT = 1024; // 10 位 AXI ID 的取值总数

    // msg_t 保存最多 150B 消息；flit_t 保存 PH byte0～9 和载荷 byte0～239。
    // ax_t 对应请求消息的 ID、64 位地址及 AXI 控制字段。
    typedef logic [MSG_BITS-1:0] msg_t;
    typedef logic [FLIT_BITS-1:0] flit_t;
    typedef struct packed {
        logic [9:0] id;
        logic [63:0] addr;
        logic [7:0] len;
        logic [2:0] size, prot;
        logic [3:0] cache, qos;
        logic lock;
        logic [15:0] user;
    } ax_t;

    // 首字节：bit7:4 为类型，bit3:2 为 RP；数据消息 bit1:0 为 DLENGTH。
    // 类型 0 为 Misc（此处仅接收 CrdtGrant）；1/2/3/4/5/6 分别为
    // 写请求/读请求/带掩码写数据/读数据/写响应/全掩码写数据。
    // 五类队列将类型 3 和 6 合并为写数据类；未知类型返回类数 5。
    // DLENGTH=0/1/2 分别表示 256/512/1024 位，编码 3 非法；长度单位为 5B 粒度。
    function automatic int dl_code(input int width);
        return width == 256 ? 0 : width == 512 ? 1 : 2;
    endfunction
    function automatic int msg_kind(input msg_t m);
        case (m[1199:1196])
            1: return 0;
            2: return 1;
            3, 6: return 2;
            4: return 3;
            5: return 4;
            default: return MSG_KIND_COUNT;
        endcase
    endfunction
    function automatic int msg_rp(input msg_t m);
        return int'(m[1195:1194]);
    endfunction
    function automatic int granules(input logic [7:0] b);
        int dl;
        dl = int'(b[1:0]);
        case (b[7:4])
            1, 2: return 3;
            5: return 1;
            3: return dl == 0 ? 8 : dl == 1 ? 15 : dl == 2 ? 30 : 0;
            4: return dl == 0 ? 8 : dl == 1 ? 14 : dl == 2 ? 27 : 0;
            6: return dl == 0 ? 7 : dl == 1 ? 14 : dl == 2 ? 27 : 0;
            0: return b[3:1] == 4 ? 2 : 0; // Misc 操作码 100 为两粒度 CrdtGrant
            default: return 0;
        endcase
    endfunction

    // 请求各占 3 粒度，写响应占 1；写数据类按更短的全掩码格式预留容量。
    // credit 每单位代表一个 5B 粒度；三位编码 0～7 对应 0、1、4、8、16、32、64、128。
    // 写响应只用两位编码 0～3；发送时选择不超过待归还量的最大编码。
    function automatic int min_granules(input int k, input int width);
        case (k)
            0, 1: return 3;
            2: return width == 256 ? 7 : width == 512 ? 14 : 27;
            3: return width == 256 ? 8 : width == 512 ? 14 : 27;
            4: return 1;
            default: return 0;
        endcase
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
            default: return 128;
        endcase
    endfunction
    function automatic logic [2:0] credit_encode(input int amount, input int k);
        logic [2:0] result;
        result = 0;
        for (int e = 0; e < 8; e++) begin
            if ((k != 4 || e < 4) && credit_amount(e) <= amount) begin
                result = 3'(e);
            end
        end
        return result;
    endfunction

    // 写/读请求各占 15B：类型(4)、RP(2)、保留(1)、LOCK(1)、USER(16)、
    // 随后为 ID(10)、SIZE(3)、PROT(3)、LEN(8)、CACHE(4)、QOS(4)、ADDR(64)。
    // BURST 不上线，接收侧按 INCR 处理；地址需按拍大小对齐且不能跨 4KB 边界。
    function automatic msg_t make_req(input ax_t a, input logic wr, input int rp);
        return {wr ? 4'h1 : 4'h2, 2'(rp), 1'b0, a.lock, a.user,
                a.id, a.size, a.prot, a.len, a.cache, a.qos, a.addr, 1080'b0};
    endfunction
    function automatic ax_t get_req(input msg_t m);
        ax_t a;
        a.lock = m[1192];
        a.user = m[1191:1176];
        a.id = m[1175:1166];
        a.size = m[1165:1163];
        a.prot = m[1162:1160];
        a.len = m[1159:1152];
        a.cache = m[1151:1148];
        a.qos = m[1147:1144];
        a.addr = m[1143:1080];
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

    // 写数据：类型/RP/DLENGTH/USER 共 3B，随后是完整总线 DATA，非全掩码时再跟 STRB 位图。
    // 读数据：上述 3B 后接 ID(10)、RESP(2)、LAST(1)、保留(3)，再跟完整总线 DATA。
    // 写响应：类型/RP/保留(2)、USER(16)、ID(10)、RESP(2)、保留(4)，共 5B。
    // DATA 和 STRB 均先放高 byte lane；全掩码写数据省略 STRB，由类型 6 表示。
    function automatic msg_t make_wdata(input logic [1023:0] data,
                                        input logic [127:0] strb,
                                        input logic [15:0] user, input int rp,
                                        input int width);
        msg_t m;
        logic full;
        int n;
        n = width/8;
        full = 1;
        for (int j = 0; j < 128; j++) begin
            if (j < n && !strb[j]) begin
                full = 0;
            end
        end
        m = '0;
        m[1199:1176] = {full ? 4'h6 : 4'h3, 2'(rp), 2'(dl_code(width)), user};
        for (int j = 0; j < 128; j++) begin
            if (j < n) begin
                m[1199-(3+j)*8 -: 8] = data[(n-1-j)*8 +: 8];
            end
        end
        for (int j = 0; j < 16; j++) begin
            if (!full && j < n/8) begin
                m[1199-(3+n+j)*8 -: 8] = strb[(n/8-1-j)*8 +: 8];
            end
        end
        return m;
    endfunction
    function automatic msg_t make_rdata(input logic [1023:0] data,
                                        input logic [9:0] id, input logic [15:0] user,
                                        input logic [1:0] resp, input logic last,
                                        input int rp, input int width);
        msg_t m;
        m = '0;
        m[1199:1160] = {4'h4,2'(rp),2'(dl_code(width)),user,id,resp,last,3'b0};
        for (int j = 0; j < 128; j++) begin
            if (j < width/8) begin
                m[1199-(5+j)*8 -: 8] = data[(width/8-1-j)*8 +: 8];
            end
        end
        return m;
    endfunction
    function automatic msg_t make_b(input logic [9:0] id, input logic [15:0] user,
                                     input logic [1:0] resp, input int rp);
        return {4'h5,2'(rp),2'b0,user,id,resp,4'b0,1160'b0};
    endfunction
    function automatic logic [1023:0] get_data(input msg_t m, input int width);
        logic [1023:0] data;
        int start;
        start = m[1199:1196] == 4 ? 5 : 3;
        data = '0;
        for (int j = 0; j < 128; j++) begin
            if (j < width/8) begin
                data[(width/8-1-j)*8 +: 8] = m[1199-(start+j)*8 -: 8];
            end
        end
        return data;
    endfunction
    function automatic logic [127:0] get_strb(input msg_t m, input int width);
        logic [127:0] strb;
        strb = '0;
        for (int j = 0; j < 128; j++) begin
            if (j < width/8 && m[1199:1196] == 6) begin
                strb[j] = 1;
            end
        end
        for (int j = 0; j < 16; j++) begin
            if (j < width/64 && m[1199:1196] == 3) begin
                strb[(width/64-1-j)*8 +: 8] = m[1199-(3+width/8+j)*8 -: 8];
            end
        end
        return strb;
    endfunction

    // PH byte0～9：B0 高四位是 MsgStart[3:0]、低两位 FDId 固定为 0；
    // B1/B2 高四位/B3 对应 MsgStart[11:4]/[15:12]/[23:16]；
    // B4/B5 分别是 MsgCredit[7:0]/[15:8]；B6 高四位/B7/B8 高四位/B9
    // 对应 MsgStart[27:24]/[35:28]/[39:36]/[47:40]，其余位保留为 0。
    // MsgStart[i]=1 表示载荷第 i 个 5B 粒度开始一条新消息；续片不重复置位。
    // MsgCredit[15:14] 为 RP，[13:12] 为写响应编码，[11:0] 每三位依次为
    // 读数据、写数据、读请求、写请求编码（从高位到低位）。
    function automatic logic [47:0] get_starts(input flit_t f);
        logic [47:0] s;
        s[3:0] = f[1999 -:4];
        s[11:4] = f[1991 -:8];
        s[15:12] = f[1983 -:4];
        s[23:16] = f[1975 -:8];
        s[27:24] = f[1951 -:4];
        s[35:28] = f[1943 -:8];
        s[39:36] = f[1935 -:4];
        s[47:40] = f[1927 -:8];
        return s;
    endfunction
    function automatic flit_t make_flit(input logic [1919:0] payload,
                                       input logic [47:0] s, input logic [15:0] c);
        return {s[3:0],4'b0,s[11:4],s[15:12],4'b0,s[23:16],
                c[7:0],c[15:8],s[27:24],4'b0,s[35:28],
                s[39:36],4'b0,s[47:40],payload};
    endfunction
    function automatic logic legal_ph(input flit_t f);
        return f[1995:1992]==0 && f[1979:1976]==0 &&
               f[1947:1944]==0 && f[1931:1928]==0;
    endfunction
endpackage
