`timescale 1ps/1ps
module Physical_Register_File(
    input Clk,
    input Resetb,	
    //Interface with Integer Issue queue---
    input [5:0] Iss_RsPhyAddrAlu,
    input [5:0] Iss_RtPhyAddrAlu,
    //Interface with Load Store Issue queue---
    input [5:0] Iss_RsPhyAddrLsq,//计算effective address
    //Interface with Multiply Issue queue---
    input [5:0] Iss_RsPhyAddrMul,
    input [5:0] Iss_RtPhyAddrMul,
    //Interface with Divide Issue queue---
    input [5:0] Iss_RsPhyAddrDiv,
    input [5:0] Iss_RtPhyAddrDiv,
    //Interface with Dispatch---
    input [5:0] Dis_PhyRsAddr,//sent from dispatch unit stage2
    output PhyReg_RsDataRdy,// for dispatch unit
    input [5:0] Dis_PhyRtAddr,
    output PhyReg_RtDataRdy,//for dispatch unit
    //////////////////////////
    //used for update ready bit array
    input [5:0] Dis_NewRdPhyAddr,
    input Dis_RegWrite,
    //Interface with Integer Execution Unit---
    output [31:0] PhyReg_AluRsData,
    output [31:0] PhyReg_AluRtData,
    //Interface with Load Store Execution Unit---
    output [31:0] PhyReg_LsqRsData,
    //Interface with Multiply Execution Unit---
    output [31:0] PhyReg_MultRsData,
    output [31:0] PhyReg_MultRtData	,
    //Interface with Divide Execution Unit---
    output [31:0] PhyReg_DivRsData,
    output [31:0] PhyReg_DivRtData,
    //Interface with CDB ---
    input [31:0] Cdb_RdData,
    input [5:0] Cdb_RdPhyAddr,
    input Cdb_Valid,
    input Cdb_PhyRegWrite,
    //Interface with Store Buffer ---
    //fetch out date to be written into data cache
    input [5:0] Rob_CommitCurrPhyAddr,
    output [31:0] PhyReg_StoreData  
);
    integer i;
    ///physical register file with ready bit array
    reg [31:0] PRF [47:0]; //48 location, 32 location is initialized, 16 tag available
    reg [47:0] RBA;// ready bit array
    //the ready bit array don't need reset, when a new reg write instruction is fetched, the entry will be updated to zero
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            RBA<=48'h0000_ffff_ffff;//the first 32 entry is initialized, since the RRAT contains these phy tag, means they already achieve a valid data;
            for(i=0;i<48;i=i+1)begin
                PRF[i]<=i; 
            end	
        end else begin
            //重点:physical register file 没有cdb flush信号，那么当dispatch unit 2中指令被flush时应如何？
            //此指令同样会向RBA中写入0，即使被flush也没事，因为该tag还会被后面的指令重新使用的
            //PRF的更新内容如下：
            //1. dispatch 新的register write指令时，向ready bit写入1
            //2. 当指令从cdb出来时，将ready bit写入1,并更新data
            if(Dis_RegWrite)begin
                RBA[Dis_NewRdPhyAddr]<=1'b0;
            end
            ////////////
            if(Cdb_Valid&&Cdb_PhyRegWrite)begin
                RBA[Cdb_RdPhyAddr]<=1'b1;
                PRF[Cdb_RdPhyAddr]<=Cdb_RdData;
            end
        end
    end
    assign PhyReg_RsDataRdy=RBA[Dis_PhyRsAddr];
    assign PhyReg_RtDataRdy=RBA[Dis_PhyRtAddr];
    ////////////////////
    assign PhyReg_StoreData=PRF[Rob_CommitCurrPhyAddr];
    //////////////////////////
    //Interface with Integer Execution Unit---
    assign PhyReg_AluRsData=PRF[Iss_RsPhyAddrAlu];
    assign PhyReg_AluRtData=PRF[Iss_RtPhyAddrAlu];
    //Interface with Load Store Execution Unit---
    assign PhyReg_LsqRsData=PRF[Iss_RsPhyAddrLsq];
    //Interface with Multiply Execution Unit---
    assign PhyReg_MultRsData=PRF[Iss_RsPhyAddrMul];
    assign PhyReg_MultRtData=PRF[Iss_RtPhyAddrMul];
    //Interface with Divide Execution Unit---
    assign PhyReg_DivRsData=PRF[Iss_RsPhyAddrDiv];
    assign PhyReg_DivRtData=PRF[Iss_RtPhyAddrDiv];
endmodule