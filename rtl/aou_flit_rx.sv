// 250B Flit→消息：可同时查看前两帧的 FIFO、跨帧拼接 MUX、消息输出寄存器。
// 每拍至多输出一条完整消息。先检查起点重叠/长度，再提交该消息；错误置 sticky fault。
// 空粒度允许包含任意字节，只有 MsgStart 和未完成消息决定哪些字节有协议含义。
module aou_flit_rx #(
    parameter int FRAME_DEPTH = 2
) (
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

    // 帧 FIFO 默认两个槽位；最大消息 30 粒度小于每帧 48 粒度，只需查看前两帧。
    localparam int PTR_WIDTH = FRAME_DEPTH > 1 ? $clog2(FRAME_DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(FRAME_DEPTH + 1);
    flit_t frames[FRAME_DEPTH];
    flit_t frame, following_frame;
    logic [PTR_WIDTH-1:0] read_ptr, write_ptr, following_ptr;
    logic [COUNT_WIDTH-1:0] frame_count;
    logic frame_pop;

    // 队首解析位置与输出寄存器的下一拍值；跨帧消息等下一帧到齐后一次拼接。
    logic valid_n, fault_n;
    logic [5:0] cursor, cursor_n;
    msg_t output_n, work;

    // 消息边界、长度和跨帧复制时使用的组合临时量。
    logic [FLIT_GRANULES-1:0] starts, following_starts;
    int pos, len, end_pos;
    logic found, bad;

    // PH credit 仅在外部接收握手时处理一次，FIFO 出队不重复授信。
    assign flit_ready = rst_n && enable && !fault && (frame_count < FRAME_DEPTH || frame_pop);
    assign header_valid = flit_valid && flit_ready && legal_ph(flit_data);
    assign header_credit = {flit_data[1959 -:8], flit_data[1967 -:8]};

    assign following_ptr = read_ptr == FRAME_DEPTH-1 ? '0 : read_ptr+1'b1;
    assign frame = frames[read_ptr];
    assign following_frame = frames[following_ptr];

    // 组合逻辑：每拍最多提取一条完整消息，跨帧不额外占用片段解析周期。
    always_comb begin
        frame_pop = 0;
        cursor_n = cursor;
        output_n = msg_data;
        valid_n = msg_valid;
        fault_n = fault;
        starts = get_starts(frame);
        following_starts = get_starts(following_frame);
        pos = 0;
        len = 0;
        end_pos = 0;
        found = 0;
        bad = 0;
        work = '0;

        if (msg_valid && msg_ready) begin
            valid_n = 0;
        end
        if (enable && !fault) begin
            if (frame_count != 0 && !valid_n) begin
                for (int g = 0; g < FLIT_GRANULES; g++) begin
                    if (!found && g >= int'(cursor) && starts[g]) begin
                        found = 1;
                        pos = g;
                    end
                end
                if (!found) begin
                    frame_pop = 1;
                    cursor_n = 0;
                end else begin
                    len = granules(frame[1919-pos*40 -:8]);
                    end_pos = pos+len;
                    bad = len == 0;
                    for (int g = 0; g < MSG_MAX_GRANULES; g++) begin
                        if (g < len) begin
                            if (pos+g < FLIT_GRANULES) begin
                                if (g > 0 && starts[pos+g]) begin
                                    bad = 1;
                                end
                                work[1199-g*40 -:40] = frame[1919-(pos+g)*40 -:40];
                            end else if (frame_count >= 2) begin
                                // 下一帧被本消息占用的粒度不能再标记为新消息起点。
                                if (following_starts[pos+g-FLIT_GRANULES]) begin
                                    bad = 1;
                                end
                                work[1199-g*40 -:40] = following_frame[1919-(pos+g-FLIT_GRANULES)*40 -:40];
                            end
                        end
                    end
                    if (bad) begin
                        fault_n = 1;
                    end else if (end_pos <= FLIT_GRANULES || frame_count >= 2) begin
                        output_n = work;
                        valid_n = 1;
                        cursor_n = 6'(end_pos);
                        if (end_pos >= FLIT_GRANULES) begin
                            frame_pop = 1;
                            cursor_n = 6'(end_pos-FLIT_GRANULES);
                        end
                    end
                end
            end
        end
    end

    // 帧 FIFO 支持满时同拍替换；先读取旧帧，时钟沿后写入新帧，存储内容无需复位。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_ptr <= 0;
            write_ptr <= 0;
            frame_count <= 0;
        end else begin
            if (header_valid) begin
                frames[write_ptr] <= flit_data;
                write_ptr <= write_ptr == FRAME_DEPTH-1 ? '0 : write_ptr+1'b1;
            end
            if (frame_pop) begin
                read_ptr <= following_ptr;
            end
            case ({header_valid, frame_pop})
                2'b10: frame_count <= frame_count+1'b1;
                2'b01: frame_count <= frame_count-1'b1;
                default: ;
            endcase
        end
    end

    // 时序逻辑：异步低有效复位清空消息、解析状态和 sticky fault。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cursor <= 0;
            msg_valid <= 0;
            msg_data <= '0;
            fault <= 0;
        end else begin
            cursor <= cursor_n;
            msg_valid <= valid_n;
            msg_data <= output_n;
            // 独立登记输入 PH 错误，避免将输入 ready 引回帧出队组合路径。
            fault <= fault_n || (flit_valid && flit_ready && !legal_ph(flit_data));
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (FRAME_DEPTH < 2) $fatal(1, "RX frame FIFO requires at least two entries");
    end
`endif
endmodule
