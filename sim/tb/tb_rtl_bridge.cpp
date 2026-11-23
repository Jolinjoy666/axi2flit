/*
 * RTL 联合验证：AXI 激励、独立字节记分板、可乱序完成的 MC 模型、AoU 字节对拍。
 * DUT 仅在时钟沿更新；参考内存依据 AXI 握手更新，MC 内存依据 MC 命令更新，二者分离。
 * 定义 TB_MC_HIF（默认构建）时存储侧为 HIF 接口，控制器由 SV 模型 hif_mc_model 建模：不再逐拍核对 MC 命令，
 * 改由模型检查 HIF 协议（credit、token、写指针、写数据拍数），端到端仍按参考内存核对每个 R 拍。
 * SystemC MsgBuilder 只构造期望消息，AouStreamDecoder 只解析线上字节；不参与 DUT 执行。
 * 仿真错误通过异常/非零退出码传播到 Makefile，不能把“程序运行结束”当作通过。
 */
#include "Vtb_rtl_bridge.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "aou_wire.h"
#include "aou_stream_decoder.h"
#include "msg_builder.h"
#include "credit_manager.h"
#include "bridge_test_config.h"
#include <array>
#include <deque>
#include <map>
#include <memory>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <type_traits>
#include <chrono>
#include <cstdio>

// 编译期配置，仅用于报告（由 Makefile 传入，与 RTL 参数一致）。
#ifndef TEST_TX_DEPTH
#define TEST_TX_DEPTH 0
#define TEST_WR_ROUTE_DEPTH 0
#define TEST_WRESP_DEPTH 0
#define TEST_WREQ_DEPTH 0
#define TEST_RREQ_DEPTH 0
#define TEST_RESPONSE_DEPTH 0
#define TEST_MC_RD_SLOTS 0
#define TEST_MC_WR_SLOTS 0
#define TEST_LINK_DEPTH 0
#endif
constexpr unsigned BYTES=AXI_DATA_BYTES;

// 吞吐结果：功能测试结束时汇总打印；quiet 时不输出逐项机器格式行。
struct PerfSummary { std::string dir; double gbps=0,upper=0,wgbps=0; uint64_t cycles=0; };
static std::vector<PerfSummary> g_perf;
static bool g_perf_quiet=false;
constexpr uint64_t BASE=0x1234567800000000ULL;
constexpr unsigned MEM_BYTES=128*1024;
#ifdef TB_MC_HIF
constexpr bool HIF=true;
#else
constexpr bool HIF=false;
#endif
#ifndef TEST_HIF_LINE_BYTES
#define TEST_HIF_LINE_BYTES 64
#define TEST_HIF_CORE_BYTES 32
#define TEST_HIF_LPR 24
#define TEST_HIF_HPR 8
#define TEST_HIF_WR 32
#endif
// HIF 控制器模型中读出时报 ECC 错误的行（与 tb_rtl_bridge.sv 的 HIF_POISON 一致）。
constexpr uint64_t HIF_POISON=(20480+AXI_DATA_BYTES)/TEST_HIF_LINE_BYTES*TEST_HIF_LINE_BYTES;
using Bytes=std::array<uint8_t,BYTES>;

template<class T> unsigned bit(const T& x, unsigned n) {
    if constexpr (std::is_integral_v<T>) return unsigned((x>>n)&1);
    else return (x[n/32]>>(n%32))&1;
}
template<class T> void set_bit(T& x, unsigned n, bool b) {
    if constexpr (std::is_integral_v<T>) {
        const T mask=T(1)<<n; x=b ? x|mask : x&~mask;
    } else {
        const uint32_t mask=uint32_t(1)<<(n%32);
        x[n/32]=b ? x[n/32]|mask : x[n/32]&~mask;
    }
}
template<class T> Bytes unpack(const T& x) {
    Bytes b{};
    for (unsigned j=0;j<BYTES;j++) for (unsigned k=0;k<8;k++) b[j]|=uint8_t(bit(x,j*8+k)<<k);
    return b;
}
template<class T> void pack(T& x,const Bytes& b) {
    x=T{};
    for (unsigned j=0;j<BYTES;j++) for (unsigned k=0;k<8;k++) set_bit(x,j*8+k,(b[j]>>k)&1);
}
// 参考编码：数据消息宽度按每拍传输大小选择（≤32B→256 位，64B→512 位，128B→1024 位），
// 只携带本拍字节地址所在的通道组；与被测 RTL 的编码独立实现。
unsigned dl_of(unsigned size) { return size<=5 ? 0 : size==6 ? 1 : 2; }
unsigned chunk_bytes(unsigned size) { return 32u<<dl_of(size); }
unsigned chunk_base(unsigned size,unsigned lane) { return lane/chunk_bytes(size)*chunk_bytes(size); }
AouMessage ref_wdata(const Bytes& data,const Bytes& strb,uint16_t user,unsigned rp,unsigned size,unsigned lane) {
    const unsigned n=chunk_bytes(size),base=chunk_base(size,lane);
    bool full=true; for(unsigned j=0;j<n;j++) full=full&&strb[base+j];
    AouMessage m; m.type=full ? MsgType::WriteDataFull : MsgType::WriteData; m.rp=uint8_t(rp);
    m.granules=full ? wdatafull_granules(DataLength(dl_of(size))) : wdata_granules(DataLength(dl_of(size)));
    m.byte_len=m.granules*GRANULE_BYTES;
    BitWriter bw(m.data);
    bw.put(unsigned(m.type),4); bw.put(rp,2); bw.put(dl_of(size),2); bw.put(user,16);
    bw.put_bytes_msb_first(data.data()+base,n);
    if(!full) {
        uint8_t packed[16]={};
        for(unsigned j=0;j<n;j++) if(strb[base+j]) packed[j>>3]|=uint8_t(1u<<(j&7));
        bw.put_bytes_msb_first(packed,n/8);
    }
    return m;
}
AouMessage ref_rdata(const RChannel& r,unsigned rp,unsigned size,unsigned lane) {
    const unsigned n=chunk_bytes(size),base=chunk_base(size,lane);
    AouMessage m; m.type=MsgType::ReadData; m.rp=uint8_t(rp);
    m.granules=rdata_granules(DataLength(dl_of(size))); m.byte_len=m.granules*GRANULE_BYTES;
    BitWriter bw(m.data);
    bw.put(unsigned(m.type),4); bw.put(rp,2); bw.put(dl_of(size),2); bw.put(r.user,16);
    bw.put(r.id&AXI_ID_MASK,10); bw.put(r.resp,2); bw.put(r.last,1); bw.skip(3);
    bw.put_bytes_msb_first(r.data+base,n);
    return m;
}
// SoC 把窄读数据复制到整条总线：通道 j 取所在组内偏移 j%n 的字节。
void replicate(uint8_t* data,unsigned size,unsigned lane) {
    const unsigned n=chunk_bytes(size),base=chunk_base(size,lane);
    uint8_t chunk[128]; std::copy(data+base,data+base+n,chunk);
    for(unsigned j=0;j<BYTES;j++) data[j]=chunk[j%n];
}

template<class T> AouWireFlit wire(const T& x) {
    AouWireFlit b{};
    for (unsigned j=0;j<250;j++) for(unsigned k=0;k<8;k++) b[j]|=uint8_t(bit(x,(249-j)*8+k)<<k);
    return b;
}

struct Cmd { AxChannel a; unsigned beat=0; bool write=false; Bytes data{},strb{}; uint16_t wuser=0; };
struct WriteContext { AxChannel a; unsigned beat=0; uint8_t status=0; };
struct Response { unsigned tag=0; uint8_t status=0; uint64_t due=0,sequence=0; Bytes data{}; };

struct Bench {
    std::unique_ptr<VerilatedContext> context=std::make_unique<VerilatedContext>();
    std::unique_ptr<Vtb_rtl_bridge> dut;
    std::unique_ptr<VerilatedVcdC> trace;
    uint64_t cycle=0,aw_count=0,w_count=0,ar_count=0,r_count=0,b_count=0,read_done=0,mc_count=0,mc_rd=0,mc_wr=0;
    uint64_t message_count=0,spanning=0,ooo=0,fwd_frames=0,rev_frames=0,stall_cycles=0;
    bool stress=false,pace=false,checking=true,allow_error=false,measure=false;
    bool block_mc=false,block_axi=false,block_link=false;
    bool corrupt_read=false; // 仅破坏记分板期望，验证检查器确实能拒绝错误数据。
    bool aw_fire=false,w_fire=false,ar_fire=false;
    double fbudget=512,rbudget=512;
    BridgeTestConfig config;
    std::array<std::deque<double>,2> arrival;
    std::array<double,2> next_launch{};
    std::array<uint64_t,14> stalls{};
    std::array<uint64_t,2> used_granules{}, empty_frames{};
    std::array<unsigned,2> wire_remaining{};
    unsigned rob_peak=0;
    std::array<uint64_t,2> next_mc_issue{};   // [0]=读口，[1]=写口
    std::string phase="initialization";
    std::vector<uint8_t> reference=std::vector<uint8_t>(MEM_BYTES),memory=std::vector<uint8_t>(MEM_BYTES);
    std::deque<WriteContext> write_context;
    std::map<unsigned,std::deque<RChannel>> expect_r;
    std::map<unsigned,std::deque<BChannel>> expect_b;
    std::array<std::array<std::deque<Cmd>,2>,TEST_RP> expect_cmd;
    std::array<std::array<std::array<std::deque<AouMessage>,5>,TEST_RP>,2> expect_msg;
    std::array<AouStreamDecoder,4> decoder;
    std::array<CreditMatrix,2> credits{};
    std::array<std::vector<Response>,2> responses;   // [0]=读完成，[1]=写完成
    uint64_t ar_time=0,w_time=0,tx_time=0,rx_time=0,target_req_time=0,target_w_time=0,target_rsp_time=0;
    unsigned max_tx=0,max_rx=0,max_target=0,max_return=0;
    // HIF 模型的统计在复位时清零，这里按增量累计；hif_first 表示等待请求后的第一条 HIF 命令。
    uint64_t interleave=0; std::array<uint32_t,4> hif_prev{}; bool hif_first=false;

