// 250B Flit→消息：固定帧寄存器、跨帧消息寄存器、消息输出寄存器。
// 每拍至多输出一条完整消息。先检查起点重叠/长度，再提交该消息；错误置 sticky fault。
// 空粒度允许包含任意字节，只有 MsgStart 和未完成消息决定哪些字节有协议含义。
module aou_flit_rx (
    // 时钟、复位与接收使能。
    input logic clk,
    input logic rst_n,
    input logic enable,
    // Flit 输入握手。
    input logic flit_valid,
    output logic flit_ready,
    input aou_pkg::flit_t flit_data,
    // 完整消息输出握手。
    output logic msg_valid,
    input logic msg_ready,
    output aou_pkg::msg_t msg_data,
    // PH credit 与解析错误。
    output logic header_valid,
    output logic [15:0] header_credit,
    output logic fault
);
    import aou_pkg::*;

    // 当前 Flit 的解析状态及对应下一拍值。
    flit_t frame, frame_n;
    logic active, active_n, valid_n, fault_n;
    logic [5:0] cursor, cursor_n, carry_count, carry_count_n;
    msg_t carry, carry_n, output_n, work;

    // 消息边界、长度和跨帧复制时使用的组合临时量。
    logic [FLIT_GRANULES-1:0] starts;
    int pos, len, take_count, offset;
    logic found, bad;

    // 组合逻辑：仅空闲且无故障时接收新帧；PH credit 在接收握手时有效。
    assign flit_ready = enable && !fault && !active;
    assign header_valid = flit_valid && flit_ready && legal_ph(flit_data);
    assign header_credit = {flit_data[1959 -:8], flit_data[1967 -:8]};

    // 组合逻辑：按 MsgStart 查找消息，并在跨帧时接续未完成的消息。
    always_comb begin
        frame_n = frame;
        active_n = active;
        cursor_n = cursor;
        carry_n = carry;
        carry_count_n = carry_count;
        output_n = msg_data;
        valid_n = msg_valid;
        fault_n = fault;
        starts = get_starts(frame);
        pos = 0;
        len = 0;
        take_count = 0;
        offset = 0;
        found = 0;
        bad = 0;
        work = '0;

        if (msg_valid && msg_ready) begin
            valid_n = 0;
        end
        if (enable && !fault) begin
            if (active && !valid_n) begin
                if (carry_count != 0) begin
                    found = 1;
                    pos = 0;
                    work = carry;
                    offset = int'(carry_count);
                    if (starts[0]) begin
                        bad = 1;
                    end
                end else begin
                    for (int g = 0; g < FLIT_GRANULES; g++) begin
                        if (!found && g >= int'(cursor) && starts[g]) begin
                            found = 1;
                            pos = g;
                        end
                    end
                    if (found) begin
                        work[1199 -:8] = frame[1919-pos*40 -:8];
                    end
                end
                if (!found) begin
                    active_n = 0;
                    cursor_n = 0;
                end else begin
                    len = granules(work[1199 -:8]);
                    if (len == 0 || offset >= len) begin
                        bad = 1;
                    end
                    take_count = len-offset < FLIT_GRANULES-pos ? len-offset : FLIT_GRANULES-pos;
                    for (int g = 0; g < MSG_MAX_GRANULES; g++) begin
                        if (g < take_count) begin
                            if (g > 0 && starts[pos+g]) begin
                                bad = 1;
                            end
                            work[1199-(offset+g)*40 -:40] = frame[1919-(pos+g)*40 -:40];
                        end
                    end
                    if (bad) begin
                        fault_n = 1;
                    end else begin
                        if (offset+take_count == len) begin
                            output_n = work;
                            valid_n = 1;
                            carry_n = '0;
                            carry_count_n = 0;
                        end else begin
                            carry_n = work;
                            carry_count_n = 6'(offset+take_count);
                        end
                        cursor_n = 6'(pos+take_count);
                        if (pos+take_count == FLIT_GRANULES) begin
                            active_n = 0;
                            cursor_n = 0;
                        end
                    end
                end
            end
            if (flit_valid && flit_ready) begin
                if (!legal_ph(flit_data)) begin
                    fault_n = 1;
                end else begin
                    frame_n = flit_data;
                    active_n = 1;
                    cursor_n = 0;
                end
            end
        end
    end

    // 时序逻辑：异步低有效复位清空消息、解析状态和 sticky fault。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame <= '0;
            active <= 0;
            cursor <= 0;
            carry <= '0;
            carry_count <= 0;
            msg_valid <= 0;
            msg_data <= '0;
            fault <= 0;
        end else begin
            frame <= frame_n;
            active <= active_n;
            cursor <= cursor_n;
            carry <= carry_n;
            carry_count <= carry_count_n;
            msg_valid <= valid_n;
            msg_data <= output_n;
            fault <= fault_n;
        end
    end
endmodule
