// Scaler for the 160x192 TIA picture: 6x horizontally, 3x vertically = 960x576 centred in 1280x720 (x 160..1119, y 72..647).
// Pipeline: frame buffer address -> colour index -> palette ROM; `active` and `rgb` are aligned (P0 appears at cx = 159).
module atari_video #(parameter PAL_FILE = "rom/palette.hex") (
    input  logic        clk,
    input  logic [10:0] cx,
    input  logic [9:0]  cy,
    output logic [14:0] vaddr,
    input  logic [6:0]  vq,
    output logic        active,
    output logic [23:0] rgb
);
    logic [23:0] pal [0:127];
    initial $readmemh(PAL_FILE, pal);
    logic [14:0] rowbase; logic [1:0] ys; logic vact;
    logic [2:0] sx; logic [7:0] xi; logic hrun, a0, a1;
    always_ff @(posedge clk) begin
        if (cx == 11'd0) begin
            if (cy == 10'd72) begin vact <= 1'b1; ys <= 0; rowbase <= 0; end
            else if (cy == 10'd648) vact <= 1'b0;
            else if (vact) begin
                if (ys == 2'd2) begin ys <= 0; rowbase <= rowbase + 15'd160; end
                else ys <= ys + 2'd1;
            end
        end
        if (cx == 11'd156) begin hrun <= 1'b1; sx <= 0; xi <= 0; vaddr <= rowbase; end
        else if (hrun) begin
            if (sx == 3'd5) begin
                sx <= 0;
                if (xi == 8'd159) hrun <= 1'b0;
                else begin xi <= xi + 8'd1; vaddr <= rowbase + {7'd0, xi} + 15'd1; end
            end else sx <= sx + 3'd1;
        end
        a0 <= hrun && vact; a1 <= a0; active <= a1;
        rgb <= pal[vq];
    end
endmodule
