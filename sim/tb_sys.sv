`timescale 1ns/1ps
module tb_sys;
    logic clk = 0, rst = 1; always #5 clk = ~clk;
    logic [6:0] vq, cap_q; logic vs_fall;
    atari_sys #(.ROM_FILE(`ROM)) dut(.clk(clk), .rst(rst), .fire0(1'b0), .fire1(1'b0), .vclk(clk), .vaddr(15'd0), .vq(vq),
                                    .cap_addr(15'd0), .cap_q(cap_q), .vs_fall(vs_fall));
    integer tc = 0, f, g, i, falls = 0;
    initial begin
        f = $fopen("build/tia_writes.txt", "w");
        repeat (4) @(posedge clk); rst <= 0;
    end
    always @(posedge clk) if (!rst) begin
        if (dut.ce_cpu && dut.we && dut.sel_tia) $fwrite(f, "%0d %0d %0d\n", tc, dut.addr[5:0], dut.dout);
        if (dut.ce_color) tc <= tc + 1;
    end
    // the TIA reports the VSYNC release one clk after the write edge; the colour-clock counter has not moved in between
    always @(posedge clk) if (vs_fall) begin
        falls <= falls + 1;
        if (falls + 1 == `FALLS) begin
            $fclose(f);
            g = $fopen("build/rtl_fb.txt", "w");
            for (i = 0; i < 30720; i++) $fwrite(g, "%02x\n", dut.fb[i]);
            $fclose(g);
            g = $fopen("build/rtl_cx.txt", "w");
            $fwrite(g, "%0d %0d\n", tc - 1, dut.u_tia.cx);
            $fclose(g);
            $finish;
        end
    end
endmodule
