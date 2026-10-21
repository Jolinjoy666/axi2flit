// 单元吞吐与边界验证：独立参考组帧，逐字节对比，不用 TX 输出作为 RX 的唯一期望。
#include "Vtb_flit_codec.h"
#include "verilated.h"
#include "aou_wire.h"
#include "msg_builder.h"
#include <iostream>
#include <vector>
#include <stdexcept>

template<class T> void put(T& x,const uint8_t* bytes,unsigned n) {
    x={};
    for(unsigned j=0;j<n;j++) for(unsigned k=0;k<8;k++)
        if((bytes[j]>>k)&1) x[((n-1-j)*8+k)/32]|=uint32_t(1)<<(((n-1-j)*8+k)%32);
}
template<class T> bool equal(const T& x,const uint8_t* bytes,unsigned n) {
    for(unsigned j=0;j<n;j++) for(unsigned k=0;k<8;k++)
        if(((x[((n-1-j)*8+k)/32]>>(((n-1-j)*8+k)%32))&1)!=((bytes[j]>>k)&1)) return false;
    return true;
}
void check(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }

struct CodecBench {
    VerilatedContext context;
    Vtb_flit_codec dut{&context};
    unsigned cycle=0;
    void edge() { dut.clk=1; dut.eval(); ++cycle; }
    void low() { dut.clk=0; dut.eval(); }
    void reset() {
        dut.rst_n=0; dut.tx_valid=0; dut.rx_flit_valid=0; dut.tx_flit_ready=1; dut.rx_ready=1;
        for(int i=0;i<3;i++) { low(); edge(); }
        dut.rst_n=1; low();
    }
};

std::vector<AouMessage> messages(unsigned kind) {
    std::vector<AouMessage> result;
    for(unsigned n=0;n<96;n++) {
        AxChannel a; a.id=n; a.addr=0x10000+n*128; a.size=AXI_SIZE_CODE; a.len=0; a.burst=1;
        WChannel w; RChannel r; BChannel b;
        w.user=n; w.last=true; r.id=n; r.user=n*7; r.last=true; b.id=n;
        for(unsigned j=0;j<AXI_DATA_BYTES;j++) {
            w.data[j]=r.data[j]=uint8_t(n*17+j*3); w.strb[j]=kind==5 ? j%3!=0 : 1;
        }
        if(kind==0) result.push_back(MsgBuilder::build_write_req(a,0));
        if(kind==1) result.push_back(MsgBuilder::build_read_req(a,0));
        if(kind==2) result.push_back(MsgBuilder::build_write_data_full(w,0));
        if(kind==3) result.push_back(MsgBuilder::build_read_data(r,0));
        if(kind==4) result.push_back(MsgBuilder::build_write_resp(b,0));
        if(kind==5) result.push_back(MsgBuilder::build_write_data(w,0));
    }
    return result;
}

std::vector<AouWireFlit> frame_reference(const std::vector<AouMessage>& messages) {
    std::vector<AouWireFlit> frames; AouFlit f; f.clear(); unsigned used=0;
    for(const auto& m:messages) {
        f.msg_start|=uint64_t(1)<<used;
        for(unsigned g=0;g<unsigned(m.granules);g++) {
            std::copy_n(m.data+g*5,5,f.payload+used*5);
            if(++used==48) { frames.push_back(serialize_aou(f)); f.clear(); used=0; }
        }
    }
    if(used) frames.push_back(serialize_aou(f));
    return frames;
}

