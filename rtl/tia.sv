// Television Interface Adaptor for MiSTang (Atari 2600 style video). Original implementation from the public hardware description.
// One call of `ce_color` = one colour clock (228 per line: 68 blank + 160 visible). Pixels are reported with their position
// in the 160x192 picture; the picture starts 37 lines after the end of VSYNC.
module tia (
    input  logic       clk, rst,
    input  logic       ce_color,          // colour clock tick (3.58 MHz)
    // CPU write port (strobe, one clk, aligned with a ce_color tick)
    input  logic       wr,
    input  logic [5:0] wa,
    input  logic [7:0] wd,
    // CPU read port (combinational)
    input  logic [3:0] ra,
    output logic [7:0] rd,
    input  logic       fire0, fire1,      // 1 = pressed
    output logic       rdy,               // low while WSYNC waits
    // picture out
    output logic       pv,                // pixel valid (one clk)
    output logic [7:0] px,
    output logic [7:0] py,
    output logic [6:0] pc,                // colour index, hue*8+lum
    output logic       vs_fall,           // VSYNC ended (new frame)
    output logic [7:0] dbg_hc,
    output logic [7:0] dbg_ln
);
    logic [7:0] hc, ln;
    logic vsync, vblank, wsync, hmblank, ctrl_pf_dummy;
    logic [7:0] nusiz0, nusiz1, colup0, colup1, colupf, colubk, ctrlpf, pf0, pf1, pf2;
    logic refp0, refp1, enam0, enam1, enabl, enabl_old, vdp0, vdp1, vdbl, resmp0, resmp1;
    logic [7:0] grp0, grp1, grp0_old, grp1_old;
    logic [7:0] pos_p0, pos_p1, pos_m0, pos_m1, pos_bl;
    logic [3:0] hm_p0, hm_p1, hm_m0, hm_m1, hm_bl;
    logic [14:0] cx;     // collision latches
    assign rdy = !wsync;
    assign dbg_hc = hc; assign dbg_ln = ln;

    // ---- helpers ----
    function automatic [7:0] wrap160(input signed [9:0] v);
        logic signed [9:0] t;
        t = v;
        if (t < 0) t = t + 10'sd160;
        if (t >= 10'sd160) t = t - 10'sd160;
        wrap160 = t[7:0];
    endfunction
    // offset of x from an object start, 0..159
    function automatic [7:0] odist(input [7:0] x, input [7:0] p);
        logic signed [9:0] t;
        t = $signed({2'b0, x}) - $signed({2'b0, p});
        odist = wrap160(t);
    endfunction
    // does the player / missile pattern with NUSIZ `m` cover distance d? returns the in-copy offset in dd
    function automatic [8:0] copyhit(input [2:0] m, input [7:0] d, input [5:0] w);   // w = copy width in pixels; result {hit, dd[7:0]}
        logic [3:0] mask; logic h; logic [7:0] dd;
        case (m)
            3'd0, 3'd5, 3'd7: mask = 4'b0001;
            3'd1: mask = 4'b0011;
            3'd2: mask = 4'b0101;
            3'd3: mask = 4'b0111;
            3'd4: mask = 4'b1001;
            default: mask = 4'b1101;    // 6: 0, 32, 64
        endcase
        h = 0; dd = 0;
        // offsets: bit0 -> 0, bit1 -> 16, bit2 -> 32, bit3 -> 64
        if (mask[0] && d < w) begin h = 1; dd = d; end
        if (mask[1] && d >= 8'd16 && d - 8'd16 < w) begin h = 1; dd = d - 8'd16; end
        if (mask[2] && d >= 8'd32 && d - 8'd32 < w) begin h = 1; dd = d - 8'd32; end
        if (mask[3] && d >= 8'd64 && d - 8'd64 < w) begin h = 1; dd = d - 8'd64; end
        copyhit = {h, dd};
    endfunction

    // ---- pixel logic for position x ----
    logic [7:0] x;
    logic p0, p1, m0, m1, pfp, blp;
    logic [8:0] ch;
    logic [7:0] dd8, g0, g1;
    logic [5:0] scl0, scl1, mw0, mw1, bw;
    logic [5:0] k;
    logic [4:0] pfi;
    logic pfbit;
    logic [7:0] colour;
    always_comb begin
        x = hc - 8'd68;
        g0 = vdp0 ? grp0_old : grp0;
        g1 = vdp1 ? grp1_old : grp1;
        scl0 = (nusiz0[2:0] == 3'd5) ? 6'd16 : (nusiz0[2:0] == 3'd7) ? 6'd32 : 6'd8;
        scl1 = (nusiz1[2:0] == 3'd5) ? 6'd16 : (nusiz1[2:0] == 3'd7) ? 6'd32 : 6'd8;
        // player 0
        ch = copyhit(nusiz0[2:0], odist(x, pos_p0), scl0);
        p0 = 0;
        if (ch[8]) begin
            dd8 = (scl0 == 6'd8) ? ch[7:0] : (scl0 == 6'd16) ? {1'b0, ch[7:1]} : {2'b0, ch[7:2]};
            p0 = g0[refp0 ? dd8[2:0] : (3'd7 - dd8[2:0])];
        end
        // player 1
        ch = copyhit(nusiz1[2:0], odist(x, pos_p1), scl1);
        p1 = 0;
        if (ch[8]) begin
            dd8 = (scl1 == 6'd8) ? ch[7:0] : (scl1 == 6'd16) ? {1'b0, ch[7:1]} : {2'b0, ch[7:2]};
            p1 = g1[refp1 ? dd8[2:0] : (3'd7 - dd8[2:0])];
        end
        // missiles
        mw0 = 6'd1 << nusiz0[5:4]; mw1 = 6'd1 << nusiz1[5:4];
        ch = copyhit(nusiz0[2:0], odist(x, pos_m0), mw0); m0 = ch[8] && enam0 && !resmp0;
        ch = copyhit(nusiz1[2:0], odist(x, pos_m1), mw1); m1 = ch[8] && enam1 && !resmp1;
        // ball
        bw = 6'd1 << ctrlpf[5:4];
        blp = ((vdbl ? enabl_old : enabl) && odist(x, pos_bl) < {2'b0, bw});
        // playfield
        k = x[7:2];
        if (k < 6'd20) pfi = k[4:0];
        else pfi = ctrlpf[0] ? (5'd19 - (k[4:0] - 5'd20)) : (k[4:0] - 5'd20);
        if (pfi < 5'd4)        pfbit = pf0[4 + pfi[1:0]];
        else if (pfi < 5'd12)  pfbit = pf1[7 - (pfi - 5'd4)];
        else                   pfbit = pf2[pfi - 5'd12];
        pfp = pfbit;
        // colour priority
        colour = colubk;
        if (ctrlpf[2]) begin
            if (pfp)        colour = (ctrlpf[1]) ? ((x < 8'd80) ? colup0 : colup1) : colupf;
            else if (blp)   colour = colupf;
            else if (p0 || m0) colour = colup0;
            else if (p1 || m1) colour = colup1;
        end else begin
            if (p0 || m0)   colour = colup0;
            else if (p1 || m1) colour = colup1;
            else if (pfp)   colour = (ctrlpf[1]) ? ((x < 8'd80) ? colup0 : colup1) : colupf;
            else if (blp)   colour = colupf;
        end
    end

    // ---- reads ----
    always_comb begin
        rd = 8'h00;
        case (ra)
            4'h0: rd = {cx[0],  cx[1],  6'b0};      // CXM0P : M0-P1, M0-P0
            4'h1: rd = {cx[2],  cx[3],  6'b0};      // CXM1P : M1-P0, M1-P1
            4'h2: rd = {cx[4],  cx[5],  6'b0};      // CXP0FB: P0-PF, P0-BL
            4'h3: rd = {cx[6],  cx[7],  6'b0};      // CXP1FB: P1-PF, P1-BL
            4'h4: rd = {cx[8],  cx[9],  6'b0};      // CXM0FB: M0-PF, M0-BL
            4'h5: rd = {cx[10], cx[11], 6'b0};      // CXM1FB: M1-PF, M1-BL
            4'h6: rd = {cx[12], 7'b0};              // CXBLPF: BL-PF
            4'h7: rd = {cx[13], cx[14], 6'b0};      // CXPPMM: P0-P1, M0-M1
            4'hC: rd = {~fire0, 7'b0};              // INPT4
            4'hD: rd = {~fire1, 7'b0};              // INPT5
            default: rd = 8'h00;
        endcase
    end

    // ---- state ----
    wire in_pic = (ln >= 8'd37) && (ln < 8'd229);
    logic [7:0] ypic;
    assign ypic = ln - 8'd37;
    logic signed [9:0] mv;
    function automatic signed [4:0] hmv(input [3:0] h);   // HM nibble to signed motion
        hmv = {h[3], h};
    endfunction
    logic [7:0] pmin;
    logic hmove_pend;

    always_ff @(posedge clk) begin
        pv <= 1'b0; vs_fall <= 1'b0;
        if (rst) begin
            hc <= 0; ln <= 0; vsync <= 0; vblank <= 0; wsync <= 0; hmblank <= 0;
            nusiz0 <= 0; nusiz1 <= 0; colup0 <= 0; colup1 <= 0; colupf <= 0; colubk <= 0; ctrlpf <= 0; pf0 <= 0; pf1 <= 0; pf2 <= 0;
            refp0 <= 0; refp1 <= 0; enam0 <= 0; enam1 <= 0; enabl <= 0; enabl_old <= 0; vdp0 <= 0; vdp1 <= 0; vdbl <= 0; resmp0 <= 0; resmp1 <= 0;
            grp0 <= 0; grp1 <= 0; grp0_old <= 0; grp1_old <= 0; pos_p0 <= 0; pos_p1 <= 0; pos_m0 <= 0; pos_m1 <= 0; pos_bl <= 0;
            hm_p0 <= 0; hm_p1 <= 0; hm_m0 <= 0; hm_m1 <= 0; hm_bl <= 0; cx <= 0;
        end else begin
            // ---- per colour clock ----
            if (ce_color) begin
                if (hc >= 8'd68) begin
                    // collisions (visible part only)
                    cx[0]  <= cx[0]  | (m0 && p1);   cx[1]  <= cx[1]  | (m0 && p0);
                    cx[2]  <= cx[2]  | (m1 && p0);   cx[3]  <= cx[3]  | (m1 && p1);
                    cx[4]  <= cx[4]  | (p0 && pfp);  cx[5]  <= cx[5]  | (p0 && blp);
                    cx[6]  <= cx[6]  | (p1 && pfp);  cx[7]  <= cx[7]  | (p1 && blp);
                    cx[8]  <= cx[8]  | (m0 && pfp);  cx[9]  <= cx[9]  | (m0 && blp);
                    cx[10] <= cx[10] | (m1 && pfp);  cx[11] <= cx[11] | (m1 && blp);
                    cx[12] <= cx[12] | (blp && pfp);
                    cx[13] <= cx[13] | (p0 && p1);   cx[14] <= cx[14] | (m0 && m1);
                    if (in_pic) begin
                        pv <= 1'b1; px <= x; py <= ypic;
                        pc <= (vblank || (hmblank && x < 8'd8)) ? 7'd0 : colour[7:1];
                    end
                end
                if (hc == 8'd227) begin
                    hc <= 0; wsync <= 0; hmblank <= 0;
                    if (ln != 8'hFF) ln <= ln + 8'd1;
                end else hc <= hc + 8'd1;
            end
            // ---- CPU register writes ----
            if (wr) begin
                case (wa)
                    6'h00: begin
                        vsync <= wd[1];
                        if (vsync && !wd[1]) begin ln <= 0; vs_fall <= 1'b1; end
                    end
                    6'h01: vblank <= wd[1];
                    6'h02: wsync <= 1'b1;
                    6'h04: nusiz0 <= wd; 6'h05: nusiz1 <= wd;
                    6'h06: colup0 <= wd; 6'h07: colup1 <= wd; 6'h08: colupf <= wd; 6'h09: colubk <= wd;
                    6'h0A: ctrlpf <= wd;
                    6'h0B: refp0 <= wd[3]; 6'h0C: refp1 <= wd[3];
                    6'h0D: pf0 <= wd; 6'h0E: pf1 <= wd; 6'h0F: pf2 <= wd;
                    6'h10: pos_p0 <= (hc < 8'd68 + 8'd0 || hc - 8'd65 < 8'd3) ? 8'd3 : wrap160($signed({2'b0, hc}) - 10'sd65);
                    6'h11: pos_p1 <= (hc < 8'd68 + 8'd0 || hc - 8'd65 < 8'd3) ? 8'd3 : wrap160($signed({2'b0, hc}) - 10'sd65);
                    6'h12: pos_m0 <= (hc < 8'd68) ? 8'd2 : wrap160($signed({2'b0, hc}) - 10'sd66);
                    6'h13: pos_m1 <= (hc < 8'd68) ? 8'd2 : wrap160($signed({2'b0, hc}) - 10'sd66);
                    6'h14: pos_bl <= (hc < 8'd68) ? 8'd2 : wrap160($signed({2'b0, hc}) - 10'sd66);
                    6'h1B: begin grp0 <= wd; grp1_old <= grp1; end
                    6'h1C: begin grp1 <= wd; grp0_old <= grp0; enabl_old <= enabl; end
                    6'h1D: enam0 <= wd[1]; 6'h1E: enam1 <= wd[1]; 6'h1F: enabl <= wd[1];
                    6'h20: hm_p0 <= wd[7:4]; 6'h21: hm_p1 <= wd[7:4]; 6'h22: hm_m0 <= wd[7:4]; 6'h23: hm_m1 <= wd[7:4]; 6'h24: hm_bl <= wd[7:4];
                    6'h25: vdp0 <= wd[0]; 6'h26: vdp1 <= wd[0]; 6'h27: vdbl <= wd[0];
                    6'h28: begin resmp0 <= wd[1]; if (wd[1]) pos_m0 <= wrap160($signed({2'b0, pos_p0}) + 10'sd4); end
                    6'h29: begin resmp1 <= wd[1]; if (wd[1]) pos_m1 <= wrap160($signed({2'b0, pos_p1}) + 10'sd4); end
                    6'h2A: begin
                        pos_p0 <= wrap160($signed({2'b0, pos_p0}) - hmv(hm_p0));
                        pos_p1 <= wrap160($signed({2'b0, pos_p1}) - hmv(hm_p1));
                        pos_m0 <= wrap160($signed({2'b0, pos_m0}) - hmv(hm_m0));
                        pos_m1 <= wrap160($signed({2'b0, pos_m1}) - hmv(hm_m1));
                        pos_bl <= wrap160($signed({2'b0, pos_bl}) - hmv(hm_bl));
                        if (hc < 8'd68) hmblank <= 1'b1;
                    end
                    6'h2B: begin hm_p0 <= 0; hm_p1 <= 0; hm_m0 <= 0; hm_m1 <= 0; hm_bl <= 0; end
                    6'h2C: cx <= 0;
                    default: ;
                endcase
            end
        end
    end
endmodule
