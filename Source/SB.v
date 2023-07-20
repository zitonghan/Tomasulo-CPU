`timescale 1ps/1ps
module Store_Buffer(
    input Clk,
    input Resetb,			
	//interface with ROB
	input [31:0] Rob_SwAddr,
	input [31:0] PhyReg_StoreData,
	input Rob_CommitMemWrite,//rob在
	output SB_Full,
	//interface with lsq
	output SB_FlushSw,
	output [1:0] SB_FlushSwTag,
	output [1:0] SBTag_counter,
		
	//interface with Data Cache Emulator
	output [31:0] SB_DataDmem,
	output [31:0] SB_AddrDmem,
	output SB_DataValid,
	input DCE_WriteDone  
);
    //four location buffer
    //n+1 bit pointer
    reg [31:0] SB_Data [3:0];
    reg [31:0] SB_Addr [3:0];
    reg [2:0] Wr_ptr, Rd_ptr;
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            Wr_ptr<='b0;
            Rd_ptr<='b0;
        end else begin
            //write pointer update
            //rob在产生Rob_CommitMemWrite信号时已经考虑了SB没有满的条件，因此这里不需要再考虑了，并且
            if(Rob_CommitMemWrite)begin
               Wr_ptr<=Wr_ptr+1; 
               SB_Data[Wr_ptr[1:0]]<=PhyReg_StoreData;
               SB_Addr[Wr_ptr[1:0]]<=Rob_SwAddr;
            end
            //////////////////
            //SB_DataValid会当做write cache信号，而DCE_WriteDone是在write cache信号激活后才会产生的，因此这里不需要考虑data valid信号
            //SB 中的entry应该在确定data写入cache后才能release，因为如果在指令进入cache就release，那么SAB中的记录会被flush，那么lsq中的lw就
            //会进入cache读取信息，这时如果data没有写入，那么lw就会读出错误的data，措意不行
            if(DCE_WriteDone)begin
                Rd_ptr<=Rd_ptr+1;
            end
        end
    end
    assign SB_Full=((Wr_ptr^Rd_ptr)==3'b100)?1'b1:1'b0;
    assign SB_DataValid=((Wr_ptr^Rd_ptr)==3'b000)?1'b0:1'b1;//empty signals
    assign SB_DataDmem=SB_Data[Rd_ptr[1:0]];
	assign SB_AddrDmem=SB_Addr[Rd_ptr[1:0]];
    //////////////////////////////////////////
    //一旦DCE_WriteDone=1，表明当前sw已经写入了data cache，因此SAB可以进行flush了，而write done又是在有write cache时才会激活
    //因此没有问题
    assign SB_FlushSw=DCE_WriteDone;
	assign SB_FlushSwTag=Rd_ptr[1:0];
	assign SBTag_counter=Wr_ptr[1:0];
endmodule