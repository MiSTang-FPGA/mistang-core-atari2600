// Cycle-exact NMOS 6502 for MiSTang. Original implementation (official opcodes; unofficial = 2-cycle NOP).
// One bus cycle per `ce` step, including the dummy reads / writes of the real chip, so raster-timed software works.
// The bus (`addr`, `we`, `dout`) is presented for the current cycle; `din` must hold the byte of that address when
// `ce` arrives. `rdy` low stalls the CPU on read cycles (WSYNC). No IRQ/NMI (BRK / RTI work).
module cpu6502c (
    input  logic        clk, rst, ce, rdy,
    output logic [15:0] addr,
    output logic        we,
    output logic [7:0]  dout,
    input  logic [7:0]  din,
    output logic        sync,            // current cycle is an opcode fetch
    output logic [15:0] dbg_pc,
    output logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p
);
    typedef enum logic [4:0] {
        C_V0, C_V1, C_T0, C_T1, C_AD2, C_DUM, C_PL, C_PH, C_FIX, C_RD, C_WR, C_M1,
        C_B2, C_B3, C_PSH, C_JD, C_JH, C_PL0, C_PLR, C_RS4
    } st_t;
    st_t s;
    typedef enum logic [3:0] {P_PLA, P_PLP, P_RTS_LO, P_RTS_HI, P_RTI_P, P_RTI_LO, P_RTI_HI} pc_t;
    pc_t pcont;
    typedef enum logic [2:0] {N_NONE, N_J2, N_J3, N_B2, N_B3, N_B4} nk_t;
    nk_t nk;

    logic [7:0] A, X, Y, S;
    logic [15:0] PC, ea, fixa, vec;
    logic fN, fV, fD, fI, fZ, fC, xpg;
    logic [7:0] op, lo, dat;

    wire [1:0] cc  = op[1:0];
    wire [2:0] bbb = op[4:2];
    wire [2:0] aaa = op[7:5];

    typedef enum logic [3:0] {M_IMP, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABX, M_ABY, M_INX, M_INY, M_IND} mode_t;
    typedef enum logic [1:0] {K_NONE, K_READ, K_WRITE, K_RMW} kind_t;
    mode_t  mode;
    kind_t  kind;
    logic   is_branch, is_special;
    always_comb begin
        mode = M_IMP; kind = K_NONE; is_branch = 0; is_special = 0;
        if (op[4:0] == 5'b10000) is_branch = 1;
        else if (op == 8'h00 || op == 8'h20 || op == 8'h40 || op == 8'h60 || op == 8'h08 || op == 8'h28 || op == 8'h48 || op == 8'h68) is_special = 1;
        else if (op == 8'h4C) mode = M_ABS;
        else if (op == 8'h6C) mode = M_IND;
        else case (cc)
            2'b01: begin
                case (bbb) 0: mode = M_INX; 1: mode = M_ZP; 2: mode = M_IMM; 3: mode = M_ABS; 4: mode = M_INY; 5: mode = M_ZPX; 6: mode = M_ABY; default: mode = M_ABX; endcase
                if (aaa == 3'd4) kind = K_WRITE; else kind = K_READ;
                if (aaa == 3'd4 && bbb == 3'd2) begin mode = M_IMP; kind = K_NONE; end
            end
            2'b10: begin
                case (bbb) 0: mode = M_IMM; 1: mode = M_ZP; 3: mode = M_ABS; 5: mode = M_ZPX; 7: mode = M_ABX; default: mode = M_IMP; endcase
                if ((aaa == 3'd4 || aaa == 3'd5) && bbb == 3'd5) mode = M_ZPY;
                if ((aaa == 3'd4 || aaa == 3'd5) && bbb == 3'd7) mode = M_ABY;
                if (mode != M_IMP) begin
                    if (aaa == 3'd4) kind = K_WRITE; else if (aaa == 3'd5) kind = K_READ; else kind = K_RMW;
                    if (bbb == 3'd0 && aaa != 3'd5) begin mode = M_IMP; kind = K_NONE; end
                    if (aaa == 3'd4 && bbb == 3'd7) begin mode = M_IMP; kind = K_NONE; end
                end
            end
            2'b00: begin
                case (bbb) 0: mode = M_IMM; 1: mode = M_ZP; 3: mode = M_ABS; 5: mode = M_ZPX; 7: mode = M_ABX; default: mode = M_IMP; endcase
                case (aaa)
                    3'd1: begin if (bbb == 3'd1 || bbb == 3'd3) kind = K_READ; else mode = M_IMP; end
                    3'd4: begin if (bbb == 3'd1 || bbb == 3'd3 || bbb == 3'd5) kind = K_WRITE; else mode = M_IMP; end
                    3'd5: begin kind = K_READ; end
                    3'd6, 3'd7: begin if (bbb == 3'd0 || bbb == 3'd1 || bbb == 3'd3) kind = K_READ; else mode = M_IMP; end
                    default: mode = M_IMP;
                endcase
                if (kind == K_NONE) mode = M_IMP;
            end
            default: ;
        endcase
    end

    wire [7:0] P_push = {fN, fV, 2'b11, fD, fI, fZ, fC};
    wire [7:0] wsrc = (cc == 2'b01) ? A : (cc == 2'b10) ? X : Y;
    assign dbg_pc = PC; assign dbg_a = A; assign dbg_x = X; assign dbg_y = Y; assign dbg_s = S;
    assign dbg_p = {fN, fV, 2'b11, fD, fI, fZ, fC};
    assign sync = (s == C_T0);

    always_comb begin
        addr = PC; we = 1'b0; dout = 8'h00;
        case (s)
            C_V0: addr = vec;
            C_V1: addr = vec + 16'd1;
            C_DUM, C_PL, C_RD: addr = ea;
            C_PH: addr = {ea[15:8], ea[7:0] + 8'd1};
            C_FIX: addr = fixa;
            C_WR: begin addr = ea; we = 1'b1; dout = (kind == K_RMW) ? dat : wsrc; end
            C_M1: begin addr = ea; we = 1'b1; dout = dat; end
            C_B3: addr = {PC[15:8], ea[7:0]};
            C_PSH: begin addr = {8'h01, S}; we = 1'b1; dout = dat; end
            C_JD, C_PL0, C_PLR: addr = {8'h01, S};
            default: addr = PC;
        endcase
    end

    task automatic setnz(input [7:0] v); fN <= v[7]; fZ <= (v == 8'h00); endtask

    // read-class operation executed on the byte `d`
    task automatic do_read(input [7:0] d);
        logic [8:0] t9; logic [4:0] alo; logic [9:0] ahi; logic signed [9:0] sa, sb;
        case (cc)
            2'b01: case (aaa)
                3'd0: begin A <= A | d; setnz(A | d); end
                3'd1: begin A <= A & d; setnz(A & d); end
                3'd2: begin A <= A ^ d; setnz(A ^ d); end
                3'd5: begin A <= d; setnz(d); end
                3'd6: begin t9 = {1'b0, A} - {1'b0, d}; fC <= (A >= d); setnz(t9[7:0]); end
                3'd3: begin
                    t9 = {1'b0, A} + {1'b0, d} + {8'b0, fC};
                    if (!fD) begin A <= t9[7:0]; fC <= t9[8]; setnz(t9[7:0]); fV <= (~(A ^ d) & (A ^ t9[7:0])) >> 7; end
                    else begin
                        alo = {1'b0, A[3:0]} + {1'b0, d[3:0]} + {4'b0, fC};
                        if (alo >= 5'd10) alo = ((alo + 5'd6) & 5'h0F) + 5'd16;
                        ahi = {2'b0, A[7:4], 4'b0} + {2'b0, d[7:4], 4'b0} + {5'b0, alo};
                        sa = $signed({{2{A[7]}}, A[7:4], 4'b0}) + $signed({{2{d[7]}}, d[7:4], 4'b0}) + $signed({5'b0, alo});
                        fN <= ahi[7]; fV <= (sa < -10'sd128) || (sa > 10'sd127); fZ <= (t9[7:0] == 8'h00);
                        if (ahi >= 10'd160) ahi = ahi + 10'd96;
                        A <= ahi[7:0]; fC <= (ahi >= 10'd256);
                    end
                end
                3'd7: begin
                    t9 = {1'b0, A} + {1'b0, ~d} + {8'b0, fC};
                    fC <= t9[8]; fV <= ((A ^ d) & (A ^ t9[7:0])) >> 7; setnz(t9[7:0]);
                    if (!fD) A <= t9[7:0];
                    else begin
                        sa = $signed({6'b0, A[3:0]}) - $signed({6'b0, d[3:0]}) + (fC ? 10'sd0 : -10'sd1);
                        if (sa < 0) sa = (((sa - 10'sd6) & 10'sd15)) - 10'sd16;
                        sb = $signed({2'b0, A[7:4], 4'b0}) - $signed({2'b0, d[7:4], 4'b0}) + sa;
                        if (sb < 0) sb = sb - 10'sd96;
                        A <= sb[7:0];
                    end
                end
                default: ;
            endcase
            2'b10: if (aaa == 3'd5) begin X <= d; setnz(d); end
            2'b00: case (aaa)
                3'd1: begin fZ <= ((A & d) == 8'h00); fN <= d[7]; fV <= d[6]; end
                3'd5: begin Y <= d; setnz(d); end
                3'd6: begin t9 = {1'b0, Y} - {1'b0, d}; fC <= (Y >= d); setnz(t9[7:0]); end
                3'd7: begin t9 = {1'b0, X} - {1'b0, d}; fC <= (X >= d); setnz(t9[7:0]); end
                default: ;
            endcase
            default: ;
        endcase
    endtask

    task automatic do_implied;
        case (op)
            8'h18: fC <= 0; 8'h38: fC <= 1; 8'h58: fI <= 0; 8'h78: fI <= 1; 8'hB8: fV <= 0; 8'hD8: fD <= 0; 8'hF8: fD <= 1;
            8'h88: begin Y <= Y - 8'd1; setnz(Y - 8'd1); end
            8'hC8: begin Y <= Y + 8'd1; setnz(Y + 8'd1); end
            8'hE8: begin X <= X + 8'd1; setnz(X + 8'd1); end
            8'hCA: begin X <= X - 8'd1; setnz(X - 8'd1); end
            8'hA8: begin Y <= A; setnz(A); end
            8'hAA: begin X <= A; setnz(A); end
            8'h98: begin A <= Y; setnz(Y); end
            8'h8A: begin A <= X; setnz(X); end
            8'hBA: begin X <= S; setnz(S); end
            8'h9A: S <= X;
            8'h0A: begin A <= {A[6:0], 1'b0}; fC <= A[7]; setnz({A[6:0], 1'b0}); end
            8'h2A: begin A <= {A[6:0], fC};   fC <= A[7]; setnz({A[6:0], fC}); end
            8'h4A: begin A <= {1'b0, A[7:1]}; fC <= A[0]; setnz({1'b0, A[7:1]}); end
            8'h6A: begin A <= {fC, A[7:1]};   fC <= A[0]; setnz({fC, A[7:1]}); end
            default: ;
        endcase
    endtask

    // effective address known: start the access phase
    task automatic go_ea(input [15:0] e);
        ea <= e;
        case (kind)
            K_READ, K_RMW: s <= C_RD;
            K_WRITE: s <= C_WR;
            default: begin PC <= e; s <= C_T0; end   // JMP abs
        endcase
    endtask

    logic [8:0] sum9; logic [7:0] v8; logic [15:0] tgt; logic take;
    wire step = ce && (rdy || we);
    always_ff @(posedge clk) begin
        if (rst) begin
            s <= C_V0; vec <= 16'hFFFC; S <= 8'hFD; fI <= 1; fD <= 0; A <= 0; X <= 0; Y <= 0; fN <= 0; fV <= 0; fZ <= 0; fC <= 0; PC <= 0;
        end else if (step) begin
            case (s)
                C_V0: begin lo <= din; s <= C_V1; end
                C_V1: begin PC <= {din, lo}; s <= C_T0; end
                C_T0: begin op <= din; PC <= PC + 16'd1; s <= C_T1; end
                C_T1: begin
                    if (is_branch) begin
                        lo <= din; PC <= PC + 16'd1;
                        case (op[7:6])
                            2'b00: take = (op[5] == fN);
                            2'b01: take = (op[5] == fV);
                            2'b10: take = (op[5] == fC);
                            default: take = (op[5] == fZ);
                        endcase
                        if (take) s <= C_B2; else s <= C_T0;
                    end else if (is_special) begin
                        case (op)
                            8'h48: begin dat <= A; nk <= N_NONE; s <= C_PSH; end
                            8'h08: begin dat <= P_push; nk <= N_NONE; s <= C_PSH; end
                            8'h68: begin pcont <= P_PLA; s <= C_PL0; end
                            8'h28: begin pcont <= P_PLP; s <= C_PL0; end
                            8'h20: begin lo <= din; PC <= PC + 16'd1; s <= C_JD; end
                            8'h60: begin pcont <= P_RTS_LO; s <= C_PL0; end
                            8'h40: begin pcont <= P_RTI_P; s <= C_PL0; end
                            default: begin PC <= PC + 16'd1; dat <= (PC + 16'd1) >> 8; nk <= N_B2; s <= C_PSH; end   // BRK
                        endcase
                    end else if (mode == M_IMP) begin
                        do_implied(); s <= C_T0;
                    end else if (mode == M_IMM) begin
                        do_read(din); PC <= PC + 16'd1; s <= C_T0;
                    end else begin
                        PC <= PC + 16'd1; lo <= din;
                        case (mode)
                            M_ZP:  go_ea({8'h00, din});
                            M_ZPX, M_ZPY, M_INX: begin ea <= {8'h00, din}; s <= C_DUM; end
                            M_INY: begin ea <= {8'h00, din}; s <= C_PL; end
                            default: s <= C_AD2;
                        endcase
                    end
                end
                C_AD2: begin
                    PC <= PC + 16'd1;
                    case (mode)
                        M_ABS: go_ea({din, lo});
                        M_IND: begin ea <= {din, lo}; s <= C_PL; end
                        default: begin   // ABX / ABY
                            sum9 = {1'b0, lo} + {1'b0, (mode == M_ABX) ? X : Y};
                            ea <= {din + {7'b0, sum9[8]}, sum9[7:0]}; fixa <= {din, sum9[7:0]}; xpg <= sum9[8]; s <= C_FIX;
                        end
                    endcase
                end
                C_DUM: begin
                    if (mode == M_INX) begin ea <= {8'h00, ea[7:0] + X}; s <= C_PL; end
                    else go_ea({8'h00, ea[7:0] + ((mode == M_ZPY) ? Y : X)});
                end
                C_PL: begin lo <= din; s <= C_PH; end
                C_PH: begin
                    if (mode == M_IND) begin PC <= {din, lo}; s <= C_T0; end
                    else if (mode == M_INY) begin
                        sum9 = {1'b0, lo} + {1'b0, Y};
                        ea <= {din + {7'b0, sum9[8]}, sum9[7:0]}; fixa <= {din, sum9[7:0]}; xpg <= sum9[8]; s <= C_FIX;
                    end else go_ea({din, lo});
                end
                C_FIX: begin
                    if (kind == K_READ && !xpg) begin do_read(din); s <= C_T0; end
                    else if (kind == K_WRITE) s <= C_WR;
                    else s <= C_RD;
                end
                C_RD: begin
                    dat <= din;
                    if (kind == K_RMW) s <= C_M1;
                    else begin do_read(din); s <= C_T0; end
                end
                C_M1: begin
                    case (aaa)
                        3'd0: begin v8 = {dat[6:0], 1'b0}; fC <= dat[7]; end
                        3'd1: begin v8 = {dat[6:0], fC};   fC <= dat[7]; end
                        3'd2: begin v8 = {1'b0, dat[7:1]}; fC <= dat[0]; end
                        3'd3: begin v8 = {fC, dat[7:1]};   fC <= dat[0]; end
                        3'd6: v8 = dat - 8'd1;
                        default: v8 = dat + 8'd1;
                    endcase
                    dat <= v8; setnz(v8); s <= C_WR;
                end
                C_WR: s <= C_T0;
                C_B2: begin
                    tgt = PC + {{8{lo[7]}}, lo};
                    ea <= tgt;
                    if (tgt[15:8] == PC[15:8]) begin PC <= tgt; s <= C_T0; end
                    else s <= C_B3;
                end
                C_B3: begin PC <= ea; s <= C_T0; end
                C_PSH: begin
                    S <= S - 8'd1;
                    case (nk)
                        N_NONE: s <= C_T0;
                        N_J2: begin dat <= PC[7:0]; nk <= N_J3; s <= C_PSH; end
                        N_J3: s <= C_JH;
                        N_B2: begin dat <= PC[7:0]; nk <= N_B3; s <= C_PSH; end
                        N_B3: begin dat <= P_push; nk <= N_B4; s <= C_PSH; end
                        default: begin fI <= 1; vec <= 16'hFFFE; s <= C_V0; end
                    endcase
                end
                C_JD: begin dat <= PC[15:8]; nk <= N_J2; s <= C_PSH; end
                C_JH: begin PC <= {din, lo}; s <= C_T0; end
                C_PL0: begin S <= S + 8'd1; s <= C_PLR; end
                C_PLR: begin
                    case (pcont)
                        P_PLA: begin A <= din; setnz(din); s <= C_T0; end
                        P_PLP: begin fN <= din[7]; fV <= din[6]; fD <= din[3]; fI <= din[2]; fZ <= din[1]; fC <= din[0]; s <= C_T0; end
                        P_RTS_LO: begin lo <= din; S <= S + 8'd1; pcont <= P_RTS_HI; end
                        P_RTS_HI: begin PC <= {din, lo}; s <= C_RS4; end
                        P_RTI_P: begin fN <= din[7]; fV <= din[6]; fD <= din[3]; fI <= din[2]; fZ <= din[1]; fC <= din[0]; S <= S + 8'd1; pcont <= P_RTI_LO; end
                        P_RTI_LO: begin lo <= din; S <= S + 8'd1; pcont <= P_RTI_HI; end
                        default: begin PC <= {din, lo}; s <= C_T0; end
                    endcase
                end
                C_RS4: begin PC <= PC + 16'd1; s <= C_T0; end
                default: s <= C_T0;
            endcase
        end
    end
endmodule
