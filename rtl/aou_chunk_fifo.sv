// 数据消息接收缓冲：按 8 粒度（320 位）一块分块存放，BANKS 个 bank 交错，第 s 块位于
// bank s%BANKS 的第 s/BANKS 行。一条消息占 chunk_count(粒度数) 个连续块（最多 BANKS 块），
// 每拍可写入一条、读出一条：每个 bank 每拍只读写一行，再按起始 bank 旋转拼成消息。
// 满且同拍出队时，按出队后释放的块数判断能否入队。level 以块计。
module aou_chunk_fifo #(
    parameter int BANKS = 4,
    parameter int ROWS = 32,
    localparam int N = BANKS * ROWS,
    localparam int PW = N > 1 ? $clog2(N) : 1,
    localparam int CW = $clog2(N + 1)
) (
    input logic clk,
    input logic rst_n,
    // 写入侧：一条完整消息，首字节在最高位。
    input logic s_valid,
    output logic s_ready,
    input aou_pkg::msg_t s_data,
    // 读出侧：队首消息。
    output logic m_valid,
    input logic m_ready,
    output aou_pkg::msg_t m_data,
    output logic [CW-1:0] level
);
    import aou_pkg::*;
    localparam int SLOT_BITS = 8 * GRANULE_BITS;

    logic [SLOT_BITS-1:0] mem [BANKS][ROWS];
    logic [PW-1:0] rd, wr;
    logic [4*SLOT_BITS-1:0] s_ext, m_ext;
    logic [SLOT_BITS-1:0] bank_out [BANKS];
    int s_need, m_need;
    logic push, pop;

    // 第 base+i 块（i<BANKS）的 bank 与行；超过 N 时回绕。
    function automatic int slot_of(input int base, input int i);
        int s;
        s = base + i;
        return s >= N ? s - N : s;
    endfunction
    function automatic int bank_of(input int s);
        return BANKS > 1 ? s % BANKS : 0;
    endfunction
    function automatic int row_of(input int s);
        return BANKS > 1 ? s / BANKS : s;
    endfunction

    // 组合逻辑：每个 bank 读出本拍需要的一行，再按读指针所在 bank 旋转。
    always_comb begin
        for (int b = 0; b < BANKS; b++) begin
            int i;
            i = (b - bank_of(int'(rd)) + BANKS) % BANKS;
            bank_out[b] = mem[b][row_of(slot_of(int'(rd), i))];
        end
        m_ext = '0;
        for (int i = 0; i < 4; i++) begin
            if (i < BANKS) begin
                m_ext[4*SLOT_BITS-1-i*SLOT_BITS -: SLOT_BITS] = bank_out[(bank_of(int'(rd)) + i) % BANKS];
            end
        end
    end
    assign m_data = m_ext[4*SLOT_BITS-1 -: MSG_BITS];
    assign s_ext = {s_data, {(4*SLOT_BITS-MSG_BITS){1'b0}}};
    assign s_need = chunk_count(granules(s_data[1199:1192]));
    assign m_need = chunk_count(granules(m_data[1199:1192]));
    assign m_valid = rst_n && level != 0;
    assign pop = m_valid && m_ready;
    assign s_ready = rst_n && (int'(level) - (pop ? m_need : 0) + s_need <= N);
    assign push = s_valid && s_ready;

    // 时序逻辑：入队写入连续块，出队按消息块数推进读指针；存储内容无需复位。
    always_ff @(posedge clk) begin
        if (push) begin
            for (int b = 0; b < BANKS; b++) begin
                int i;
                i = (b - bank_of(int'(wr)) + BANKS) % BANKS;
                if (i < s_need) begin
                    mem[b][row_of(slot_of(int'(wr), i))] <= s_ext[4*SLOT_BITS-1-i*SLOT_BITS -: SLOT_BITS];
                end
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd <= '0;
            wr <= '0;
            level <= '0;
        end else begin
            if (push) begin
                wr <= PW'(slot_of(int'(wr), s_need));
            end
            if (pop) begin
                rd <= PW'(slot_of(int'(rd), m_need));
            end
            level <= CW'(int'(level) + (push ? s_need : 0) - (pop ? m_need : 0));
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (!(BANKS == 1 || BANKS == 2 || BANKS == 4) || ROWS < 1) begin
            $fatal(1, "chunk FIFO requires BANKS of 1/2/4 and ROWS >= 1");
        end
    end
`endif
endmodule
