`timescale 1ps/1ps
module BRAM #(
    parameter ADDR_WIDTH = $clog2(8*32),
              DOUT_WIDTH = 6,
              ID = 1
)(
    input clk,
    input wea,
    input [ADDR_WIDTH-1:0] addra, 
    input [ADDR_WIDTH-1:0] addrb,
    input [DOUT_WIDTH-1:0] dina,
    output reg [DOUT_WIDTH-1:0] doutb
);
    integer i;
    (* ram_style = "block" *) reg [DOUT_WIDTH-1:0] mem [2**ADDR_WIDTH-1:0];
    //////////////////////////////////////
    //bram initialize
    initial begin
        if(ID==2)begin
            for(i=0;i<32;i=i+1)begin
                mem[i]=i;
            end 
        end
    end

    always @(posedge clk) begin
        if(wea)begin
            mem[addra]<=dina;
        end
        doutb<=mem[addrb];//output register mode bram
    end
endmodule