    explicit Bench(bool waves=false,BridgeTestConfig settings={}) : config(settings) {
        context->traceEverOn(waves);
        dut=std::make_unique<Vtb_rtl_bridge>(context.get());
        if(waves) {
            trace=std::make_unique<VerilatedVcdC>(); dut->trace(trace.get(),4);
            const std::string path="results/rtl_"+std::to_string(AXI_DATA_WIDTH)+"_rp"+std::to_string(TEST_RP)+".vcd";
            trace->open(path.c_str());
        }
        dut->rst_n=0; dut->link_up=0;
        for(int i=0;i<4;i++) tick();
        dut->rst_n=1;
        for(int i=0;i<3;i++) tick();
        require(!dut->s_axi_awready&&!dut->s_axi_arready,"request accepted before link_up");
        dut->link_up=1;
        for(int i=0;i<80;i++) tick(); // 初始授信全部经过真实 RTL 路径
    }
    ~Bench() { if(trace) trace->close(); dut->final(); }
    void require(bool ok,const std::string& what) {
        if(!ok) throw std::runtime_error(phase+" cycle="+std::to_string(cycle)+": "+what);
    }
    bool range(uint64_t a,unsigned size) const { return a>=BASE && a-BASE+size<=MEM_BYTES; }
    uint8_t status(const AxChannel& a,unsigned beat,bool write) const {
        const uint64_t at=a.addr+(uint64_t(beat)<<a.size); const unsigned size=1u<<a.size;
        if(!range(at,size)) return 3;
        if(HIF) {
            // HIF 没有独占与逐拍写状态：独占按普通访问返回 OKAY；读到 ECC 中毒行的拍为 SLVERR。
            const uint64_t p=BASE+HIF_POISON;
            return (!write && at<p+TEST_HIF_LINE_BYTES && at+size>p) ? 2 : 0;
        }
        if(a.user==0xe002 && beat==1) return 2; // 定向故障：中间拍失败、末拍成功，验证 B 不丢错误。
        return a.lock ? 2 : 0;
    }
    void expected(unsigned dir,const AouMessage& m) {
        expect_msg[dir][m.rp][credit_kind_index(msgtype_to_credit_kind(m.type))].push_back(m);
    }
    AxChannel fields(bool wr) {
        AxChannel a;
        if(wr) {
            a.id=dut->s_axi_awid; a.addr=dut->s_axi_awaddr; a.len=dut->s_axi_awlen;
            a.size=dut->s_axi_awsize; a.burst=dut->s_axi_awburst; a.prot=dut->s_axi_awprot;
            a.cache=dut->s_axi_awcache; a.qos=dut->s_axi_awqos; a.lock=dut->s_axi_awlock; a.user=dut->s_axi_awuser;
        } else {
            a.id=dut->s_axi_arid; a.addr=dut->s_axi_araddr; a.len=dut->s_axi_arlen;
            a.size=dut->s_axi_arsize; a.burst=dut->s_axi_arburst; a.prot=dut->s_axi_arprot;
            a.cache=dut->s_axi_arcache; a.qos=dut->s_axi_arqos; a.lock=dut->s_axi_arlock; a.user=dut->s_axi_aruser;
        }
        return a;
    }
    void host_events() {
        if(aw_fire) {
            const auto a=fields(true); write_context.push_back({a,0,0}); ++aw_count;
            expected(0,MsgBuilder::build_write_req(a,a.qos%TEST_RP));
        }
        if(w_fire) {
            require(!write_context.empty(),"W without accepted AW");
            auto& c=write_context.front(); WChannel w; auto d=unpack(dut->s_axi_wdata);
            std::copy(d.begin(),d.end(),w.data); w.user=dut->s_axi_wuser; w.last=dut->s_axi_wlast;
            Cmd cmd; cmd.a=c.a; cmd.beat=c.beat; cmd.write=true; cmd.data=d; cmd.wuser=w.user;
            const unsigned rp=c.a.qos%TEST_RP, size=1u<<c.a.size;
            const uint64_t address=c.a.addr+uint64_t(c.beat)*size;
            const unsigned lane=unsigned(address%BYTES);
            auto s=status(c.a,c.beat,true);
            for(unsigned j=0;j<BYTES;j++) {
                w.strb[j]=cmd.strb[j]=uint8_t(bit(dut->s_axi_wstrb,j));
                if(w.strb[j]&&(j<lane||j>=lane+size)) s=2;
            }
            c.status=std::max(c.status,s);
            if(!s) for(unsigned j=0;j<size;j++) if(w.strb[lane+j]) reference[address-BASE+j]=d[lane+j];
            require(w.last==(c.beat==c.a.len),"host WLAST construction");
            expected(0,ref_wdata(d,cmd.strb,w.user,rp,c.a.size,lane));
            if(!HIF) expect_cmd[rp][1].push_back(cmd);
            ++c.beat; ++w_count;
            if(w.last) {
                w_time=cycle; BChannel b; b.id=c.a.id; b.user=c.a.user; b.resp=c.status;
                expect_b[b.id].push_back(b); expected(1,MsgBuilder::build_write_resp(b,rp));
                write_context.pop_front();
            }
        }
        if(ar_fire) {
            const auto a=fields(false); const unsigned rp=a.qos%TEST_RP;
            ++ar_count; ar_time=cycle; expected(0,MsgBuilder::build_read_req(a,rp));
            for(unsigned n=0;n<=a.len;n++) {
                Cmd cmd; cmd.a=a; cmd.beat=n; if(!HIF) expect_cmd[rp][0].push_back(cmd);
                RChannel r; r.id=a.id; r.user=a.user; r.last=n==a.len; r.resp=status(a,n,false);
                uint64_t address=a.addr+(uint64_t(n)<<a.size); unsigned lane=unsigned(address%BYTES);
                if(!r.resp) for(unsigned j=0;j<(1u<<a.size);j++) r.data[lane+j]=reference[address-BASE+j];
                expected(1,ref_rdata(r,rp,a.size,lane));
                replicate(r.data,a.size,lane);
                expect_r[a.id].push_back(r);
                if(corrupt_read) { expect_r[a.id].back().data[0]^=1; corrupt_read=false; }
            }
        }
        if(dut->s_axi_rvalid && dut->s_axi_rready) {
            auto& q=expect_r[dut->s_axi_rid]; require(!q.empty(),"unexpected/duplicate R");
            const auto e=q.front(); q.pop_front(); const auto data=unpack(dut->s_axi_rdata);
            require(dut->s_axi_rresp==e.resp&&dut->s_axi_rlast==e.last&&dut->s_axi_ruser==e.user,"R attributes/LAST");
            require(std::equal(data.begin(),data.end(),e.data),"R data mismatch");
            ++r_count; if(e.last) ++read_done;
            if(measure) { max_tx=std::max(max_tx,unsigned((tx_time-ar_time)*2)); max_rx=std::max(max_rx,unsigned((cycle-rx_time)*2)); }
        }
        if(dut->s_axi_bvalid && dut->s_axi_bready) {
            auto& q=expect_b[dut->s_axi_bid]; require(!q.empty(),"unexpected/duplicate B");
            const auto e=q.front(); q.pop_front();
            require(dut->s_axi_bresp==e.resp&&dut->s_axi_buser==e.user,"B status/USER aggregation");
            ++b_count;
            if(measure) { max_tx=std::max(max_tx,unsigned((tx_time-w_time)*2)); max_rx=std::max(max_rx,unsigned((cycle-rx_time)*2)); }
        }
    }
    template<class Fields> void mc_issue(bool write,const Fields& f) {
        auto& q=expect_cmd[f.rp][write]; require(!q.empty(),"unrequested MC command");
        const auto e=q.front(); q.pop_front(); const auto& a=e.a;
        require(f.id==a.id && f.addr==a.addr+(uint64_t(e.beat)<<a.size),"MC address/ID");
        require(f.size==a.size&&f.len==a.len&&f.beat==e.beat,"MC SIZE/LEN/beat");
        require(f.first==(e.beat==0)&&f.last==(e.beat==a.len),"MC first/last");
        require(f.prot==a.prot&&f.cache==a.cache&&f.qos==a.qos&&f.lock==a.lock&&f.user==a.user,"MC attributes");
        const unsigned size=1u<<a.size; const auto addr=f.addr; const unsigned lane=unsigned(addr%BYTES);
        if(write) {
            // 写数据只比较本拍所在通道组；选通在组外必须为 0。
            const unsigned n=chunk_bytes(a.size),base=chunk_base(a.size,lane);
            for(unsigned j=base;j<base+n;j++) require(f.data[j]==e.data[j],"MC WDATA byte mapping");
            require(f.strb==e.strb,"MC WSTRB mapping");
            require(f.wuser==e.wuser,"MC WUSER");
        }
        auto& list=responses[write];
        for(const auto& r:list) require(r.tag!=f.tag,"MC tag reused while outstanding");
        Response r; r.tag=f.tag; r.status=status(a,e.beat,write); r.sequence=mc_count++; ++(write ? mc_wr : mc_rd);
        r.due=cycle+(stress ? config.mc_latency+(mc_count*7)%23 : config.mc_latency);
        next_mc_issue[write]=cycle+config.mc_interval;
        for(unsigned j=0;j<BYTES;j++) if(write&&e.strb[j]&&(j<lane||j>=lane+size)) r.status=2;
        if(!r.status) for(unsigned j=0;j<size;j++) {
            if(write) { if(e.strb[lane+j]) memory[addr-BASE+j]=e.data[lane+j]; }
            else r.data[lane+j]=memory[addr-BASE+j];
        }
        list.push_back(r);
        if(measure) max_target=std::max(max_target,unsigned((cycle-(write ? std::max(target_req_time,target_w_time) : target_req_time))*2));
    }
    // HIF：模型统计按增量累计；延迟按“请求帧到达→第一条 HIF 命令”“末拍数据→响应上线”测量。
    void hif_event() {
        require(!dut->mc_model_error,"HIF controller model reported a protocol violation");
        const std::array<uint32_t,4> now{dut->mc_stat_rd,dut->mc_stat_wr,dut->mc_stat_ooo,dut->mc_stat_interleave};
        std::array<uint64_t*,4> total{&mc_rd,&mc_wr,&ooo,&interleave};
        for(unsigned i=0;i<4;i++) { if(now[i]<hif_prev[i]) hif_prev[i]=0; *total[i]+=now[i]-hif_prev[i]; hif_prev[i]=now[i]; }
        if(measure) {
            if((dut->hif_obs&1)&&hif_first) {
                max_target=std::max(max_target,unsigned((cycle-std::max(target_req_time,target_w_time))*2));
                hif_first=false;
            }
            if(dut->hif_obs&6) target_rsp_time=cycle;
        }
    }
    struct McFields {
        unsigned tag=0,rp=0,id=0,size=0,len=0,beat=0,prot=0,cache=0,qos=0,user=0,wuser=0;
        uint64_t addr=0; bool first=false,last=false,lock=false; Bytes data{},strb{};
    };
    void mc_event() {
        if(dut->mc_rd_valid&&dut->mc_rd_ready) {
            McFields f; f.tag=dut->mc_rd_tag; f.rp=dut->mc_rd_rp; f.id=dut->mc_rd_id; f.addr=dut->mc_rd_addr;
            f.size=dut->mc_rd_size; f.len=dut->mc_rd_len; f.beat=dut->mc_rd_beat; f.first=dut->mc_rd_first;
            f.last=dut->mc_rd_last; f.prot=dut->mc_rd_prot; f.cache=dut->mc_rd_cache; f.qos=dut->mc_rd_qos;
            f.lock=dut->mc_rd_lock; f.user=dut->mc_rd_user;
            mc_issue(false,f);
        }
        if(dut->mc_wr_valid&&dut->mc_wr_ready) {
            McFields f; f.tag=dut->mc_wr_tag; f.rp=dut->mc_wr_rp; f.id=dut->mc_wr_id; f.addr=dut->mc_wr_addr;
            f.size=dut->mc_wr_size; f.len=dut->mc_wr_len; f.beat=dut->mc_wr_beat; f.first=dut->mc_wr_first;
            f.last=dut->mc_wr_last; f.prot=dut->mc_wr_prot; f.cache=dut->mc_wr_cache; f.qos=dut->mc_wr_qos;
            f.lock=dut->mc_wr_lock; f.user=dut->mc_wr_user; f.wuser=dut->mc_wr_wuser;
            f.data=unpack(dut->mc_wr_data);
            for(unsigned j=0;j<BYTES;j++) f.strb[j]=uint8_t(bit(dut->mc_wr_strb,j));
            mc_issue(true,f);
        }
    }
    // 在 Flit 实际交付点检查格式：消息内容与 AXI/MC 期望比较，credit 另做独立账本。
    template<class T> void frame(unsigned index,const T& bits) {
        const auto f=deserialize_aou(wire(bits));
        const bool carry=decoder[index].carry_active(); const auto parsed=decoder[index].consume(f);
        if(index<2) {
            const unsigned dir=index; if(dir==0) ++fwd_frames; else ++rev_frames;
            if(!f.msg_start && wire_remaining[dir]==0) ++empty_frames[dir];
            for(unsigned g=0;g<48;g++) {
                if((f.msg_start>>g)&1) wire_remaining[dir]=unsigned(message_granules_from_header(f.payload[g*5]));
                if(wire_remaining[dir]) { ++used_granules[dir]; --wire_remaining[dir]; }
            }
            if(carry) ++spanning;
            decode_header_credits(f.msg_credit,TEST_RP,[&](const CreditUpdate& c) { credits[1-dir][c.rp][credit_kind_index(c.kind)]+=c.granules; });
            for(unsigned g=0;g<48;g++) if((f.msg_start>>g)&1) {
                const uint8_t b=f.payload[g*5]; const auto kind=msgtype_to_credit_kind(msg_type_of(b));
                if(kind!=CreditKind::Count) {
                    auto& balance=credits[dir][msg_rp_of(b)][credit_kind_index(kind)];
                    unsigned need=unsigned(message_granules_from_header(b));
                    require(balance>=need,"wire-level credit underflow"); balance-=need;
                }
            }
            for(const auto& m:parsed.messages) {
                if(m.type==MsgType::Misc) {
                    CreditMatrix grants{}; require(decode_crdt_grant_message(m,TEST_RP,grants),"invalid wire Misc");
                    for(unsigned rp=0;rp<TEST_RP;rp++) for(unsigned k=0;k<5;k++) credits[1-dir][rp][k]+=grants[rp][k];
                    continue;
                }
                auto& q=expect_msg[dir][m.rp][credit_kind_index(msgtype_to_credit_kind(m.type))];
                require(!q.empty(),"unexpected wire message"); const auto e=q.front(); q.pop_front();
                require(m.granules==e.granules&&std::equal(m.data,m.data+m.byte_len,e.data),"RTL/SystemC wire bytes differ");
                ++message_count;
                if(measure&&dir==0&&(m.type==MsgType::ReadReq||m.type==MsgType::WriteData||m.type==MsgType::WriteDataFull)) tx_time=cycle;
                if(measure&&dir==1) max_return=std::max(max_return,unsigned((cycle-target_rsp_time)*2));
            }
        } else if(measure) {
            for(const auto& m:parsed.messages) {
                if(index==2&&(m.type==MsgType::ReadData||m.type==MsgType::WriteResp)) rx_time=cycle;
                if(index==3&&(m.type==MsgType::ReadReq||m.type==MsgType::WriteReq)) { target_req_time=cycle; hif_first=true; }
                if(index==3&&(m.type==MsgType::WriteData||m.type==MsgType::WriteDataFull)) target_w_time=cycle;
            }
        }
    }
    void tick() {
        require(cycle<2000000,"watchdog timeout"); dut->clk=0;
        fbudget=std::min(512.0,fbudget+config.wire_gbps()*2);
        rbudget=std::min(512.0,rbudget+config.wire_gbps()*2);
        dut->forward_enable=!block_link&&(!pace||fbudget>=256)&&(!stress||cycle%7!=0);
        dut->reverse_enable=!block_link&&(!pace||rbudget>=256)&&(!stress||cycle%5!=0);
        dut->s_axi_rready=!block_axi&&(!stress||cycle%11>=4);
        dut->s_axi_bready=!block_axi&&(!stress||cycle%13>=3);
        if(HIF) { dut->mc_block=block_mc; dut->mc_stress=stress; }
        else {
            dut->mc_rd_ready=!block_mc&&cycle>=next_mc_issue[0]&&(!stress||cycle%9>=3);
            dut->mc_wr_ready=!block_mc&&cycle>=next_mc_issue[1]&&(!stress||cycle%7>=2);
        }
        dut->forward_deliver=1; dut->reverse_deliver=1;
        if(config.physical()) {
            // 串行发送间隔与传播流水线分别建模；延迟不会重复降低稳态带宽。
            dut->forward_enable=!block_link && cycle*2.0+2.0+1e-9>=next_launch[0];
            dut->reverse_enable=!block_link && cycle*2.0+2.0+1e-9>=next_launch[1];
            dut->forward_deliver=!arrival[0].empty() && arrival[0].front()<=cycle*2.0+1e-9;
            dut->reverse_deliver=!arrival[1].empty() && arrival[1].front()<=cycle*2.0+1e-9;
        }
        std::array<int,2> response{-1,-1};
        for(unsigned port=0;port<2;port++)
            for(unsigned i=0;i<responses[port].size();i++) if(responses[port][i].due<=cycle) {
                response[port]=int(i); if(!stress) break;
            }
        // 固定响应就绪接口没有反压时直接选择；异常测试可自己驱动完成口。
        if(checking&&!HIF) {
            dut->mc_rd_rsp_valid=response[0]>=0;
            if(response[0]>=0) { const auto& r=responses[0][response[0]]; dut->mc_rd_rsp_tag=r.tag; dut->mc_rd_rsp_resp=r.status; pack(dut->mc_rd_rsp_data,r.data); }
            dut->mc_wr_rsp_valid=response[1]>=0;
            if(response[1]>=0) { const auto& r=responses[1][response[1]]; dut->mc_wr_rsp_tag=r.tag; dut->mc_wr_rsp_resp=r.status; }
        }
        dut->eval();
        aw_fire=dut->s_axi_awvalid&&dut->s_axi_awready;
        ar_fire=dut->s_axi_arvalid&&dut->s_axi_arready;
        w_fire=dut->s_axi_wvalid&&dut->s_axi_wready;
        if(checking&&dut->rst_n&&dut->link_up) {
            for(unsigned n=0;n<stalls.size();n++) stalls[n]+=((dut->perf_stall>>n)&1);
            rob_peak=std::max(rob_peak,unsigned(dut->perf_rob_level));
            host_events();
            if(dut->fwd_valid&&dut->fwd_ready) { frame(0,dut->fwd_data); fbudget-=256; }
            if(dut->rev_valid&&dut->rev_ready) { frame(1,dut->rev_data); rbudget-=256; }
            if(dut->soc_rx_valid&&dut->soc_rx_ready) frame(2,dut->soc_rx_data);
            if(dut->target_rx_valid&&dut->target_rx_ready) frame(3,dut->target_rx_data);
            if(config.physical()) {
                if(dut->soc_rx_valid&&dut->soc_rx_ready) { require(!arrival[1].empty(),"missing reverse flight"); arrival[1].pop_front(); }
                if(dut->target_rx_valid&&dut->target_rx_ready) { require(!arrival[0].empty(),"missing forward flight"); arrival[0].pop_front(); }
                for(unsigned dir=0;dir<2;dir++) {
                    const bool sent=dir ? dut->rev_valid&&dut->rev_ready : dut->fwd_valid&&dut->fwd_ready;
                    if(sent) {
                        // 最多提前一拍排入串行器，发送时刻不早于接受时刻，保留分数周期相位。
                        const double launch=std::max(next_launch[dir],cycle*2.0);
                        arrival[dir].push_back(launch+config.flight_ns());
                        next_launch[dir]=launch+256/config.wire_gbps();
                    }
                }
            }
            for(unsigned port=0;port<2&&!HIF;port++) {
                const bool fire=port ? dut->mc_wr_rsp_valid&&dut->mc_wr_rsp_ready : dut->mc_rd_rsp_valid&&dut->mc_rd_rsp_ready;
                if(response[port]<0||!fire) continue;
                if(measure) target_rsp_time=cycle;
                auto& list=responses[port];
                for(unsigned i=0;i<list.size();i++) if(list[i].sequence<list[response[port]].sequence) { ++ooo; break; }
                list.erase(list.begin()+response[port]);
            }
            if(HIF) hif_event(); else mc_event();
            if((dut->fwd_valid&&!dut->fwd_ready)||(dut->s_axi_rvalid&&!dut->s_axi_rready)||
               ((dut->perf_stall>>11)&1)) ++stall_cycles;
        }
        context->timeInc(1000); if(trace) trace->dump(context->time());
        dut->clk=1; dut->eval(); context->timeInc(1000); if(trace) trace->dump(context->time());
        ++cycle;
        if(!allow_error) require(!dut->soc_error&&!dut->target_error,"RTL protocol_error asserted");
    }
    template<class P> void until(P predicate,unsigned timeout=200000) {
        const auto end=cycle+timeout;
        do { tick(); require(cycle<end,"transaction timeout"); } while(!predicate());
    }
    AxChannel addr(unsigned off,unsigned n,unsigned size,unsigned id,unsigned qos=0,bool lock=false) {
        AxChannel a; a.addr=BASE+off; a.id=uint16_t(id); a.len=uint8_t(n-1); a.size=uint8_t(size);
        a.burst=1; a.qos=uint8_t(qos); a.user=uint16_t(0x8100+id); a.prot=3; a.cache=10; a.lock=lock; return a;
    }
    void aw(const AxChannel& a) {
        drive_aw(a); dut->s_axi_awvalid=1;
        until([&]{return aw_fire;}); dut->s_axi_awvalid=0;
    }
    void ar(const AxChannel& a) {
        dut->s_axi_araddr=a.addr; dut->s_axi_arid=a.id; dut->s_axi_arlen=a.len; dut->s_axi_arsize=a.size;
        dut->s_axi_arburst=a.burst; dut->s_axi_arqos=a.qos; dut->s_axi_arcache=a.cache; dut->s_axi_arprot=a.prot;
        dut->s_axi_arlock=a.lock; dut->s_axi_aruser=a.user; dut->s_axi_arvalid=1;
        until([&]{return ar_fire;}); dut->s_axi_arvalid=0;
    }
    void drive_aw(const AxChannel& a) {
        dut->s_axi_awaddr=a.addr; dut->s_axi_awid=a.id; dut->s_axi_awlen=a.len; dut->s_axi_awsize=a.size;
        dut->s_axi_awburst=a.burst; dut->s_axi_awqos=a.qos; dut->s_axi_awcache=a.cache; dut->s_axi_awprot=a.prot;
        dut->s_axi_awlock=a.lock; dut->s_axi_awuser=a.user;
    }
    void drive_w(const AxChannel& a,unsigned n,unsigned seed,int mask) {
        Bytes d{}; dut->s_axi_wstrb={}; const unsigned lane=unsigned((a.addr+(uint64_t(n)<<a.size))%BYTES);
        for(unsigned j=0;j<BYTES;j++) {
            d[j]=uint8_t(seed*17+n*29+j*7+(j>>3));
            bool strobe=j>=lane&&j<lane+(1u<<a.size);
            if(mask==1) strobe=strobe&&(j%3!=0); if(mask==2) strobe=false;
            set_bit(dut->s_axi_wstrb,j,strobe);
        }
        pack(dut->s_axi_wdata,d); dut->s_axi_wuser=uint16_t(0x5100+n); dut->s_axi_wlast=n==a.len;
    }
    void w(const AxChannel& a,unsigned seed=1,int mask=0) {
        for(unsigned n=0;n<=a.len;n++) {
            drive_w(a,n,seed,mask); dut->s_axi_wvalid=1;
            until([&]{return w_fire;}); dut->s_axi_wvalid=0;
        }
    }
    // 多笔写突发：AW 与 W 两个通道各自推进，第 i 笔数据种子为 i+1。
    // AXI 规定主机不得等 AWREADY 才给出 WVALID；从机何时接受 AW、W 由 RTL 决定（本桥要等对应 AW 进入写路由 FIFO）。
    void aw_w(const std::vector<AxChannel>& bursts) {
        size_t ai=0,wi=0; unsigned beat=0; const auto end=cycle+200000;
        while(ai<bursts.size()||wi<bursts.size()) {
            dut->s_axi_awvalid=ai<bursts.size(); if(ai<bursts.size()) drive_aw(bursts[ai]);
            dut->s_axi_wvalid=wi<bursts.size(); if(wi<bursts.size()) drive_w(bursts[wi],beat,unsigned(wi+1),0);
            tick(); require(cycle<end,"transaction timeout");
            if(aw_fire) ++ai;
            if(w_fire) { if(beat==bursts[wi].len) { ++wi; beat=0; } else ++beat; }
        }
        dut->s_axi_awvalid=0; dut->s_axi_wvalid=0;
    }
    void write(const AxChannel& a,unsigned seed=1,int mask=0) { auto b=b_count; aw(a); w(a,seed,mask); until([&]{return b_count==b+1;}); }
    void read(const AxChannel& a) { auto n=read_done; ar(a); until([&]{return read_done==n+1;}); }
    void drain() {
        until([&]{return b_count==aw_count&&read_done==ar_count;});
        for(int i=0;i<100;i++) tick();
        require(responses[0].empty()&&responses[1].empty()&&write_context.empty(),"pending MC/AXI state after drain");
        for(auto& dir:expect_msg) for(auto& rp:dir) for(auto& q:rp) require(q.empty(),"missing wire message after drain");
        for(auto& rp:expect_cmd) for(auto& q:rp) require(q.empty(),"missing MC command after drain");
        if(!HIF) require(reference==memory,"final independent memory images differ");
    }
    // 联合复位明确取消所有在途事务；两端、链路 FIFO、MC 模型和记分板同时清空。
    // 不把“单端复位后旧 MC 响应继续到达”误当成受支持的恢复协议。
    void coordinated_reset() {
        checking=false; dut->link_up=0; dut->rst_n=0;
        dut->s_axi_awvalid=0; dut->s_axi_arvalid=0; dut->s_axi_wvalid=0;
        dut->mc_rd_rsp_valid=0; dut->mc_wr_rsp_valid=0; dut->mc_block=0; dut->mc_stress=0;
        for(int i=0;i<4;i++) tick();
        write_context.clear(); responses={}; expect_r.clear(); expect_b.clear();
        for(auto& rp:expect_cmd) for(auto& q:rp) q.clear();
        for(auto& dir:expect_msg) for(auto& rp:dir) for(auto& q:rp) q.clear();
        decoder={}; credits={};
        arrival={}; next_launch={}; next_mc_issue={}; wire_remaining={};
        reference.assign(MEM_BYTES,0); memory.assign(MEM_BYTES,0);
        aw_count=w_count=ar_count=r_count=b_count=read_done=mc_count=mc_rd=mc_wr=0;
        block_axi=block_mc=block_link=false; stress=false; fbudget=rbudget=512;
        dut->rst_n=1;
        for(int i=0;i<3;i++) tick();
        checking=true; dut->link_up=1;
        for(int i=0;i<80;i++) tick();
    }
};

