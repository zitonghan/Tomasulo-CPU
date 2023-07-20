`timescale 1ps/1ps
module dispatch_unit(
    input Clk,//
    input Resetb,//
    //Interface with Intsruction Fetch Queue
    input [31:0] Ifetch_Instruction,// instruction from IFQ
    input [31:0] Ifetch_PcPlusFour,//the PC+4 value carried forward for jumping and branching
    input Ifetch_EmptyFlag,//signal showing that the ifq is empty,hence stopping any decoding and dispatch of the current if_inst
    output reg Dis_Ren,//stalling caused due to issue queue being full
    output reg [31:0] Dis_JmpBrAddr,//the jump or branch address
    output Dis_JmpBr,//validating that address to cause a jump or branch// control
    output Dis_JmpBrAddrValid,//to tell if the jump or branch address is valid or not.. will be invalid for "jr $rs" inst
////////////////////////////////////////////////////////////////////////////////////
//Interface with branch prediction buffer
    output Dis_CdbUpdBranch,//indicates that a branch is processed by the cdb and gives the pred(wen to bpb)
    output [2:0] Dis_CdbUpdBranchAddr,//indiactes the least significant 3 bit PC[4:2] of the branch beign processed by cdb
    output Dis_CdbBranchOutcome,//indiacates the outocome of the branch to the bpb  

    input Bpb_BranchPrediction,//this bit tells the dispatch what is the prediction based on bpb state-mc

    output [2:0] Dis_BpbBranchPCBits,//indiaces the 3 least sig bits of the PC value of the current instr being dis (PC[4:2])
    output Dis_BpbBranch,//indiactes a branch instr (ren to the bpb)
////////////////////////////////////////////////////////////////////////////////////
//interface with the cdb  
    input Cdb_Branch,//
    input Cdb_BranchOutcome,//
    input [31:0] Cdb_BranchAddr,//
    input [2:0] Cdb_BrUpdtAddr,// 
    input Cdb_Flush ,//
    input [4:0] Cdb_RobTag,//虽然JR$!31类型的指令不会进入rob,但是还是会分配一个robtag,用于识别其到达了cdb
////////////////////////////////////////////////////////////////////////////////////
//interface with checkpoint module (CFC)
    output [4:0] Dis_CfcRsAddr,//indicates the Rs Address to be read from Reg file
    output [4:0] Dis_CfcRtAddr,//indicates the Rt Address to be read from Reg file
    output [4:0] Dis_CfcRdAddr,//indicates the Rd Address to be written by instruction
//goes to Dis_CfcRdAddr of ROB too
    input [5:0] Cfc_RsPhyAddr,//Rs Physical register Tag corresponding to Rs Addr
    input [5:0] Cfc_RtPhyAddr,//Rt Physical register Tag corresponding to Rt Addr
    input [5:0] Cfc_RdPhyAddr,//Rd Old Physical register Tag corresponding to Rd Addr
    input Cfc_Full,//indicates that all RATs are used and hence we stall in case of branch or Jr $31
    output [4:0] Dis_CfcBranchTag,//indicats the rob tag of the branch for which checkpoint is to be done
    output Dis_CfcRegWrite,//indicates that the instruction in the dispatch is a register writing instruction and hence should update the active RAT with destination register tag.
    output [5:0] Dis_CfcNewRdPhyAddr,//indicates the new physical register to be assigned to Rd for the instruciton in first stage
    output Dis_CfcBranch,//indicates if branch is there in first stage of dispatch... tells cfc to checkpoint 
    output Dis_CfcInstValid,//
////////////////////////////////////////////////////////////////////////////////////
//physical register interface
    input PhyReg_RsDataRdy,//indicating if the value of Rs is ready at the physical tag location
    input PhyReg_RtDataRdy,//indicating if the value of Rt is ready at the physical tag location	  
////////////////////////////////////////////////////////////////////////////////////
//interface with issue queues 
    output reg Dis_RegWrite,//     
    output Dis_RsDataRdy,//tells the queues that Rs value is ready in PRF and no need to snoop on CDB for that.
    output Dis_RtDataRdy,//tells the queues that Rt value is ready in PRF and no need to snoop on CDB for that.
    output [5:0] Dis_RsPhyAddr,// tells the physical register mapped to Rs (as given by Cfc)
    output [5:0] Dis_RtPhyAddr,//tells the physical register mapped to Rt (as given by Cfc)
    output reg [4:0] Dis_RobTag,//
    output reg [2:0] Dis_Opcode,// gives the Opcode of the given instruction for ALU operation
    
    output reg Dis_IntIssquenable,//informs the respective issue queue that the dispatch is going to enter a new entry
    output reg Dis_LdIssquenable,//informs the respective issue queue that the dispatch is going to enter a new entry
    output reg Dis_DivIssquenable,//informs the respective issue queue that the dispatch is going to enter a new entry
    output reg Dis_MulIssquenable,//informs the respective issue queue that the dispatch is going to enter a new entry
   //重点：above 4个enable 信号表明了dispatch unit stage2的指令类型
    output reg [15:0] Dis_Immediate,//15 bit immediate value for lw/sw address calculation and addi instruction
    input Issque_IntQueueFull,
	input Issque_IntQueueTwoOrMoreVacant,    
    input Issque_LSQueueFull,
	input Issque_LSQueueTwoOrMoreVacant,  
    input Issque_DivQueueFull,
	input Issque_DivQueueTwoOrMoreVacant,  
    input Issque_MulQueueFull,
	input Issque_MulQueueTwoOrMoreVacant,  
    output reg [31:0] Dis_BranchOtherAddr,//如果指令是branch，则地址为misprediction所指向的方向；如果是jal，则是pc+4
    output reg Dis_BranchPredict,//indicates the prediction given by BPB for branch instruction
    output reg Dis_Branch,//
    output reg [2:0] Dis_BranchPCBits,//
    output reg Dis_JrRsInst,//
    output reg Dis_JalInst,// Indicating whether there is a call instruction
    output reg Dis_Jr31Inst,//   
////////////////////////////////////////////////////////////////////////////////////
//interface with the FRL---- accessed in first sage only so dont need NaerlyEmpty signal from Frl
    input [5:0] Frl_RdPhyAddr,// Physical tag for the next available free register
    output Dis_FrlRead,//indicating if free register given by FRL is used or not	  
    input Frl_Empty,// indicates that there are no more free physical registers
////////////////////////////////////////////////////////////////////////////////////
//interface with the RAS
    output Dis_RasJalInst,//indicating whether there is a call instruction
    output Dis_RasJr31Inst,//
    output [31:0] Dis_PcPlusFour,//注意：这里的pc+4是传给ras，而不是jal携带进入instruction queue的
    input [31:0] Ras_Addr,//popped RAS address from RAS
////////////////////////////////////////////////////////////////////////////////////
//interface with the rob
    output [5:0] Dis_PrevPhyAddr,//indicates old physical register mapped to Rd of the instruction
    output reg [5:0] Dis_NewRdPhyAddr,//indicates new physical register to be assigned to Rd (given by FRL)
    output [4:0] Dis_RobRdAddr,//indicates the Rd Address to be written by instruction                                                      -- send to Physical register file too.. so that he can make data ready bit "0"
    output Dis_InstValid,//
    output Dis_InstSw,//
    output [5:0] Dis_SwRtPhyAddr,//indicates physical register mapped to Rt of the Sw instruction
    input [4:0] Rob_BottomPtr,//
    input Rob_Full//already considered the rob commit and rob is full situation
); 
    ////////////////////
    reg [5:0] Rob_tag_Jrnot31;//internal register to store the temporary，MSB是valid bit
    ///////////////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////
    wire [31:0] extended_branch_addr,branch_target_addr;///拓展branch address，=signed extended left shifed 2bits +pc+4
    assign extended_branch_addr=Ifetch_Instruction[15]?{16'hffff,Ifetch_Instruction[15:0]}:{16'h0000,Ifetch_Instruction[15:0]};
    assign branch_target_addr={extended_branch_addr[29:0],2'b00}+Ifetch_PcPlusFour;
    //////////////////////////////////////////////////////////////////////////////////////////////////
    //decode logic
    //instruction type:1: r_type: add,sub,and,or,slt,jr，div,mul
    //addi,
    //beq,bne
    //jal
    //jump
    //sw,lw
    reg inst_add,inst_sub,inst_and,inst_or,inst_slt,inst_jr,inst_div,inst_mul,inst_jal,inst_jmp,inst_addi,inst_beq,inst_bne,inst_lw,inst_sw;
    wire inst_nonbubble;//indicate current instruction is not a bubble
    assign inst_nonbubble=|{inst_add,inst_sub,inst_and,inst_or,inst_slt,inst_jr,inst_div,inst_mul,inst_jal,inst_jmp,inst_addi,inst_beq,inst_bne,inst_lw,inst_sw};
    //decode anyway, ohter control signal will be restricted by read_enable signal
    always@(*)begin
        inst_add=1'b0;
        inst_sub=1'b0;
        inst_and=1'b0;
        inst_or=1'b0;
        inst_slt=1'b0;
        inst_jr=1'b0;
        inst_div=1'b0;
        inst_mul=1'b0;
        inst_jmp=1'b0;
        inst_jal=1'b0;
        inst_addi=1'b0;
        inst_beq=1'b0;
        inst_bne=1'b0;
        inst_lw=1'b0;
        inst_sw=1'b0;
        case(Ifetch_Instruction[31:26])//opcode
            6'b000000:begin//r_type:add,sub,and,or,slt,jr，div,mul
                case(Ifetch_Instruction[5:0])//function bit
                    6'b100000:inst_add=1'b1;//add
                    6'b100010:inst_sub=1'b1;//sub
                    6'b100100:inst_and=1'b1;//and
                    6'b100101:inst_or=1'b1;//or
                    6'b101010:inst_slt=1'b1;//slt
                    6'b001000:inst_jr=1'b1;//jr
                    6'b011011:inst_div=1'b1;//div
                    6'b011001:inst_mul=1'b1;//mul
                endcase
            end
            6'b000010:inst_jmp=1'b1;//jmp
            6'b001000:inst_addi=1'b1;//addi
            6'b000101:inst_bne=1'b1;//bne
            6'b000100:inst_beq=1'b1;//beq
            6'b000011:inst_jal=1'b1;//jal
            6'b100011:inst_lw=1'b1;//lw
            6'b101011:inst_sw=1'b1;//sw
        endcase  
    end
    //control signals
    //not controlled by read enable signal
    wire RegWrite_int, Branch_Jr31_int, Inst2IntQueue, Inst2LSQueue,Inst2DivQueue,Inst2MulQueue;
    assign RegWrite_int=inst_add||inst_sub||inst_and||inst_or||inst_slt||inst_div||inst_mul||inst_addi||inst_jal||inst_lw;
    assign Branch_Jr31_int=inst_bne||inst_beq||inst_jr&&Ifetch_Instruction[25:21]==5'b11111;//used for cfc
    //////////////////////////////////////////
    //issue queue division
    assign Inst2IntQueue=inst_add||inst_sub||inst_and||inst_or||inst_slt||inst_addi||inst_jal||inst_jr||inst_bne||inst_beq;
    assign Inst2LSQueue=inst_lw||inst_sw;
    assign Inst2DivQueue=inst_div;
    assign Inst2MulQueue=inst_mul;
    //interface with IFQ Start**************************************************************************************//
    //1.dis_ren
    //the read enable should be inactivated if ROB is full, cfc is full, issue queue is full, IFQ is empty
    //一个重点:
    //read_enable to IFQ,
    //namely stall logic 7种情况
    always@(*)begin
        Dis_Ren=1'b1;
        if(Cdb_Flush//misprediction flush
           ||Rob_Full&&inst_nonbubble&&!inst_jmp&&!(inst_jr&&(Ifetch_Instruction[25:21]!=5'b11111))//if rob is full and current instruction has to allocate a entry(not jmp or jr$rs) of rob, then stall
           ||Ifetch_EmptyFlag//IFQ empty
           ||Frl_Empty&&RegWrite_int//if current instruction is a register write type and frl is empty
           ||Cfc_Full&&Branch_Jr31_int//cfc full
           ||(Inst2IntQueue&&Dis_IntIssquenable&&!Issque_IntQueueTwoOrMoreVacant||Inst2IntQueue&&!Dis_IntIssquenable&&Issque_IntQueueFull||Inst2LSQueue&&Dis_LdIssquenable&&!Issque_LSQueueTwoOrMoreVacant||Inst2LSQueue&&!Dis_LdIssquenable&&Issque_LSQueueFull||Inst2DivQueue&&Dis_DivIssquenable&&!Issque_DivQueueTwoOrMoreVacant||Inst2DivQueue&&!Dis_DivIssquenable&&Issque_DivQueueFull||Inst2MulQueue&&Dis_MulIssquenable&&!Issque_MulQueueTwoOrMoreVacant||Inst2MulQueue&&!Dis_MulIssquenable&&Issque_MulQueueFull)
           ||inst_jr&&(Ifetch_Instruction[25:21]!=5'b11111)&&(Rob_tag_Jrnot31!=Cdb_RobTag))//jr$!31
        begin
            Dis_Ren=1'b0;
        end
    end
    ///2. dis_jmp IFQ立即更新pc
    //重点：
    //cdb flush 同样通过这个信号传给IFQ
    assign Dis_JmpBr=Cdb_Flush||inst_jal||inst_jmp||(inst_bne||inst_beq)&&Bpb_BranchPrediction||inst_jr&&Ifetch_Instruction[25:21]==5'b11111||inst_jr&&Ifetch_Instruction[25:21]!=5'b11111&&Rob_tag_Jrnot31==Cdb_RobTag;
    ///3. Dis_JmpBrAddrValid
     //CDB FLUSH应该单独激活Dis_JmpBrAddrValid，因为当其到达cdb时，此时dispatch unit有可能在stall，从而dis_ren为0
    assign Dis_JmpBrAddrValid=(Cdb_Flush||Dis_Ren)&&Dis_JmpBr;//controlled by dis_ren signal, so the pc will be updated once the current isntruction can be fetched
    //重点：存在BUG，当CDB_FLUSH时，dis_ren没有变为0，原因是empty flag没有被激活，这是因为addrvalid信号原先使用dis_ren&&dis_jmpbr产生，但是dcb_flush时，dis_ren为0,所以出现dispatch unit提取到错误的指令
    //4. Dis_JmpBrAddr
    always @(*) begin//for generating Dis_JmpBrAddr
        Dis_JmpBrAddr=Cdb_BranchAddr;//default assignment
        if(!Cdb_Flush)begin
            case({inst_jmp||inst_jal,inst_beq||inst_bne,inst_jr})
                3'b100:Dis_JmpBrAddr={Ifetch_PcPlusFour[31:28],Ifetch_Instruction[25:0],2'b00};//jmp,jal
                3'b010:Dis_JmpBrAddr=branch_target_addr;//bne,beq
                3'b001:begin
                    if(Ifetch_Instruction[25:21]==5'b11111)begin//jr31
                        Dis_JmpBrAddr=Ras_Addr;
                    end else begin
                        Dis_JmpBrAddr=Cdb_BranchAddr;
                    end
                end
            endcase
        end
    end
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //interface with IFQ Finish**************************************************************************************//
    /////////////////////////////////
    //interface with RAS Start**************************************************************************************//
    //ras don't need flush when misprediction occurs
    //Dis_Ren means stall logic, the signals can be active only if stall signal is 0
    assign Dis_RasJalInst=inst_jal&&Dis_Ren;//if current cdb flush is active, the RAS will not be updated
    assign Dis_RasJr31Inst=inst_jr&&Ifetch_Instruction[25:21]==5'b11111&&Dis_Ren;
    assign Dis_PcPlusFour=Ifetch_PcPlusFour;
    //interface with RAS Finish**************************************************************************************//
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //interface with BPB Start**************************************************************************************//
    assign Dis_BpbBranch=(inst_bne||inst_beq)&&Dis_Ren;
    assign Dis_BpbBranchPCBits=Ifetch_PcPlusFour[4:2]-1;//use the pc of branch instruction to index bpb
    assign Dis_CdbBranchOutcome=Cdb_BranchOutcome;//forward the branch outcome sent from cdb to bpb
    assign Dis_CdbUpdBranchAddr=Cdb_BrUpdtAddr;
    assign Dis_CdbUpdBranch=Cdb_Branch;
    //interface with BPB Finish**************************************************************************************//
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //interface with FRL Start**************************************************************************************//
    assign Dis_FrlRead=RegWrite_int&&Dis_Ren;
    //interface with FRL Finish**************************************************************************************//
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //interface with CFC Start**************************************************************************************//
    assign Dis_CfcRegWrite=RegWrite_int&&Dis_Ren;//same as frl read
    assign Dis_CfcBranch=Branch_Jr31_int&&Dis_Ren;
    assign Dis_CfcInstValid=Dis_Ren&&inst_nonbubble;//if read enable is 1 and instruction is not a bubble , that means current instruction is valid,it might be bubble, but the decode logic will take care of that
    //inst valid signal并不影响cfc读取
    assign Dis_CfcRsAddr=Ifetch_Instruction[25:21];
    assign Dis_CfcRtAddr=Ifetch_Instruction[20:16];
    //重点：传给CFC的rd address，需要根据不同的指令类型进行调整，lw.addi都是rt作为rd的，jal是$31
    assign Dis_CfcRdAddr=(inst_lw||inst_addi)?Ifetch_Instruction[20:16]:(inst_jal?5'b11111:Ifetch_Instruction[15:11]);
    assign Dis_CfcBranchTag=Rob_BottomPtr;//it will be used only if current dispatching instruction is a valid branch or jr$31
    assign Dis_CfcNewRdPhyAddr=Frl_RdPhyAddr;
    //interface with CFC Finish**************************************************************************************//
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //interface with ROB Start**************************************************************************************//
    //it is a little different, if current instruction is valid in dispatch unit stage1, then one entry will be allocated
    //current rd source will be written into rob in stage 1, but pre tag will be done in stage2
    assign Dis_InstValid=Dis_Ren&&inst_nonbubble&&!inst_jmp&&!(inst_jr&&Ifetch_Instruction[25:21]!=5'b11111);//allocate one entry of rob if read enable is active and instruction is not a bubble, jmp and jr$!31
    assign Dis_InstSw=inst_sw&&Dis_Ren;
    assign Dis_SwRtPhyAddr=Cfc_RtPhyAddr;//it is written into rob in stage2
    assign Dis_RobRdAddr=(inst_lw||inst_addi)?Ifetch_Instruction[20:16]:(inst_jal?5'b11111:Ifetch_Instruction[15:11]);
    //重点：传给cfc和rob的rd addr应该一样
    assign Dis_PrevPhyAddr=Cfc_RdPhyAddr;//it is written into rob in stage2
    //interface with ROB Finish**************************************************************************************//
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //stage register and tone internal register****************************************************************************************************
    //some of stage register are interface signals to issue queue
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            //control signals
            Dis_RegWrite<=1'b0;
            Dis_IntIssquenable<=1'b0;
            Dis_LdIssquenable<=1'b0;
            Dis_DivIssquenable<=1'b0;
            Dis_MulIssquenable<=1'b0;
            Dis_Branch<=1'b0;
            Dis_JrRsInst<=1'b0;
            Dis_JalInst<=1'b0;
            Dis_Jr31Inst<=1'b0;
            //////data signals
            Dis_RobTag<='bx;
            Dis_Opcode<='bx;
            Dis_Immediate<='bx;
            Dis_BranchOtherAddr<='bx;
            Dis_BranchPCBits<='bx;
            Dis_BranchPredict<=1'bx;
            Dis_NewRdPhyAddr<='bx;
            //////////////////////
            //internal registers
            Rob_tag_Jrnot31[5]<=1'b0;
            Rob_tag_Jrnot31[4:0]<='bx;
            //重点:当jr指令到达cdb时，下一个
        end else begin
            if(Cdb_Flush)begin//if flush is 1, the instruction in stage2 should be bubble
                Dis_RegWrite<=1'b0;
                Dis_IntIssquenable<=1'b0;
                Dis_LdIssquenable<=1'b0;
                Dis_DivIssquenable<=1'b0;
                Dis_MulIssquenable<=1'b0;
                Dis_Branch<=1'b0;
                Dis_JrRsInst<=1'b0;
                Dis_JalInst<=1'b0;
                Dis_Jr31Inst<=1'b0;
            end else if(!Dis_Ren)begin//due to structural hazards, the dispatch unit stage 1 is stalled, bubble injected into stage2
                Dis_RegWrite<=1'b0;
                Dis_IntIssquenable<=1'b0;
                Dis_LdIssquenable<=1'b0;
                Dis_DivIssquenable<=1'b0;
                Dis_MulIssquenable<=1'b0;
                //if above four signals are all zeros, means current instruction in stage is a bubble
                Dis_Branch<=1'b0;
                Dis_JrRsInst<=1'b0;
                Dis_JalInst<=1'b0;
                Dis_Jr31Inst<=1'b0;
                if(inst_jr&&(Ifetch_Instruction[25:21]!=5'b11111)&&!Rob_tag_Jrnot31[5]&&(Dis_IntIssquenable&&Issque_IntQueueTwoOrMoreVacant||!Dis_IntIssquenable&&!Issque_IntQueueFull))begin//如果stall是由jr$rs引起的，那么rob tag应该更新
                   Rob_tag_Jrnot31[4:0]<=Rob_BottomPtr; 
                   Rob_tag_Jrnot31[5]<=~Rob_tag_Jrnot31[5];
                   //重点：除了下方的bug外，还存在另一个bug,当dispatch unit产生stall信号，既因为jr!31又因为issue queue没有容量时，那么也不能让jr进入stage2中否则会出错
                   //重点：代码存在bug,因为当read enable =0时，会直接将所有的控制信号变为0，但是忘记了当前指令是jr！31的情况,因此这种情况下还是要确保指令可以正常进入int queue
                   //并且jr应该只在出现的第一个clock结束时，将有效的指令传到stage2，但是之后在jr到达cdb之前，stage2应该时钟是bubble，否则的话，每一个时钟都会有一个jr传入issue queue,显然是错的
                   //因此我们需要一个valid bit，用于定位jr第一次出现的时刻，此时置一，当指令出现在cdb时将valid置零
                   Dis_JrRsInst<=1'b1;
                   Dis_IntIssquenable<=Inst2IntQueue;
                   Dis_RobTag<=Rob_BottomPtr;
                   //rs的physical tag在一下个时钟时由CFC提供，只要指令是有效的那么就写入issue queue
                end
            end else begin//正常情况下
                Dis_RegWrite<=RegWrite_int;
                Dis_IntIssquenable<=Inst2IntQueue;
                Dis_LdIssquenable<=Inst2LSQueue;
                Dis_DivIssquenable<=Inst2DivQueue;
                Dis_MulIssquenable<=Inst2MulQueue;
                Dis_Branch<=inst_beq||inst_bne;
                Dis_JrRsInst<=inst_jr&&Ifetch_Instruction[25:21]!=5'b11111;//jr!$31
                Dis_JalInst<=inst_jal;
                Dis_Jr31Inst<=inst_jr&&Ifetch_Instruction[25:21]==5'b11111;
                Dis_RobTag<=Rob_BottomPtr;
                Dis_Immediate<=Ifetch_Instruction[15:0];
                Dis_BranchPredict<=Bpb_BranchPrediction;
                Dis_BranchOtherAddr<=Ifetch_PcPlusFour;//default assignment
                Dis_NewRdPhyAddr<=Frl_RdPhyAddr;
                //重点：清楚那些指令会使用branchotheraddr信号
                if((inst_beq||inst_bne)&&!Bpb_BranchPrediction)begin//if rbanch is predicted as untaken, other address is target address
                    Dis_BranchOtherAddr<=branch_target_addr;
                end else if(inst_jr&&Ifetch_Instruction[25:21]==5'b11111)begin//jr31,branch addr存放的是RAS提供的prediction，当指令进入alu时，会将该prediction与真实rs中的数值进行比较，如果不同则产生flush
                    Dis_BranchOtherAddr<=Ras_Addr;
                end
                
                Dis_BranchPCBits<=Ifetch_PcPlusFour[4:2]-1;
                ///////////////////////////////////////////////////
                //重点：当jr出现在cdb时，此时read enable变为1，因此不能再上面的if 分支里更新Rob_tag_Jrnot31[5]
                //需要在这里进行，将valid bit置零，从而为以一个jr做准备
                if(inst_jr&&(Ifetch_Instruction[25:21]!=5'b11111)&&Rob_tag_Jrnot31[5]&&Rob_tag_Jrnot31[4:0]==Cdb_RobTag)begin
                    Rob_tag_Jrnot31[5]<=~Rob_tag_Jrnot31[5];
                end
                //opcode generate
                case({inst_addi,inst_add,inst_sub,inst_and,inst_or,inst_slt,inst_jr,inst_jal,inst_bne,inst_beq})
                    10'h200:Dis_Opcode<=3'b100;//addi
                    10'h100:Dis_Opcode<=3'b000;//add
                    10'h080:Dis_Opcode<=3'b001;//sub
                    10'h040:Dis_Opcode<=3'b010;//and
                    10'h020:Dis_Opcode<=3'b011;//or
                    10'h010:Dis_Opcode<=3'b101;//slt
                    10'h008:Dis_Opcode<=3'b000;//jr 因为拥有额外的jal,jr,register write 信号进行区分
                    10'h004:Dis_Opcode<=3'b000;//jal
                    10'h002:Dis_Opcode<=3'b111;//bne
                    10'h001:Dis_Opcode<=3'b110;//beq
                    default:Dis_Opcode<=3'b000;//bubble
                endcase
            end
        end
    end
    //***************************************************************************************************************
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Rest signals's assignment of interface with issue queues Start*******************************************************************************
    assign Dis_RsDataRdy=PhyReg_RsDataRdy;
    assign Dis_RtDataRdy=PhyReg_RtDataRdy;
    assign Dis_RsPhyAddr=Cfc_RsPhyAddr;
    assign Dis_RtPhyAddr=Cfc_RtPhyAddr;
    //interface with issue queues Finish******************************************************************************
endmodule
