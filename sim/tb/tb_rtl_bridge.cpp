/*
 * RTL 联合验证：AXI 激励、独立字节记分板、可乱序完成的 MC 模型、AoU 字节对拍。
 * DUT 仅在时钟沿更新；参考内存依据 AXI 握手更新，MC 内存依据 MC 命令更新，二者分离。
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
#include <array>
#include <deque>
#include <map>
#include <memory>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <type_traits>

constexpr unsigned BYTES=AXI_DATA_BYTES;
constexpr uint64_t BASE=0x1234567800000000ULL;
constexpr unsigned MEM_BYTES=128*1024;
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
    uint64_t cycle=0,aw_count=0,w_count=0,ar_count=0,r_count=0,b_count=0,read_done=0,mc_count=0;
    uint64_t message_count=0,spanning=0,ooo=0,fwd_frames=0,rev_frames=0,stall_cycles=0;
    bool stress=false,pace=false,checking=true,allow_error=false,measure=false;
    bool block_mc=false,block_axi=false,block_link=false;
    bool corrupt_read=false; // 仅破坏记分板期望，验证检查器确实能拒绝错误数据。
    bool aw_fire=false,w_fire=false,ar_fire=false;
    double fbudget=512,rbudget=512;
    std::string phase="initialization";
    std::vector<uint8_t> reference=std::vector<uint8_t>(MEM_BYTES),memory=std::vector<uint8_t>(MEM_BYTES);
    std::deque<WriteContext> write_context;
    std::map<unsigned,std::deque<RChannel>> expect_r;
    std::map<unsigned,std::deque<BChannel>> expect_b;
    std::array<std::array<std::deque<Cmd>,2>,TEST_RP> expect_cmd;
    std::array<std::array<std::array<std::deque<AouMessage>,5>,TEST_RP>,2> expect_msg;
    std::array<AouStreamDecoder,4> decoder;
    std::array<CreditMatrix,2> credits{};
    std::vector<Response> responses;
    uint64_t ar_time=0,w_time=0,tx_time=0,rx_time=0,target_req_time=0,target_w_time=0,target_rsp_time=0;
    unsigned max_tx=0,max_rx=0,max_target=0,max_return=0;

    explicit Bench(bool waves=false) {
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
    uint8_t status(const AxChannel& a,unsigned beat) const {
        if(!range(a.addr+(uint64_t(beat)<<a.size),1u<<a.size)) return 3;
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
            auto s=status(c.a,c.beat);
            for(unsigned j=0;j<BYTES;j++) {
                w.strb[j]=cmd.strb[j]=uint8_t(bit(dut->s_axi_wstrb,j));
                if(w.strb[j]&&(j<lane||j>=lane+size)) s=2;
            }
            c.status=std::max(c.status,s);
            if(!s) for(unsigned j=0;j<size;j++) if(w.strb[lane+j]) reference[address-BASE+j]=d[lane+j];
            require(w.last==(c.beat==c.a.len),"host WLAST construction");
            expected(0,MsgBuilder::is_full_strobe(w) ? MsgBuilder::build_write_data_full(w,rp) : MsgBuilder::build_write_data(w,rp));
            expect_cmd[rp][1].push_back(cmd); ++c.beat; ++w_count;
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
                Cmd cmd; cmd.a=a; cmd.beat=n; expect_cmd[rp][0].push_back(cmd);
                RChannel r; r.id=a.id; r.user=a.user; r.last=n==a.len; r.resp=status(a,n);
                uint64_t address=a.addr+(uint64_t(n)<<a.size); unsigned lane=unsigned(address%BYTES);
                if(!r.resp) for(unsigned j=0;j<(1u<<a.size);j++) r.data[lane+j]=reference[address-BASE+j];
                expect_r[a.id].push_back(r); expected(1,MsgBuilder::build_read_data(r,rp));
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
    void mc_event() {
        if(!(dut->mc_req_valid&&dut->mc_req_ready)) return;
        auto& q=expect_cmd[dut->mc_req_rp][dut->mc_req_write]; require(!q.empty(),"unrequested MC command");
        const auto e=q.front(); q.pop_front(); const auto& a=e.a;
        require(dut->mc_req_id==a.id && dut->mc_req_addr==a.addr+(uint64_t(e.beat)<<a.size),"MC address/ID");
        require(dut->mc_req_size==a.size&&dut->mc_req_len==a.len&&dut->mc_req_beat==e.beat,"MC SIZE/LEN/beat");
        require(dut->mc_req_first==(e.beat==0)&&dut->mc_req_last==(e.beat==a.len),"MC first/last");
        require(dut->mc_req_prot==a.prot&&dut->mc_req_cache==a.cache&&dut->mc_req_qos==a.qos&&
                dut->mc_req_lock==a.lock&&dut->mc_req_auser==a.user,"MC attributes");
        require(unpack(dut->mc_req_wdata)==e.data,"MC WDATA byte mapping");
        for(unsigned j=0;j<BYTES;j++) require(bit(dut->mc_req_wstrb,j)==e.strb[j],"MC WSTRB mapping");
        require(dut->mc_req_wuser==e.wuser,"MC WUSER");
        for(const auto& r:responses) require(r.tag!=dut->mc_req_tag,"MC tag reused while outstanding");
        Response r; r.tag=dut->mc_req_tag; r.status=status(a,e.beat); r.sequence=mc_count++;
        r.due=cycle+(stress ? 2+(mc_count*7)%23 : 2);
        const unsigned size=1u<<a.size; const auto addr=dut->mc_req_addr; const unsigned lane=unsigned(addr%BYTES);
        for(unsigned j=0;j<BYTES;j++) if(e.write&&e.strb[j]&&(j<lane||j>=lane+size)) r.status=2;
        if(!r.status) for(unsigned j=0;j<size;j++) {
            if(e.write) { if(e.strb[lane+j]) memory[addr-BASE+j]=e.data[lane+j]; }
            else r.data[lane+j]=memory[addr-BASE+j];
        }
        responses.push_back(r);
        if(measure) max_target=std::max(max_target,unsigned((cycle-(e.write ? std::max(target_req_time,target_w_time) : target_req_time))*2));
    }
    // 在 Flit 实际交付点检查格式：消息内容与 AXI/MC 期望比较，credit 另做独立账本。
    template<class T> void frame(unsigned index,const T& bits) {
        const auto f=deserialize_aou(wire(bits));
        const bool carry=decoder[index].carry_active(); const auto parsed=decoder[index].consume(f);
        if(index<2) {
            const unsigned dir=index; if(dir==0) ++fwd_frames; else ++rev_frames;
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
                if(index==3&&(m.type==MsgType::ReadReq||m.type==MsgType::WriteReq)) target_req_time=cycle;
                if(index==3&&(m.type==MsgType::WriteData||m.type==MsgType::WriteDataFull)) target_w_time=cycle;
            }
        }
    }
    void tick() {
        require(cycle<2000000,"watchdog timeout"); dut->clk=0;
        fbudget=std::min(512.0,fbudget+96); rbudget=std::min(512.0,rbudget+96);
        dut->forward_enable=!block_link&&(!pace||fbudget>=256)&&(!stress||cycle%7!=0);
        dut->reverse_enable=!block_link&&(!pace||rbudget>=256)&&(!stress||cycle%5!=0);
        dut->s_axi_rready=!block_axi&&(!stress||cycle%11>=4);
        dut->s_axi_bready=!block_axi&&(!stress||cycle%13>=3);
        dut->mc_req_ready=!block_mc&&(!stress||cycle%9>=3);
        int response=-1;
        for(unsigned i=0;i<responses.size();i++) if(responses[i].due<=cycle) {
            response=int(i); if(!stress) break;
        }
        // 固定响应就绪接口没有反压时直接选择；异常测试可自己驱动 mc_rsp_valid。
        if(checking) {
            dut->mc_rsp_valid=response>=0;
            if(response>=0) { const auto& r=responses[response]; dut->mc_rsp_tag=r.tag; dut->mc_rsp_resp=r.status; pack(dut->mc_rsp_rdata,r.data); }
        }
        dut->eval();
        aw_fire=dut->s_axi_awvalid&&dut->s_axi_awready;
        ar_fire=dut->s_axi_arvalid&&dut->s_axi_arready;
        w_fire=dut->s_axi_wvalid&&dut->s_axi_wready;
        if(checking&&dut->rst_n&&dut->link_up) {
            host_events();
            if(dut->fwd_valid&&dut->fwd_ready) { frame(0,dut->fwd_data); fbudget-=256; }
            if(dut->rev_valid&&dut->rev_ready) { frame(1,dut->rev_data); rbudget-=256; }
            if(dut->soc_rx_valid&&dut->soc_rx_ready) frame(2,dut->soc_rx_data);
            if(dut->target_rx_valid&&dut->target_rx_ready) frame(3,dut->target_rx_data);
            if(response>=0&&dut->mc_rsp_valid&&dut->mc_rsp_ready) {
                if(measure) target_rsp_time=cycle;
                for(unsigned i=0;i<responses.size();i++) if(responses[i].sequence<responses[response].sequence) { ++ooo; break; }
                responses.erase(responses.begin()+response);
            }
            mc_event();
            if((dut->fwd_valid&&!dut->fwd_ready)||(dut->s_axi_rvalid&&!dut->s_axi_rready)||
               (dut->mc_req_valid&&!dut->mc_req_ready)) ++stall_cycles;
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
        dut->s_axi_awaddr=a.addr; dut->s_axi_awid=a.id; dut->s_axi_awlen=a.len; dut->s_axi_awsize=a.size;
        dut->s_axi_awburst=a.burst; dut->s_axi_awqos=a.qos; dut->s_axi_awcache=a.cache; dut->s_axi_awprot=a.prot;
        dut->s_axi_awlock=a.lock; dut->s_axi_awuser=a.user; dut->s_axi_awvalid=1;
        until([&]{return aw_fire;}); dut->s_axi_awvalid=0;
    }
    void ar(const AxChannel& a) {
        dut->s_axi_araddr=a.addr; dut->s_axi_arid=a.id; dut->s_axi_arlen=a.len; dut->s_axi_arsize=a.size;
        dut->s_axi_arburst=a.burst; dut->s_axi_arqos=a.qos; dut->s_axi_arcache=a.cache; dut->s_axi_arprot=a.prot;
        dut->s_axi_arlock=a.lock; dut->s_axi_aruser=a.user; dut->s_axi_arvalid=1;
        until([&]{return ar_fire;}); dut->s_axi_arvalid=0;
    }
    void w(const AxChannel& a,unsigned seed=1,int mask=0) {
        for(unsigned n=0;n<=a.len;n++) {
            Bytes d{}; dut->s_axi_wstrb={}; const unsigned lane=unsigned((a.addr+(uint64_t(n)<<a.size))%BYTES);
            for(unsigned j=0;j<BYTES;j++) {
                d[j]=uint8_t(seed*17+n*29+j*7+(j>>3));
                bool strobe=j>=lane&&j<lane+(1u<<a.size);
                if(mask==1) strobe=strobe&&(j%3!=0); if(mask==2) strobe=false;
                set_bit(dut->s_axi_wstrb,j,strobe);
            }
            pack(dut->s_axi_wdata,d); dut->s_axi_wuser=uint16_t(0x5100+n);
            dut->s_axi_wlast=n==a.len; dut->s_axi_wvalid=1;
            until([&]{return w_fire;}); dut->s_axi_wvalid=0;
        }
    }
    void write(const AxChannel& a,unsigned seed=1,int mask=0) { auto b=b_count; aw(a); w(a,seed,mask); until([&]{return b_count==b+1;}); }
    void read(const AxChannel& a) { auto n=read_done; ar(a); until([&]{return read_done==n+1;}); }
    void drain() {
        until([&]{return b_count==aw_count&&read_done==ar_count;});
        for(int i=0;i<100;i++) tick();
        require(responses.empty()&&write_context.empty(),"pending MC/AXI state after drain");
        for(auto& dir:expect_msg) for(auto& rp:dir) for(auto& q:rp) require(q.empty(),"missing wire message after drain");
        for(auto& rp:expect_cmd) for(auto& q:rp) require(q.empty(),"missing MC command after drain");
        require(reference==memory,"final independent memory images differ");
    }
    // 联合复位明确取消所有在途事务；两端、链路 FIFO、MC 模型和记分板同时清空。
    // 不把“单端复位后旧 MC 响应继续到达”误当成受支持的恢复协议。
    void coordinated_reset() {
        checking=false; dut->link_up=0; dut->rst_n=0;
        dut->s_axi_awvalid=0; dut->s_axi_arvalid=0; dut->s_axi_wvalid=0; dut->mc_rsp_valid=0;
        for(int i=0;i<4;i++) tick();
        write_context.clear(); responses.clear(); expect_r.clear(); expect_b.clear();
        for(auto& rp:expect_cmd) for(auto& q:rp) q.clear();
        for(auto& dir:expect_msg) for(auto& rp:dir) for(auto& q:rp) q.clear();
        decoder={}; credits={};
        reference.assign(MEM_BYTES,0); memory.assign(MEM_BYTES,0);
        aw_count=w_count=ar_count=r_count=b_count=read_done=mc_count=0;
        block_axi=block_mc=block_link=false; stress=false; fbudget=rbudget=512;
        dut->rst_n=1;
        for(int i=0;i<3;i++) tick();
        checking=true; dut->link_up=1;
        for(int i=0;i<80;i++) tick();
    }
};

void functional(bool waves) {
    Bench b(waves); constexpr unsigned SIZE=AXI_SIZE_CODE;
    b.phase="single-beat latency"; b.measure=true;
    b.read(b.addr(0,1,SIZE,1)); b.write(b.addr(4096,1,SIZE,2),3); b.read(b.addr(4096,1,SIZE,3));
    b.measure=false; b.require(b.max_tx+b.max_rx<=20,"SoC bridge sample latency >20ns");
    b.require(b.max_target<=20,"Target request conversion sample latency >20ns");
    b.require(b.max_target+b.max_return<=20,"Target request+return sample latency >20ns");
    b.phase="bursts, masks, narrow lanes";
    for(unsigned n:{2u,4u,16u,4096u/BYTES}) { auto a=b.addr(8192,n,SIZE,10+n); b.write(a,n); b.read(a); }
    auto masked=b.addr(8192,16,SIZE,30); b.write(masked,21,1); b.read(masked); b.write(masked,43,2); b.read(masked);
    auto narrow=b.addr(12288+4,16,2,31); b.write(narrow,9,1); b.read(narrow);
    auto longburst=b.addr(16384,256,2,32); b.write(longburst,7); b.read(longburst);
    b.phase="error responses";
    auto outside=b.addr(MEM_BYTES,4,SIZE,40); b.write(outside); b.read(outside);
    auto lock=b.addr(20480,2,SIZE,41,0,true); b.write(lock); b.read(lock);
    auto middle_error=b.addr(20480,4,SIZE,42); middle_error.user=0xe002;
    b.write(middle_error,19); b.read(middle_error);
    b.phase="outstanding, multi-RP, MC reordering"; b.stress=true;
    std::vector<AxChannel> batch;
    for(unsigned i=0;i<4;i++) { batch.push_back(b.addr(24576+i*4096,16,SIZE,50+i,i)); b.aw(batch.back()); }
    for(unsigned i=0;i<batch.size();i++) b.w(batch[i],i+1);
    b.until([&]{return b.b_count==b.aw_count;});
    for(const auto& a:batch) b.ar(a);
    b.until([&]{return b.read_done==b.ar_count;});
    // 同 ID 多笔同 RP 顺序，及一个方向等待时另一个方向仍能推进。
    for(unsigned i=0;i<3;i++) b.ar(b.addr(24576+i*4096,16,SIZE,70,0));
    b.write(b.addr(45056,16,SIZE,80,TEST_RP-1),16);
    b.drain();
    b.phase="long downstream stalls and credit recovery";
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
        b.phase="same ID cross-RP admission";
        b.block_axi=true; b.ar(b.addr(8192,4,SIZE,100,0));
        // 驱动另一个 RP 的同 ID 请求，前一笔未完成时必须持续背压。
        b.dut->s_axi_arqos=1; b.dut->s_axi_arvalid=1;
        for(int i=0;i<60;i++) { b.tick(); b.require(!b.ar_fire,"same-ID cross-RP request admitted early"); }
        b.block_axi=false; b.until([&]{return b.ar_fire;}); b.dut->s_axi_arvalid=0; b.drain();
    }
    b.require(b.spanning>0&&b.ooo>0&&b.stall_cycles>0,"required spanning/reordering/stall coverage absent");
    std::cout<<"RTL PASS width="<<AXI_DATA_WIDTH<<" RP="<<TEST_RP
             <<" AW="<<b.aw_count<<" AR="<<b.ar_count<<" MC="<<b.mc_count
             <<" byte_checked_messages="<<b.message_count<<" spanning="<<b.spanning
             <<" out_of_order_MC="<<b.ooo<<" stall_cycles="<<b.stall_cycles<<"\n";
    std::cout<<"LATENCY_NS SoC_TX_max="<<b.max_tx<<" SoC_RX_max="<<b.max_rx
             <<" Target_request_max="<<b.max_target<<" Target_return_max="<<b.max_return
             <<" (isolated full-width single beat)\n";
    b.phase="coordinated reset during outstanding traffic";
    b.block_axi=true; b.ar(b.addr(8192,16,SIZE,101));
    for(int i=0;i<30;i++) b.tick();
    b.require(b.read_done<b.ar_count,"reset scenario has no outstanding read");
    b.coordinated_reset();
    b.write(b.addr(4096,4,SIZE,102),23); b.read(b.addr(4096,4,SIZE,103)); b.drain();
    std::cout<<"RESET PASS coordinated cancellation and fresh credit initialization\n";
}

// 持续负载基线：每个方向 48GB/s 物理预算，按 256B/帧限速；不模拟 CRC/重放。
// 先预热，再以实际窗口长度计完成字节；写必须收到 B，不能只拿 W 接收速率充数。
// 固定 RP0、16 拍全宽突发、MC 两拍返回。此处如未达 90% 要如实报告，不自动套用
// SystemC 模型的性能数值。AXI 驱动也会消耗发地址的一拍，属于本基线负载条件。
void performance() {
    for(bool wr:{false,true}) {
        Bench b; b.phase=wr ? "write throughput" : "read throughput"; b.pace=true;
        unsigned seq=0;
        auto load=[&](unsigned clocks) {
            const auto end=b.cycle+clocks;
            while(b.cycle<end) {
                auto a=b.addr(0,16,AXI_SIZE_CODE,seq++%32);
                if(wr) { b.aw(a); b.w(a,1); } else b.ar(a);
            }
        };
        load(1500);
        const auto start=b.cycle, completions=wr ? b.b_count : b.r_count;
        const auto first_frame=wr ? b.fwd_frames : b.rev_frames;
        load(4000);
        const auto duration=(b.cycle-start)*2;
        const auto bytes=((wr ? b.b_count : b.r_count)-completions)*BYTES*(wr ? 16 : 1);
        const auto frames=(wr ? b.fwd_frames : b.rev_frames)-first_frame;
        const double bandwidth=double(bytes)/duration;
        b.require(bytes>0&&frames>0&&bandwidth<=45.5,"invalid throughput accounting");
        b.drain();
        std::cout<<std::fixed<<std::setprecision(4)
                 <<"PERF "<<(wr ? "write" : "read")<<" width="<<AXI_DATA_WIDTH<<" RP="<<TEST_RP
                 <<" duration_ns="<<duration<<" completed_bytes="<<bytes<<" data_direction_frames="<<frames
                 <<" GBps="<<bandwidth<<" time_eff_percent="<<bandwidth/45*100
                 <<" window_payload_ratio_percent="<<double(bytes)/(frames*240)*100<<"\n";
    }
}

// 负向用例各用一套全新 DUT/复位状态，必须观察指定端的错误，不接受任意超时/崩溃。
void negative() {
    for(const std::string name:{"aw_fixed","ar_4k","unaligned","size","wlast","bad_ph","bad_length","overlap","bad_mc_tag","unsolicited_r","credit_overflow"}) {
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
            } else if(name=="bad_mc_tag") { b.dut->mc_rsp_valid=1; b.dut->mc_rsp_tag=0; }
            else {
                AouFlit f; f.clear(); f.valid=true;
                if(name=="bad_length") { f.msg_start=1; f.payload[0]=0x33; }
                if(name=="overlap") { f.msg_start=3; f.payload[0]=0x20; }
                if(name=="unsolicited_r") {
                    RChannel r; r.id=333; r.last=false; const auto m=MsgBuilder::build_read_data(r,0);
                    f.msg_start=1; std::copy(m.data,m.data+m.byte_len,f.payload);
                }
                if(name=="credit_overflow") f.msg_credit=7; // 持续重复增加 128 个 WREQ credit。
                auto bytes=serialize_aou(f); if(name=="bad_ph") bytes[0]=4;
                for(unsigned i=0;i<250;i++) for(unsigned k=0;k<8;k++) set_bit(b.dut->inject_data,(249-i)*8+k,(bytes[i]>>k)&1);
                b.dut->inject_soc=name=="unsolicited_r"; b.dut->inject_valid=1;
            }
        }
        const bool soc=name=="aw_fixed"||name=="ar_4k"||name=="unaligned"||name=="size"||name=="wlast"||name=="unsolicited_r";
        b.until([&]{return soc ? b.dut->soc_error : b.dut->target_error;},100);
        std::cout<<"NEGATIVE PASS "<<name<<"\n";
    }
}

int sc_main(int argc,char** argv) {
    try {
        bool neg=false,trace=false,perf=false,corrupt=false;
        for(int i=1;i<argc;i++) {
            const std::string arg=argv[i];
            if(arg=="--negative") neg=true; else if(arg=="--trace") trace=true;
            else if(arg=="--perf") perf=true; else if(arg=="--corrupt-read") corrupt=true;
            else throw std::runtime_error("unknown argument: "+arg);
        }
        if(neg) negative();
        else if(perf) performance();
        else if(corrupt) { Bench b; b.phase="checker negative control"; b.corrupt_read=true; b.read(b.addr(0,1,AXI_SIZE_CODE,1)); }
        else functional(trace);
        return 0;
    } catch(const std::exception& e) { std::cerr<<"RTL FAIL: "<<e.what()<<"\n"; return 1; }
}