// 阶段统计：各阶段的周期数与事务数。协同复位会清零计数，用 pause/resume 跨过复位。
struct PhaseLog {
    struct Row { std::string name; uint64_t cycles=0,aw=0,w=0,ar=0,r=0; };
    std::vector<Row> rows;
    uint64_t c0=0,aw0=0,w0=0,ar0=0,r0=0;
    Bench* b=nullptr;
    void snap() { c0=b->cycle; aw0=b->aw_count; w0=b->w_count; ar0=b->ar_count; r0=b->r_count; }
    void add() {
        auto& x=rows.back();
        x.cycles+=b->cycle-c0; x.aw+=b->aw_count-aw0; x.w+=b->w_count-w0; x.ar+=b->ar_count-ar0; x.r+=b->r_count-r0;
    }
    void begin(const std::string& name,const char* tag) { if(!rows.empty()) add(); rows.push_back({name}); b->phase=tag; snap(); }
    void end() { add(); }
};

static void report_functional(const Bench& b,const PhaseLog& log,double wall_s,uint64_t total_cycles,
                              uint64_t aw,uint64_t w,uint64_t ar,uint64_t r,uint64_t mc_rd,uint64_t mc_wr) {
    // 中文按显示宽度对齐：汉字占 2 列。
    auto pad=[](const std::string& t,int width) {
        int cols=0; for(unsigned char c:t) { if(c<0x80) ++cols; else if((c&0xC0)!=0x80) cols+=2; }
        return t+std::string(std::max(0,width-cols),' ');
    };
    auto u=[](uint64_t v) { return (unsigned long long)v; };
    std::printf("\n============ 独立 RTL 仿真  DATA_WIDTH=%u  RP=%u%s ============\n",AXI_DATA_WIDTH,TEST_RP,
                HIF ? "  存储侧 HIF" : "");
    std::printf("配置  深度 TX %d、写路由 %d，RDATA/WRESP %d/%d，WREQ/RREQ/WDATA %d/%d/%d，RESPONSE %d；",
                TEST_TX_DEPTH,TEST_WR_ROUTE_DEPTH,TEST_RX_DEPTH,TEST_WRESP_DEPTH,TEST_WREQ_DEPTH,TEST_RREQ_DEPTH,TEST_WDATA_DEPTH,
                TEST_RESPONSE_DEPTH);
    if(HIF) std::printf("HIF %d 位、每条命令 %dB，credit LPR/HPR/WR %d/%d/%d；",TEST_HIF_CORE_BYTES*8,TEST_HIF_LINE_BYTES,
                        TEST_HIF_LPR,TEST_HIF_HPR,TEST_HIF_WR);
    else std::printf("MC_SLOTS %d/%d；",TEST_MC_RD_SLOTS,TEST_MC_WR_SLOTS);
    std::printf("链路限速 %.0f GB/s（%s）\n",LINK_BYTES_PER_NS,LINK_BITS_PER_SYMBOL==2 ? "PAM4" : "NRZ");
    std::printf("%s%s%s%s\n",pad("阶段",28).c_str(),pad("周期",8).c_str(),pad("写 突发/拍",12).c_str(),"读 突发/拍");
    for(const auto& x:log.rows) {
        char wbuf[32],rbuf[32],cbuf[32];
        std::snprintf(cbuf,sizeof cbuf,"%llu",u(x.cycles));
        std::snprintf(wbuf,sizeof wbuf,"%llu/%llu",u(x.aw),u(x.w));
        std::snprintf(rbuf,sizeof rbuf,"%llu/%llu",u(x.ar),u(x.r));
        std::printf("%s%s%s%s\n",pad(x.name,28).c_str(),pad(cbuf,8).c_str(),pad(wbuf,12).c_str(),rbuf);
    }
    std::printf("延迟  SoC 侧 %u ns（发送 %u + 接收 %u），存储侧 %u ns（接收 %u + 发送 %u）\n",
                b.max_tx+b.max_rx,b.max_tx,b.max_rx,b.max_target+b.max_return,b.max_target,b.max_return);
    for(const auto& p:g_perf) {
        const char* head=&p==&g_perf[0] ? "吞吐  " : "      ";
        if(p.dir=="read")  std::printf("%s读 %.2f GB/s（上限 %.2f）\n",head,p.gbps,p.upper);
        if(p.dir=="write") std::printf("%s写 %.2f GB/s（上限 %.2f）\n",head,p.gbps,p.upper);
        if(p.dir=="mixed") std::printf("%s同时读写 %.2f / %.2f GB/s\n",head,p.gbps,p.wgbps);
    }
    if(HIF) std::printf("统计  写 %llu 突发 %llu 拍、读 %llu 突发 %llu 拍，HIF 命令 读 %llu 写 %llu，乱序返回 %llu、交织 %llu，链路消息核对 %llu 条（跨帧 %llu），数据错误 0\n",
                u(aw),u(w),u(ar),u(r),u(mc_rd),u(mc_wr),u(b.ooo),u(b.interleave),u(b.message_count),u(b.spanning));
    else std::printf("统计  写 %llu 突发 %llu 拍、读 %llu 突发 %llu 拍，MC 命令 读 %llu 写 %llu，MC 乱序 %llu，链路消息核对 %llu 条（跨帧 %llu），数据错误 0\n",
                u(aw),u(w),u(ar),u(r),u(mc_rd),u(mc_wr),u(b.ooo),u(b.message_count),u(b.spanning));
    uint64_t perf_cycles=0; for(const auto& p:g_perf) perf_cycles+=p.cycles;
    std::printf("用时  硬件时间 %.1f us（被仿真电路经过的时间），本机运行 %.1f s\n",(total_cycles+perf_cycles)*2/1000.0,wall_s);
}

