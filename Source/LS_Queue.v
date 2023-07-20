`timescale 1ps/1ps
module LS_Queue(
    input Clk,
    input Resetb,
    // Information to be captured from the CDB (Common Data Bus)
    input [5:0] Cdb_RdPhyAddr,
    input Cdb_PhyRegWrite,
    // Information from the Dispatch Unit
    input Dis_Opcode,
    input [15:0] Dis_Immediate,
    input Dis_RsDataRdy,
    input Dis_RtDataRdy,
    input [5:0] Dis_RsPhyAddr,
    input [4:0] Dis_RobTag,
    input [5:0] Dis_RdRtPhyAddr,//该输入在从dispatch unit传来时应该进行选择，如果当前LSQ enable=1，如果lw则接收rd phy tag,否则接收rt phy tag
    input Dis_LdIssquenable,
    output Issque_LdStQueueFull,
    output Issque_LdStQueueTwoOrMoreVacant,
    // interface with PRF
    output reg [5:0] Iss_RsPhyAddrLsq,
    input [31:0] PhyReg_LsqRsData,//用于计算memory的有效访问地址
    // Interface with the Issue Unit
    output Iss_LdStReady,
    output reg Iss_LdStOpcode,
    output reg [4:0] Iss_LdStRobTag,
    output reg [31:0] Iss_LdStAddr,
    //input Iss_LdStIssued,
    output reg [5:0] Iss_LdStPhyAddr,//rt,rd phy registere
    input DCE_ReadBusy,//connect with data cache
    input DCE_ReadDone,
    //interface with ls buffer
    input Lsbuf_Full,
    input Lsbuf_TwoOrMoreVaccant,
    //Interface with ROB
    input Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth,
    input SB_FlushSw,
    //interface with SAB
    input [1:0] SB_FlushSwTag,
    input [1:0] SBTag_counter,        
    input Rob_CommitMemWrite
);
    integer i,j;
    ///基本的逻辑是，sw issue需要有valid address以及rt ready，而获得valid address需要rsready，我们要求必须entry中的这些信号变为1时才会产生ready信号
    //虽然牺牲了一定的性能，但是简化了逻辑
    //对于lw则需要rs ready之后计算出valid address，通过扫描SAB和bypass counter判断是否有disambiguation
    reg [7:0] LSQ_InstValid, LSQ_AddrValid, LSQ_Opcode, LSQ_RsDataRdy, LSQ_RtDataRdy;
    reg [31:0] LSQ_Addr [7:0];
    reg [15:0] LSQ_Immediate [7:0];
    reg [5:0] LSQ_RsPhyAddr [7:0];
    reg [5:0] LSQ_RdRtPhyAddr[7:0];
    reg [4:0] LSQ_RobTag [7:0];
    ///////////////////////////
    //entry used for recording bypass
    //每个entry允许三个
    //为方便每一次有baypass的sw写入，我们将每个entry的三个bypass location 也做成queue的形式
    reg [2:0] ByPass_SW_Valid [7:0];
    reg [4:0] ByPass_SW_RobTag [7:0] [2:0];//重点：越靠近里面越具有高优先级
    reg [31:0] ByPass_SW_Addr [7:0] [2:0];
    reg [6:0]Allow_ByPass;//每一个bypass entry都产生一个信号，是否允许其上面的lw进行bypass
    ////////////////////////////////////////
    //combinational signals
    reg [7:0] Flush, Valid_AfterFlush, Ready_Issue, Ready_CompAddr;//表示entry准备好计算地址了
    reg [6:0] Shift_En;
    reg [2:0] ByPass_Valid_AfterFlush [7:0];
    reg [2:0] ByPass_Flush [7:0];
    /////////////////
    //interface with SAB
    wire[31:0] ScanAddr[7:0];//scan address (address of entries in lsq) --signal from LSQ
    wire AddrMatch[7:0];//each entry of LSQ will compare with all entries of SAB
    wire [2:0] AddrMatchNum[7:0];
    wire SAB_Full;
    wire [36:0] LsqSwAddr;
    //////////////////////////////////////////////////////////////////////
    //intereface with Bypass counter
    reg [1:0] BP_SwAddrMatchNum [7:0];
    ///////////////////////////////////////////////////////////////////////
    //用于产生two more location signals
    wire Upper4_Full,Lower4_Full, Upper4_2More, Lower4_2More;
    assign Upper4_Full=&Valid_AfterFlush[7:4];
    assign Lower4_Full=&Valid_AfterFlush[3:0];
    assign Upper4_2More=!Valid_AfterFlush[7]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[5]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[4]||!Valid_AfterFlush[5]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[5];
    assign Lower4_2More=!Valid_AfterFlush[3]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[1];
    assign Issque_LdStQueueTwoOrMoreVacant=!Upper4_Full&&Iss_LdStReady||!Lower4_Full&&Iss_LdStReady||!Upper4_Full&&!Lower4_Full||Lower4_2More||Upper4_2More;
    assign Issque_LdStQueueFull=Upper4_Full&&Lower4_Full&&!Iss_LdStReady;
    /////////////////////////////////////////////////////////////////////////
    assign ScanAddr[0]=LSQ_Addr[0];
    assign ScanAddr[1]=LSQ_Addr[1];
    assign ScanAddr[2]=LSQ_Addr[2];
    assign ScanAddr[3]=LSQ_Addr[3];
    assign ScanAddr[4]=LSQ_Addr[4];
    assign ScanAddr[5]=LSQ_Addr[5];
    assign ScanAddr[6]=LSQ_Addr[6];
    assign ScanAddr[7]=LSQ_Addr[7];
    //////////////////
    assign Iss_LdStReady=|Ready_Issue;
    assign LsqSwAddr={Iss_LdStRobTag,Iss_LdStAddr};
    /////////////////
    //LSQ主体中的信号
    //generate above combinational signals
    always @(*) begin
        Flush=8'h00;
        Valid_AfterFlush=8'h00;
        Ready_Issue=8'h00;
        if(Cdb_Flush)begin
            for(i=0;i<8;i=i+1)begin
                if(LSQ_InstValid[i]&&(LSQ_RobTag[i]-Rob_TopPtr>Cdb_RobDepth))begin
                    Flush[i]=1'b1;
                end
            end
        end
        ////////////////
        Valid_AfterFlush=LSQ_InstValid&(~Flush);
        //generate ready_issue signals
        //重点1：
        //sw在离开entry之前还需要判断其下方的lw entry的bypass counter还有没有位置，如果没有位置则还是需要等
        //因此只能每个entry分开写
        //sw想要ready的条件：没有被flush，rt ready,并且address valid，SAB没有满，当前如果cache正在处理lw,那么只有在当前没有data从data cache中读出时可以发送sw,否则不可
        //并且发送sw时需要SAB中拥有两个以上的空位，如果此时data cache并没有处理lw,那么只需SAB没满即可。还需要检测bypass counter的位置
        ////////////////////////////
        //重点2：
        //ready的条件：没有被flush，valid address，并且在SAB中没有match的sw，并且当前cache不是busy的,并且lsbuffer必须没满
        //lw的ready issue信号有bug: lw什么时间可以发送的条件，除了上述的SAB中没有match address以外，还需要保证lsq中其下方没有地址未ready的指令，
        //同时如果其下方有地址ready并与lw相同的指令时，也不能ready issue
        //由于每个entry下方的entry数量不同，因此不方便使用for loop描写，只能分开写
        //entry0
        if(!LSQ_Opcode[0])begin//sw
            Ready_Issue[0]=Valid_AfterFlush[0]&&LSQ_RtDataRdy[0]&&LSQ_AddrValid[0]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full);
        end else begin // lw
            Ready_Issue[0]=Valid_AfterFlush[0]&&LSQ_AddrValid[0]&&!DCE_ReadBusy&&(!AddrMatch[0]||AddrMatchNum[0]-BP_SwAddrMatchNum[0]==0)&&!Lsbuf_Full;
        end
        //entry1
        if(!LSQ_Opcode[1])begin
            Ready_Issue[1]=Valid_AfterFlush[1]&&LSQ_RtDataRdy[1]&&LSQ_AddrValid[1]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&Allow_ByPass[0];
        end else begin // lw
            Ready_Issue[1]=Valid_AfterFlush[1]&&LSQ_AddrValid[1]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[1]))&&(!AddrMatch[1]||AddrMatchNum[1]-BP_SwAddrMatchNum[1]==0)&&!Lsbuf_Full;
        end
        //entry2
        if(!LSQ_Opcode[2])begin
            Ready_Issue[2]=Valid_AfterFlush[2]&&LSQ_RtDataRdy[2]&&LSQ_AddrValid[2]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[1:0]);
        end else begin // lw
            Ready_Issue[2]=Valid_AfterFlush[2]&&LSQ_AddrValid[2]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[2]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[2]!=LSQ_Addr[1]))&&(!AddrMatch[2]||AddrMatchNum[2]-BP_SwAddrMatchNum[2]==0)&&!Lsbuf_Full;
        end
        //entry3
        if(!LSQ_Opcode[3])begin
            Ready_Issue[3]=Valid_AfterFlush[3]&&LSQ_RtDataRdy[3]&&LSQ_AddrValid[3]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[2:0]);
        end else begin // lw
            Ready_Issue[3]=Valid_AfterFlush[3]&&LSQ_AddrValid[3]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[3]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[3]!=LSQ_Addr[1]))&&(!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&(LSQ_Opcode[2]||!LSQ_Opcode[2]&&LSQ_AddrValid[2]&&LSQ_Addr[2]!=LSQ_Addr[3]))&&(!AddrMatch[3]||AddrMatchNum[3]-BP_SwAddrMatchNum[3]==0)&&!Lsbuf_Full;
        end
        //entry4
        if(!LSQ_Opcode[4])begin
            Ready_Issue[4]=Valid_AfterFlush[4]&&LSQ_RtDataRdy[4]&&LSQ_AddrValid[4]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[3:0]);
        end else begin // lw
            Ready_Issue[4]=Valid_AfterFlush[4]&&LSQ_AddrValid[4]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[4]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[4]!=LSQ_Addr[1]))&&(!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&(LSQ_Opcode[2]||!LSQ_Opcode[2]&&LSQ_AddrValid[2]&&LSQ_Addr[2]!=LSQ_Addr[4]))&&(!Valid_AfterFlush[3]||Valid_AfterFlush[3]&&(LSQ_Opcode[3]||!LSQ_Opcode[3]&&LSQ_AddrValid[3]&&LSQ_Addr[3]!=LSQ_Addr[4]))&&(!AddrMatch[4]||AddrMatchNum[4]-BP_SwAddrMatchNum[4]==0)&&!Lsbuf_Full;
        end 
        //entry5
        if(!LSQ_Opcode[5])begin
            Ready_Issue[5]=Valid_AfterFlush[5]&&LSQ_RtDataRdy[5]&&LSQ_AddrValid[5]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[4:0]);
        end else begin // lw
            Ready_Issue[5]=Valid_AfterFlush[5]&&LSQ_AddrValid[5]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[5]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[5]!=LSQ_Addr[1]))&&(!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&(LSQ_Opcode[2]||!LSQ_Opcode[2]&&LSQ_AddrValid[2]&&LSQ_Addr[2]!=LSQ_Addr[5]))&&(!Valid_AfterFlush[3]||Valid_AfterFlush[3]&&(LSQ_Opcode[3]||!LSQ_Opcode[3]&&LSQ_AddrValid[3]&&LSQ_Addr[3]!=LSQ_Addr[5]))&&(!Valid_AfterFlush[4]||Valid_AfterFlush[4]&&(LSQ_Opcode[4]||!LSQ_Opcode[4]&&LSQ_AddrValid[4]&&LSQ_Addr[4]!=LSQ_Addr[5]))&&(!AddrMatch[5]||AddrMatchNum[5]-BP_SwAddrMatchNum[5]==0)&&!Lsbuf_Full;
        end 
        //entry6
        if(!LSQ_Opcode[6])begin
            Ready_Issue[6]=Valid_AfterFlush[6]&&LSQ_RtDataRdy[6]&&LSQ_AddrValid[6]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[5:0]);
        end else begin // lw
            Ready_Issue[6]=Valid_AfterFlush[6]&&LSQ_AddrValid[6]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[6]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[6]!=LSQ_Addr[1]))&&(!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&(LSQ_Opcode[2]||!LSQ_Opcode[2]&&LSQ_AddrValid[2]&&LSQ_Addr[2]!=LSQ_Addr[6]))&&(!Valid_AfterFlush[3]||Valid_AfterFlush[3]&&(LSQ_Opcode[3]||!LSQ_Opcode[3]&&LSQ_AddrValid[3]&&LSQ_Addr[3]!=LSQ_Addr[6]))&&(!Valid_AfterFlush[4]||Valid_AfterFlush[4]&&(LSQ_Opcode[4]||!LSQ_Opcode[4]&&LSQ_AddrValid[4]&&LSQ_Addr[4]!=LSQ_Addr[6]))&&(!Valid_AfterFlush[5]||Valid_AfterFlush[5]&&(LSQ_Opcode[5]||!LSQ_Opcode[5]&&LSQ_AddrValid[5]&&LSQ_Addr[5]!=LSQ_Addr[6]))&&(!AddrMatch[6]||AddrMatchNum[6]-BP_SwAddrMatchNum[6]==0)&&!Lsbuf_Full;
        end 
        //entry7
        if(!LSQ_Opcode[7])begin
            Ready_Issue[7]=Valid_AfterFlush[7]&&LSQ_RtDataRdy[7]&&LSQ_AddrValid[7]&&!SAB_Full&&(DCE_ReadBusy&&!DCE_ReadDone&&Lsbuf_TwoOrMoreVaccant||!DCE_ReadBusy&&!Lsbuf_Full)&&(&Allow_ByPass[6:0]);
        end else begin // lw
            Ready_Issue[7]=Valid_AfterFlush[7]&&LSQ_AddrValid[7]&&!DCE_ReadBusy&&(!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&(LSQ_Opcode[0]||!LSQ_Opcode[0]&&LSQ_AddrValid[0]&&LSQ_Addr[0]!=LSQ_Addr[7]))&&(!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&(LSQ_Opcode[1]||!LSQ_Opcode[1]&&LSQ_AddrValid[1]&&LSQ_Addr[7]!=LSQ_Addr[1]))&&(!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&(LSQ_Opcode[2]||!LSQ_Opcode[2]&&LSQ_AddrValid[2]&&LSQ_Addr[2]!=LSQ_Addr[7]))&&(!Valid_AfterFlush[3]||Valid_AfterFlush[3]&&(LSQ_Opcode[3]||!LSQ_Opcode[3]&&LSQ_AddrValid[3]&&LSQ_Addr[3]!=LSQ_Addr[7]))&&(!Valid_AfterFlush[4]||Valid_AfterFlush[4]&&(LSQ_Opcode[4]||!LSQ_Opcode[4]&&LSQ_AddrValid[4]&&LSQ_Addr[4]!=LSQ_Addr[7]))&&(!Valid_AfterFlush[5]||Valid_AfterFlush[5]&&(LSQ_Opcode[5]||!LSQ_Opcode[5]&&LSQ_AddrValid[5]&&LSQ_Addr[5]!=LSQ_Addr[7]))&&(!Valid_AfterFlush[6]||Valid_AfterFlush[6]&&(LSQ_Opcode[6]||!LSQ_Opcode[6]&&LSQ_AddrValid[6]&&LSQ_Addr[6]!=LSQ_Addr[7]))&&(!AddrMatch[7]||AddrMatchNum[7]-BP_SwAddrMatchNum[7]==0)&&!Lsbuf_Full;
        end 
        //////////////////////////////////////
        //由于仍然要求停留时间最长的指令优先离开，因此shift enable信号分开写
        //只要ready enable升高，即表示其可以离开lsq,否则的话是不不会激活ready信号的
        Shift_En[0]=!Valid_AfterFlush[0]||Ready_Issue[0];
        Shift_En[1]=Shift_En[0]||!Valid_AfterFlush[1]||Ready_Issue[1]&&!Ready_Issue[0];
        Shift_En[2]=Shift_En[1]||!Valid_AfterFlush[2]||Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0];
        Shift_En[3]=Shift_En[2]||!Valid_AfterFlush[3]||Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0];
        Shift_En[4]=Shift_En[3]||!Valid_AfterFlush[4]||Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0];
        Shift_En[5]=Shift_En[4]||!Valid_AfterFlush[5]||Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0];
        Shift_En[6]=Shift_En[5]||!Valid_AfterFlush[6]||Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0];
        ////////////////////////////////////////////
        //generate ready calculate address signals, 优先级同样给到最老的指令
        //但是优先级的体现在外部组合逻辑读取ready 信号时，当前每一个entry产生ready compute信号只需要自身满足条件即可
        //重点：
        //ready compute addr与前面的ready issue激活有一些不同，因为其他module中ready issue一旦激活，那么就会issue，issue后该信号自动变零
        //但是ready compute并不一样，激活之后，计算完地址，可能并不会立刻发送，此时如果地址已经算出来，但是ready compute还是1，那么将导致其他location无法计算地址
        Ready_CompAddr=(~LSQ_AddrValid)&Valid_AfterFlush&LSQ_RsDataRdy;
        ///////////////////////////////////
        //generate ByPass Valid after flush
        for(i=0;i<8;i=i+1)begin
            ByPass_Flush[i]=3'b000;
            if(Cdb_Flush)begin
                for(j=0;j<3;j=j+1)begin
                    if(ByPass_SW_Valid[i][j]&&(ByPass_SW_RobTag[i][j]-Rob_TopPtr>Cdb_RobDepth))begin
                        ByPass_Flush[i][j]=1'b1;
                    end
                end
            end
            /////////////////////////////////////
            ByPass_Valid_AfterFlush[i]=ByPass_SW_Valid[i]&(~ByPass_Flush[i]);
        end

    end
    ///////////////////////////
    //产生bypass counter 中的一些组合逻辑信号
    //每一个sw想要bypass时都需要看其下面的allow是不是全部为1，只要有一个不为1则不能bypass
    always@(*)begin
        Allow_ByPass=7'b1111111;
        for(i=0;i<7;i=i+1)begin
            //什么情况下不允许bypass:首先指令是有效的，是lw,并且bypass位置满了
            if(Valid_AfterFlush[i]&&LSQ_Opcode[i]&&(&ByPass_SW_Valid[i]))begin
                Allow_ByPass[i]=1'b0;
            end
        end   
    end
    //////////////////////////////////////////////
    //genereate BP_SwAddrMatchNum
    always@(*)begin
        for(i=0;i<8;i=i+1)begin
            BP_SwAddrMatchNum[i]=2'b00;
            for(j=0;j<3;j=j+1)begin
                if(ByPass_SW_Addr[i][j]==LSQ_Addr[i])begin
                     BP_SwAddrMatchNum[i]= BP_SwAddrMatchNum[i]+1;
                end
            end
        end
    end
    ////////////////////////////////////////////////////
    //select a correct data to compute address and issue correct instruction to sab and ls buffer
    always@(*)begin
        casez(Ready_CompAddr)
        8'bzzzz_zz10:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[1];
        8'bzzzz_z100:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[2];
        8'bzzzz_1000:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[3];
        8'bzzz1_0000:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[4];
        8'bzz10_0000:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[5];
        8'bz100_0000:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[6];
        8'b1000_0000:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[7];
        default:Iss_RsPhyAddrLsq=LSQ_RsPhyAddr[0];
        endcase
        //////////////////////////////////////////////////////
        casez(Ready_Issue)
            8'bzzzz_zz10:begin
                Iss_LdStOpcode=LSQ_Opcode[1];
                Iss_LdStRobTag=LSQ_RobTag[1];
                Iss_LdStAddr=LSQ_Addr[1];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[1];
            end
            8'bzzzz_z100:begin
                Iss_LdStOpcode=LSQ_Opcode[2];
                Iss_LdStRobTag=LSQ_RobTag[2];
                Iss_LdStAddr=LSQ_Addr[2];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[2];
            end
            8'bzzzz_1000:begin
                Iss_LdStOpcode=LSQ_Opcode[3];
                Iss_LdStRobTag=LSQ_RobTag[3];
                Iss_LdStAddr=LSQ_Addr[3];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[3];
            end
            8'bzzz1_0000:begin
                Iss_LdStOpcode=LSQ_Opcode[4];
                Iss_LdStRobTag=LSQ_RobTag[4];
                Iss_LdStAddr=LSQ_Addr[4];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[4];
            end
            8'bzz10_0000:begin
                Iss_LdStOpcode=LSQ_Opcode[5];
                Iss_LdStRobTag=LSQ_RobTag[5];
                Iss_LdStAddr=LSQ_Addr[5];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[5];
            end
            8'bz100_0000:begin
                Iss_LdStOpcode=LSQ_Opcode[6];
                Iss_LdStRobTag=LSQ_RobTag[6];
                Iss_LdStAddr=LSQ_Addr[6];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[6];
            end
            8'b1000_0000:begin
                Iss_LdStOpcode=LSQ_Opcode[7];
                Iss_LdStRobTag=LSQ_RobTag[7];
                Iss_LdStAddr=LSQ_Addr[7];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[7];
            end
            default:begin
                Iss_LdStOpcode=LSQ_Opcode[0];
                Iss_LdStRobTag=LSQ_RobTag[0];
                Iss_LdStAddr=LSQ_Addr[0];
                Iss_LdStPhyAddr=LSQ_RdRtPhyAddr[0];
            end
        endcase
    end
    ///////////////////////////////////////////////////////////////////////
    //entry update logic of lsq and bypass counter
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            LSQ_InstValid<='b0;
            LSQ_AddrValid<='bx;//在entry7写入指令时会写入0，因此不需要reset
            LSQ_Opcode<='bx; 
            LSQ_RsDataRdy<='bx;
            LSQ_RtDataRdy<='bx;
            for(i=0;i<8;i=i+1)begin
                ByPass_SW_Valid[i]<=3'b000;
                LSQ_Addr[i]<='bx;
                LSQ_Immediate[i]<='bx;
                LSQ_RsPhyAddr[i]<='bx;
                LSQ_RdRtPhyAddr[i]<='bx;
                LSQ_RobTag[i]<='bx;
                ByPass_SW_RobTag[i][0]<='bx;
                ByPass_SW_RobTag[i][1]<='bx;
                ByPass_SW_RobTag[i][2]<='bx;
                ByPass_SW_Addr[i][0]<='bx;
                ByPass_SW_Addr[i][1]<='bx;
                ByPass_SW_Addr[i][2]<='bx;
            end
        end else begin
            //entry 0->6 lsq
            //整个过程中，无论是否shift，需要更新的内容有：instvalid, addr valid，addr ,2个 ready bit， bypass valid, rob, addr
            for(i=1;i<8;i=i+1)begin
                if(Shift_En[i-1])begin//shifted
                    LSQ_Opcode[i-1]<=LSQ_Opcode[i]; 
                    LSQ_Addr[i-1]<=LSQ_Addr[i];
                    LSQ_Immediate[i-1]<=LSQ_Immediate[i];
                    LSQ_RsPhyAddr[i-1]<=LSQ_RsPhyAddr[i];
                    LSQ_RdRtPhyAddr[i-1]<=LSQ_RdRtPhyAddr[i];
                    LSQ_RobTag[i-1]<=LSQ_RobTag[i];
                    /////////////////////
                    //更新data ready bit
                    //重点：
                    //更新ready bit时，cdb上是reg write指令，因此不需要使用valid——after flush信号，使用valid_reg即可，可以优化时序
                    if(Cdb_PhyRegWrite)begin
                        if(!LSQ_RsDataRdy[i]&&LSQ_InstValid[i]&&LSQ_RsPhyAddr[i]==Cdb_RdPhyAddr)begin
                            LSQ_RsDataRdy[i-1]<=1'b1;
                        end else begin
                            LSQ_RsDataRdy[i-1]<=LSQ_RsDataRdy[i];
                        end
                        ////////////////
                        if(!LSQ_Opcode[i]&&!LSQ_RtDataRdy[i]&&LSQ_InstValid[i]&&LSQ_RdRtPhyAddr[i]==Cdb_RdPhyAddr)begin
                            LSQ_RtDataRdy[i-1]<=1'b1;
                        end else begin
                            LSQ_RtDataRdy[i-1]<=LSQ_RtDataRdy[i];
                        end
                    end else begin
                        LSQ_RsDataRdy[i-1]<=LSQ_RsDataRdy[i];
                        LSQ_RtDataRdy[i-1]<=LSQ_RtDataRdy[i];
                    end
                end else begin//non-shifted
                    //更新data ready bit
                    //重点：
                    //更新ready bit时，cdb上是reg write指令，因此不需要使用valid——after flush信号，使用valid_reg即可，可以优化时序
                    if(Cdb_PhyRegWrite)begin
                        if(!LSQ_RsDataRdy[i-1]&&LSQ_InstValid[i-1]&&LSQ_RsPhyAddr[i-1]==Cdb_RdPhyAddr)begin
                            LSQ_RsDataRdy[i-1]<=1'b1;
                        end 
                        ////////////////
                        if(!LSQ_Opcode[i-1]&&!LSQ_RtDataRdy[i-1]&&LSQ_InstValid[i-1]&&LSQ_RdRtPhyAddr[i-1]==Cdb_RdPhyAddr)begin
                            LSQ_RtDataRdy[i-1]<=1'b1;
                        end
                    end 
                end
            end
            ///更新valid addr
            //由于valid addr的更新需要考虑其下方没有ready compute信号，所以不方便使用for loop
            if(Shift_En[0])begin//shifted
                    if(Ready_CompAddr[1]&&!Ready_CompAddr[0])begin
                        LSQ_AddrValid[0]<=1'b1;
                        LSQ_Addr[0]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[1][15]}},LSQ_Immediate[1]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[0]<=LSQ_AddrValid[1];
                        LSQ_Addr[0]<=LSQ_Addr[1];
                    end
            end else begin//non-shifted，location一定是valid
                if(Ready_CompAddr[0])begin
                    LSQ_AddrValid[0]<=1'b1;
                    LSQ_Addr[0]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[0][15]}},LSQ_Immediate[0]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[1])begin
                    if(Ready_CompAddr[2]&&!(|Ready_CompAddr[1:0]))begin
                        LSQ_AddrValid[1]<=1'b1;
                        LSQ_Addr[1]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[2][15]}},LSQ_Immediate[2]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[1]<=LSQ_AddrValid[2];
                        LSQ_Addr[1]<=LSQ_Addr[2];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[1]&&!Ready_CompAddr[0])begin
                    LSQ_AddrValid[1]<=1'b1;
                    LSQ_Addr[1]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[1][15]}},LSQ_Immediate[1]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[2])begin
                    if(Ready_CompAddr[3]&&!(|Ready_CompAddr[2:0]))begin
                        LSQ_AddrValid[2]<=1'b1;
                        LSQ_Addr[2]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[3][15]}},LSQ_Immediate[3]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[2]<=LSQ_AddrValid[3];
                        LSQ_Addr[2]<=LSQ_Addr[3];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[2]&&!(|Ready_CompAddr[1:0]))begin
                    LSQ_AddrValid[2]<=1'b1;
                    LSQ_Addr[2]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[2][15]}},LSQ_Immediate[2]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[3])begin
                    if(Ready_CompAddr[4]&&!(|Ready_CompAddr[3:0]))begin
                        LSQ_AddrValid[3]<=1'b1;
                        LSQ_Addr[3]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[4][15]}},LSQ_Immediate[4]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[3]<=LSQ_AddrValid[4];
                        LSQ_Addr[3]<=LSQ_Addr[4];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[3]&&!(|Ready_CompAddr[2:0]))begin
                    LSQ_AddrValid[3]<=1'b1;
                    LSQ_Addr[3]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[3][15]}},LSQ_Immediate[3]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[4])begin
                    if(Ready_CompAddr[5]&&!(|Ready_CompAddr[4:0]))begin
                        LSQ_AddrValid[4]<=1'b1;
                        LSQ_Addr[4]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[5][15]}},LSQ_Immediate[5]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[4]<=LSQ_AddrValid[5];
                        LSQ_Addr[4]<=LSQ_Addr[5];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[4]&&!(|Ready_CompAddr[3:0]))begin
                    LSQ_AddrValid[4]<=1'b1;
                    LSQ_Addr[4]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[4][15]}},LSQ_Immediate[4]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[5])begin
                    if(Ready_CompAddr[6]&&!(|Ready_CompAddr[5:0]))begin
                        LSQ_AddrValid[5]<=1'b1;
                        LSQ_Addr[5]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[6][15]}},LSQ_Immediate[6]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[5]<=LSQ_AddrValid[6];
                        LSQ_Addr[5]<=LSQ_Addr[6];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[5]&&!(|Ready_CompAddr[4:0]))begin
                    LSQ_AddrValid[5]<=1'b1;
                    LSQ_Addr[5]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[5][15]}},LSQ_Immediate[5]};
                end
            end
            ////////////////////////////////////////////////////////////////////////////////////////////
            if(Shift_En[6])begin
                    if(Ready_CompAddr[7]&&!(|Ready_CompAddr[6:0]))begin
                        LSQ_AddrValid[6]<=1'b1;
                        LSQ_Addr[6]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[7][15]}},LSQ_Immediate[7]};//将immediate address符号位拓展
                    end else begin
                        LSQ_AddrValid[6]<=LSQ_AddrValid[7];
                        LSQ_Addr[6]<=LSQ_Addr[7];
                    end
            end else begin//不能shift，location一定是valid
                if(Ready_CompAddr[6]&&!(|Ready_CompAddr[5:0]))begin
                    LSQ_AddrValid[6]<=1'b1;
                    LSQ_Addr[6]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[6][15]}},LSQ_Immediate[6]};
                end
            end
            ////////////////////////////////////////////////
            //更新inst valid
            if(Shift_En[0])begin//没有flush且没有issue即向下一个location写入1
                LSQ_InstValid[0]<=Valid_AfterFlush[1]&&(!Ready_Issue[1]||Ready_Issue[1]&&Ready_Issue[0]);
            end//若不能shift则表明指令一定是有效的，保持即可
            if(Shift_En[1])begin
                LSQ_InstValid[1]<=Valid_AfterFlush[2]&&(!Ready_Issue[2]||Ready_Issue[2]&&(Ready_Issue[1]||Ready_Issue[0]));
            end
            if(Shift_En[2])begin
                LSQ_InstValid[2]<=Valid_AfterFlush[3]&&(!Ready_Issue[3]||Ready_Issue[3]&&(Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0]));
            end
            if(Shift_En[3])begin
                LSQ_InstValid[3]<=Valid_AfterFlush[4]&&(!Ready_Issue[4]||Ready_Issue[4]&&(Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0]));
            end
            if(Shift_En[4])begin
                LSQ_InstValid[4]<=Valid_AfterFlush[5]&&(!Ready_Issue[5]||Ready_Issue[5]&&(Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0]));
            end
            if(Shift_En[5])begin
                LSQ_InstValid[5]<=Valid_AfterFlush[6]&&(!Ready_Issue[6]||Ready_Issue[6]&&(Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0]));
            end
            if(Shift_En[6])begin
                LSQ_InstValid[6]<=Valid_AfterFlush[7]&&(!Ready_Issue[7]||Ready_Issue[7]&&(Ready_Issue[6]||Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0]));
            end
            ////////////////////////////////////////////////////
            //entry 7 update
            //只要enable信号为1，那么指令一定是valid，如果是bubble，则所有queue的enable信号都不会亮
            if(Dis_LdIssquenable&&(!Cdb_Flush||Cdb_Flush&&Dis_RobTag-Rob_TopPtr<Cdb_RobDepth))begin//valid input 且没有flush
                LSQ_InstValid[7]<=1'b1;
                LSQ_AddrValid[7]<=1'b0;//在entry7写入指令时会写入0，因此不需要reset
                LSQ_Opcode[7]<=Dis_Opcode; 
                if(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==Dis_RsPhyAddr)||Dis_RsDataRdy)begin//既看cdb又看ready bit array
                    LSQ_RsDataRdy[7]<=1'b1;
                end else begin
                    LSQ_RsDataRdy[7]<=1'b0;
                end
                //sw
                if(!Dis_Opcode&&(Cdb_PhyRegWrite&&(Cdb_RdPhyAddr==Dis_RdRtPhyAddr)||Dis_RtDataRdy))begin//既看cdb又看ready bit array
                    LSQ_RtDataRdy[7]<=1'b1;
                end else begin
                    LSQ_RtDataRdy[7]<=1'b0;
                end
                LSQ_Immediate[7]<=Dis_Immediate;
                LSQ_RsPhyAddr[7]<=Dis_RsPhyAddr;
                LSQ_RdRtPhyAddr[7]<=Dis_RdRtPhyAddr;
                LSQ_RobTag[7]<=Dis_RobTag;
                ByPass_SW_Valid[7]<=3'b0;
            end else if(Shift_En[6])begin
                LSQ_InstValid[7]<=1'b0;
                LSQ_AddrValid[7]<=1'b0;
                LSQ_RsDataRdy[7]<=1'b0;
                LSQ_RtDataRdy[7]<=1'b0;
                ByPass_SW_Valid[7]<=3'b0;
            end else if(LSQ_InstValid[7])begin//更新inst valid, addr valid, addr,而 bypass counter不用更新
                //注意当前由于cdb flush为1，说明不可能更新ready bit
                LSQ_InstValid[7]<=Valid_AfterFlush[7];
                if(Ready_CompAddr[7]&&!(|Ready_CompAddr[6:0]))begin
                    LSQ_AddrValid[7]<=1'b1;
                    LSQ_Addr[7]<=PhyReg_LsqRsData+{{16{LSQ_Immediate[7][15]}},LSQ_Immediate[7]}; 
                end
                if(Cdb_PhyRegWrite&&Cdb_RdPhyAddr==LSQ_RsPhyAddr[7])begin
                    LSQ_RsDataRdy[7]<=1'b1;
                end
                if(Cdb_PhyRegWrite&&Cdb_RdPhyAddr==LSQ_RdRtPhyAddr[7])begin
                    LSQ_RtDataRdy[7]<=1'b1;
                end
            end
            //////////////////////////////////////////////////////
            //bypass counter update
            //重点：在shift的过程中valid，robtag, addr都需要更新
            //记得还得flush
            //我们应该从每一个clock哪一个entry发送进行讨论，再区分shift与non-shifted进行code
            casez(Ready_Issue)
                8'bzzzz_zzz1:begin//当前location0进行发送，因此shift_en[0]一定是1，因此bypass 的内容由上一级替代
                    //由于需要考虑cdb flush带来的影响，因此每一种发射情况，所有entry的update都需要考虑
                    //因为当前entry0发送出去，因此上面所有的指令都需要向下移
                    for(i=1;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end 
                    end
                    //entry7不需要考虑flush的影响，因为没有人能bypass entry7，所以不需要考虑cdb flush
                end
                8'bzzzz_zz10:begin//当前发送的location1,那么需要分析shift_en[0]是否为0，如果是0，则说明里面的指令是有效的，那么如果是lw则应该对bypass 的sw进行记录
                    //重点：对于location 0而言，他已经不能向下移了，因此只有当他是有效的时候我们才会写入bypass
                    //而对于其他位置我们需要考虑他是否会下移，如果下移则需要往下一个位置写入
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[1])begin//entry0中指令有效且是lw,并且发送的指令时sw
                            //重点：需要注意的是，虽然我们想写入的顺序是先看loc0有没有指令，有的话看loc1,之后再看loc2
                            //但是由于flush的存在，当loc valid=0时，其他位置可能会存在有效的data
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[1];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[1];
                                //////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[1];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[1];
                                ////////////////////////////////////
                                //bypass counter中3个location中0已经被占，因此需要将valid after flush写入
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[1];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[1];
                                ///////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            end
                        end else begin//如果当时发送的指令不是sw,那么location0中的内容就按照flush进行保存即可
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                        end
                    end//如果当前entry0中的内容不是lw,则根本bucare  
                    //当前entry1发射，因此entry2-7都会向下移
                    //entry2-7 update
                    for(i=2;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end
                    end
                end
                8'bzzzz_z100:begin//entry2 发射
                //分别讨论他下面的每一个entry是否是valid，如果是valid再看会不会shift,然后再选择bypass buffer更新的位置
                    ///更新lsq entry1的bypass内容
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[2])begin
                            if(Shift_En[0])begin//如果1->0shift,那么bypass内容卸载entry0中，否则写在entry1
                                //把新的bypas 信息写在空的位置里
                                //如果有的entry bypass valid已经是1，那么按序往下传即可
                                //写入时永远先往0里写，如果满了再往1里写
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[2];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[2];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[2];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[2];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[2];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[2];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[2];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                end
                            end
                        end else begin//如果指令不是sw, 没有bypass,但是entry写需要根据flush进行update
                            if(Shift_En[0])begin
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                //////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                /////////////////////////////////////
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                            end else begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];    
                            end
                        end
                    end
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[2])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[2];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[2];
                                //////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[2];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[2];
                                //////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[2];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[2];
                                //////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            end
                        end else begin
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                        end
                    end
                    //entry2发射，所以3-7下移
                    //entry3-7 update
                    for(i=3;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end
                    end
                end
                8'bzzzz_1000:begin//entry3发射
                    //先看entry2
                    if(Valid_AfterFlush[2]&&LSQ_Opcode[2])begin
                        if(!LSQ_Opcode[3])begin
                            if(Shift_En[1])begin
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[3];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[3];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[3];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[3];
                                    ////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[3];
                                    ////////////////////////////////
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else begin
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[3];
                                    ////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                end
                            end
                        end else begin
                            if(Shift_En[1])begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                            end else begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                            end
                        end
                    end
                    
                    //entry1
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[3])begin
                            if(Shift_En[0])begin
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[3];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    ///////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[3];
                                    ///////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[3];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[3];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[3];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[3];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[3];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                end
                            end
                        end else begin
                            if(Shift_En[0])begin
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                ///////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                ///////////////////////////////////////////
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                            end else begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                            end
                        end
                    end
                    
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[3])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[3];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[3];
                                //////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[3];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[3];
                                //////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[3];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[3];
                                //////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            end
                        end else begin
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                        end
                    end
                    //entry4-7 update
                    for(i=4;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end
                    end
                    
                end
                8'bzzz1_0000:begin//entry4发射
                    //先看entry3
                    if(Valid_AfterFlush[3]&&LSQ_Opcode[3])begin
                        if(!LSQ_Opcode[4])begin
                            if(Shift_En[2])begin
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[4];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[4];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[4];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[4];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[4];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                end else begin
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[4];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                end
                            end
                        end else begin
                            if(Shift_En[2])begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                //////////////////////////////////////
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                //////////////////////////////////////
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                            end else begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                            end
                        end
                    end
                    
                    //entry2
                    if(Valid_AfterFlush[2]&&LSQ_Opcode[2])begin
                        if(!LSQ_Opcode[4])begin
                            if(Shift_En[1])begin
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[4];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[4];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[4];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[4];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[4];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else begin
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[4];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                end
                            end
                        end else begin
                            if(Shift_En[1])begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                            end else begin
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                            end
                        end
                    end
                    
                    //entry1
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[4])begin
                            if(Shift_En[0])begin
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[4];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[4];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[4];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[4];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[4];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[4];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                end
                            end
                        end else begin
                            if(Shift_En[0])begin
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                /////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                            end else begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                            end
                        end
                    end
                    
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[4])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[4];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[4];
                                /////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[4];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[4];
                                /////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[4];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[4];
                                /////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            end
                        end
                    end
                    //entry5-7 update
                    for(i=5;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end
                    end
                    
                end
                8'bzz10_0000:begin//entry5发射
                    //先看entry4
                    if(Valid_AfterFlush[4]&&LSQ_Opcode[4])begin
                        if(!LSQ_Opcode[5])begin
                            if(Shift_En[3])begin
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[5];
                                    ////////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[5];
                                    ////////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[5];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[4][0]<=1'b1;
                                    ByPass_SW_RobTag[4][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[4][0]<=LSQ_Addr[5];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    ByPass_SW_Valid[4][1]<=1'b1;
                                    ByPass_SW_RobTag[4][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[4][1]<=LSQ_Addr[5];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else begin
                                    ByPass_SW_Valid[4][2]<=1'b1;
                                    ByPass_SW_RobTag[4][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[4][2]<=LSQ_Addr[5];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                end
                            end
                        end else begin
                            if(Shift_En[3])begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                 ////////////////////////////////////////////
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                            end else begin
                                ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                            end
                        end
                    end
                    
                    //entry3
                    if(Valid_AfterFlush[3]&&LSQ_Opcode[3])begin
                        if(!LSQ_Opcode[5])begin
                            if(Shift_En[2])begin
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[5];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[5];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[5];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[5];
                                    ///////////////////////////
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[5];
                                    ///////////////////////////
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                end else begin
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[5];
                                    ///////////////////////////
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                end
                            end
                        end else begin
                            if(Shift_En[2])begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                 //////////////////////////////////////////
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                            end else begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                            end
                        end
                    end
                    
                    //entry2
                    if(Valid_AfterFlush[2]&&LSQ_Opcode[2])begin
                        if(!LSQ_Opcode[5])begin
                            if(Shift_En[1])begin
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[5];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[5];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[5];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[5];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[5];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                end else begin
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[5];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                end
                            end
                        end else begin
                            if(Shift_En[1])begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                            end else begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                            end
                        end
                    end
                    
                    //entry1
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[5])begin
                            if(Shift_En[0])begin
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[5];
                                    //////////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[5];
                                    //////////////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[5];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[5];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[4];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[4];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[4];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[4];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                end
                            end
                        end else begin
                            if(Shift_En[0])begin
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                //////////////////////////////////////////////
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                            end else begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                            end
                        end
                    end
                    
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[5])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[5];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[5];
                                ///////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[5];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[5];
                                ///////////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[5];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[5];
                                ///////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            end
                        end else begin
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                        end
                    end
                    
                    //entry6-7 update
                    for(i=6;i<8;i=i+1)begin
                        ByPass_SW_Valid[i-1]<=ByPass_Valid_AfterFlush[i];
                        for(j=0;j<3;j=j+1)begin
                            ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                            ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                        end
                    end
                end
                8'bz100_0000:begin//发射entry6
                    //先看entry5
                    if(Valid_AfterFlush[5]&&LSQ_Opcode[5])begin
                        if(!LSQ_Opcode[6])begin
                            if(Shift_En[4])begin
                                if(!ByPass_SW_Valid[5][0])begin
                                    ByPass_SW_Valid[4][0]<=1'b1;
                                    ByPass_SW_RobTag[4][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][0]<=LSQ_Addr[6];
                                    ///////////////////////////////////////
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                    ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                    ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                    ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                                    //bypass counter entry2更新
                                end else if(!ByPass_SW_Valid[5][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                    ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[4][1]<=1'b1;
                                    ByPass_SW_RobTag[4][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][1]<=LSQ_Addr[6];
                                    ///////////////////////////////////////
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                    ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                    ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                    ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                    ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[4][2]<=1'b1;
                                    ByPass_SW_RobTag[4][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][2]<=LSQ_Addr[6];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[5][0])begin
                                    ByPass_SW_Valid[5][0]<=1'b1;
                                    ByPass_SW_RobTag[5][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[5][0]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                                end else if(!ByPass_SW_Valid[5][1])begin
                                    ByPass_SW_Valid[5][1]<=1'b1;
                                    ByPass_SW_RobTag[5][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[5][1]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                                end else begin
                                    ByPass_SW_Valid[5][2]<=1'b1;
                                    ByPass_SW_RobTag[5][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[5][2]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                end
                            end
                        end else begin
                            if(Shift_En[4])begin
                                ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                ///////////////////////////////////////
                                ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                            end else begin
                                ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                            end
                        end
                    end
                    
                    //entry4
                    if(Valid_AfterFlush[4]&&LSQ_Opcode[4])begin
                       if(!LSQ_Opcode[6])begin
                            if(Shift_En[3])begin
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[6];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[4][0]<=1'b1;
                                    ByPass_SW_RobTag[4][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][0]<=LSQ_Addr[6];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    ByPass_SW_Valid[4][1]<=1'b1;
                                    ByPass_SW_RobTag[4][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][1]<=LSQ_Addr[6];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else begin
                                    ByPass_SW_Valid[4][2]<=1'b1;
                                    ByPass_SW_RobTag[4][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[4][2]<=LSQ_Addr[6];
                                    ///////////////////////////////////
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                end
                            end
                        end else begin
                            if(Shift_En[3])begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                ////////////////////////////////////////////////////
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                            end else begin
                                ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                            end
                        end
                    end
                    
                    //entry3
                    if(Valid_AfterFlush[3]&&LSQ_Opcode[3])begin
                        if(!LSQ_Opcode[6])begin
                            if(Shift_En[2])begin
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[6];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[6];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                end else begin
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                end
                            end
                        end else begin
                            if(Shift_En[2])begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                 /////////////////////////////////////
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                            end else begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                            end
                        end
                    end
                    
                    //entry2
                    if(Valid_AfterFlush[2]&&LSQ_Opcode[2])begin
                        if(!LSQ_Opcode[6])begin
                            if(Shift_En[1])begin
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[6];
                                    //////////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[6];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[6];
                                    /////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[6];
                                    /////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                end else begin
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[6];
                                    /////////////////////////////////
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                end
                            end
                        end else begin
                            if(Shift_En[1])begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                //////////////////////////////////////////
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                            end else begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                            end
                        end
                    end
                    
                    //entry1
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[6])begin
                            if(Shift_En[0])begin
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[6];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[6];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[6];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[6];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[6];
                                    ////////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                end
                            end
                        end
                    end
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[6])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[6];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[6];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[6];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[6];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[6];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[6];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            end
                        end  else begin
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                        end
                    end
                    
                    //entry7->6
                    ByPass_SW_Valid[6]<=ByPass_Valid_AfterFlush[7];
                    for(j=0;j<3;j=j+1)begin
                        ByPass_SW_RobTag[6][j]<=ByPass_SW_RobTag[7][j];
                        ByPass_SW_Addr[6][j]<=ByPass_SW_Addr[7][j];
                    end
                end
                8'b1000_0000:begin
                    //先看entry6
                    if(Valid_AfterFlush[6]&&LSQ_Opcode[6])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[5])begin
                                if(!ByPass_SW_Valid[6][0])begin
                                    ByPass_SW_Valid[5][0]<=1'b1;
                                    ByPass_SW_RobTag[5][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][0]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[6][2];
                                    ByPass_SW_RobTag[5][2]<=ByPass_SW_RobTag[6][2];
                                    ByPass_SW_Addr[5][2]<=ByPass_SW_Addr[6][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[6][1];
                                    ByPass_SW_RobTag[5][1]<=ByPass_SW_RobTag[6][1];
                                    ByPass_SW_Addr[5][1]<=ByPass_SW_Addr[6][1];
                                end else if(!ByPass_SW_Valid[6][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[6][0];
                                    ByPass_SW_RobTag[5][0]<=ByPass_SW_RobTag[6][0];
                                    ByPass_SW_Addr[5][0]<=ByPass_SW_Addr[6][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[5][1]<=1'b1;
                                    ByPass_SW_RobTag[5][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][1]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[6][2];
                                    ByPass_SW_RobTag[5][2]<=ByPass_SW_RobTag[6][2];
                                    ByPass_SW_Addr[5][2]<=ByPass_SW_Addr[6][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[6][0];
                                    ByPass_SW_RobTag[5][0]<=ByPass_SW_RobTag[6][0];
                                    ByPass_SW_Addr[5][0]<=ByPass_SW_Addr[6][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[6][1];
                                    ByPass_SW_RobTag[5][1]<=ByPass_SW_RobTag[6][1];
                                    ByPass_SW_Addr[5][1]<=ByPass_SW_Addr[6][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[5][2]<=1'b1;
                                    ByPass_SW_RobTag[5][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[6][0])begin
                                    ByPass_SW_Valid[6][0]<=1'b1;
                                    ByPass_SW_RobTag[6][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[6][0]<=LSQ_Addr[7];
                                    ///////////////////////////////////////////////
                                    ByPass_SW_Valid[6][1]<=ByPass_Valid_AfterFlush[6][1];
                                    ByPass_SW_Valid[6][2]<=ByPass_Valid_AfterFlush[6][2];
                                end else if(!ByPass_SW_Valid[6][1])begin
                                    ByPass_SW_Valid[6][1]<=1'b1;
                                    ByPass_SW_RobTag[6][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[6][1]<=LSQ_Addr[7];
                                    ///////////////////////////////////////////////
                                    ByPass_SW_Valid[6][0]<=ByPass_Valid_AfterFlush[6][0];
                                    ByPass_SW_Valid[6][2]<=ByPass_Valid_AfterFlush[6][2];
                                end else begin
                                    ByPass_SW_Valid[6][2]<=1'b1;
                                    ByPass_SW_RobTag[6][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[6][2]<=LSQ_Addr[7];
                                    ///////////////////////////////////////////////
                                    ByPass_SW_Valid[6][1]<=ByPass_Valid_AfterFlush[6][1];
                                    ByPass_SW_Valid[6][0]<=ByPass_Valid_AfterFlush[6][0];
                                end
                            end
                        end else begin
                            if(Shift_En[5])begin
                                ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[6][0];
                                ByPass_SW_RobTag[5][0]<=ByPass_SW_RobTag[6][0];
                                ByPass_SW_Addr[5][0]<=ByPass_SW_Addr[6][0];
                                /////////////////////////////////////////
                                ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[6][2];
                                ByPass_SW_RobTag[5][2]<=ByPass_SW_RobTag[6][2];
                                ByPass_SW_Addr[5][2]<=ByPass_SW_Addr[6][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[6][1];
                                ByPass_SW_RobTag[5][1]<=ByPass_SW_RobTag[6][1];
                                ByPass_SW_Addr[5][1]<=ByPass_SW_Addr[6][1];
                            end else begin
                                ByPass_SW_Valid[6][0]<=ByPass_Valid_AfterFlush[6][0];
                                ByPass_SW_Valid[6][1]<=ByPass_Valid_AfterFlush[6][1];
                                ByPass_SW_Valid[6][2]<=ByPass_Valid_AfterFlush[6][2];
                            end
                        end
                    end
                
                    //entry5
                    if(Valid_AfterFlush[5]&&LSQ_Opcode[5])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[4])begin
                                if(!ByPass_SW_Valid[5][0])begin
                                    ByPass_SW_Valid[4][0]<=1'b1;
                                    ByPass_SW_RobTag[4][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][0]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                    ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                    ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                    ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                                end else if(!ByPass_SW_Valid[5][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                    ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[4][1]<=1'b1;
                                    ByPass_SW_RobTag[4][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][1]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                    ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                    ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                    ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                    ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[4][2]<=1'b1;
                                    ByPass_SW_RobTag[4][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[5][0])begin
                                    ByPass_SW_Valid[5][0]<=1'b1;
                                    ByPass_SW_RobTag[5][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][0]<=LSQ_Addr[7];
                                    ////////////////////////////////////
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                                end else if(!ByPass_SW_Valid[5][1])begin
                                    ByPass_SW_Valid[5][1]<=1'b1;
                                    ByPass_SW_RobTag[5][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][1]<=LSQ_Addr[7];
                                    ////////////////////////////////////
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                    ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                                end else begin
                                    ByPass_SW_Valid[5][2]<=1'b1;
                                    ByPass_SW_RobTag[5][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[5][2]<=LSQ_Addr[7];
                                    ////////////////////////////////////
                                    ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                    ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                end
                            end
                        end else begin
                            if(Shift_En[4])begin
                                ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[5][0];
                                ByPass_SW_RobTag[4][0]<=ByPass_SW_RobTag[5][0];
                                ByPass_SW_Addr[4][0]<=ByPass_SW_Addr[5][0];
                                /////////////////////////////////////////
                                ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[5][2];
                                ByPass_SW_RobTag[4][2]<=ByPass_SW_RobTag[5][2];
                                ByPass_SW_Addr[4][2]<=ByPass_SW_Addr[5][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[5][1];
                                ByPass_SW_RobTag[4][1]<=ByPass_SW_RobTag[5][1];
                                ByPass_SW_Addr[4][1]<=ByPass_SW_Addr[5][1];
                            end else begin
                                ByPass_SW_Valid[5][0]<=ByPass_Valid_AfterFlush[5][0];
                                ByPass_SW_Valid[5][1]<=ByPass_Valid_AfterFlush[5][1];
                                ByPass_SW_Valid[5][2]<=ByPass_Valid_AfterFlush[5][2];
                            end
                        end
                    end
                    
                    //entry4
                    if(Valid_AfterFlush[4]&&LSQ_Opcode[4])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[3])begin
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                    ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                    ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                    ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                    ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[4][0])begin
                                    ByPass_SW_Valid[4][0]<=1'b1;
                                    ByPass_SW_RobTag[4][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][0]<=LSQ_Addr[7];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else if(!ByPass_SW_Valid[4][1])begin
                                    ByPass_SW_Valid[4][1]<=1'b1;
                                    ByPass_SW_RobTag[4][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][1]<=LSQ_Addr[7];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                    ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                                end else begin
                                    ByPass_SW_Valid[4][2]<=1'b1;
                                    ByPass_SW_RobTag[4][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[4][2]<=LSQ_Addr[7];
                                    /////////////////////////////////////
                                    ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                    ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                end
                            end
                        end else begin
                            if(Shift_En[3])begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_RobTag[3][0]<=ByPass_SW_RobTag[4][0];
                                ByPass_SW_Addr[3][0]<=ByPass_SW_Addr[4][0];
                                //////////////////////////////////////
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[4][2];
                                ByPass_SW_RobTag[3][2]<=ByPass_SW_RobTag[4][2];
                                ByPass_SW_Addr[3][2]<=ByPass_SW_Addr[4][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_RobTag[3][1]<=ByPass_SW_RobTag[4][1];
                                ByPass_SW_Addr[3][1]<=ByPass_SW_Addr[4][1];
                            end else begin
                                ByPass_SW_Valid[4][0]<=ByPass_Valid_AfterFlush[4][0];
                                ByPass_SW_Valid[4][1]<=ByPass_Valid_AfterFlush[4][1];
                                ByPass_SW_Valid[4][2]<=ByPass_Valid_AfterFlush[4][2];
                            end
                        end
                    end
                    
                    //entry3
                    if(Valid_AfterFlush[3]&&LSQ_Opcode[3])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[2])begin
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[7];
                                    /////////////////////////////////////////
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                    ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                    ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                    ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                    ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[3][0])begin
                                    ByPass_SW_Valid[3][0]<=1'b1;
                                    ByPass_SW_RobTag[3][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][0]<=LSQ_Addr[7];
                                    ///////////////////////////////////////
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                end else if(!ByPass_SW_Valid[3][1])begin
                                    ByPass_SW_Valid[3][1]<=1'b1;
                                    ByPass_SW_RobTag[3][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][1]<=LSQ_Addr[7];
                                    ///////////////////////////////////////
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                    ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                                end else begin
                                    ByPass_SW_Valid[3][2]<=1'b1;
                                    ByPass_SW_RobTag[3][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[3][2]<=LSQ_Addr[7];
                                    ///////////////////////////////////////
                                    ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                    ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                end
                            end
                        end else begin
                            if(Shift_En[2])begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_RobTag[2][0]<=ByPass_SW_RobTag[3][0];
                                ByPass_SW_Addr[2][0]<=ByPass_SW_Addr[3][0];
                                /////////////////////////////////////////
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[3][2];
                                ByPass_SW_RobTag[2][2]<=ByPass_SW_RobTag[3][2];
                                ByPass_SW_Addr[2][2]<=ByPass_SW_Addr[3][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_RobTag[2][1]<=ByPass_SW_RobTag[3][1];
                                ByPass_SW_Addr[2][1]<=ByPass_SW_Addr[3][1];
                            end else begin
                                ByPass_SW_Valid[3][0]<=ByPass_Valid_AfterFlush[3][0];
                                ByPass_SW_Valid[3][1]<=ByPass_Valid_AfterFlush[3][1];
                                ByPass_SW_Valid[3][2]<=ByPass_Valid_AfterFlush[3][2];
                            end
                        end
                    end
                    
                    //entry2
                    if(Valid_AfterFlush[2]&&LSQ_Opcode[2])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[1])begin
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                    ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                    ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                    ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                    ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[2][0])begin
                                    ByPass_SW_Valid[2][0]<=1'b1;
                                    ByPass_SW_RobTag[2][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][0]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else if(!ByPass_SW_Valid[2][1])begin
                                    ByPass_SW_Valid[2][1]<=1'b1;
                                    ByPass_SW_RobTag[2][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][1]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                    ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                                end else begin
                                    ByPass_SW_Valid[2][2]<=1'b1;
                                    ByPass_SW_RobTag[2][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[2][2]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                    ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                end
                            end
                        end else begin
                            if(Shift_En[1])begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_RobTag[1][0]<=ByPass_SW_RobTag[2][0];
                                ByPass_SW_Addr[1][0]<=ByPass_SW_Addr[2][0];
                                //////////////////////////////////////
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[2][2];
                                ByPass_SW_RobTag[1][2]<=ByPass_SW_RobTag[2][2];
                                ByPass_SW_Addr[1][2]<=ByPass_SW_Addr[2][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_RobTag[1][1]<=ByPass_SW_RobTag[2][1];
                                ByPass_SW_Addr[1][1]<=ByPass_SW_Addr[2][1];
                            end else begin
                                ByPass_SW_Valid[2][0]<=ByPass_Valid_AfterFlush[2][0];
                                ByPass_SW_Valid[2][1]<=ByPass_Valid_AfterFlush[2][1];
                                ByPass_SW_Valid[2][2]<=ByPass_Valid_AfterFlush[2][2];
                            end
                        end
                    end
                    
                    //entry1
                    if(Valid_AfterFlush[1]&&LSQ_Opcode[1])begin
                        if(!LSQ_Opcode[7])begin
                            if(Shift_En[0])begin
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[0][0]<=1'b1;
                                    ByPass_SW_RobTag[0][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[0][0]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    ///////////////////////
                                    ByPass_SW_Valid[0][1]<=1'b1;
                                    ByPass_SW_RobTag[0][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[0][1]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                    ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                    ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                end else begin//ByPass_SW_Valid[1]=0
                                    //bypass counter entry0更新
                                    ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                    ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                    //bypass counter entry1更新
                                    ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                    ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                                    //bypass counter entry2更新
                                    ByPass_SW_Valid[0][2]<=1'b1;
                                    ByPass_SW_RobTag[0][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[0][2]<=LSQ_Addr[7];
                                end
                            end else begin//不发生shift,则原地更新
                                if(!ByPass_SW_Valid[1][0])begin
                                    ByPass_SW_Valid[1][0]<=1'b1;
                                    ByPass_SW_RobTag[1][0]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][0]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else if(!ByPass_SW_Valid[1][1])begin
                                    ByPass_SW_Valid[1][1]<=1'b1;
                                    ByPass_SW_RobTag[1][1]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][1]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                    ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                                end else begin
                                    ByPass_SW_Valid[1][2]<=1'b1;
                                    ByPass_SW_RobTag[1][2]<=LSQ_RobTag[7];
                                    ByPass_SW_Addr[1][2]<=LSQ_Addr[7];
                                    //////////////////////////////////////
                                    ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                    ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                end
                            end
                        end else begin
                            if(Shift_En[0])begin
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_RobTag[0][0]<=ByPass_SW_RobTag[1][0];
                                ByPass_SW_Addr[0][0]<=ByPass_SW_Addr[1][0];
                                //////////////////////////////////////
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[1][2];
                                ByPass_SW_RobTag[0][2]<=ByPass_SW_RobTag[1][2];
                                ByPass_SW_Addr[0][2]<=ByPass_SW_Addr[1][2];
                                //bypass counter entry1更新
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_RobTag[0][1]<=ByPass_SW_RobTag[1][1];
                                ByPass_SW_Addr[0][1]<=ByPass_SW_Addr[1][1];
                            end else begin
                                ByPass_SW_Valid[1][0]<=ByPass_Valid_AfterFlush[1][0];
                                ByPass_SW_Valid[1][1]<=ByPass_Valid_AfterFlush[1][1];
                                ByPass_SW_Valid[1][2]<=ByPass_Valid_AfterFlush[1][2];
                            end
                        end
                    end
                    
                    ///////////////////////////////
                    ///更新lsq entry0的bypass内容
                    if(Valid_AfterFlush[0]&&LSQ_Opcode[0])begin
                        if(!LSQ_Opcode[7])begin
                            if(!ByPass_SW_Valid[0][0])begin
                                ByPass_SW_Valid[0][0]<=1'b1;
                                ByPass_SW_RobTag[0][0]<=LSQ_RobTag[7];
                                ByPass_SW_Addr[0][0]<=LSQ_Addr[7];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][1])begin
                                ByPass_SW_Valid[0][1]<=1'b1;
                                ByPass_SW_RobTag[0][1]<=LSQ_RobTag[7];
                                ByPass_SW_Addr[0][1]<=LSQ_Addr[7];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                                ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            end else if(!ByPass_SW_Valid[0][2])begin//ByPass_SW_Valid[1]=0
                                ByPass_SW_Valid[0][2]<=1'b1;
                                ByPass_SW_RobTag[0][2]<=LSQ_RobTag[7];
                                ByPass_SW_Addr[0][2]<=LSQ_Addr[7];
                                ////////////////////////////////////////
                                ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                                ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                            end
                        end else begin
                            ByPass_SW_Valid[0][2]<=ByPass_Valid_AfterFlush[0][2];
                            ByPass_SW_Valid[0][1]<=ByPass_Valid_AfterFlush[0][1];
                            ByPass_SW_Valid[0][0]<=ByPass_Valid_AfterFlush[0][0];
                        end
                    end
                end
                default:begin//没有东西issue时，只需要考虑shift和flush即可
                    for(i=1;i<8;i=i+1)begin
                        if(Shift_En[i-1])begin
                            for(j=0;j<3;j=j+1)begin
                                ByPass_SW_Valid[i-1][j]<=ByPass_Valid_AfterFlush[i][j];
                                ByPass_SW_RobTag[i-1][j]<=ByPass_SW_RobTag[i][j];
                                ByPass_SW_Addr[i-1][j]<=ByPass_SW_Addr[i][j];
                            end
                        end else begin
                            for(j=0;j<3;j=j+1)begin
                                ByPass_SW_Valid[i-1][j]<=ByPass_Valid_AfterFlush[i][j];
                            end
                        end
                    end
                end
            endcase
        end
    end
    ///////////////////////////////////////////////////////////////////////
    SAB Store_Address_Buffer(
        .Clk(Clk),
        .Resetb(Resetb),
        .AddrBuffFull(SAB_Full),//buffer full
        .AddrMatch0(AddrMatch[0]),//each entry of LSQ will compare with all entries of SAB
        .AddrMatch1(AddrMatch[1]),
        .AddrMatch2(AddrMatch[2]),
        .AddrMatch3(AddrMatch[3]),
        .AddrMatch4(AddrMatch[4]),
        .AddrMatch5(AddrMatch[5]),
        .AddrMatch6(AddrMatch[6]),
        .AddrMatch7(AddrMatch[7]),
        .AddrMatch0Num(AddrMatchNum[0]),
        .AddrMatch1Num(AddrMatchNum[1]),
        .AddrMatch2Num(AddrMatchNum[2]),
        .AddrMatch3Num(AddrMatchNum[3]),
        .AddrMatch4Num(AddrMatchNum[4]),
        .AddrMatch5Num(AddrMatchNum[5]),
        .AddrMatch6Num(AddrMatchNum[6]),
        .AddrMatch7Num(AddrMatchNum[7]),
        .ScanAddr0(ScanAddr[0]),
        .ScanAddr1(ScanAddr[1]),
        .ScanAddr2(ScanAddr[2]),
        .ScanAddr3(ScanAddr[3]),
        .ScanAddr4(ScanAddr[4]),
        .ScanAddr5(ScanAddr[5]),
        .ScanAddr6(ScanAddr[6]),
        .ScanAddr7(ScanAddr[7]),
        .LsqSwAddr(LsqSwAddr),
        .SWAddr_Valid(!Iss_LdStOpcode&&Iss_LdStReady),
        .Cdb_Flush(Cdb_Flush),
        .Rob_TopPtr(Rob_TopPtr),
        .Cdb_RobDepth(Cdb_RobDepth),
        .SB_FlushSw(SB_FlushSw),
        .SB_FlushSwTag(SB_FlushSwTag),
        .SBTag_counter(SBTag_counter),
        //Interface with ROB
        .Rob_CommitMemWrite(Rob_CommitMemWrite)

    );
endmodule