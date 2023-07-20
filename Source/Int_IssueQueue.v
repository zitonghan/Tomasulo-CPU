`timescale 1ps/1ps
module Int_IssueQueue(
    //Global Clk and dispat Signals
    input Clk,
    input  Resetb,
	//Information to be captured from the Write port of Physical Register file
    input [5:0] Cdb_RdPhyAddr,
	input Cdb_PhyRegWrite,
    //Information from the Dispatch Unit 
    input Dis_Issquenable,
    input Dis_RsDataRdy,//sent from ready bit array
    input Dis_RtDataRdy,
	input Dis_RegWrite,
    input [5:0] Dis_RsPhyAddr,
    input [5:0] Dis_RtPhyAddr,
    input [5:0] Dis_NewRdPhyAddr,
	input [4:0] Dis_RobTag,
    input [2:0] Dis_Opcode,
	input [15:0] Dis_Immediate,
	input Dis_Branch,
	input Dis_BranchPredict,
	input [31:0] Dis_BranchOtherAddr,
	input [2:0] Dis_BranchPCBits,
	output Issque_IntQueueFull,
	output Issque_IntQueueTwoOrMoreVacant,
	input Dis_Jr31Inst,
	input Dis_JalInst,
	input Dis_JrRsInst,
    //Interface with the Issue Unit
    output IssInt_Rdy,
	input Iss_Int,	
	//Interface with the Physical Register File
    output reg [5:0] Iss_RsPhyAddrAlu,
    output reg [5:0] Iss_RtPhyAddrAlu,
	//Interface with the Execution unit
	output reg [5:0] Iss_RdPhyAddrAlu,
	output reg [4:0] Iss_RobTagAlu,
	output reg [2:0] Iss_OpcodeAlu,
	output reg [31:0] Iss_BranchAddrAlu,	
    output reg Iss_BranchAlu,
	output reg Iss_RegWriteAlu,
	output reg [2:0] Iss_BranchUptAddrAlu,
	output reg Iss_BranchPredictAlu,
	output reg Iss_JalInstAlu,
	output reg Iss_JrInstAlu,
    output reg Iss_JrRsInstAlu,
	output reg [15:0] Iss_ImmediateAlu,
    //Interface with ROB 
    input Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth
);
    ////////////////
    integer i;
    //issue queue主体,都是registers
    reg [5:0] IssuequeRsPhyAddrReg [7:0];//phy tag array
    reg [5:0] IssuequeRtPhyAddrReg [7:0];
    reg [5:0] IssuequeRdPhyAddrReg [7:0];
    
    reg [7:0] IssuequeInstrValReg, IssuequeRtReadyReg, IssuequeRsReadyReg;//ready bits and valid bit
    reg [4:0] IssuequeRobTag [7:0];//rob tag
    reg [2:0] IssuequeOpcodeReg [7:0];//opcode
    reg [2:0] IssuequeBranchPcBits [7:0];//used to update BPB
    reg [7:0] IssuequeJR, IssuequeJRrs, IssuequeJAL, IssuequeBranch, IssuequeRegWrite, IssuequeBranchPredict;
    reg [31:0] IssuequeBranchOtherAddr [7:0];//branch otehr direction address
    reg [15:0] IssuequeImmediate [7:0];//immediate address for addi
    ////////////////////////////
    reg [7:0] Que_Flush, Ready_Issue;//flush flag, it is not a register
    reg [6:0] Shift_En;
    ////////////////////////////////////////
    reg [7:0] Valid_AfterFlush;//the valid signal after Flush, this signal should be combination of flush and int_issue signal
    //the oldest instruction always stay at the last valid location of the queue,并不一定0location,但一定是所有valid的entry中的最后一个
    //因此我们应该先产生每个entry的ready signal，这需要根据具体的指令类型来进行
    wire Upper4_Full,Lower4_Full, Upper4_2More, Lower4_2More;
    assign Upper4_Full=&Valid_AfterFlush[7:4];
    assign Lower4_Full=&Valid_AfterFlush[3:0];
    assign Upper4_2More=!Valid_AfterFlush[7]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[5]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[4]||!Valid_AfterFlush[5]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[5];
    assign Lower4_2More=!Valid_AfterFlush[3]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[1];
    assign Issque_IntQueueTwoOrMoreVacant=!Upper4_Full&&Iss_Int||!Lower4_Full&&Iss_Int||!Upper4_Full&&!Lower4_Full||Lower4_2More||Upper4_2More;
    assign Issque_IntQueueFull=Upper4_Full&&Lower4_Full&&!Iss_Int;
    ////////////////////////////
    //重点：
    //shift logic以及dipatch unit写入新的instrtuction
    //整个issue queue中只有valid bit和ready bit最重要，如果当前一个clock中一条指令发送出去了，我们并不需要将原有的ready bit清空，因为上面的指令下移时，会用自己的数据覆盖掉
    //重点：由于valid bit的更新涉及到issue的问题，而指令能否issue需要看其下方指令有没有产生ready issue，而ready issue又涉及到ready bit
    //因此在写ready issue逻辑时，应该赋予有效的默认值，而不是直接使用多个信号的组合逻辑，这样会产生x
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            IssuequeInstrValReg<='b0;
            IssuequeRtReadyReg<='bx;
            IssuequeRsReadyReg<='bx;
            IssuequeJR<='bx;
            IssuequeJRrs<='bx; 
            IssuequeJAL<='bx; 
            IssuequeBranch<='bx;
            IssuequeRegWrite<='bx;
            IssuequeBranchPredict<='bx;
            for(i=0;i<8;i=i+1)begin
                IssuequeRsPhyAddrReg[i]<='bx;
                IssuequeRtPhyAddrReg[i]<='bx; 
                IssuequeRdPhyAddrReg[i]<='bx;
                IssuequeRobTag[i]<='bx; 
                IssuequeOpcodeReg[i]<='bx;
                IssuequeBranchOtherAddr[i]<='bx; 
                IssuequeImmediate[i]<='bx;
                IssuequeBranchPcBits[i]<='bx;
            end
        end else begin
            //*************************************************************************
            //shift logic
            //***************************************************************************
            //只有valid , ready 信号的更新需要考虑，因为只有这两个内容会发生变化
            //其他数据只要可以移动就向下移即可
            for(i=1;i<8;i=i+1)begin
                if(Shift_En[i-1])begin
                    IssuequeJR[i-1]<=IssuequeJR[i];
                    IssuequeJRrs[i-1]<=IssuequeJRrs[i];
                    IssuequeJAL[i-1]<=IssuequeJAL[i];
                    IssuequeBranch[i-1]<=IssuequeBranch[i];
                    IssuequeRegWrite[i-1]<=IssuequeRegWrite[i];
                    IssuequeBranchPredict[i-1]<=IssuequeBranchPredict[i];
                    IssuequeRsPhyAddrReg[i-1]<=IssuequeRsPhyAddrReg[i];
                    IssuequeRtPhyAddrReg[i-1]<=IssuequeRtPhyAddrReg[i]; 
                    IssuequeRdPhyAddrReg[i-1]<=IssuequeRdPhyAddrReg[i];
                    IssuequeRobTag[i-1]<=IssuequeRobTag[i]; 
                    IssuequeOpcodeReg[i-1]<=IssuequeOpcodeReg[i];
                    IssuequeBranchOtherAddr[i-1]<=IssuequeBranchOtherAddr[i]; 
                    IssuequeImmediate[i-1]<=IssuequeImmediate[i]; 
                    IssuequeBranchPcBits[i-1]<=IssuequeBranchPcBits[i];
                    //重点：
                    //虽然让指令检测各个execution unit的出口可以增加performance，但是增加了布线难度
                    //为了降低布线难度以及节省组合逻辑资源，我们让指令不管是在dispatch unit stage2，还是在issue queue中，都只看cdb
                    //注意我们是将ready bit先写入issue queue在产生ready_issue信号，因此会有一定的性能损失，但是无所谓，节省了组合逻辑
                    if(!Ready_Issue[i]&&IssuequeInstrValReg[i]&&Cdb_PhyRegWrite)begin//指令一定没发送
                        //更新rt ready bit
                        if(Cdb_RdPhyAddr==IssuequeRtPhyAddrReg[i])begin
                            IssuequeRtReadyReg[i-1]<=1'b1;
                        end else begin
                            IssuequeRtReadyReg[i-1]<=IssuequeRtReadyReg[i];
                        end
                        //更新rs ready bit
                        if(Cdb_RdPhyAddr==IssuequeRsPhyAddrReg[i])begin
                            IssuequeRsReadyReg[i-1]<=1'b1;
                        end else begin
                            IssuequeRsReadyReg[i-1]<=IssuequeRsReadyReg[i];
                        end
                    end else begin//即使指令发送了也没关系，并不需要将ready bit置零，因为总是会被其他人覆盖的
                        IssuequeRtReadyReg[i-1]<=IssuequeRtReadyReg[i];
                        IssuequeRsReadyReg[i-1]<=IssuequeRsReadyReg[i];
                    end
                end else begin//如果不能shift， ready bit 也需要进行更新
                    if(!Ready_Issue[i-1]&&IssuequeInstrValReg[i-1]&&Cdb_PhyRegWrite)begin
                        //更新rt ready bit
                        if(Cdb_RdPhyAddr==IssuequeRtPhyAddrReg[i-1])begin
                            IssuequeRtReadyReg[i-1]<=1'b1;
                        end 
                        //更新rs ready bit
                        if(Cdb_RdPhyAddr==IssuequeRsPhyAddrReg[i-1])begin
                            IssuequeRsReadyReg[i-1]<=1'b1;
                        end 
                    end 
                end
            end
            //重点：
            //valid bit的shift需要特别注意，以下几种情况下上一个location1会向location1移入1：
            //1.本身指令没有被flush
            //2.没有flush后，指令本身没有准备好issue
            //3.准备好issue但是前面有其他高优先级的
            //4.准备好issue，前面没有高优先级的指令，但是由于structural hazard，issue unit并没有允许自己向execution unit发送
            //move valid bit carefully
            if(Shift_En[0])begin//如果shift【0】=0,那么意味着location中的指令一定是valid,没有flush,也没有issue，因此保持即可
                IssuequeInstrValReg[0]<=Valid_AfterFlush[1]&&(!Ready_Issue[1]||Ready_Issue[1]&&Ready_Issue[0]||Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end 
            if(Shift_En[1])begin
                IssuequeInstrValReg[1]<=Valid_AfterFlush[2]&&(!Ready_Issue[2]||Ready_Issue[2]&&(Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            if(Shift_En[2])begin
                IssuequeInstrValReg[2]<=Valid_AfterFlush[3]&&(!Ready_Issue[3]||Ready_Issue[3]&&(Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            if(Shift_En[3])begin
                IssuequeInstrValReg[3]<=Valid_AfterFlush[4]&&(!Ready_Issue[4]||Ready_Issue[4]&&(Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            if(Shift_En[4])begin
                IssuequeInstrValReg[4]<=Valid_AfterFlush[5]&&(!Ready_Issue[5]||Ready_Issue[5]&&(Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            if(Shift_En[5])begin
                IssuequeInstrValReg[5]<=Valid_AfterFlush[6]&&(!Ready_Issue[6]||Ready_Issue[6]&&(Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            if(Shift_En[6])begin
                IssuequeInstrValReg[6]<=Valid_AfterFlush[7]&&(!Ready_Issue[7]||Ready_Issue[7]&&(Ready_Issue[6]||Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[7]&&!Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Int);
            end
            /////////////////////////////////////////////////
            //更新entry7,需要注意不管能不能向下移valid以及ready bit都需要进行更新
            //重点：
            //只要enable信号为1，那么指令一定可以写入issue queue，所以不需要额外的判断条件
            //
            if(Dis_Issquenable&&(!Cdb_Flush||Cdb_Flush&&Dis_RobTag-Rob_TopPtr<Cdb_RobDepth))begin//int issue queue write enable
                IssuequeInstrValReg[7]<=1'b1;
                IssuequeJR[7]<=Dis_Jr31Inst;
                IssuequeJRrs[7]<=Dis_JrRsInst;
                IssuequeJAL[7]<=Dis_JalInst;
                IssuequeBranch[7]<=Dis_Branch;
                IssuequeRegWrite[7]<=Dis_RegWrite;
                IssuequeBranchPredict[7]<=Dis_BranchPredict;
                IssuequeRsPhyAddrReg[7]<=Dis_RsPhyAddr;
                IssuequeRtPhyAddrReg[7]<=Dis_RtPhyAddr; 
                IssuequeRdPhyAddrReg[7]<=Dis_NewRdPhyAddr;
                IssuequeRobTag[7]<=Dis_RobTag; 
                IssuequeOpcodeReg[7]<=Dis_Opcode;
                IssuequeBranchOtherAddr[7]<=Dis_BranchOtherAddr; 
                IssuequeImmediate[7]<=Dis_Immediate; 
                IssuequeBranchPcBits[7]<=Dis_BranchPCBits;
                //出于资源和和布线的考虑，我们只看cdb 和ready bit array
                if(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==Dis_RsPhyAddr)||Dis_RsDataRdy)begin
                    IssuequeRsReadyReg[7]<=1'b1;
                end else begin
                    IssuequeRsReadyReg[7]<=1'b0;
                end
                if(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==Dis_RtPhyAddr)||Dis_RtDataRdy)begin
                    IssuequeRtReadyReg[7]<=1'b1;
                end else begin
                    IssuequeRtReadyReg[7]<=1'b0;
                end
            end else if(Shift_En[6])begin//重点：//invalid input or valid but flush, 如果当其没有有效的指令写入【7】，但是7向下移了，那么valid应该写入0，如果不能下移，则保持原样
                IssuequeInstrValReg[7]<=1'b0;
                IssuequeRsReadyReg[7]<=1'b0;
                IssuequeRtReadyReg[7]<=1'b0;
            end else if(IssuequeInstrValReg[7])begin
                //重点：当没有指令写入且entry7不能shift到entry6时，说明0到6都是满的，那么此时enrty7可能有指令也可能没有
                //如果没有指令，那么保持即可，但是如果有，那么同样需要检测ready bit
                //当没有有效的指令写入，issue queue已经满了，entry7不能下移，那么此时entry7也需要检查cdb从而更新ready bit
                IssuequeInstrValReg[7]<=Valid_AfterFlush[7];
                //当entry7中的指令有效时，validbit同样需要更新，由于flush，但是由于shift enable=0说明其下面还有有效的指令
                //因此entry7valid变为0的原因只可能是因为flush引起
                if(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==IssuequeRsPhyAddrReg[7]))begin
                    IssuequeRsReadyReg[7]<=1'b1;
                end 
                if(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==IssuequeRtPhyAddrReg[7]))begin
                    IssuequeRtReadyReg[7]<=1'b1;
                end 
            end
        end
    end
    ///////////////////////////////////////
    //generete flush signals for each entry
    //genereate ready_issue for each entry, used for sending to issue unit a request
    //generate Valid_AfterFlush signals based on flush, used for genetrate full and two more location signals
    //generate Shift_En for shiftling logic
    always @(*) begin
        Que_Flush='b0;
        Valid_AfterFlush='b0;
        Ready_Issue='b0;//default assignment
        if(Cdb_Flush)begin
            for(i=0;i<8;i=i+1)begin
                if(IssuequeRobTag[i]-Rob_TopPtr>Cdb_RobDepth)begin//注意这里是无符号减法，verilog会自动判断
                    Que_Flush[i]=1'b1;
                end
            end
        end
        for(i=0;i<8;i=i+1)begin
            Valid_AfterFlush[i]=IssuequeInstrValReg[i]&&!Que_Flush[i];
            ///////////////////////////////////////////
            //Ready_Issue
            if(Valid_AfterFlush[i])begin//valid instruction
                case({IssuequeJR[i]||IssuequeJRrs[i], IssuequeJAL[i], IssuequeBranch[i], !IssuequeJAL[i]&&IssuequeRegWrite[i]})
                //重点：jal也是register write指令，因此在讨论不同register write时，一定要将jal排除掉
                    4'b1000:Ready_Issue[i]=IssuequeRsReadyReg[i];//jr指令跳转地址存放在rs当中
                    4'b0100:Ready_Issue[i]=1'b1;//jal将pc+4写入$31中，因此不需要其他条件
                    4'b0010:Ready_Issue[i]=IssuequeRtReadyReg[i]&&IssuequeRsReadyReg[i];//beq,bne 需要两个source registers
                    4'b0001:begin
                        if(IssuequeOpcodeReg[i]==3'b100)begin//addi只需要rs和immediate address
                            Ready_Issue[i]=IssuequeRsReadyReg[i];
                        end else begin
                            Ready_Issue[i]=IssuequeRtReadyReg[i]&&IssuequeRsReadyReg[i];//其他算术指令都需要两个source register
                        end
                    end
                endcase
            end
            ///////////////////////////////////////////////
            //一次指向下移动一个location
            //以location1向location0移动为例，需要满足以下几个条件之一：
            //1.shift[0]=1,意味着当前location1中的指令可以下移
            //2.当前指令本身valid=0或者valid=1但是被flush掉了
            //3.或者valid=1并且没有flush掉，但是当前clock决定将其发送出去，因此issue_int=1，ready_issue[1]=1,但是ready_issue[0]=0；
            //Shift_En if it is one, it means another instruction can move into it in the next clock
            Shift_En[0]=!Valid_AfterFlush[0]||Ready_Issue[0]&&Iss_Int;//valid_afterflush 在产生ready_issue时已经使用，这里就不用了
            Shift_En[1]=Shift_En[0]||!Valid_AfterFlush[1]||Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            Shift_En[2]=Shift_En[1]||!Valid_AfterFlush[2]||Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            Shift_En[3]=Shift_En[2]||!Valid_AfterFlush[3]||Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            Shift_En[4]=Shift_En[3]||!Valid_AfterFlush[4]||Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            Shift_En[5]=Shift_En[4]||!Valid_AfterFlush[5]||Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            Shift_En[6]=Shift_En[5]||!Valid_AfterFlush[6]||Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
            //Shift_En[7]=Shift_En[6]||!Valid_AferFlush[7]||Ready_Issue[7]&&!Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Int;
        end
    end
    //////////////////////////////////////////////////
    assign IssInt_Rdy=|Ready_Issue;
    //////////////////////////////////////////////////////////////////////////////////////////////
    //从众多ready的entry中选择其中一个输出在output port上，当iss_int信号为1时，issue queue自然会更新
    always@(*)begin
        casez(Ready_Issue)
            8'bzzzz_zz10:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[1];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[1];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[1];
                Iss_RobTagAlu=IssuequeRobTag[1];
                Iss_OpcodeAlu=IssuequeOpcodeReg[1];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[1];
                Iss_BranchAlu=IssuequeBranch[1];
                Iss_RegWriteAlu=IssuequeRegWrite[1];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[1];
                Iss_BranchPredictAlu=IssuequeBranchPredict[1];
                Iss_JalInstAlu=IssuequeJAL[1];
                Iss_JrInstAlu=IssuequeJR[1];
                Iss_JrRsInstAlu=IssuequeJRrs[1];
                Iss_ImmediateAlu=IssuequeImmediate[1];
            end
            8'bzzzz_z100:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[2];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[2];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[2];
                Iss_RobTagAlu=IssuequeRobTag[2];
                Iss_OpcodeAlu=IssuequeOpcodeReg[2];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[2];
                Iss_BranchAlu=IssuequeBranch[2];
                Iss_RegWriteAlu=IssuequeRegWrite[2];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[2];
                Iss_BranchPredictAlu=IssuequeBranchPredict[2];
                Iss_JalInstAlu=IssuequeJAL[2];
                Iss_JrInstAlu=IssuequeJR[2];
                Iss_JrRsInstAlu=IssuequeJRrs[2];
                Iss_ImmediateAlu=IssuequeImmediate[2];
            end
            8'bzzzz_1000:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[3];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[3];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[3];
                Iss_RobTagAlu=IssuequeRobTag[3];
                Iss_OpcodeAlu=IssuequeOpcodeReg[3];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[3];
                Iss_BranchAlu=IssuequeBranch[3];
                Iss_RegWriteAlu=IssuequeRegWrite[3];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[3];
                Iss_BranchPredictAlu=IssuequeBranchPredict[3];
                Iss_JalInstAlu=IssuequeJAL[3];
                Iss_JrInstAlu=IssuequeJR[3];
                Iss_JrRsInstAlu=IssuequeJRrs[3];
                Iss_ImmediateAlu=IssuequeImmediate[3];
            end
            8'bzzz1_0000:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[4];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[4];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[4];
                Iss_RobTagAlu=IssuequeRobTag[4];
                Iss_OpcodeAlu=IssuequeOpcodeReg[4];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[4];
                Iss_BranchAlu=IssuequeBranch[4];
                Iss_RegWriteAlu=IssuequeRegWrite[4];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[4];
                Iss_BranchPredictAlu=IssuequeBranchPredict[4];
                Iss_JalInstAlu=IssuequeJAL[4];
                Iss_JrInstAlu=IssuequeJR[4];
                Iss_JrRsInstAlu=IssuequeJRrs[4];
                Iss_ImmediateAlu=IssuequeImmediate[4];
            end
            8'bzz10_0000:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[5];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[5];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[5];
                Iss_RobTagAlu=IssuequeRobTag[5];
                Iss_OpcodeAlu=IssuequeOpcodeReg[5];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[5];
                Iss_BranchAlu=IssuequeBranch[5];
                Iss_RegWriteAlu=IssuequeRegWrite[5];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[5];
                Iss_BranchPredictAlu=IssuequeBranchPredict[5];
                Iss_JalInstAlu=IssuequeJAL[5];
                Iss_JrInstAlu=IssuequeJR[5];
                Iss_JrRsInstAlu=IssuequeJRrs[5];
                Iss_ImmediateAlu=IssuequeImmediate[5];
            end
            8'bz100_0000:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[6];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[6];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[6];
                Iss_RobTagAlu=IssuequeRobTag[6];
                Iss_OpcodeAlu=IssuequeOpcodeReg[6];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[6];
                Iss_BranchAlu=IssuequeBranch[6];
                Iss_RegWriteAlu=IssuequeRegWrite[6];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[6];
                Iss_BranchPredictAlu=IssuequeBranchPredict[6];
                Iss_JalInstAlu=IssuequeJAL[6];
                Iss_JrInstAlu=IssuequeJR[6];
                Iss_JrRsInstAlu=IssuequeJRrs[6];
                Iss_ImmediateAlu=IssuequeImmediate[6];
            end
            8'b1000_0000:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[7];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[7];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[7];
                Iss_RobTagAlu=IssuequeRobTag[7];
                Iss_OpcodeAlu=IssuequeOpcodeReg[7];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[7];
                Iss_BranchAlu=IssuequeBranch[7];
                Iss_RegWriteAlu=IssuequeRegWrite[7];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[7];
                Iss_BranchPredictAlu=IssuequeBranchPredict[7];
                Iss_JalInstAlu=IssuequeJAL[7];
                Iss_JrInstAlu=IssuequeJR[7];
                Iss_JrRsInstAlu=IssuequeJRrs[7];
                Iss_ImmediateAlu=IssuequeImmediate[7];
            end
            default:begin
                Iss_RsPhyAddrAlu=IssuequeRsPhyAddrReg[0];
                Iss_RtPhyAddrAlu=IssuequeRtPhyAddrReg[0];
                Iss_RdPhyAddrAlu=IssuequeRdPhyAddrReg[0];
                Iss_RobTagAlu=IssuequeRobTag[0];
                Iss_OpcodeAlu=IssuequeOpcodeReg[0];
                Iss_BranchAddrAlu=IssuequeBranchOtherAddr[0];
                Iss_BranchAlu=IssuequeBranch[0];
                Iss_RegWriteAlu=IssuequeRegWrite[0];
                Iss_BranchUptAddrAlu=IssuequeBranchPcBits[0];
                Iss_BranchPredictAlu=IssuequeBranchPredict[0];
                Iss_JalInstAlu=IssuequeJAL[0];
                Iss_JrInstAlu=IssuequeJR[0];
                Iss_JrRsInstAlu=IssuequeJRrs[0];
                Iss_ImmediateAlu=IssuequeImmediate[0];
            end
        endcase
    end
endmodule