void performance(const BridgeTestConfig& cfg);
void functional(bool waves,bool with_perf) {
    const auto t0=std::chrono::steady_clock::now();
    Bench b(waves); constexpr unsigned SIZE=AXI_SIZE_CODE;
    PhaseLog log; log.b=&b;
    log.begin("单拍空载延迟","single-beat latency"); b.measure=true;
    b.read(b.addr(0,1,SIZE,1)); b.write(b.addr(4096,1,SIZE,2),3); b.read(b.addr(4096,1,SIZE,3));
    b.measure=false; b.require(b.max_tx+b.max_rx<=20,"SoC bridge sample latency >20ns");
    b.require(b.max_target<=20,"Target request conversion sample latency >20ns");
    b.require(b.max_target+b.max_return<=20,"Target request+return sample latency >20ns");
    log.begin("突发、掩码、窄访问","bursts, masks, narrow lanes");
    for(unsigned n:{2u,4u,16u,4096u/BYTES}) { auto a=b.addr(8192,n,SIZE,10+n); b.write(a,n); b.read(a); }
    auto masked=b.addr(8192,16,SIZE,30); b.write(masked,21,1); b.read(masked); b.write(masked,43,2); b.read(masked);
    auto narrow=b.addr(12288+4,16,2,31); b.write(narrow,9,1); b.read(narrow);
    auto longburst=b.addr(16384,256,2,32); b.write(longburst,7); b.read(longburst);
    // 32B/64B 传输大小：在更宽的总线上分别走 256/512 位数据消息，含全选通与部分选通。
    for(unsigned sz=5;sz<SIZE;sz++) {
        auto mid=b.addr(65536+(sz-5)*4096+(1u<<sz),8,sz,33+sz);
        b.write(mid,5+sz); b.read(mid); b.write(mid,9+sz,1); b.read(mid);
    }
    log.begin("错误响应","error responses");
    auto outside=b.addr(MEM_BYTES,4,SIZE,40); b.write(outside); b.read(outside);
    auto lock=b.addr(20480,2,SIZE,41,0,true); b.write(lock); b.read(lock);
    auto middle_error=b.addr(20480,4,SIZE,42); middle_error.user=0xe002;
    b.write(middle_error,19); b.read(middle_error);
    if(HIF) { auto far=b.addr(4*MEM_BYTES,2,SIZE,43); b.write(far); b.read(far); }   // 桥的地址窗口外
    log.begin(TEST_RP>1 ? "多事务并发、多RP、MC乱序" : "多事务并发、MC乱序","outstanding, multi-RP, MC reordering"); b.stress=true;
    std::vector<AxChannel> batch;
    for(unsigned i=0;i<4;i++) batch.push_back(b.addr(24576+i*4096,16,SIZE,50+i,i));
    b.aw_w(batch);
    b.until([&]{return b.b_count==b.aw_count;});
    for(const auto& a:batch) b.ar(a);
    b.until([&]{return b.read_done==b.ar_count;});
    // 同 ID 多笔同 RP 顺序，及一个方向等待时另一个方向仍能推进。
    for(unsigned i=0;i<3;i++) b.ar(b.addr(24576+i*4096,16,SIZE,70,0));
    b.write(b.addr(45056,16,SIZE,80,TEST_RP-1),16);
    b.drain();
    log.begin("长时间背压与credit恢复","long downstream stalls and credit recovery");
    b.block_axi=true;
    b.ar(b.addr(16384,256,2,90));
    for(int i=0;i<400;i++) b.tick();
    b.block_axi=false; b.drain();
    b.block_mc=true; b.ar(b.addr(8192,16,SIZE,91));
    for(int i=0;i<60;i++) b.tick();
    b.block_mc=false; b.drain();
    b.block_link=true; b.ar(b.addr(8192,4,SIZE,92));
    for(int i=0;i<60;i++) b.tick();
    b.block_link=false; b.drain();
    if(TEST_RP>1) {
        log.begin("同ID跨RP准入背压","same ID cross-RP admission");
        b.block_axi=true; b.ar(b.addr(8192,4,SIZE,100,0));
        // 驱动另一个 RP 的同 ID 请求，前一笔未完成时必须持续背压。
        b.dut->s_axi_arqos=1; b.dut->s_axi_arvalid=1;
        for(int i=0;i<60;i++) { b.tick(); b.require(!b.ar_fire,"same-ID cross-RP request admitted early"); }
        b.block_axi=false; b.until([&]{return b.ar_fire;}); b.dut->s_axi_arvalid=0; b.drain();
    }
    b.require(b.spanning>0&&b.ooo>0&&b.stall_cycles>0,"required spanning/reordering/stall coverage absent: spanning="+std::to_string(b.spanning)+" ooo="+std::to_string(b.ooo)+" stall="+std::to_string(b.stall_cycles));
    // 复位前的累计值；复位会清零计数器。
    const uint64_t aw=b.aw_count,w=b.w_count,ar=b.ar_count,r=b.r_count,mc_rd=b.mc_rd,mc_wr=b.mc_wr;
    log.begin("在途事务时协同复位","coordinated reset during outstanding traffic");
    b.block_axi=true; b.ar(b.addr(8192,16,SIZE,101));
    for(int i=0;i<30;i++) b.tick();
    b.require(b.read_done<b.ar_count,"reset scenario has no outstanding read");
    log.add(); b.coordinated_reset(); log.snap();
    b.write(b.addr(4096,4,SIZE,102),23); b.read(b.addr(4096,4,SIZE,103)); b.drain();
    log.end();
    const uint64_t total_cycles=b.cycle;
    if(with_perf) {
        // 简短吞吐测量：满载场景，读、写分别运行，再读写同时。
        g_perf_quiet=true;
        BridgeTestConfig cfg; cfg.scenario="saturated"; cfg.warmup=1000; cfg.cycles=10000;
        performance(cfg);
        cfg.direction="mixed"; performance(cfg);
        g_perf_quiet=false;
    }
    const double wall=std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    report_functional(b,log,wall,total_cycles,aw+b.aw_count,w+b.w_count,ar+b.ar_count,r+b.r_count,
                      mc_rd+b.mc_rd,mc_wr+b.mc_wr);
}

