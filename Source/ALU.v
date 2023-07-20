`timescale 1ps/1ps
module ALU(
    input [31:0] PhyReg_AluRsData,
	input [31:0] PhyReg_AluRtData,
	input [2:0] Iss_OpcodeAlu,
	input [4:0] Iss_RobTagAlu,
	input [5:0] Iss_RdPhyAddrAlu,
	input [31:0] Iss_BranchAddrAlu,	//branch mispredicted direction	
    input Iss_BranchAlu,
	input Iss_RegWriteAlu,
	input [2:0] Iss_BranchUptAddrAlu,
	input Iss_BranchPredictAlu,
	input Iss_JalInstAlu,
	input Iss_JrInstAlu,//jr rs会直接把rs data存入branch address中，dispatch unit通过对比rob tag识别，并通过branch addr进行跳转
	input Iss_JrRsInstAlu,
	input [15:0] Iss_ImmediateAlu,	
	output reg [31:0] Alu_RdData, //
    output [5:0] Alu_RdPhyAddr,//
    output reg [31:0] Alu_BranchAddr,	//bne,beq,jr$31,jr!31,
    output Alu_Branch,//
	output reg Alu_BranchOutcome,//
	output [4:0]Alu_RobTag,//
	output [2:0] Alu_BranchUptAddr, //
    output Alu_BranchPredict,//
	output Alu_RdWrite,//
	output reg Alu_JrFlush
);
    assign Alu_RdWrite=Iss_RegWriteAlu;
    assign Alu_BranchPredict=Iss_BranchPredictAlu;
    assign Alu_BranchUptAddr=Iss_BranchUptAddrAlu;
    assign Alu_RobTag=Iss_RobTagAlu;
    assign Alu_Branch=Iss_BranchAlu;
    assign Alu_RdPhyAddr=Iss_RdPhyAddrAlu;
    ///////////////////////////////////////////////
    //combinational logic
    always@(*)begin
        Alu_BranchOutcome=1'b0;
        Alu_JrFlush=1'b0;
        Alu_BranchAddr=Iss_BranchAddrAlu;
        //default assignment
        //branch 
        if(Iss_BranchAlu)begin
            if(Iss_OpcodeAlu[0])begin//bne ->111, beq->110
                //bne
                if(PhyReg_AluRsData!=PhyReg_AluRtData)begin
                    Alu_BranchOutcome=1'b1;
                end
            end else begin//beq
                if(PhyReg_AluRsData==PhyReg_AluRtData)begin
                    Alu_BranchOutcome=1'b1;
                end
            end
        end
        //////////////////////////
        //update rd data
        //add,sub,and,or,slt,jal,
        //jal->将pc+4写入$31中
        //注意：dispatch unit中的pc+4是给RAS的，而jal需要的pc+4则是存在了branchaddr中
        case(Iss_OpcodeAlu)
            3'b100: Alu_RdData=PhyReg_AluRsData+{{16{Iss_ImmediateAlu[15]}},Iss_ImmediateAlu};//addi
            3'b001: Alu_RdData=PhyReg_AluRsData-PhyReg_AluRtData;//sub
            3'b010: Alu_RdData=PhyReg_AluRtData&PhyReg_AluRsData;//and
            3'b011: Alu_RdData=PhyReg_AluRtData|PhyReg_AluRsData;//or
            3'b101:begin//slt
                if(PhyReg_AluRsData<PhyReg_AluRtData)begin
                    Alu_RdData='b1;
                end else begin
                    Alu_RdData='b0;
                end
            end
            default:begin//add,jal,jr,bne,beq
                if(!Iss_JalInstAlu&&Iss_RegWriteAlu)begin//add
                    Alu_RdData=PhyReg_AluRsData+PhyReg_AluRtData;
                end else begin//jal+其他不是regwrite类型的指令
                    Alu_RdData=Iss_BranchAddrAlu;
                end
            end
        endcase
        //////////////////////////////
        //更新 Alu_BranchAddr 以及jr_flush
        //jr rs and jr 31都会更新Alu_BranchAddr 
        if(Iss_JrRsInstAlu)begin
            Alu_BranchAddr=PhyReg_AluRsData;
        end else if(Iss_JrInstAlu&&Iss_BranchAddrAlu!=PhyReg_AluRsData)begin
            Alu_BranchAddr=PhyReg_AluRsData;
            Alu_JrFlush=1'b1;
        end
    end


endmodule