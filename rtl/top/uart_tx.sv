module uart_tx #(parameter int DIV = 645) (
    input  logic clk, input logic [7:0] data, input logic start,
    output logic busy, output logic tx
);
    logic [9:0] sh = 10'h3FF; logic [3:0] n = 0; logic [11:0] c = 0;
    assign busy = (n != 0);
    assign tx = sh[0];
    always_ff @(posedge clk) begin
        if (n == 0) begin
            if (start) begin sh <= {1'b1, data, 1'b0}; n <= 4'd10; c <= DIV - 1; end
        end else if (c == 0) begin
            sh <= {1'b1, sh[9:1]}; n <= n - 4'd1; c <= DIV - 1;
        end else c <= c - 12'd1;
    end
endmodule