// 满载测试：AW 与 W 独立推进，MC 可每拍接收/返回；等待时间不等于发起间隔。
// baseline 保留原先逐笔发 AW 再发 W 的激励，供修改前后的同条件对比。
void performance_mixed(const BridgeTestConfig& cfg);
void performance(const BridgeTestConfig& cfg) {
    cfg.validate(BYTES);
    if(cfg.direction=="mixed") { performance_mixed(cfg); return; }
    // 每拍传输大小可用 --size 设为窄传输；数据消息宽度随之选择。
    const unsigned SZ=cfg.size<0 ? AXI_SIZE_CODE : unsigned(cfg.size), BB=1u<<SZ;
    for(bool wr:{false,true}) {
        if((wr&&cfg.direction=="read")||(!wr&&cfg.direction=="write")) continue;
        Bench b(false,cfg); b.phase=wr ? "write throughput" : "read throughput";
        b.pace=cfg.paced(); b.stress=cfg.scenario=="backpressure";
        unsigned seq=0;
        auto pump=[&](bool accept_new) {
            // 固定 RP0 便于分别测读/写上限；多 RP 乱序和公平性由功能场景覆盖。
            const auto a=b.addr(0,cfg.burst,SZ,seq%32);
            if(wr) {
                b.dut->s_axi_awvalid=accept_new && b.write_context.size()<8;
                b.dut->s_axi_awaddr=a.addr; b.dut->s_axi_awid=a.id; b.dut->s_axi_awlen=a.len;
                b.dut->s_axi_awsize=a.size; b.dut->s_axi_awburst=1; b.dut->s_axi_awqos=0;
                b.dut->s_axi_awcache=a.cache; b.dut->s_axi_awprot=a.prot;
                b.dut->s_axi_awlock=0; b.dut->s_axi_awuser=a.user;
                b.dut->s_axi_wvalid=!b.write_context.empty();
                if(!b.write_context.empty()) {
                    const auto& c=b.write_context.front(); Bytes data{}; b.dut->s_axi_wstrb={};
                    const unsigned lane=unsigned((c.a.addr+(uint64_t(c.beat)<<c.a.size))%BYTES);
                    for(unsigned j=0;j<BYTES;j++) {
                        data[j]=uint8_t(c.a.id*17+c.beat*29+j*7); set_bit(b.dut->s_axi_wstrb,j,j>=lane&&j<lane+BB);
                    }
                    pack(b.dut->s_axi_wdata,data); b.dut->s_axi_wlast=c.beat==c.a.len;
                    b.dut->s_axi_wuser=uint16_t(0x5100+c.beat);
                }
            } else {
                b.dut->s_axi_arvalid=accept_new;
                b.dut->s_axi_araddr=a.addr; b.dut->s_axi_arid=a.id; b.dut->s_axi_arlen=a.len;
                b.dut->s_axi_arsize=a.size; b.dut->s_axi_arburst=1; b.dut->s_axi_arqos=0;
                b.dut->s_axi_arcache=a.cache; b.dut->s_axi_arprot=a.prot;
                b.dut->s_axi_arlock=0; b.dut->s_axi_aruser=a.user;
            }
            b.tick(); if(wr ? b.aw_fire : b.ar_fire) ++seq;
        };
        auto load=[&](unsigned clocks) {
            const auto end=b.cycle+clocks;
            while(b.cycle<end) {
                if(cfg.scenario=="baseline") {
                    auto a=b.addr(0,cfg.burst,SZ,seq++%32);
                    if(wr) { b.aw(a); b.w(a,1); } else b.ar(a);
                } else pump(true);
            }
        };
        load(cfg.warmup);
        // 读按 R 握手、写按 W 握手逐拍计字节；按 B 计会使统计窗边界误差达到整笔突发。
        const auto start=b.cycle, completions=wr ? b.w_count : b.r_count;
        const auto first_frame=wr ? b.fwd_frames : b.rev_frames;
        const unsigned dir=wr ? 0 : 1;
        const auto used_start=b.used_granules[dir],empty_start=b.empty_frames[dir];
        const auto stall_start=b.stalls; b.rob_peak=0;
        load(cfg.cycles);
        const auto duration=(b.cycle-start)*2;
        const auto bytes=((wr ? b.w_count : b.r_count)-completions)*BB;
        const auto frames=(wr ? b.fwd_frames : b.rev_frames)-first_frame;
        const auto used=b.used_granules[dir]-used_start,empty=b.empty_frames[dir]-empty_start;
        const auto stalls=b.stalls; const auto peak=b.rob_peak;
        const double bandwidth=double(bytes)/duration;
        b.require(bytes>0&&frames>0,"invalid throughput accounting");
        const unsigned dl=dl_of(SZ);
        const unsigned g=wr ? (BB<32 ? 8 : dl==0 ? 7 : dl==1 ? 14 : 27) : (dl==0 ? 8 : dl==1 ? 14 : 27);
        const double wire_eff=double(cfg.burst*BB)/(g*5*cfg.burst+(wr ? 15 : 0))*240/256;
        const double codec_cap=BB/2.0*(wr ? double(cfg.burst)/(cfg.burst+1) : 1);
        double upper=std::min(codec_cap,BB/(2.0*cfg.mc_interval));
        if(HIF) upper=std::min(upper,TEST_HIF_CORE_BYTES/2.0);   // HIF 数据口每拍 CORE_DATA_WIDTH
        if(cfg.paced()) upper=std::min(upper,cfg.wire_gbps()*wire_eff);
        // 统计窗边界误差不超过一拍；上限检查容许两拍的差额。
        b.require(bandwidth<=upper+2.0*BB/duration,"throughput exceeds configured upper bound");
        const double rate=upper/BB*2;
        const unsigned required_depth=unsigned(std::ceil(rate*cfg.credit_rtt_cycles))+2;
        const unsigned configured_depth=wr ? TEST_WDATA_DEPTH : TEST_RX_DEPTH;
        const double achieved=bandwidth/cfg.target_gbps;
        // 已经拉高但尚未握手的地址继续保持；完成后才停止新地址，收尾不计入测量窗。
        if(cfg.scenario!="baseline") {
            while(wr ? (b.dut->s_axi_awvalid&&!b.aw_fire) : (b.dut->s_axi_arvalid&&!b.ar_fire)) pump(true);
        }
        // 发完已经接受 AW 的所有 W，最后等待全部 R/B 并核对内存。
        b.dut->s_axi_awvalid=0; b.dut->s_axi_arvalid=0;
        if(wr && cfg.scenario!="baseline") while(!b.write_context.empty()) pump(false);
        b.dut->s_axi_wvalid=0;
        b.drain();
        g_perf.push_back({wr ? "write" : "read",bandwidth,upper,0,b.cycle});
        if(!g_perf_quiet) {
        std::cout<<std::fixed<<std::setprecision(4)
                 <<"PERF "<<(wr ? "write" : "read")<<" width="<<AXI_DATA_WIDTH<<" RP="<<TEST_RP
                 <<" scenario="<<cfg.scenario<<" size_bytes="<<BB
                 <<" duration_ns="<<duration<<" completed_bytes="<<bytes<<" data_direction_frames="<<frames
                 <<" GBps="<<bandwidth<<" target_GBps="<<cfg.target_gbps<<" target_percent="<<achieved*100
                 <<" theoretical_upper_GBps="<<upper<<" upper_percent="<<bandwidth/upper*100
                 <<" message_area_fill_percent="<<double(used)/(frames*48)*100
                 <<" empty_frames="<<empty<<"\n";
        std::cout<<"CREDIT data_kind="<<(wr ? "WDATA" : "RDATA")<<" granules_per_message="<<g
                 <<" assumed_RTT_cycles="<<cfg.credit_rtt_cycles<<" required_depth_with_2_spares="<<required_depth
                 <<" configured_depth="<<configured_depth<<" configured_granules="<<configured_depth*g
                 <<" capacity_sufficient="<<(configured_depth>=required_depth)<<"\n";
        static const char* names[]={"soc_msg_block","target_msg_block","soc_credit_wait","target_credit_wait",
            "rob_full","rob_head_wait","rob_reply_block","soc_frame_block","target_frame_block",
            "forward_block","reverse_block","mc_ready_block","mc_no_request","axi_r_block"};
        std::cout<<"STALL_CYCLES(nonexclusive)";
        for(unsigned n=0;n<stalls.size();n++) std::cout<<" "<<names[n]<<"="<<stalls[n]-stall_start[n];
        std::cout<<" rob_peak="<<peak<<"\n";
        if(cfg.physical()) std::cout<<"PHYSICAL raw_GBps="<<cfg.raw_gbps()<<" budget_GBps="<<cfg.wire_gbps()
            <<" serialization_ns="<<cfg.serial_ns()<<" one_way_model_ns="<<cfg.flight_ns()
            <<" rtl_cycle_ns=2 (codec latency excluded from physical delay)\n";
        }
        b.require(achieved+1e-12>=cfg.min_efficiency,"requested bandwidth efficiency not reached");
    }
}

