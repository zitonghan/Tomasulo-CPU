`timescale 1ps/1ps
module FRL(
    input Clk,          	  		
	input Resetb,       		 
	input Cdb_Flush,    			
	//Interface with Rob
	input [5:0] Rob_CommitPrePhyAddr, 	
	input Rob_Commit,   			
	input Rob_CommitRegWrite, 	
	input [4:0] Cfc_FrlHeadPtr,//16 locations, n+1 pointer
	//Interface with Dis_FrlRead unit
	output [5:0] Frl_RdPhyAddr,        	
	input Dis_FrlRead,    			
	output Frl_Empty,      			
	//Interface with Previous Head Pointer Stack
	output [4:0] Frl_HeadPtr    			
);
    reg [5:0] FRL_mem [15:0];
    reg [4:0] Head_ptr,Tail_ptr;
    integer i;
    //////////////
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            for (i=0;i<16;i=i+1)begin
                FRL_mem[i]<=i+32;
            end
            Head_ptr<=5'b00000;//read pointer
            Tail_ptr<=5'b10000;//write pointer
        end else begin
            if(Cdb_Flush)begin
                Head_ptr<= Cfc_FrlHeadPtr;
            end else if(Dis_FrlRead)begin
                Head_ptr<=Head_ptr+1;
            end
            ///////////////
            //head pointer 与tail pointer的更新逻辑应该并行进行，cdb_flush以及dispatch unit控制head pointer的更新，但是tail pointer的更新有rob控制
            if(Rob_Commit&&Rob_CommitRegWrite)begin
                FRL_mem[Tail_ptr[3:0]]<=Rob_CommitPrePhyAddr;//current tag stored in the rrat
                Tail_ptr<=Tail_ptr+1;
            end
        end
    end
    ///////////////
    assign Frl_Empty=((Head_ptr^Tail_ptr)==5'b00000)?1'b1:1'b0;
    assign Frl_HeadPtr=Head_ptr;
    assign Frl_RdPhyAddr=FRL_mem[Head_ptr[3:0]];
endmodule