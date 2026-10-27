// 消息→250B Flit。一个在建帧和一个输出寄存器；输出背压时允许继续填在建帧。
// 每拍至多接受一条新消息，可与上一消息的跨帧尾片同拍装填。credit 按整消息扣一次。
// 在有 credit 的 RP/类型之间轮转；单 RP 时只在消息类型间选择，不需要 RP 竞争。
module aou_flit_tx #(
    parameter int RP_COUNT = 1
) (
    // 时钟、复位与发送使能。
    input logic clk,
    input logic rst_n,
    input logic enable,
    // 待发送消息及逐 RP/类型握手。
    input logic [aou_pkg::MSG_KIND_COUNT-1:0] msg_valid [RP_COUNT],
    output logic [aou_pkg::MSG_KIND_COUNT-1:0] msg_ready [RP_COUNT],
    input aou_pkg::msg_t msg_data [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    // 远端 credit、待归还 credit 和本拍扣减/授信量。
    input logic [aou_pkg::CREDIT_CNT_W-1:0] available [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    input logic [aou_pkg::CREDIT_CNT_W-1:0] pending [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    output logic [aou_pkg::GRANT_W-1:0] consumed [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    output logic [aou_pkg::GRANT_W-1:0] granted [RP_COUNT][aou_pkg::MSG_KIND_COUNT],
    // Flit 输出握手。
    output logic flit_valid,
    input logic flit_ready,
    output aou_pkg::flit_t flit_data
);
    import aou_pkg::*;

    // 在建 Flit 的负载、消息起点，以及跨帧余量。
    logic [PAYLOAD_BITS-1:0] payload, payload_n;
    logic [FLIT_GRANULES-1:0] starts, starts_n;
    logic [GRANULE_IDX_W-1:0] used, used_n, spill_offset, spill_offset_n;
    msg_t spill, spill_n;

    // 输出寄存器下一拍值与轮询仲裁位置。
    logic out_valid_n;
    flit_t out_data_n;
    int unsigned next_slot, next_slot_n, next_credit, next_credit_n;

    // 本拍消息选择、credit 编码及装帧用组合临时量。
    int selected, slot, rp, k, len, took, crp, enc;
    logic appended, have_grant;
    logic [PH_CREDIT_W-1:0] header;
    msg_t candidate;

    // 组合逻辑：先接续跨帧消息，再从有 credit 的 RP/类型中选一条。
    always_comb begin
        payload_n = payload;
        starts_n = starts;
        used_n = used;
        spill_n = spill;
        spill_offset_n = spill_offset;
        next_slot_n = next_slot;
        next_credit_n = next_credit;
        out_valid_n = flit_valid;
        out_data_n = flit_data;
        selected = -1;
        slot = 0;
        rp = 0;
        k = 0;
        len = 0;
        took = 0;
        crp = -1;
        enc = 0;
        appended = 0;
        have_grant = 0;
        header = '0;
        candidate = '0;
        for (int p = 0; p < RP_COUNT; p++) begin
            msg_ready[p] = '0;
            for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                consumed[p][q] = '0;
                granted[p][q] = '0;
            end
        end
        if (flit_valid && flit_ready) begin
            out_valid_n = 0;
        end
        if (enable) begin
            if (spill_offset != 0 && used_n == 0) begin
                len = msg_granules(spill);
                took = len-int'(spill_offset);
                for (int g = 0; g < MSG_MAX_GRANULES; g++) begin
                    if (g < took) begin
                        payload_n[PAYLOAD_TOP-g*GRANULE_BITS -: GRANULE_BITS] =
                            spill[MSG_TOP-(int'(spill_offset)+g)*GRANULE_BITS -: GRANULE_BITS];
                    end
                end
                used_n = GRANULE_IDX_W'(took);
                spill_offset_n = 0;
                appended = 1;
            end
            // 查找只读旧 credit；同拍收到的新 credit 从下一拍起可用，避免组合反馈。
            if (spill_offset_n == 0 && used_n < FLIT_GRANULES) begin
                for (int n = 0; n < RP_COUNT*MSG_KIND_COUNT; n++) begin
                    slot = (int'(next_slot)+n)%(RP_COUNT*MSG_KIND_COUNT);
                    rp = slot/MSG_KIND_COUNT;
                    k = slot%MSG_KIND_COUNT;
                    len = msg_granules(msg_data[rp][k]);
                    if (selected < 0 && msg_valid[rp][k] && len > 0 && available[rp][k] >= len) begin
                        selected = slot;
                    end
                end
            end
            if (selected >= 0) begin
                rp = selected/MSG_KIND_COUNT;
                k = selected%MSG_KIND_COUNT;
                candidate = msg_data[rp][k];
                len = msg_granules(candidate);
                took = len < FLIT_GRANULES-int'(used_n) ? len : FLIT_GRANULES-int'(used_n);
                starts_n[used_n] = 1;
                for (int g = 0; g < MSG_MAX_GRANULES; g++) begin
                    if (g < took) begin
                        payload_n[PAYLOAD_TOP-(int'(used_n)+g)*GRANULE_BITS -: GRANULE_BITS] =
                            candidate[MSG_TOP-g*GRANULE_BITS -: GRANULE_BITS];
                    end
                end
                used_n = GRANULE_IDX_W'(int'(used_n)+took);
                if (took < len) begin
                    spill_n = candidate;
                    spill_offset_n = GRANULE_IDX_W'(took);
                end
                msg_ready[rp][k] = 1;
                consumed[rp][k] = GRANT_W'(len);
                appended = 1;
                next_slot_n = unsigned'((selected+1)%(RP_COUNT*MSG_KIND_COUNT));
            end
            for (int n = 0; n < RP_COUNT; n++) begin
                rp = (int'(next_credit)+n)%RP_COUNT;
                for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                    if (crp < 0 && pending[rp][q] != 0) begin
                        crp = rp;
                    end
                end
            end
            have_grant = crp >= 0;
            // 满帧立即发；没有新消息时发出部分帧，单条请求最多增加一个攒包周期。
            // 无业务时也发 PH-only credit 帧，保证冷启动与单向流量不会相互等待。
            if (!out_valid_n && (used_n == FLIT_GRANULES || (used_n != 0 && !appended) ||
                                 (used_n == 0 && have_grant))) begin
                if (have_grant) begin
                    header[PH_CREDIT_W-1 -: RP_W] = RP_W'(crp);
                    for (int q = 0; q < MSG_KIND_COUNT; q++) begin
                        enc = int'(credit_encode(int'(pending[crp][q]), q));
                        if (q != K_WRESP) begin
                            header[q*3 +:3] = 3'(enc);
                        end else begin
                            header[13:12] = 2'(enc);
                        end
                        granted[crp][q] = GRANT_W'(credit_amount(enc));
                    end
                    next_credit_n = unsigned'((crp+1)%RP_COUNT);
                end
                out_data_n = make_flit(payload_n, starts_n, header);
                out_valid_n = 1;
                payload_n = '0;
                starts_n = '0;
                used_n = 0;
            end
        end
    end

    // 时序逻辑：异步低有效复位；背压期间保持输出寄存器。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            payload <= '0;
            starts <= '0;
            used <= 0;
            spill <= '0;
            spill_offset <= 0;
            next_slot <= 0;
            next_credit <= 0;
            flit_valid <= 0;
            flit_data <= '0;
        end else begin
            payload <= payload_n;
            starts <= starts_n;
            used <= used_n;
            spill <= spill_n;
            spill_offset <= spill_offset_n;
            next_slot <= next_slot_n;
            next_credit <= next_credit_n;
            flit_valid <= out_valid_n;
            flit_data <= out_data_n;
        end
    end
endmodule