// 读写并发：同一套 DUT 上读、写同时持续供数，读写地址区不重叠，避免读写竞争改变期望数据。
// 读按 R 握手字节、写按收到 B 的突发字节统计；两个方向的帧填充率分别报告。
void performance_mixed(const BridgeTestConfig& cfg) {
    Bench b(false,cfg); b.phase="mixed read/write throughput";
    b.pace=cfg.paced(); b.stress=cfg.scenario=="backpressure";
    unsigned rseq=0,wseq=0;
    // ar_new < 0 时 AR 与 AW 一样由 accept_new 决定；收尾时分别控制，只保持尚未握手的那一个。
    auto pump=[&](bool accept_new,int ar_new=-1) {
        const auto w=b.addr(4096,cfg.burst,AXI_SIZE_CODE,wseq%32);
        b.dut->s_axi_awvalid=accept_new && b.write_context.size()<8;
        b.dut->s_axi_awaddr=w.addr; b.dut->s_axi_awid=w.id; b.dut->s_axi_awlen=w.len;
        b.dut->s_axi_awsize=w.size; b.dut->s_axi_awburst=1; b.dut->s_axi_awqos=0;
        b.dut->s_axi_awcache=w.cache; b.dut->s_axi_awprot=w.prot;
        b.dut->s_axi_awlock=0; b.dut->s_axi_awuser=w.user;
        b.dut->s_axi_wvalid=!b.write_context.empty();
        if(!b.write_context.empty()) {
            const auto& c=b.write_context.front(); Bytes data{}; b.dut->s_axi_wstrb={};
            for(unsigned j=0;j<BYTES;j++) { data[j]=uint8_t(c.a.id*17+c.beat*29+j*7); set_bit(b.dut->s_axi_wstrb,j,true); }
            pack(b.dut->s_axi_wdata,data); b.dut->s_axi_wlast=c.beat==c.a.len;
            b.dut->s_axi_wuser=uint16_t(0x5100+c.beat);
        }
        const auto r=b.addr(0,cfg.burst,AXI_SIZE_CODE,32+rseq%32);
        b.dut->s_axi_arvalid=ar_new<0 ? accept_new : ar_new!=0;
        b.dut->s_axi_araddr=r.addr; b.dut->s_axi_arid=r.id; b.dut->s_axi_arlen=r.len;
        b.dut->s_axi_arsize=r.size; b.dut->s_axi_arburst=1; b.dut->s_axi_arqos=0;
        b.dut->s_axi_arcache=r.cache; b.dut->s_axi_arprot=r.prot;
        b.dut->s_axi_arlock=0; b.dut->s_axi_aruser=r.user;
        b.tick(); if(b.aw_fire) ++wseq; if(b.ar_fire) ++rseq;
    };
    for(unsigned n=0;n<cfg.warmup;n++) pump(true);
    const auto start=b.cycle,r0=b.r_count,w0=b.w_count,f0=b.fwd_frames,v0=b.rev_frames;
    const auto u0=b.used_granules; const auto stall_start=b.stalls; b.rob_peak=0;
    for(unsigned n=0;n<cfg.cycles;n++) pump(true);
    const auto duration=(b.cycle-start)*2;
    const double rd=double((b.r_count-r0)*BYTES)/duration, wr=double((b.w_count-w0)*BYTES)/duration;
    const auto ff=b.fwd_frames-f0,rf=b.rev_frames-v0;
    const double ffill=double(b.used_granules[0]-u0[0])/(ff*48)*100, rfill=double(b.used_granules[1]-u0[1])/(rf*48)*100;
    const auto stalls=b.stalls; const auto peak=b.rob_peak;
    b.require(ff>0&&rf>0&&rd>0&&wr>0,"invalid mixed throughput accounting");
    // 收尾：已拉高的地址保持到握手，发完已接受 AW 的 W，再排空并核对内存。
    bool aw_wait=b.dut->s_axi_awvalid&&!b.aw_fire, ar_wait=b.dut->s_axi_arvalid&&!b.ar_fire;
    while(aw_wait||ar_wait) { pump(aw_wait,int(ar_wait)); if(b.aw_fire) aw_wait=false; if(b.ar_fire) ar_wait=false; }
    b.dut->s_axi_awvalid=0; b.dut->s_axi_arvalid=0;
    while(!b.write_context.empty()) pump(false);
    b.dut->s_axi_wvalid=0; b.dut->s_axi_arvalid=0;
    b.drain();
    g_perf.push_back({"mixed",rd,0,wr,b.cycle});
    if(!g_perf_quiet) {
    std::cout<<std::fixed<<std::setprecision(4)
             <<"PERF mixed width="<<AXI_DATA_WIDTH<<" RP="<<TEST_RP<<" scenario="<<cfg.scenario
             <<" duration_ns="<<duration<<" read_GBps="<<rd<<" write_GBps="<<wr<<" total_GBps="<<rd+wr
             <<" read_target_percent="<<rd/cfg.target_gbps*100<<" write_target_percent="<<wr/cfg.target_gbps*100
             <<" forward_frames="<<ff<<" reverse_frames="<<rf
             <<" forward_fill_percent="<<ffill<<" reverse_fill_percent="<<rfill<<"\n";
    static const char* names[]={"soc_msg_block","target_msg_block","soc_credit_wait","target_credit_wait",
        "rob_full","rob_head_wait","rob_reply_block","soc_frame_block","target_frame_block",
        "forward_block","reverse_block","mc_ready_block","mc_no_request","axi_r_block"};
    std::cout<<"STALL_CYCLES(nonexclusive)";
    for(unsigned n=0;n<stalls.size();n++) std::cout<<" "<<names[n]<<"="<<stalls[n]-stall_start[n];
    std::cout<<" rob_peak="<<peak<<"\n";
    }
    b.require(std::min(rd,wr)/cfg.target_gbps+1e-12>=cfg.min_efficiency,"requested bandwidth efficiency not reached");
}

