// Atari 2600 style system for MiSTang: 6502 (cycle exact), TIA video, RIOT (128 bytes RAM, interval timer, I/O), 4 KiB cartridge.
// Original implementation. The colour clock is derived from sys_clk with a phase accumulator (3.579545 MHz).
module atari_sys #(
    parameter ROM_FILE = "rom/demo.hex",
    parameter [15:0] CINC = 16'd8688          // 65536 * 3.579545 / 27
)(
    input  logic        clk, rst,
    input  logic        fire0, fire1,
    // video read port (vclk domain) and capture port (clk domain): 160x192, 7-bit colour index
    input  logic        vclk,
    input  logic [14:0] vaddr,
    output logic [6:0]  vq,
    input  logic [14:0] cap_addr,
    output logic [6:0]  cap_q,
    output logic        vs_fall
);
    // ---- clocks ----
    logic [16:0] acc; logic ce_color; logic [1:0] ph;
    always_ff @(posedge clk) begin
        if (rst) begin acc <= 0; ce_color <= 0; ph <= 0; end
        else begin
            acc <= {1'b0, acc[15:0]} + {1'b0, CINC};
            ce_color <= acc[16];
            if (ce_color) ph <= (ph == 2'd2) ? 2'd0 : ph + 2'd1;
        end
    end
    wire ce_cpu = ce_color && (ph == 2'd2);

    // ---- CPU ----
    logic [15:0] addr; logic we; logic [7:0] dout, din; logic rdy; logic sync;
    cpu6502c cpu (.clk(clk), .rst(rst), .ce(ce_cpu), .rdy(rdy), .addr(addr), .we(we), .dout(dout), .din(din), .sync(sync),
                  .dbg_pc(), .dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p());

    wire a12 = addr[12], a7 = addr[7], a9 = addr[9];
    wire sel_rom  = a12;
    wire sel_tia  = !a12 && !a7;
    wire sel_ram  = !a12 && a7 && !a9;
    wire sel_riot = !a12 && a7 && a9;

    // ---- memories ----
    logic [7:0] rom [0:4095]; logic [7:0] ram [0:127];
    initial $readmemh(ROM_FILE, rom);
    logic [7:0] rom_q, ram_q;
    always_ff @(posedge clk) begin
        rom_q <= rom[addr[11:0]];
        if (we && sel_ram) ram[addr[6:0]] <= dout;
        ram_q <= ram[addr[6:0]];
    end

    // ---- RIOT timer ----
    logic [7:0] intim; logic [9:0] sub; logic [10:0] plim; logic uf, ufm;
    wire tim_wr = we && sel_riot && addr[2] && addr[4];
    always_ff @(posedge clk) begin
        if (rst) begin intim <= 8'hFF; sub <= 0; plim <= 11'd1; uf <= 0; ufm <= 0; end
        else if (ce_cpu) begin
            if (tim_wr) begin
                intim <= dout; sub <= 0; uf <= 0; ufm <= 0;
                case (addr[1:0]) 2'd0: plim <= 11'd1; 2'd1: plim <= 11'd8; 2'd2: plim <= 11'd64; default: plim <= 11'd1024; endcase
            end else if (ufm) intim <= intim - 8'd1;
            else if ({1'b0, sub} + 11'd1 >= plim) begin
                sub <= 0;
                if (intim == 8'd0) begin intim <= 8'hFF; uf <= 1; ufm <= 1; end
                else intim <= intim - 8'd1;
            end else sub <= sub + 10'd1;
        end
    end

    // ---- TIA ----
    logic [7:0] tia_rd; logic tia_pv; logic [7:0] tia_px, tia_py; logic [6:0] tia_pc;
    tia u_tia (.clk(clk), .rst(rst), .ce_color(ce_color), .wr(ce_cpu && we && sel_tia), .wa(addr[5:0]), .wd(dout),
               .ra(addr[3:0]), .rd(tia_rd), .fire0(fire0), .fire1(fire1), .rdy(rdy),
               .pv(tia_pv), .px(tia_px), .py(tia_py), .pc(tia_pc), .vs_fall(vs_fall), .dbg_hc(), .dbg_ln());

    always_comb begin
        din = 8'hFF;
        if (sel_rom) din = rom_q;
        else if (sel_tia) din = tia_rd;
        else if (sel_ram) din = ram_q;
        else if (!addr[2]) begin
            case (addr[1:0]) 2'd0: din = 8'hFF; 2'd2: din = 8'hFF; default: din = 8'h00; endcase   // SWCHA, SWCHB
        end else din = addr[0] ? {uf, 7'b0} : intim;
    end

    // ---- frame buffer ----
    logic [6:0] fb [0:30719];     // read by the capture port (clk domain)
    logic [6:0] fbv [0:30719];    // identical copy read by the video (vclk domain): one read port per RAM block
    logic [14:0] waddr; logic [6:0] wdata; logic wen;
    always_ff @(posedge clk) begin
        wen <= tia_pv; wdata <= tia_pc;
        waddr <= {tia_py, 7'b0} + {2'b0, tia_py, 5'b0} + {7'b0, tia_px};
        if (wen) begin fb[waddr] <= wdata; fbv[waddr] <= wdata; end
        cap_q <= fb[cap_addr];
    end
    always_ff @(posedge vclk) vq <= fbv[vaddr];
endmodule
