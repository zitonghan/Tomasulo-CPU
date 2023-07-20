`timescale 1ns/1ps
module tb;
    reg ClkIn;
    reg rst_pin;

    ///////////////
    Tomasulo_Top DUT(
        .ClkIn(ClkIn),
        .rst_pin(rst_pin)
    );
    initial ClkIn=0;
    always begin
        #2 ClkIn=~ClkIn;
    end
    initial begin
        rst_pin=1'b1;
        @(posedge ClkIn);
        #1;
        rst_pin=1'b0;
        #500000 $stop;
    end
endmodule