// 负向用例各用一套全新 DUT/复位状态，必须观察指定端的错误，不接受任意超时/崩溃。
void negative() {
    for(const std::string name:{"aw_fixed","ar_4k","unaligned","size","wlast","bad_ph","bad_length","overlap","bad_mc_tag","unsolicited_r","credit_overrun"}) {
        if(name=="size" && AXI_SIZE_CODE==7) continue; // 1024 位总线的所有三位 SIZE 编码均可表示。
        Bench b; b.phase=name; b.allow_error=true;
        if(name=="wlast") {
            b.aw(b.addr(0,2,AXI_SIZE_CODE,1)); b.checking=false;
            b.dut->s_axi_wlast=1; b.dut->s_axi_wvalid=1;
        } else {
            b.checking=false;
            if(name=="aw_fixed") { b.dut->s_axi_awvalid=1; b.dut->s_axi_awburst=0; }
            else if(name=="ar_4k") {
                b.dut->s_axi_arvalid=1; b.dut->s_axi_arburst=1; b.dut->s_axi_araddr=BASE+4096-BYTES;
                b.dut->s_axi_arlen=1; b.dut->s_axi_arsize=AXI_SIZE_CODE;
            } else if(name=="unaligned"||name=="size") {
                b.dut->s_axi_arvalid=1; b.dut->s_axi_arburst=1;
                b.dut->s_axi_araddr=BASE+1; b.dut->s_axi_arsize=AXI_SIZE_CODE;
                if(name=="size") { b.dut->s_axi_araddr=BASE; b.dut->s_axi_arsize=7; }
            } else if(name=="bad_mc_tag") {
                if(HIF) b.dut->mc_inject_bad_token=1; else { b.dut->mc_rd_rsp_valid=1; b.dut->mc_rd_rsp_tag=0; }
            }
            else {
                AouFlit f; f.clear(); f.valid=true;
                if(name=="bad_length") { f.msg_start=1; f.payload[0]=0x33; }
                if(name=="overlap") { f.msg_start=3; f.payload[0]=0x20; }
                if(name=="unsolicited_r") {
                    RChannel r; r.id=333; r.last=false; const auto m=MsgBuilder::build_read_data(r,0);
                    f.msg_start=1; std::copy(m.data,m.data+m.byte_len,f.payload);
                }
                // 对端超出已授 credit 发送：MC 停止接收，读请求队列占满后不再归还 credit，
                // 反复注入的满帧读请求必然超出存储侧已公布的量。
                if(name=="credit_overrun") {
                    b.block_mc=true;
                    AxChannel a; a.addr=BASE; a.len=0; a.size=AXI_SIZE_CODE; a.burst=1;
                    for(unsigned i=0;i<16;i++) { a.id=uint16_t(i); f.pack_message(MsgBuilder::build_read_req(a,0)); }
                }
                auto bytes=serialize_aou(f); if(name=="bad_ph") bytes[0]=4;
                for(unsigned i=0;i<250;i++) for(unsigned k=0;k<8;k++) set_bit(b.dut->inject_data,(249-i)*8+k,(bytes[i]>>k)&1);
                b.dut->inject_soc=name=="unsolicited_r"; b.dut->inject_valid=1;
            }
        }
        const bool soc=name=="aw_fixed"||name=="ar_4k"||name=="unaligned"||name=="size"||name=="wlast"||name=="unsolicited_r";
        b.until([&]{return soc ? b.dut->soc_error : b.dut->target_error;},100);
        std::cout<<"NEGATIVE PASS "<<name<<"\n";
    }
    // 对端授信超过 12 位计数上限时饱和而不报错（规范 6.4 节）。
    Bench b; b.phase="credit_saturation"; b.checking=false;
    AouFlit f; f.clear(); f.valid=true; f.msg_credit=7;   // 每帧再给 128 个 WREQ credit
    const auto bytes=serialize_aou(f);
    for(unsigned i=0;i<250;i++) for(unsigned k=0;k<8;k++) set_bit(b.dut->inject_data,(249-i)*8+k,(bytes[i]>>k)&1);
    b.dut->inject_soc=0; b.dut->inject_valid=1;
    for(int i=0;i<60;i++) b.tick();
    b.dut->inject_valid=0; b.tick();
    b.require(b.dut->target_wreq_available==4095,"credit counter did not saturate at 4095");
    std::cout<<"CREDIT SATURATION PASS available=4095 without protocol_error\n";
}

