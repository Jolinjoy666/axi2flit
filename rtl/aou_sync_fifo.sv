// 单时钟同步 FIFO，数据宽度与深度可配置，深度支持 1 和非 2 的幂。
// FWFT=1（First Word Fall Through）：非空时队首直接出现在 rd_data，rd_en 同拍取走。
// FWFT=0（标准模式）：rd_en 后下一拍 rd_data 给出读出的数据，输出寄存。
// 读写使能在空/满时自动忽略；满且同拍读出时允许写入，调用方的写就绪为 !full || rd_en。
module aou_sync_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 8,
    parameter bit FWFT = 1'b1,
    localparam int PW = DEPTH > 1 ? $clog2(DEPTH) : 1,
    localparam int CW = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst_n,
    // 写端口
    input logic wr_en,
    input logic [WIDTH-1:0] wr_data,
    output logic full,
    // 读端口
    input logic rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic empty,
    // 当前存储项数
    output logic [CW-1:0] level
);
    logic [WIDTH-1:0] mem [DEPTH];
    logic [PW-1:0] rp, wp;
    logic push, pop;

    assign empty = level == 0;
    assign full = level == CW'(DEPTH);
    assign pop = rd_en && !empty;
    assign push = wr_en && (!full || pop);

    always_ff @(posedge clk) begin
        if (push) begin
            mem[wp] <= wr_data;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rp <= '0;
            wp <= '0;
            level <= '0;
        end else begin
            if (push) begin
                wp <= wp == PW'(DEPTH - 1) ? '0 : wp + 1'b1;
            end
            if (pop) begin
                rp <= rp == PW'(DEPTH - 1) ? '0 : rp + 1'b1;
            end
            case ({push, pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
        end
    end

    generate
        if (FWFT) begin : g_fwft
            assign rd_data = mem[rp];
        end else begin : g_std
            logic [WIDTH-1:0] rd_reg;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rd_reg <= '0;
                end else if (pop) begin
                    rd_reg <= mem[rp];
                end
            end
            assign rd_data = rd_reg;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1) $fatal(1, "FIFO DEPTH must be positive");
    end
`endif
endmodule
