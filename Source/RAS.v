`timescale 1ps/1ps
module RAS(
    input Resetb,					
	input Clk,						
	input [31:0] Dis_PcPlusFour,
    input Dis_RasJalInst,
    input Dis_RasJr31Inst,
    output [31:0] Ras_Addr				
);
    //it can store four JAL return address
    //JAL equivalizes to call isntrcution
    reg [31:0] mem [3:0];
    reg [1:0] TOSP,TOSP_plus1;
    reg [2:0] counter;//used to count the number of return address stored in the RAS
    reg [31:0] UseWhenEmpty;//when RAS become empty, the last return address will be stored in this register
    ////////////////
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            counter<='b0;
            TOSP_plus1<='b0;//push pointer
            TOSP<=2'b11;//pop pointer
            UseWhenEmpty<='b0;
        end else begin
            if(Dis_RasJalInst&&!Dis_RasJr31Inst)begin
                mem[TOSP_plus1]<=Dis_PcPlusFour;
                TOSP<=TOSP+1;
                TOSP_plus1<=TOSP_plus1+1;
                if(counter<4)begin//if counter = 3'b100, it will keep constant
                    counter<=counter+1;
                end
            end else if(!Dis_RasJalInst&&Dis_RasJr31Inst)begin
                if(counter>0)begin
                    counter<=counter-1;
                    TOSP<=TOSP-1;
                    TOSP_plus1<=TOSP_plus1-1;
                    if(counter==1)begin
                        UseWhenEmpty<=mem[TOSP];
                    end
                end
            end
        end
    end
    /////////////////
    assign Ras_Addr=(counter>0)?mem[TOSP]:UseWhenEmpty;
    
endmodule