int sc_main(int argc,char** argv) {
    try {
        bool neg=false,trace=false,perf=false,corrupt=false,no_perf=false;
        BridgeTestConfig cfg;
        for(int i=1;i<argc;i++) {
            const std::string arg=argv[i];
            auto value=[&]() -> std::string {
                if(i+1>=argc) throw std::runtime_error("missing value for "+arg);
                return argv[++i];
            };
            auto number=[&]() {
                const auto s=value(); size_t end=0; const double n=std::stod(s,&end);
                if(end!=s.size()||!std::isfinite(n)) throw std::runtime_error("invalid number for "+arg);
                return n;
            };
            auto count=[&]() {
                const double n=number();
                if(n<0||n>1000000||std::floor(n)!=n) throw std::runtime_error("invalid count for "+arg);
                return unsigned(n);
            };
            if(arg=="--negative") neg=true; else if(arg=="--trace") trace=true;
            else if(arg=="--perf") perf=true; else if(arg=="--corrupt-read") corrupt=true;
            else if(arg=="--no-perf") no_perf=true;
            else if(arg=="--help") { bridge_help(); return 0; }
            else if(arg=="--scenario") {
                cfg.scenario=value(); neg=cfg.scenario=="negative";
                perf=cfg.scenario!="functional" && !neg;
            }
            else if(arg=="--direction") cfg.direction=value();
            else if(arg=="--burst") cfg.burst=count();
            else if(arg=="--size") cfg.size=int(count());
            else if(arg=="--warmup") cfg.warmup=count();
            else if(arg=="--cycles") cfg.cycles=count();
            else if(arg=="--mc-latency") cfg.mc_latency=count();
            else if(arg=="--mc-interval") cfg.mc_interval=count();
            else if(arg=="--credit-rtt-cycles") cfg.credit_rtt_cycles=count();
            else if(arg=="--link-gbps") cfg.link_gbps=number();
            else if(arg=="--target-gbps") cfg.target_gbps=number();
            else if(arg=="--min-efficiency") cfg.min_efficiency=number();
            else if(arg=="--package") cfg.package=value();
            else if(arg=="--lanes") cfg.lanes=count();
            else if(arg=="--modules") cfg.modules=count();
            else if(arg=="--lane-gbps") cfg.lane_gbps=number();
            else if(arg=="--shoreline-mm") cfg.shoreline_mm=number();
            else if(arg=="--density-gbps-mm") cfg.density_gbps_mm=number();
            else if(arg=="--phy-ns") cfg.phy_ns=number();
            else if(arg=="--prop-ns") cfg.prop_ns=number();
            else if(arg=="--cdc-ns") cfg.cdc_ns=number();
            else if(arg=="--adapter-ns") cfg.adapter_ns=number();
            else throw std::runtime_error("unknown argument: "+arg);
        }
        if(neg) negative();
        else if(perf) performance(cfg);
        else if(corrupt) { Bench b; b.phase="checker negative control"; b.corrupt_read=true; b.read(b.addr(0,1,AXI_SIZE_CODE,1)); }
        else functional(trace,!no_perf);
        return 0;
    } catch(const std::exception& e) { std::cerr<<"RTL FAIL: "<<e.what()<<"\n"; return 1; }
}