void run(unsigned kind,bool stalls) {
    CodecBench b; b.reset(); const auto msgs=messages(kind); const auto frames=frame_reference(msgs);
    unsigned sent=0,received=0,first=0,last=0,debit=0;
    while(received<frames.size()) {
        check(b.cycle<20000,"TX timeout"); b.dut.tx_valid=sent<msgs.size();
        if(sent<msgs.size()) put(b.dut.tx_message,msgs[sent].data,150);
        b.dut.tx_flit_ready=!stalls||b.cycle%9>=4; b.low();
        debit+=b.dut.tx_debit;
        if(b.dut.tx_valid&&b.dut.tx_ready) { if(!sent) first=b.cycle; last=b.cycle; ++sent; }
        if(b.dut.tx_flit_valid&&b.dut.tx_flit_ready) {
            check(equal(b.dut.tx_flit,frames[received].data(),250),"TX frame bytes differ"); ++received;
        }
        b.edge();
    }
    check(sent==msgs.size(),"missing TX messages");
    check(debit==msgs.size()*msgs[0].granules,"credit not debited exactly once per message");
    if(!stalls) check(last-first+1==msgs.size(),"TX failed one message per cycle");
    const unsigned tx_cycles=last-first+1;
    b.reset(); sent=received=0; unsigned headers=0;
    while(received<msgs.size()) {
        check(b.cycle<40000,"RX timeout"); b.dut.rx_flit_valid=sent<frames.size();
        if(sent<frames.size()) {
            auto bytes=frames[sent]; bytes[4]=uint8_t(sent+1); bytes[5]=0x12;
            put(b.dut.rx_flit,bytes.data(),250);
        }
        b.dut.rx_ready=!stalls||b.cycle%11>=5; b.low();
        if(b.dut.rx_header_valid) {
            check(b.dut.rx_header_credit==(0x1200|unsigned(uint8_t(sent+1))),"PH belongs to wrong frame");
            ++headers;
        }
        if(b.dut.rx_flit_valid&&b.dut.rx_flit_ready) ++sent;
        if(b.dut.rx_valid&&b.dut.rx_ready) {
            check(equal(b.dut.rx_message,msgs[received].data,150),"RX message bytes differ");
            if(!received) first=b.cycle; last=b.cycle; ++received;
        }
        b.edge(); check(!b.dut.rx_fault,"unexpected RX fault");
    }
    check(headers==frames.size(),"PH not accepted exactly once");
    if(!stalls) check(last-first+1==msgs.size(),"RX failed one message per cycle across frame boundary");
    for(int n=0;n<5;n++) { b.dut.rx_flit_valid=0; b.dut.rx_ready=1; b.low(); check(!b.dut.rx_valid,"duplicate RX message"); b.edge(); }
    std::cout<<"CODEC PASS width="<<AXI_DATA_WIDTH<<" kind="<<kind<<" stalls="<<stalls
             <<" messages="<<msgs.size()<<" frames="<<frames.size()<<" TX_cycles="<<tx_cycles
             <<" RX_cycles="<<last-first+1<<"\n";
}

void boundaries() {
    CodecBench b; b.reset();
    // 在第 47 粒度开始一条三粒度请求，必须等第二帧到达后才能输出。
    const auto msg=messages(0).front(); AouFlit first,second; first.clear(); second.clear();
    first.msg_start=uint64_t(1)<<47; std::copy_n(msg.data,5,first.payload+235);
    std::copy_n(msg.data+5,10,second.payload);
    auto send=[&](const AouFlit& f) {
        const auto bytes=serialize_aou(f); put(b.dut.rx_flit,bytes.data(),250); b.dut.rx_flit_valid=1;
        bool fire=false;
        for(unsigned n=0;!fire;n++) { check(n<30,"boundary input timeout"); b.low(); fire=b.dut.rx_flit_ready; b.edge(); }
        b.dut.rx_flit_valid=0;
    };
    send(first);
    for(int n=0;n<8;n++) { b.low(); check(!b.dut.rx_valid&&!b.dut.rx_fault,"partial message escaped"); b.edge(); }
    send(second); b.low(); b.edge(); b.low();
    check(b.dut.rx_valid&&equal(b.dut.rx_message,msg.data,150),"delayed continuation lost"); b.edge();
    // 跨帧占用的第二帧粒度零不能同时声明新消息。
    b.reset(); second.msg_start=1; send(first); send(second); b.low(); b.edge();
    check(b.dut.rx_fault&&!b.dut.rx_valid,"cross-frame overlap not rejected");
    // 等待后半帧时复位必须取消旧上下文，随后可接收独立完整消息。
    b.reset(); send(first); b.reset(); AouFlit fresh; fresh.clear(); fresh.msg_start=1;
    std::copy_n(msg.data,msg.byte_len,fresh.payload); send(fresh); b.low(); b.edge(); b.low();
    check(b.dut.rx_valid&&!b.dut.rx_fault&&equal(b.dut.rx_message,msg.data,150),"reset retained partial frame");
    std::cout<<"CODEC BOUNDARY PASS delayed continuation / overlap / partial reset\n";
}

int sc_main(int,char**) {
    try {
        for(unsigned kind=0;kind<6;kind++) for(bool stalls:{false,true}) run(kind,stalls);
        boundaries();
        return 0;
    } catch(const std::exception& e) { std::cerr<<"CODEC FAIL: "<<e.what()<<"\n"; return 1; }
}
