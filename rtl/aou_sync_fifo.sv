// 单时钟、单写单读的固定深度 FIFO。FWFT=0 时空队列不组合旁路；
// FWFT=1 时空队列可将输入直接送到输出，同拍握手不占用存储。
// 满且同拍出队允许入队；背压时读指针不动，输出自然保持。深度支持 1 和非 2 的幂。
module aou_sync_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8,
    parameter bit FWFT = 1'b0,
    localparam int PW = DEPTH > 1 ? $clog2(DEPTH) : 1,
    localparam int CW = $clog2(DEPTH + 1)
) (
    // 时钟和低有效异步复位。
    input logic clk,
    input logic rst_n,
    // 写入侧 ready/valid 与数据。
    input logic s_valid,
    output logic s_ready,
    input logic [WIDTH-1:0] s_data,
    // 读出侧 ready/valid、数据和当前占用量。
    output logic m_valid,
    input logic m_ready,
    output logic [WIDTH-1:0] m_data,
    output logic [CW-1:0] level
);
    // 存储数组及读写指针：指针在 DEPTH 处显式回绕，兼容非 2 的幂深度。
    logic [WIDTH-1:0] mem [DEPTH];
    logic [PW-1:0] rd, wr;

    // 握手信号：空队列直通不访问存储，满且同拍出队时仍可入队。
    logic empty, bypass_valid, bypass_fire;
    logic push, pop, mem_push, mem_pop;

    // 组合逻辑：FWFT 仅在空队列时旁路；非空时始终输出队首存储项。
    assign empty = level == 0;
    assign bypass_valid = FWFT && empty && s_valid;
    assign m_valid = rst_n && (!empty || bypass_valid);
    assign s_ready = rst_n && (level < DEPTH || (m_valid && m_ready));
    assign m_data = FWFT && empty ? s_data : mem[rd];
    assign push = s_valid && s_ready;
    assign pop = m_valid && m_ready;
    assign bypass_fire = bypass_valid && push && pop;
    assign mem_push = push && !bypass_fire;
    assign mem_pop = pop && !bypass_fire;

    // 时序逻辑：直通握手不改变计数与指针；其余出入队正常更新。
    // 异步低有效复位清空计数与指针，存储内容无需复位。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd <= '0;
            wr <= '0;
            level <= '0;
        end else begin
            if (mem_push) begin
                mem[wr] <= s_data;
                wr <= wr == DEPTH - 1 ? '0 : wr + 1'b1;
            end
            if (mem_pop) begin
                rd <= rd == DEPTH - 1 ? '0 : rd + 1'b1;
            end
            case ({mem_push, mem_pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
        end
    end

    // 仿真期检查参数；综合时由 SYNTHESIS 宏排除检查逻辑。
`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1) $fatal(1, "FIFO DEPTH must be positive");
    end
`endif
endmodule
