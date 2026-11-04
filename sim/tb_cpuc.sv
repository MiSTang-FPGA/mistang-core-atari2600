`timescale 1ns/1ps
module tb_cpuc;
    logic clk = 0, rst = 1; always #5 clk = ~clk;
    logic [7:0] mem [0:65535];
    logic [15:0] addr; logic we; logic [7:0] dout; logic sync;
    logic [15:0] pc; logic [7:0] a, x, y, sp, p;
    wire [7:0] din = mem[addr];
    cpu6502c dut(.clk(clk), .rst(rst), .ce(1'b1), .rdy(1'b1), .addr(addr), .we(we), .dout(dout), .din(din), .sync(sync),
                 .dbg_pc(pc), .dbg_a(a), .dbg_x(x), .dbg_y(y), .dbg_s(sp), .dbg_p(p));
    always_ff @(posedge clk) if (we && !rst) mem[addr] <= dout;
    integer n = 0, f, i, g; reg started = 0;
    initial begin
        $readmemh("build/rand_mem.hex", mem);
        f = $fopen("build/rtl_trace.txt", "w");
        repeat (3) @(posedge clk); rst <= 0;
        // trace until the (INSTR+1)th opcode fetch begins
        while (1) begin
            @(negedge clk);
            if (sync && !rst) begin if (n == `INSTR) break; n++; end
            if (n > 0) $fwrite(f, "%04x %0d %02x\n", addr, we, we ? dout : 8'h00);
            if (n == 0 && !sync) ;
        end
        $fclose(f);
        f = $fopen("build/rtl_state.txt", "w");
        $fwrite(f, "%04x %02x %02x %02x %02x %02x\n", pc, a, x, y, sp, p);
        for (i = 0; i < 65536; i++) $fwrite(f, "%02x\n", mem[i]);
        $fclose(f); $finish;
    end
endmodule
