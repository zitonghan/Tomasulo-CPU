`timescale 1ps/1ps
module Common_Data_Bus(
    input Clk,
    input Resetb,        
    //from ROB 
    input [5:0] Rob_TopPtr,
    //from integer execution unit
    input [31:0] Alu_RdData,   
    input [5:0] Alu_RdPhyAddr,
    input [31:0] Alu_BranchAddr,		
    input Alu_Branch,
	input Alu_BranchOutcome,
	input [2:0] Alu_BranchUptAddr,
    input Iss_Int,
    input Alu_BranchPredict,			
	input Alu_JrFlush,
	input [4:0] Alu_RobTag,
	input Alu_RdWrite,
    //from mult execution unit
    input [31:0] Mul_RdData,// mult_data coming from the multiplier
    input [5:0] Mul_RdPhyAddr,// mult_prfaddr coming from the multiplier
    input Mul_Done,// this is the valid bit coming from the bottom most pipeline register in the multiplier wrapper
    input [4:0] Mul_RobTag,
	input Mul_RdWrite,
	//from div execution unit
    input [31:0] Div_Rddata,// div_data coming from the divider
    input [5:0] Div_RdPhyAddr,// div_prfaddr coming from the divider
    input Div_Done,// this is the valid bit coming from the bottom most pipeline register in the multiplier wrapper
    input [4:0] Div_RobTag,
	input Div_RdWrite,
	//from load buffer and store word
    input [31:0] Lsbuf_Data, 
    input [5:0] Lsbuf_PhyAddr,  
    input Iss_Lsb,                   
    input [4:0] Lsbuf_RobTag,
	input [31:0] Lsbuf_SwAddr,
	input Lsbuf_RdWrite,
    //outputs of cdb 
    output reg Cdb_Valid,//used to write instruction into ROB, 
    //重点：由于fetch jr$!31指令时，rob已经suspend了，因此即使jr指令到达cdb，也可以写入rob,因为下一个时钟jr完成写入，IFQ完成清空，并�??
    //pc重置，开始从inst中提取指令，因此当新的指令取出时，便可以写如rob中新的�??
	output reg Cdb_PhyRegWrite,
    output reg [31:0] Cdb_Data,
    output Cdb_RobTag_DU,
    output Cdb_RobTag_ROB,
    output Cdb_RobTag_CFC,
	output reg [31:0] Cdb_BranchAddr,
    output reg Cdb_BranchOutcome,
	output reg [2:0] Cdb_BranchUpdtAddr,
    output reg Cdb_Branch,
    output reg Cdb_Flush,
	output Cdb_RobTag_Depth2IntQ,
    output Cdb_RobTag_Depth2MulQ,
    output Cdb_RobTag_Depth2DivQ,
    output Cdb_RobTag_Depth2Mul,
    output Cdb_RobTag_Depth2Div,
    output Cdb_RobTag_Depth2LSQ,
    output Cdb_RobTag_Depth2LB,
    output Cdb_RobTag_Depth2DC,
    output Cdb_RobTag_Depth2CFC,
	output reg [5:0] Cdb_RdPhyAddr,
	output reg [31:0] Cdb_SwAddr, 
	input Rob_Commit
);
    wire [4:0] Alu_RobDepth;
    wire [5:0] Rob_TopPtr_Next;
//Reduce fanout attempts
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2IntQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2MulQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2DivQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2Mul;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2Div;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2LSQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2LB;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2DC;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_Depth2CFC;
    /////////////////////////////////
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_DU;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_ROB;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [4:0] Cdb_RobTag_CFC;
    ///////////////////////////////////////////////
    //the cdb is consist of a combinational mux and a stage register
    always@(posedge Clk,negedge Resetb)begin
        if(!Resetb)begin
            Cdb_Valid<=1'b0;
            Cdb_Branch<=1'b0;
            Cdb_Flush<=1'b0;
            Cdb_PhyRegWrite<=1'b0;
            //above signals are control signals
            ///////////////////////////
            Cdb_Data<='bx;
            Cdb_RobTag_DU<='bx;
            Cdb_RobTag_CFC<='bx;
            Cdb_RobTag_ROB<='bx;
            Cdb_BranchAddr<='bx;
            Cdb_BranchOutcome<='bx;
            Cdb_BranchUpdtAddr<='bx;
            Cdb_RdPhyAddr<='bx;
            Cdb_SwAddr<='bx;
            Cdb_RobTag_Depth2IntQ<='bx;
            Cdb_RobTag_Depth2MulQ<='bx;
            Cdb_RobTag_Depth2DivQ<='bx;
            Cdb_RobTag_Depth2Mul<='bx;
            Cdb_RobTag_Depth2Div<='bx;
            Cdb_RobTag_Depth2LSQ<='bx;
            Cdb_RobTag_Depth2LB<='bx;
            Cdb_RobTag_Depth2DC<='bx;
            Cdb_RobTag_Depth2CFC<='bx;
        end else begin
            Cdb_Valid<=Iss_Int||Iss_Lsb||Mul_Done||Div_Done;
            //重点：
            //下面这些信号只有从alu传来的数据是有效的，因此他们永远都从alu接收即可
            Cdb_BranchAddr<=Alu_BranchAddr;
            Cdb_BranchOutcome<=Alu_BranchOutcome;
            Cdb_BranchUpdtAddr<=Alu_BranchUptAddr;
            /////////////////////////////////
            //iss lsd 专有data信号
            Cdb_SwAddr<=Lsbuf_SwAddr;
            //但是control signal flush，branch虽然只有int会传来有效的data，但是还是要分开讨论
            //the cdb flush has been taken care at the execution unit
            case({Iss_Int,Iss_Lsb,Mul_Done,Div_Done})
                4'b0100:begin//lsb
                    Cdb_Branch<=1'b0;
                    Cdb_Flush<=1'b0;
                    Cdb_PhyRegWrite<=Lsbuf_RdWrite;
                    Cdb_Data<=Lsbuf_Data;
                    Cdb_RobTag_CFC<=Lsbuf_RobTag;
                    Cdb_RobTag_DU<=Lsbuf_RobTag;
                    Cdb_RobTag_ROB<=Lsbuf_RobTag;
                    Cdb_RdPhyAddr<=Lsbuf_PhyAddr;
                end
                4'b0010:begin//mul
                    Cdb_Branch<=1'b0;
                    Cdb_Flush<=1'b0;
                    Cdb_PhyRegWrite<=Mul_RdWrite;
                    Cdb_Data<=Mul_RdData;
                    Cdb_RobTag_CFC<=Mul_RobTag;
                    Cdb_RobTag_DU<=Mul_RobTag;
                    Cdb_RobTag_ROB<=Mul_RobTag;
                    Cdb_RdPhyAddr<=Mul_RdPhyAddr;
                end
                4'b0001:begin//div
                    Cdb_Branch<=1'b0;
                    Cdb_Flush<=1'b0;
                    Cdb_PhyRegWrite<=Div_RdWrite;
                    Cdb_Data<=Div_Rddata; 
                    Cdb_RobTag_CFC<=Div_RobTag;
                    Cdb_RobTag_DU<=Div_RobTag;
                    Cdb_RobTag_ROB<=Div_RobTag;          
                    Cdb_RdPhyAddr<=Div_RdPhyAddr;
                end
                default:begin//default and iss int
                    Cdb_Branch<=Iss_Int&&Alu_Branch;
                    Cdb_Flush<=Iss_Int&&(Alu_JrFlush||Alu_Branch&&Alu_BranchOutcome!=Alu_BranchPredict);
                    //jr!31指令在dispatch unit中自己激活pc跳转信号，因此不用参与这里的flush信号产生
                    Cdb_PhyRegWrite<=Iss_Int&&Alu_RdWrite;
                    ////////////////////////////////////////////
                    //重点�??
                    //以上default下控制信号的更新�??要特别注意，因为包含了invalid input的情况，不想其他case，input�??定是valid
                    //这里的控制信号的产生�??要搭配iss_int，确保输入的data是有效的，避免错误的update bpb,flush以及update ready bit of instruction in instruction  queue
                    Cdb_Data<=Alu_RdData;
                    Cdb_RobTag_CFC<=Alu_RobTag;
                    Cdb_RobTag_DU<=Alu_RobTag;
                    Cdb_RobTag_ROB<=Alu_RobTag;
                    //////////////
                    Cdb_RobTag_Depth2IntQ<=Alu_RobDepth;
                    Cdb_RobTag_Depth2MulQ<=Alu_RobDepth;
                    Cdb_RobTag_Depth2DivQ<=Alu_RobDepth;
                    Cdb_RobTag_Depth2Mul<=Alu_RobDepth;
                    Cdb_RobTag_Depth2Div<=Alu_RobDepth;
                    Cdb_RobTag_Depth2LSQ<=Alu_RobDepth;
                    Cdb_RobTag_Depth2LB<=Alu_RobDepth;
                    Cdb_RobTag_Depth2DC<=Alu_RobDepth;
                    Cdb_RobTag_Depth2CFC<=Alu_RobDepth;
                    ///////////////
                    Cdb_RdPhyAddr<=Alu_RdPhyAddr;
                end
            endcase
        end
    end
    //////////////////////////////////
    //currently we are going to calculate the rob depth in front of the cdb bus, however, the rob depth feeds to other modules after the cdb register.
    //it may cause a bug, since during the next cycle other modules are calculating the rob depth of its own instruction by the updated rob topptr, so to 
    //calculate the robdepth in front of the cdb register we have to consider the update situation of the robtoptr, that why we add the rob_topptr with ROB_commit
    assign Rob_TopPtr_Next=Rob_TopPtr+Rob_Commit;
    assign Alu_RobDepth=Alu_RobTag-Rob_TopPtr_Next[4:0];
endmodule