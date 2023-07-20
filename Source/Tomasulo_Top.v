`timescale 1ps/1ps
module Tomasulo_Top(
    input ClkIn,
    input rst_pin,
    input rxd_pin,
    output txd_pin,
    ///////////////////
    input BTNL,
    output LED0,
    output LED1,
    output LED2,
    output LED3,
    output LED4,
    output LED5,
    output LED6
);
    //wire for clocking wizard
    wire Resetb;
    wire ClkOutBuf;
    wire ClkBufG;
    wire Clk, Clk_uart;
    //Interface with Intsruction Fetch Queue
    wire Dis_Ren;//stalling caused due to issue queue being full
    wire [31:0] Dis_JmpBrAddr;//the jump or branch address
    wire Dis_JmpBr;//validating that address to cause a jump or branch// control
    wire Dis_JmpBrAddrValid;//to tell if the jump or branch address is valid or not.. will be invalid for "jr $rs" inst
////////////////////////////////////////////////////////////////////////////////////
//Interface with branch prediction buffer
    wire Dis_CdbUpdBranch;//indicates that a branch is processed by the cdb and gives the pred(wen to bpb)
    wire [2:0] Dis_CdbUpdBranchAddr;//indiactes the least significant 3 bit PC[4:2] of the branch beign processed by cdb
    wire Dis_CdbBranchOutcome;//indiacates the outocome of the branch to the bpb  
    wire [2:0] Dis_BpbBranchPCBits;//indiaces the 3 least sig bits of the PC value of the current instr being dis (PC[4:2])
    wire Dis_BpbBranch;//indiactes a branch instr (ren to the bpb)
////////////////////////////////////////////////////////////////////////////////////
//interface with the cdb  
    wire Cdb_Branch;//
    wire Cdb_BranchOutcome;//
    wire [31:0] Cdb_BranchAddr;//
    wire [2:0] Cdb_BrUpdtAddr;// 
    wire Cdb_Flush ;//
    wire [4:0] Cdb_RobTag_CFC;//虽然JR$!31类型的指令不会进入rob;但是还是会分配一个robtag;用于识别其到达了cdb
    wire [4:0] Cdb_RobTag_DU;
    wire [4:0] Cdb_RobTag_ROB;
////////////////////////////////////////////////////////////////////////////////////
//interface with checkpoint module (CFC)
    wire [4:0] Dis_CfcRsAddr;//indicates the Rs Address to be read from Reg file
    wire [4:0] Dis_CfcRtAddr;//indicates the Rt Address to be read from Reg file
    wire [4:0] Dis_CfcRdAddr;//indicates the Rd Address to be written by instruction
//goes to Dis_CfcRdAddr of ROB too
    wire [4:0] Dis_CfcBranchTag;//indicats the rob tag of the branch for which checkpoint is to be done
    wire Dis_CfcRegWrite;//indicates that the instruction in the dispatch is a register writing instruction and hence should update the active RAT with destination register tag.
    wire [5:0] Dis_CfcNewRdPhyAddr;//indicates the new physical register to be assigned to Rd for the instruciton in first stage
    wire Dis_CfcBranch;//indicates if branch is there in first stage of dispatch... tells cfc to checkpoint 
    wire Dis_CfcInstValid;//
////////////////////////////////////////////////////////////////////////////////////
//physical register interface
    wire PhyReg_RsDataRdy;//indicating if the value of Rs is ready at the physical tag location
    wire PhyReg_RtDataRdy;//indicating if the value of Rt is ready at the physical tag location	  
////////////////////////////////////////////////////////////////////////////////////
//interface with issue queues 
    wire Dis_RegWrite;//     
    wire Dis_RsDataRdy;//tells the queues that Rs value is ready in PRF and no need to snoop on CDB for that.
    wire Dis_RtDataRdy;//tells the queues that Rt value is ready in PRF and no need to snoop on CDB for that.
    wire [5:0] Dis_RsPhyAddr;// tells the physical register mapped to Rs (as given by Cfc)
    wire [5:0] Dis_RtPhyAddr;//tells the physical register mapped to Rt (as given by Cfc)
    wire [4:0] Dis_RobTag;//
    wire [2:0] Dis_Opcode;// gives the Opcode of the given instruction for ALU operation
    wire Dis_IntIssquenable;//informs the respective issue queue that the dispatch is going to enter a new entry
    wire Dis_LdIssquenable;//informs the respective issue queue that the dispatch is going to enter a new entry
    wire Dis_DivIssquenable;//informs the respective issue queue that the dispatch is going to enter a new entry
    wire Dis_MulIssquenable;//informs the respective issue queue that the dispatch is going to enter a new entry
   //重点：above 4个enable 信号表明了dispatch unit stage2的指令类�??
    wire [15:0] Dis_Immediate;//15 bit immediate value for lw/sw address calculation and addi instruction 
    wire [31:0] Dis_BranchOtherAddr;//如果指令是branch，则地址为misprediction�??指向的方向；如果是jal，则是pc+4
    wire Dis_BranchPredict;//indicates the prediction given by BPB for branch instruction
    wire Dis_Branch;//
    wire [2:0] Dis_BranchPCBits;//
    wire Dis_JrRsInst;//
    wire Dis_JalInst;// Indicating whether there is a call instruction
    wire Dis_Jr31Inst;//   
////////////////////////////////////////////////////////////////////////////////////
//interface with the FRL---- accessed in first sage only so dont need NaerlyEmpty signal from Frl
    wire [5:0] Frl_RdPhyAddr;// Physical tag for the next available free register
    wire Dis_FrlRead;//indicating if free register given by FRL is used or not	  
////////////////////////////////////////////////////////////////////////////////////
//interface with the RAS
    wire Dis_RasJalInst;//indicating whether there is a call instruction
    wire Dis_RasJr31Inst;//
    wire [31:0] Dis_PcPlusFour;//注意：这里的pc+4是传给ras，�?�不是jal携带进入instruction queue�??
////////////////////////////////////////////////////////////////////////////////////
//interface with the rob
    wire [5:0] Dis_PrevPhyAddr;//indicates old physical register mapped to Rd of the instruction
    wire [5:0] Dis_NewRdPhyAddr;//indicates new physical register to be assigned to Rd (given by FRL)
    wire [4:0] Dis_RobRdAddr;//indicates the Rd Address to be written by instruction                                                      -- send to Physical register file too.. so that he can make data ready bit "0"
    wire Dis_InstValid;//
    wire Dis_InstSw;//
    wire [5:0] Dis_SwRtPhyAddr;//indicates physical register mapped to Rt of the Sw instruction
    wire Rob_Full;
    //interface with IFQ and Instruction Cache
    ///////////////////////////////////////////////////////
    wire [31:0] Ifetch_Instruction;
    wire Ifetch_EmptyFlag;
    wire [31:0] Ifetch_PcPlusFour;
    //output to cache unit
    wire [31:0] Ifetch_WpPcIn;
    wire Ifetch_ReadCache;
    wire IFQ_Flush;
    //input from cache unit
    wire [31:0] Cache_Cd0;
    wire [31:0] Cache_Cd1;
    wire [31:0] Cache_Cd2;
    wire [31:0] Cache_Cd3;
    wire Cache_ReadHit;
    ///////////////////////////////////////////////////////
    //interface with FRL
	wire [4:0] Cfc_FrlHeadPtr;//16 locations, n+1 pointer
	//Interface with Dis_FrlRead unit    	 			
	wire Frl_Empty;      			
	//Interface with Previous Head Pointer Stack
	wire [4:0] Frl_HeadPtr;
    ////////////////////////////////////////////////////////
    //interface with ROB
    wire [31:0] Cdb_SwAddr;
    wire SB_Full;//Tells the ROB that the store buffer is full
    wire  [31:0] Rob_SwAddr;// The address in case of sw instruction
    wire  Rob_CommitMemWrite;
    ////////////////
    wire [5:0] Rob_TopPtr_IntQ;
    wire [5:0] Rob_TopPtr_MulQ;
    wire [5:0] Rob_TopPtr_DivQ;
    wire [5:0] Rob_TopPtr_LSQ;
    wire [5:0] Rob_TopPtr_LSB;
    wire [5:0] Rob_TopPtr_Mul;
    wire [5:0] Rob_TopPtr_Div;
    wire [5:0] Rob_TopPtr_CFC;
    wire [5:0] Rob_TopPtr_DC;
    wire [5:0] Rob_TopPtr_CDB;
    wire [4:0] Rob_BottomPtr;//Gives the Bottom Pointer of ROB
    wire Rob_Commit;//FRL needs it to to add previously-mapped physical register to free list cfc needs it to remove the latest checkpointed copy
    wire [4:0] Rob_CommitRdAddr;//Architectural register number of committing instruction
    wire Rob_CommitRegWrite;//Indicates that the instruction that is being committed is a register writing instruction
    wire [5:0]  Rob_CommitPrePhyAddr;// pre physical addr of committing inst to be added to FRL
    //////////////////////////////////////////////////////////
    //interface with CFC
	wire [5:0] Cfc_RdPhyAddr;//Previous Physical Register Address of Rd
	wire [5:0] Cfc_RsPhyAddr;//Latest Physical Register Address of Rs
	wire [5:0] Cfc_RtPhyAddr;//Latest Physical Register Address of Rt
	wire Cfc_Full;//Flag indicating whether checkpoint table is full or not			
	wire [4:0] Cfc_RobTag;//Rob Tag of the instruction to which rob_bottom is moved after branch misprediction (also to php)
	//interface with CDB
    wire [4:0] Cdb_RobTag_Depth2IntQ;
    wire [4:0] Cdb_RobTag_Depth2MulQ;
    wire [4:0] Cdb_RobTag_Depth2DivQ;
    wire [4:0] Cdb_RobTag_Depth2Mul;
    wire [4:0] Cdb_RobTag_Depth2Div;
    wire [4:0] Cdb_RobTag_Depth2LSQ;
    wire [4:0] Cdb_RobTag_Depth2LB;
    wire [4:0] Cdb_RobTag_Depth2DC;
    wire [4:0] Cdb_RobTag_Depth2CFC;
    /////////////////////////////////////////////////////
    //interface with BPB
    wire Bpb_BranchPrediction;
    //////////////////////////////////////////////////////////
    //interface with RAS			
    wire [31:0] Ras_Addr;
    /////////////////////////////////////////////////////////
    //interface with Int_Iss_Queue
    wire [5:0] Cdb_RdPhyAddr;
	wire Cdb_PhyRegWrite;
	wire Issque_IntQueueFull;
	wire Issque_IntQueueTwoOrMoreVacant;
    //Interface with the Issue Unit
    wire IssInt_Rdy;
	wire Iss_Int;	
	//Interface with the Physical Register File
    wire [5:0] Iss_RsPhyAddrAlu;
    wire [5:0] Iss_RtPhyAddrAlu;
	//Interface with the Execution unit
	wire [5:0] Iss_RdPhyAddrAlu;
	wire [4:0] Iss_RobTagAlu;
	wire [2:0] Iss_OpcodeAlu;
	wire [31:0] Iss_BranchAddrAlu;	
    wire Iss_BranchAlu;
	wire Iss_RegWriteAlu;
	wire [2:0] Iss_BranchUptAddrAlu;
	wire Iss_BranchPredictAlu;
	wire Iss_JalInstAlu;
	wire Iss_JrInstAlu;
    wire Iss_JrRsInstAlu;
	wire [15:0] Iss_ImmediateAlu;
    ////////////////////////////////////////////////////////
    //interface with LSQ
    wire [5:0] Dis_RdRtPhyAddr;
    wire Issque_LdStQueueFull;
    wire Issque_LdStQueueTwoOrMoreVacant;
    // interface with PRF
    wire [5:0] Iss_RsPhyAddrLsq;
    wire [31:0] PhyReg_LsqRsData;
    // Interface with the Issue Unit
    wire Iss_LdStReady;
    wire Iss_LdStOpcode;
    wire [4:0] Iss_LdStRobTag;
    wire [31:0] Iss_LdStAddr;
    //reg Iss_LdStIssued;
    wire [5:0] Iss_LdStPhyAddr;//rt;rd phy registere
    //Interface with ROB
    wire SB_FlushSw;
    //interface with SAB
    wire [1:0] SB_FlushSwTag;
    wire [1:0] SBTag_counter;        
    //inputterface with lsq
    wire Lsbuf_Full;
    wire Lsbuf_TwoOrMoreVaccant;
    wire Lsbuf_Ready;//sent to issue unit
    wire [31:0] Lsbuf_Data;
    wire [5:0] Lsbuf_PhyAddr;
    wire [4:0] Lsbuf_RobTag;
    wire [31:0] Lsbuf_SwAddr;
    wire Lsbuf_RdWrite;
    //signals sent from issue unit
    wire Iss_Lsb;
    //lw from lsq
    wire [31:0] SB_AddrDmem;
    wire [31:0] SB_DataDmem;
    wire SB_DataValid;
    wire DCE_Opcode;//to ls buffer; for read operation only
    wire  [4:0] DCE_RobTag; 
    wire  [31:0] DCE_Addr;   
    wire  [31:0] DCE_MemData ;
    wire  [5:0] DCE_PhyAddr;//rd physical ister number for lw
    wire  DCE_ReadDone;
    wire  DCE_ReadBusy;
    //read busy signal is generated by ls buffer
    wire  DCE_WriteBusy;
    wire  DCE_WriteDone;
    ///////////////////////////////////////////////////////////////////////////
    //interface with mul queue
    wire IssMul_Rdy;
	wire Iss_Mult;	
	wire [5:0] Iss_RsPhyAddrMul;
    wire [5:0] Iss_RtPhyAddrMul;
    wire [5:0] Iss_RdPhyAddrMul;
    wire [4:0] Iss_RobTagMul;
    wire Iss_RegWriteMul;
    wire Issque_MulQueueFull;
    wire Issque_MulQueueTwoOrMoreVacant;
    ////
	wire [31:0] PhyReg_MultRsData;//from issue queue mult
	wire [31:0] PhyReg_MultRtData;//from issue queue mult
    ////////////////////////////////////////////////////////////////////	
    wire [5:0] Mul_RdPhyAddr ;// -- wire to CDB required
	wire Mul_RdWrite;
    ////////////////////////////////////////////////////////////////////
	wire [31:0] Mul_RdData;// wire to CDB unit (to CDB Mux)
	wire [4:0] Mul_RobTag	;// wire to CDB unit (to CDB Mux)
	wire Mul_Done;// wire to CDB unit ( to control Mux selection)
    //////////////////////////////////////////////////////////////////////////////
    //interface with Div QUEUE  
    wire IssDiv_Rdy;
	wire Iss_Div;	
	wire [5:0] Iss_RsPhyAddrDiv;
    wire [5:0] Iss_RtPhyAddrDiv;
    wire [5:0] Iss_RdPhyAddrDiv;
    wire [4:0] Iss_RobTagDiv;
    wire Iss_RegWriteDiv;
    wire Issque_DivQueueFull;
    wire Issque_DivQueueTwoOrMoreVacant;  
    //
    wire [31:0] PhyReg_DivRsData;
    wire [31:0] PhyReg_DivRtData;
    wire [5:0] Div_RdPhyAddr;
    wire Div_RdWrite;
    wire Div_Done;
    wire [4:0] Div_RobTag;
    wire [31:0] Div_Rddata;
    wire Div_ExeRdy;
    //////////////////////////////////////////////////////////////////////////////
    //interface with ALU
    wire [31:0] PhyReg_AluRsData;
	wire [31:0] PhyReg_AluRtData;
	wire [31:0] Alu_RdData; //
    wire [5:0] Alu_RdPhyAddr;//
    wire [31:0] Alu_BranchAddr;	//bne;beq;jr$31;jr!31;
    wire Alu_Branch;//
	wire Alu_BranchOutcome;//
	wire [4:0]Alu_RobTag;//
	wire [2:0] Alu_BranchUptAddr; //
    wire Alu_BranchPredict;//
	wire Alu_RdWrite;//
	wire Alu_JrFlush;
    /////////////////////////////////////////////////////////////////////////////////
    //interface with PRF
    wire [5:0] Rob_CommitCurrPhyAddr;
    wire [31:0] PhyReg_StoreData; 
    wire [31:0] Cdb_RdData;
    wire Cdb_Valid;
//////////////////////////////////////////////////////////////////////////////////////////
    wire rst_50toBuf, rst_100toBuf;
    reg [5:0] Test_Success;
    wire reset_low, rst2uart;
    assign reset_low=!rst_50toBuf;//reset for cpu
    ///////////////////////////////////////////
    //signals for uart
    wire rxd_i,txd_o;
    wire LED0_toBuf,LED1_toBuf,LED2_toBuf,LED3_toBuf,LED4_toBuf;
    reg LED5_toBuf, LED6_toBuf;
///////////////////////////////////////////////////////////////////////////////////////////
    //signals for cache initialization
    reg Cache_Init, Send_DataBack;//state signals for cache initialization and sending data back to pC
    reg CPU_Run;//signals used to indicate the CPU can start to run, it will be used to control the generation of the instCache_read signals in IFQ
    reg [11:0] Cnt_2000;
    reg [2:0] Cnt_4;
    wire btnl_scen;
    wire Uart_DataCache_WE, Uart_InstCache_WE;
    wire [5:0] Uart_Cache_InitAddr;//data cache and inst cache can share the same write address for initialization
    wire [6:0] Uart_DataCache_RdAddr, Uart_InstCache_RdAddr;
    wire [127:0] Uart_Cache_InitData;
    wire [31:0] DataCache_BackData;
    wire [127:0] InstCache_BackData;
///////////////////////////////////////////////////////////////////////////////////////////
    assign Dis_RdRtPhyAddr=Dis_RegWrite?Dis_NewRdPhyAddr:Dis_RtPhyAddr;
    //重点�??
    //当前设计的理念是，sw�??要在rs和rt都计算好的情况下才能离开lsq，因此我们需要rt phy来准备ready bit，但实际上是不需要的
    //当前设计中sw在进入ls buffer是并没有取得rt data，那么等待rt data ready再离�??sw buffer显然是不�??要的
    //sw 完全可以在rob等顶部时从phy中读取ready bit，如果ready 则写�?? SB�?? 这样效率更高�??
    //这一点留�??debug结束后在实施
    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //input buffer
    IBUF IBUF_CLK       (.I(ClkIn),      .O(ClkOutBuf));
    BUFG BUFG_CLK_uart  (.I(ClkOutBuf),      .O(Clk_uart));//100MHz
    BUFG BUFG_CLK       (.I(ClkBufG),      .O(Clk));
    BUFG BUFG_rst50     (.I(reset_low),      .O(Resetb));
    BUFG BUFG_rst2uart  (.I(rst_100toBuf),      .O(rst2uart));
    ///////////////////////////////////////////////////////////////
    //to make sure the setting of false path will not affect the timing analysis of real design
    OBUF OBUF_led0      (.I(LED0_toBuf),      .O(LED0));
    OBUF OBUF_led1      (.I(LED1_toBuf),      .O(LED1));
    OBUF OBUF_led2      (.I(LED2_toBuf),      .O(LED2));
    OBUF OBUF_led3      (.I(LED3_toBuf),      .O(LED3));
    OBUF OBUF_led4      (.I(LED4_toBuf),      .O(LED4));
    OBUF OBUF_led5      (.I(LED5_toBuf),      .O(LED5));
    OBUF OBUF_led6      (.I(LED6_toBuf),      .O(LED6));
    IBUF IBUF_rxd_i0      (.I (rxd_pin),      .O(rxd_i));
    OBUF OBUF_txd         (.I(txd_o),         .O(txd_pin));
   /////////////////////////////////////////////
   //generate reset signal for system
    /////////////////////////////////////////////
    clk_wiz_0 clk_wiz_inst1
   (
    // Clock out ports
    .clk_out1(ClkBufG),     // output clk_out1 50MHZ
    // Status and control signals    
   // Clock in ports
    .clk_in1(ClkOutBuf));      // input clk_in1
    //////////////////////////////////////////////////////
    //convert asynchronous reset signal to synchronous, so that we can use the external reset pin to reset circuit for the next test case.
    rst_gen rst_50( 
        //reset signal for CPU
        .clk_i(Clk),          // Receive clock
        .rst_i(rst_pin),           
        .rst_o(rst_50toBuf)     //synchronizaed active high  
    );
    rst_gen rst_100(
        //reset signal for uart
        .clk_i(Clk_uart),          
        .rst_i(rst_pin),           
        .rst_o(rst_100toBuf)    //synchronizaed active high  
    );
////////////////////
    Inst_Cache IC(
        Clk,
        Clk_uart,
        Resetb,
        Ifetch_WpPcIn,
        Ifetch_ReadCache,//始终�??1
        IFQ_Flush,
        Cache_Cd0,
        Cache_Cd1,
        Cache_Cd2,
        Cache_Cd3,
        Cache_ReadHit,
        Cache_Init,
        Send_DataBack,
        Uart_InstCache_WE,
        Uart_Cache_InitAddr,
        Uart_InstCache_RdAddr[5:0],
        Uart_Cache_InitData,
        InstCache_BackData
    );

    inst_fetch_q IFQ (
        Clk,
        Resetb, 
        Ifetch_Instruction,
        Ifetch_EmptyFlag,
        Ifetch_PcPlusFour,
        Dis_Ren,
        Dis_JmpBrAddr,
        Dis_JmpBr,
        Dis_JmpBrAddrValid,
        Ifetch_WpPcIn,
        Ifetch_ReadCache,
        IFQ_Flush,
        Cache_Cd0,
        Cache_Cd1,
        Cache_Cd2,
        Cache_Cd3,
        Cache_ReadHit,
        CPU_Run
    );

    dispatch_unit DU(
        Clk,
        Resetb,
        Ifetch_Instruction,
        Ifetch_PcPlusFour,
        Ifetch_EmptyFlag, 
        Dis_Ren,
        Dis_JmpBrAddr,
        Dis_JmpBr,
        Dis_JmpBrAddrValid,
        ////////////////////////////////////////////////////////////////////////////////////
        Dis_CdbUpdBranch,
        Dis_CdbUpdBranchAddr,
        Dis_CdbBranchOutcome,
        Bpb_BranchPrediction,
        Dis_BpbBranchPCBits,
        Dis_BpbBranch,
        ////////////////////////////////////////////////////////////////////////////////////
        Cdb_Branch,
        Cdb_BranchOutcome,
        Cdb_BranchAddr,
        Cdb_BrUpdtAddr,
        Cdb_Flush ,
        Cdb_RobTag_DU,
        ////////////////////////////////////////////////////////////////////////////////////
        Dis_CfcRsAddr,
        Dis_CfcRtAddr,
        Dis_CfcRdAddr,
        Cfc_RsPhyAddr,
        Cfc_RtPhyAddr,
        Cfc_RdPhyAddr,
        Cfc_Full,
        Dis_CfcBranchTag,
        Dis_CfcRegWrite,
        Dis_CfcNewRdPhyAddr,
        Dis_CfcBranch,
        Dis_CfcInstValid,
        ////////////////////////////////////////////////////////////////////////////////////
        PhyReg_RsDataRdy,
        PhyReg_RtDataRdy,  
        ////////////////////////////////////////////////////////////////////////////////////
        Dis_RegWrite,   
        Dis_RsDataRdy,
        Dis_RtDataRdy,
        Dis_RsPhyAddr,
        Dis_RtPhyAddr,
        Dis_RobTag,
        Dis_Opcode,
        Dis_IntIssquenable,
        Dis_LdIssquenable,
        Dis_DivIssquenable,
        Dis_MulIssquenable,
        Dis_Immediate,
        Issque_IntQueueFull,
        Issque_IntQueueTwoOrMoreVacant,    
        Issque_LdStQueueFull,
        Issque_LdStQueueTwoOrMoreVacant,  
        Issque_DivQueueFull,
        Issque_DivQueueTwoOrMoreVacant,  
        Issque_MulQueueFull,
        Issque_MulQueueTwoOrMoreVacant,  
        Dis_BranchOtherAddr,
        Dis_BranchPredict,
        Dis_Branch,
        Dis_BranchPCBits,
        Dis_JrRsInst,
        Dis_JalInst,
        Dis_Jr31Inst,  
        ////////////////////////////////////////////////////////////////////////////////////
        Frl_RdPhyAddr,
        Dis_FrlRead,	  
        Frl_Empty,
        ////////////////////////////////////////////////////////////////////////////////////
        Dis_RasJalInst,
        Dis_RasJr31Inst,
        Dis_PcPlusFour,
        Ras_Addr,
        ////////////////////////////////////////////////////////////////////////////////////
        Dis_PrevPhyAddr,
        Dis_NewRdPhyAddr,
        Dis_RobRdAddr,                                                 
        Dis_InstValid,
        Dis_InstSw,
        Dis_SwRtPhyAddr,
        Rob_BottomPtr,
        Rob_Full
    );

    FRL frl(
        Clk,          	  		
        Resetb,       		 
        Cdb_Flush,    			
        Rob_CommitPrePhyAddr, 	
        Rob_Commit,   			
        Rob_CommitRegWrite, 	
        Cfc_FrlHeadPtr,
        Frl_RdPhyAddr,        	
        Dis_FrlRead,    			
        Frl_Empty,      			
        Frl_HeadPtr     
    );

    ROB rob(
        Clk,
        Resetb,		  
        Cdb_Valid,                     
        Cdb_RobTag_ROB,
        Cdb_SwAddr,
        Dis_InstSw,
        Dis_CfcRegWrite,//重点：rob中该信号叫dis_regwrite,但是我们改为在stage1中写入register write bit，因此应该使用dis_cfcregwrite信号，dis_regwrite为stage2中的信号
        Dis_InstValid,
        Dis_RobRdAddr,
        Dis_CfcNewRdPhyAddr,//重点：rob写入new tag是在stage1，�?�dis_new是stage2中的信号
        Dis_PrevPhyAddr,
        Dis_SwRtPhyAddr,
        Rob_Full,             
        SB_Full,
        Rob_SwAddr,
        Rob_CommitMemWrite,			  
        Rob_TopPtr_IntQ,
        Rob_TopPtr_MulQ,
        Rob_TopPtr_DivQ,
        Rob_TopPtr_LSQ,
        Rob_TopPtr_LSB,
        Rob_TopPtr_Mul,
        Rob_TopPtr_Div,
        Rob_TopPtr_CFC,
        Rob_TopPtr_DC,
        Rob_TopPtr_CDB,
        Rob_BottomPtr,
        Rob_Commit,
        Rob_CommitRdAddr,
        Rob_CommitRegWrite,
        Rob_CommitPrePhyAddr,
        Rob_CommitCurrPhyAddr,		  
        Cdb_Flush,
        Cfc_RobTag
    );

    CFC cfc(
        Clk,
        Resetb,
        Dis_InstValid,
        Dis_CfcBranchTag,
        Dis_CfcRdAddr,
        Dis_CfcRsAddr,
        Dis_CfcRtAddr,
        Dis_CfcNewRdPhyAddr,
        Dis_CfcRegWrite,
        Dis_CfcBranch,
        Dis_Jr31Inst,
        Cfc_RdPhyAddr,
        Cfc_RsPhyAddr,
        Cfc_RtPhyAddr,
        Cfc_Full,           
        Rob_TopPtr_CFC[4:0],
        Rob_Commit ,
        Rob_CommitRdAddr,
        Rob_CommitRegWrite,
        Rob_CommitCurrPhyAddr,		
        Cfc_RobTag,
        Frl_HeadPtr,
        Cfc_FrlHeadPtr,
        Cdb_Flush ,
        Cdb_RobTag_CFC,
        Cdb_RobTag_Depth2CFC
    );

    RAS ras(
        Resetb,					
        Clk,						
        Dis_PcPlusFour,
        Dis_RasJalInst,
        Dis_RasJr31Inst,
        Ras_Addr
    );

    branch_predict_buffer BPB(
        Clk,
        Resetb,
        Dis_CdbUpdBranch,
        Dis_CdbUpdBranchAddr,
        Dis_CdbBranchOutcome,
        Dis_BpbBranchPCBits,
        Dis_BpbBranch,
        Bpb_BranchPrediction
    );

    Int_IssueQueue Int_IssQue(
        Clk,
        Resetb,
        Cdb_RdPhyAddr,
        Cdb_PhyRegWrite,
        Dis_IntIssquenable,
        Dis_RsDataRdy,
        Dis_RtDataRdy,
        Dis_RegWrite,
        Dis_RsPhyAddr,
        Dis_RtPhyAddr,
        Dis_NewRdPhyAddr,
        Dis_RobTag,
        Dis_Opcode,
        Dis_Immediate,
        Dis_Branch,
        Dis_BranchPredict,
        Dis_BranchOtherAddr,
        Dis_BranchPCBits,
        Issque_IntQueueFull,
        Issque_IntQueueTwoOrMoreVacant,
        Dis_Jr31Inst,
        Dis_JalInst,
        Dis_JrRsInst,
        IssInt_Rdy,
        Iss_Int,
        Iss_RsPhyAddrAlu,
        Iss_RtPhyAddrAlu,
        Iss_RdPhyAddrAlu,
        Iss_RobTagAlu,
        Iss_OpcodeAlu,
        Iss_BranchAddrAlu,
        Iss_BranchAlu,
        Iss_RegWriteAlu,
        Iss_BranchUptAddrAlu,
        Iss_BranchPredictAlu,
        Iss_JalInstAlu,
        Iss_JrInstAlu,
        Iss_JrRsInstAlu,
        Iss_ImmediateAlu,
        Cdb_Flush,
        Rob_TopPtr_IntQ[4:0],
        Cdb_RobTag_Depth2IntQ
    );

    LS_Queue LSQ(
        Clk,
        Resetb,
        Cdb_RdPhyAddr,
        Cdb_PhyRegWrite,
        Dis_RegWrite,//1表示lw,0表示lw
        Dis_Immediate,
        Dis_RsDataRdy,
        Dis_RtDataRdy,
        Dis_RsPhyAddr,
        Dis_RobTag,
        Dis_RdRtPhyAddr,
        Dis_LdIssquenable,
        Issque_LdStQueueFull,
        Issque_LdStQueueTwoOrMoreVacant,
        Iss_RsPhyAddrLsq,
        PhyReg_LsqRsData,
        Iss_LdStReady,
        Iss_LdStOpcode,
        Iss_LdStRobTag,
        Iss_LdStAddr,
        Iss_LdStPhyAddr,
        DCE_ReadBusy,
        DCE_ReadDone,
        Lsbuf_Full,
        Lsbuf_TwoOrMoreVaccant,
        Cdb_Flush,
        Rob_TopPtr_LSQ[4:0],
        Cdb_RobTag_Depth2LSQ,
        SB_FlushSw,
        SB_FlushSwTag,
        SBTag_counter,        
        Rob_CommitMemWrite
    );
    LS_Buffer LSB(
        Clk,
        Resetb,
        Cdb_Flush,
        Rob_TopPtr_LSB[4:0],
        Cdb_RobTag_Depth2LB,
        Iss_LdStReady,
        Iss_LdStOpcode,
        Iss_LdStRobTag,
        Iss_LdStAddr,
        Iss_LdStPhyAddr,
        DCE_PhyAddr,
        DCE_Opcode,
        DCE_RobTag,
        DCE_Addr,
        DCE_MemData,
        DCE_ReadDone,
        DCE_ReadBusy,
        Lsbuf_Full,
        Lsbuf_TwoOrMoreVaccant,
        Lsbuf_Ready,
        Lsbuf_Data,
        Lsbuf_PhyAddr,
        Lsbuf_RobTag,
        Lsbuf_SwAddr,
        Lsbuf_RdWrite,
        Iss_Lsb
    );
    Data_Cache DC(
        Clk, 
        Clk_uart,
        Resetb,
        Iss_LdStReady&&Iss_LdStOpcode,
        SB_DataValid,
        Iss_LdStRobTag,
        Iss_LdStAddr, 
        Iss_LdStPhyAddr, 
        Cdb_Flush,
        Rob_TopPtr_DC[4:0],
        Cdb_RobTag_Depth2DC,
        SB_AddrDmem,
        SB_DataDmem,
        DCE_Opcode,
        DCE_RobTag, 
        DCE_Addr,   
        DCE_MemData ,
        DCE_PhyAddr,
        DCE_ReadDone,
        DCE_WriteDone,
        DCE_ReadBusy,
        DCE_WriteBusy,
        Cache_Init, 
        Send_DataBack,
        Uart_DataCache_WE,
        Uart_Cache_InitAddr,
        Uart_DataCache_RdAddr[5:0], 
        Uart_Cache_InitData[31:0],
        DataCache_BackData
    );

    Mult_IssueQueue Mul_IssQue(
        Clk,
        Resetb,
        Cdb_RdPhyAddr,
        Cdb_PhyRegWrite,
        Dis_MulIssquenable,
        Dis_RsDataRdy,
        Dis_RtDataRdy,
        Dis_RegWrite,
        Dis_RsPhyAddr,
        Dis_RtPhyAddr,
        Dis_NewRdPhyAddr,
        Dis_RobTag,
        Issque_MulQueueFull,
        Issque_MulQueueTwoOrMoreVacant,
        IssMul_Rdy,
        Iss_Mult,
        Iss_RsPhyAddrMul,
        Iss_RtPhyAddrMul,
        Iss_RdPhyAddrMul,
        Iss_RobTagMul,
        Iss_RegWriteMul,
        Cdb_Flush,
        Rob_TopPtr_MulQ[4:0],
        Cdb_RobTag_Depth2MulQ
    );
//1000ps
    Div_IssueQueue Div_IssQue(
        Clk,
        Resetb,
        Cdb_RdPhyAddr,
        Cdb_PhyRegWrite,
        Dis_DivIssquenable,
        Dis_RsDataRdy,
        Dis_RtDataRdy,
        Dis_RegWrite,
        Dis_RsPhyAddr,
        Dis_RtPhyAddr,
        Dis_NewRdPhyAddr,
        Dis_RobTag,
        Issque_DivQueueFull,
        Issque_DivQueueTwoOrMoreVacant,
        IssDiv_Rdy,
        Iss_Div,
        Iss_RsPhyAddrDiv,
        Iss_RtPhyAddrDiv,
        Iss_RdPhyAddrDiv,
        Iss_RobTagDiv,
        Iss_RegWriteDiv,
        Cdb_Flush,
        Rob_TopPtr_DivQ[4:0],
        Cdb_RobTag_Depth2DivQ
    );

    ALU alu(
        PhyReg_AluRsData,
	    PhyReg_AluRtData,
	    Iss_OpcodeAlu,
	    Iss_RobTagAlu,
	    Iss_RdPhyAddrAlu,
	    Iss_BranchAddrAlu,	//branch mispredicted direction	
        Iss_BranchAlu,
	    Iss_RegWriteAlu,
	    Iss_BranchUptAddrAlu,
	    Iss_BranchPredictAlu,
	    Iss_JalInstAlu,
	    Iss_JrInstAlu,
	    Iss_JrRsInstAlu,
	    Iss_ImmediateAlu,	
	    Alu_RdData, //
        Alu_RdPhyAddr,//
        Alu_BranchAddr,	
        Alu_Branch,//
	    Alu_BranchOutcome,//
	    Alu_RobTag,//
	    Alu_BranchUptAddr, //
        Alu_BranchPredict,//
	    Alu_RdWrite,//
	    Alu_JrFlush
    );

    Multiplier Mul(
        Clk,
        Resetb,
        Iss_Mult,
        PhyReg_MultRsData,
        PhyReg_MultRtData,
        Iss_RobTagMul,	
        Mul_RdPhyAddr,
        Mul_RdWrite,
        Iss_RdPhyAddrMul,
        Iss_RegWriteMul,
        Mul_RdData,
        Mul_RobTag,
        Mul_Done,
        Cdb_Flush,
        Rob_TopPtr_Mul[4:0],
        Cdb_RobTag_Depth2Mul
    );

    Divider Div(
        Clk,
        Resetb,
        PhyReg_DivRsData,
        PhyReg_DivRtData,
        Iss_RobTagDiv,
        Iss_Div,
        Div_RdPhyAddr,
        Div_RdWrite,
        Iss_RdPhyAddrDiv,
        Iss_RegWriteDiv,
        Cdb_Flush,
        Rob_TopPtr_Div[4:0],
        Cdb_RobTag_Depth2Div,
        Div_Done,
        Div_RobTag,
        Div_Rddata,
        Div_ExeRdy
    );

    Common_Data_Bus CDB(
        Clk,
        Resetb,        
        Rob_TopPtr_CDB,
        Alu_RdData,   
        Alu_RdPhyAddr,
        Alu_BranchAddr,		
        Alu_Branch,
        Alu_BranchOutcome,
        Alu_BranchUptAddr,
        Iss_Int,
        Alu_BranchPredict,			
        Alu_JrFlush,
        Alu_RobTag,
        Alu_RdWrite,
        Mul_RdData,
        Mul_RdPhyAddr,
        Mul_Done,
        Mul_RobTag,
        Mul_RdWrite,
        Div_Rddata,
        Div_RdPhyAddr,
        Div_Done,
        Div_RobTag,
        Div_RdWrite,
        Lsbuf_Data, 
        Lsbuf_PhyAddr,  
        Iss_Lsb,                   
        Lsbuf_RobTag,
        Lsbuf_SwAddr,
        Lsbuf_RdWrite,
        Cdb_Valid,
        Cdb_PhyRegWrite,
        Cdb_RdData,
        Cdb_RobTag_DU,
        Cdb_RobTag_ROB,
        Cdb_RobTag_CFC,
        Cdb_BranchAddr,
        Cdb_BranchOutcome,
        Cdb_BrUpdtAddr,
        Cdb_Branch,
        Cdb_Flush,
        Cdb_RobTag_Depth2IntQ,
        Cdb_RobTag_Depth2MulQ,
        Cdb_RobTag_Depth2DivQ,
        Cdb_RobTag_Depth2Mul,
        Cdb_RobTag_Depth2Div,
        Cdb_RobTag_Depth2LSQ,
        Cdb_RobTag_Depth2LB,
        Cdb_RobTag_Depth2DC,
        Cdb_RobTag_Depth2CFC,
        Cdb_RdPhyAddr,
        Cdb_SwAddr,
        Rob_Commit		
    );

    Physical_Register_File PRF(
        Clk,
        Resetb,	
        Iss_RsPhyAddrAlu,
        Iss_RtPhyAddrAlu,
        Iss_RsPhyAddrLsq,//计算effective address
        Iss_RsPhyAddrMul,
        Iss_RtPhyAddrMul,
        Iss_RsPhyAddrDiv,
        Iss_RtPhyAddrDiv,
        Dis_RsPhyAddr,
        PhyReg_RsDataRdy,
        Dis_RtPhyAddr,
        PhyReg_RtDataRdy,
        Dis_NewRdPhyAddr,
        Dis_RegWrite,
        PhyReg_AluRsData,
        PhyReg_AluRtData,
        PhyReg_LsqRsData,
        PhyReg_MultRsData,
        PhyReg_MultRtData	,
        PhyReg_DivRsData,
        PhyReg_DivRtData,
        Cdb_RdData,
        Cdb_RdPhyAddr,
        Cdb_Valid,
        Cdb_PhyRegWrite,
        Rob_CommitCurrPhyAddr,
        PhyReg_StoreData  
    );

    Issue_Unit IU(
        Clk,
        Resetb,        
        IssInt_Rdy,
        IssMul_Rdy,
        IssDiv_Rdy,
        Lsbuf_Ready,                   
        Div_ExeRdy,
        Iss_Int,
        Iss_Mult,
        Iss_Div,
        Iss_Lsb  
    );

    Store_Buffer SB(
        Clk,
        Resetb,			
        Rob_SwAddr,
        PhyReg_StoreData,
        Rob_CommitMemWrite,
        SB_Full,
        SB_FlushSw,
        SB_FlushSwTag,
        SBTag_counter,
        SB_DataDmem,
        SB_AddrDmem,
        SB_DataValid,
        DCE_WriteDone  
);
    //uart for testing
    //Note:
    //this uart module which is a legacy from EE560 can only work under 100MHz, and the clock pin has to connect with the physical port of PLL of the FPGA,
    //otherwise it will not work even if you use a MMCM to generate a 100MHz clock signalS
    uart_tomasulo #(.CLOCK_RATE_RX(100_000_000), .CLOCK_RATE_TX(100_000_000)) uart(
        .clk_sys(Clk_uart),      // Clock input (from pin)
        .rst_clk(rst2uart),        // Active HIGH reset (from pin)
        .rxd_i(rxd_i),        // RS232 RXD pin
        .txd_o(txd_o),        // RS232 RXD pin
        .LED0(LED0_toBuf),
        .LED1(LED1_toBuf),
        .LED2(LED2_toBuf),
        .LED3(LED3_toBuf),
        .LED4(LED4_toBuf),
        .Bram_we1(Uart_DataCache_WE),//dc
        .Bram_we2(Uart_InstCache_WE),//ic
        .Bram_WrAddr(Uart_Cache_InitAddr),
        .Bram_RdAddr1(Uart_DataCache_RdAddr),
        .Bram_RdAddr2(Uart_InstCache_RdAddr),//we need the bram_rdaddr=64 as a flag to recognize the sending process is done
        .Data_OneRow(Uart_Cache_InitData),
        .Bram_Dout1(DataCache_BackData),
        .Bram_Dout2(InstCache_BackData),
        .BTNL(BTNL), //used for debug,
        .btnl_scen(btnl_scen)
    );
    //////////////////////////
    //The state machine below finishes several tasks:
    //THE LED2 will be activated when two files for initializing data cache and instruction cache has been received.
    //then we switch the Cache_Init signal to zero, so that the Data cache and instruction cache can be accessed by the CPU
    //Then we count 2000 cycles for the CPU to finished its own job, then LED6 will be on to indicate that it is time to return the contents in the data cache  back to PC so that 
    //we can check if the CPU works correctly, ohter LEDs are controlled by the FSM in uart.
    //The work done by uart module is that it receives files from PC and load them into BRAMs which are memory in the data cache and instruciton cache for storing data.
    //if the work of CPU is done, then FSM fetches out data in cache and send them back to PC
    //////////////////////////////////////////////// 
    //always block for generating cache init and sendback signals
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            Cache_Init<=1'b1;
            Send_DataBack<=1'b0;
            CPU_Run<=1'b0;
            Cnt_2000<='b0;
            Cnt_4<='b0;
            LED6_toBuf<='b0;
        end else begin
            if(LED2_toBuf&&!Cnt_2000[11])begin//all files have been received
                Cache_Init<=1'b0;
                CPU_Run<=1'b1;
                Cnt_2000<=Cnt_2000+1;
            end else if(Cnt_2000[11]&&!Cnt_4[2])begin//if the computation of CPU is done, make LED6 switched on
                Send_DataBack<=1'b1;
                Cnt_4<=Cnt_4+1;
            end else if(Cnt_4[2])begin
                LED6_toBuf<=1'b1;//the led6 will indicate it is time to press btnl
            end
        end
    end
    ////////////////////////////////////////
    //This always is used to make a output port which is affected by the CDB_valid signal, so that the synthesis tool will not optimize the CPU module since it doesn't has a output port
    //and i'm not sure if the design can be synthesized normally if below always module is removed, it is better to be kept here.
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            Test_Success<=6'b000000;
            LED5_toBuf<=1'b0;
        end else begin
            if(SB_AddrDmem==0&&SB_DataDmem==8&&DCE_WriteDone)begin
                Test_Success[0]<=1'b1;
            end
            ////////
            if(SB_AddrDmem==16&&SB_DataDmem==4&&DCE_WriteDone)begin
                Test_Success[1]<=1'b1;
            end
            /////////
            if(SB_AddrDmem==20&&SB_DataDmem==5&&DCE_WriteDone)begin
                Test_Success[2]<=1'b1;
            end
            ////////
            if(SB_AddrDmem==24&&SB_DataDmem==1&&DCE_WriteDone)begin
                Test_Success[3]<=1'b1;
            end
            /////////
            if(SB_AddrDmem==28&&SB_DataDmem==4&&DCE_WriteDone)begin
                Test_Success[4]<=1'b1;
            end
            /////////
            if(SB_AddrDmem==32&&SB_DataDmem==8&&DCE_WriteDone)begin
                Test_Success[5]<=1'b1;
            end
            if(Test_Success==6'b111111)begin
                LED5_toBuf<=1'b1; 
            end
        end
    end
endmodule