`timescale 1ps/1ps
module LS_Buffer(
    input Clk,
    input Resetb,
    //  from ROB  -- for fulsinputg the inputstruction input this buffer if appropriate.
    input Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth,
    //inputterface with lsq
    input Iss_LdStReady,//sent from LSQ
    input Iss_LdStOpcode,// 1 = lw , 0 = sw
    input [4:0] Iss_LdStRobTag,
    input [31:0] Iss_LdStAddr,//written into ROB
    input [5:0] Iss_LdStPhyAddr,
    //inputterface with data cache emulator ----------------
    input [5:0] DCE_PhyAddr,
    input DCE_Opcode,
    input [4:0] DCE_RobTag,
    input [31:0] DCE_Addr,
    input [31:0] DCE_MemData,//  data from data memory input the case of lw
    input DCE_ReadDone,// data memory (data cache) reportinputg that read finputished  -- from  ls_buffer_ram_reg_array -- inputstance name DataMem
    input DCE_ReadBusy,
    // output Lsbuf_DCETaken,// handshake signal to ls_queue
    output Lsbuf_Full,// handshake signal to ls_queue
    output Lsbuf_TwoOrMoreVaccant,//useful when current a lw is proessed in the data cache, but another sw want to move forward from the lsq
    //inputterface with issue unit
    //from load buffer and store word
    output Lsbuf_Ready,//sent to issue unit
    //changed as per CDB -------------
    output reg [31:0] Lsbuf_Data,
    output reg [5:0] Lsbuf_PhyAddr,
    output reg [4:0] Lsbuf_RobTag,
    output reg [31:0] Lsbuf_SwAddr,
    output reg Lsbuf_RdWrite,
    ///////////////////////////////////////////////////////////////
    //signals sent from issue unit
    input Iss_Lsb 
);
    integer i;
    //重点：
    //这里的data reg是用来存放lw的data的，sw的data还在register file中
    //4 locations ls buffer
    reg [3:0] LS_Buf_Valid, LS_Buf_Opcode;//valid used for flush and shift
    reg [4:0] LS_Buf_RobTag [3:0];
    reg [31:0] LS_Buf_Addr [3:0];//lw/sw address
    reg [31:0] LS_Buf_Data [3:0];//lw/sw data
    reg [5:0] LS_Buf_PhyAddr [3:0];
    //////////////////////////////////////
    //combinational signls
    reg [3:0] Flush, Valid_AfterFlush;//不需要专门的issue_ready,因为valid即ready
    reg [2:0] Shift_En;
    /////////////////////////////////////
    //重点：当lw去data Cache中取数据的时候，很有可能会出现flush，那么需要计算depth 去将正在读取的lw flush掉
    //这部分功能在data cache中实现，其会产生cache busy信号
    /////////////////////////////////////////////////////////
    assign Lsbuf_Full=(&Valid_AfterFlush)&&!Iss_Lsb;
    assign Lsbuf_TwoOrMoreVaccant=Iss_Lsb?!(&Valid_AfterFlush):(!Valid_AfterFlush[3]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[1]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[1]&&!Valid_AfterFlush[0]);
    assign Lsbuf_Ready=|Valid_AfterFlush;
    /////////////////////////////////////////////////////////
    //generate shift enable and flush signals
    always@(*)begin
        Flush='b0;
        Valid_AfterFlush='b0;
        Shift_En='b0;     
    //default assignment
    ///////////////////////////////////////
        for(i=0;i<4;i=i+1)begin
            if(LS_Buf_Valid[i]&&Cdb_Flush&&(LS_Buf_RobTag[i]-Rob_TopPtr>Cdb_RobDepth))begin
                Flush[i]=1'b1;
            end
            Valid_AfterFlush[i]=LS_Buf_Valid[i]&&!Flush[i];
        end
        //////////////////////
        //generate Shift_en
        Shift_En[0]=!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&Iss_Lsb;//本身是invalid，或者valid被flush，或者valid但是当前时钟离开了lsbuffer
        Shift_En[1]=Shift_En[0]||!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&!Valid_AfterFlush[0]&&Iss_Lsb;
        Shift_En[2]=Shift_En[1]||!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&!Valid_AfterFlush[0]&&Iss_Lsb;
        //////////////////////////////////////////////////
        //generate output result
        casez(Valid_AfterFlush)
            4'bzz10:begin
                Lsbuf_Data=LS_Buf_Data[1];
                Lsbuf_PhyAddr=LS_Buf_PhyAddr[1];
                Lsbuf_RobTag=LS_Buf_RobTag[1];
                Lsbuf_SwAddr=LS_Buf_Addr[1];
                Lsbuf_RdWrite=LS_Buf_Opcode[1]; 
            end
            4'bz100:begin
                Lsbuf_Data=LS_Buf_Data[2];
                Lsbuf_PhyAddr=LS_Buf_PhyAddr[2];
                Lsbuf_RobTag=LS_Buf_RobTag[2];
                Lsbuf_SwAddr=LS_Buf_Addr[2];
                Lsbuf_RdWrite=LS_Buf_Opcode[2]; 
            end
            4'b1000:begin
                Lsbuf_Data=LS_Buf_Data[3];
                Lsbuf_PhyAddr=LS_Buf_PhyAddr[3];
                Lsbuf_RobTag=LS_Buf_RobTag[3];
                Lsbuf_SwAddr=LS_Buf_Addr[3];
                Lsbuf_RdWrite=LS_Buf_Opcode[3]; 
            end
            default:begin
                Lsbuf_Data=LS_Buf_Data[0];
                Lsbuf_PhyAddr=LS_Buf_PhyAddr[0];
                Lsbuf_RobTag=LS_Buf_RobTag[0];
                Lsbuf_SwAddr=LS_Buf_Addr[0];
                Lsbuf_RdWrite=LS_Buf_Opcode[0]; 
            end
        endcase
    end
/////////////////////////////////////////////////////
    //ls buffer entry updating logic including shifted and non-shifted
    //同样先发送最底部的指令
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            LS_Buf_Valid<='b0; 
            LS_Buf_Opcode<='bx;
            for(i=0;i<4;i=i+1)begin
                LS_Buf_RobTag[i]<='bx;
                LS_Buf_Addr[i]<='bx;
                LS_Buf_Data[i]<='bx;
                LS_Buf_PhyAddr[i]<='bx;
            end
        end else begin
            //update entry 0->2
            //这个过程只有valid会发生变化，因此其他信号全部平移即可
            //重点：
            //由于该buffer涉及到先发送最底层的有效指令，而valid在更新时需要考虑自己发送出去的情况，但是这种情况需要考虑到其下方的指令都是无效的
            //因此不适合用for loop写
            for(i=1;i<4;i=i+1)begin
                if(Shift_En[i-1])begin
                    LS_Buf_Opcode[i-1]<=LS_Buf_Opcode[i];
                    LS_Buf_RobTag[i-1]<=LS_Buf_RobTag[i];
                    LS_Buf_Addr[i-1]<=LS_Buf_Addr[i];
                    LS_Buf_Data[i-1]<=LS_Buf_Data[i];
                    LS_Buf_PhyAddr[i-1]<=LS_Buf_PhyAddr[i];
                end//这里不需要考虑shift_en=0的情况，保持即可，因为没有除了valid以外其他需要更新的内容了
            end
            //update valid during shifting
            if(Shift_En[0])begin
                LS_Buf_Valid[0]<=Valid_AfterFlush[1]&&(Valid_AfterFlush[0]||!Valid_AfterFlush[0]&&!Iss_Lsb);
                //什么情况下valid bit会向下移入1？
                //首先自己需要时valid，没有flush,在此基础上又分为两种情况，1，下面的指令也是valid，并且被发送了，2，下面的指令无效，但是当前没有issue信号
            end//当shift=0时，表示当前指令有效，即保持即可
            if(Shift_En[1])begin
                LS_Buf_Valid[1]<=Valid_AfterFlush[2]&&(Valid_AfterFlush[0]||Valid_AfterFlush[1]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[1]&&!Iss_Lsb);
            end
            if(Shift_En[2])begin
                LS_Buf_Valid[2]<=Valid_AfterFlush[3]&&(Valid_AfterFlush[0]||Valid_AfterFlush[1]||Valid_AfterFlush[2]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[1]&&!Valid_AfterFlush[2]&&!Iss_Lsb);
            end
            //////////////////////////////////
            //分为从LSQ中接受SW和DC中接受LW
            //update the toppest entry
            //重点：这部分逻辑需要和LSQ严密配合
            //当当前data cache中有正在处理的lw时，因为我们在lsq中也有一个flag register,用于表明当前data cache正在处理一条lw,
            //此时如果我们在lsq中falg=1但是read done=1的情况下，允许下一个lw发送，虽然这样效率是最高的，但是此时下一个lw从lsq中发出
            //但是此时如果cache hit，当前时钟就会产生read done，那么我们将无法分辨这个read done属于前一个指令还是当前的，因此
            //lsq需要在flag清零后才能发送下一个lw
            if(Iss_LdStReady)begin//只要lsq发送ready， 那么说明指令一定没有被flush,否则不会激活
            //对于valid flag的更新来讲，应该分为两种情况，当flag=1但是read done=0时，lsq仍可以发送sw
                if(!Iss_LdStOpcode)begin//sw,lsq会注意，当lsq发送的是sw时，如果当前ready busy且read done同时激活，则sw根本不会产生ready issue信号，而lw会在ready busy消除之后再发送
                    LS_Buf_Valid[3]<=1'b1;
                    LS_Buf_Opcode[3]<=Iss_LdStOpcode;
                    LS_Buf_RobTag[3]<=Iss_LdStRobTag;
                    LS_Buf_Addr[3]<=Iss_LdStAddr;
                    LS_Buf_PhyAddr[3]<=Iss_LdStPhyAddr;
                end else begin//lw
                //之前设想的是，data cache可以实现cache hit without miss，所以可以直接从lsq读取lw,但是现在这种情况不会再出现了，但是代码保留着也不会影响功能上的正确性
                    if(!DCE_ReadBusy&&DCE_ReadDone)begin//表明新的lw没有发生cache miss
                        LS_Buf_Valid[3]<=1'b1;
                        LS_Buf_Opcode[3]<=Iss_LdStOpcode;
                        LS_Buf_RobTag[3]<=Iss_LdStRobTag;
                        LS_Buf_Addr[3]<=Iss_LdStAddr;
                        LS_Buf_Data[3]<=DCE_MemData;//由于是lw并且read hit,因此数据从cache中取得
                        LS_Buf_PhyAddr[3]<=Iss_LdStPhyAddr;
                    end else if(!DCE_ReadBusy&&!DCE_ReadDone)begin//cache miss
                        //重点：当进入的时lw,但是cache miss时，如果entry3向下移了，那么要在entry3写入0，否则保持即可
                        if(Shift_En[2])begin
                            LS_Buf_Valid[3]<=1'b0;
                        end
                    end
                end
            end else if(DCE_ReadBusy&&DCE_ReadDone)begin//no valid input
                //监视data cache
                LS_Buf_Valid[3]<=1'b1;
                LS_Buf_Opcode[3]<=DCE_Opcode;
                LS_Buf_RobTag[3]<=DCE_RobTag;
                LS_Buf_Addr[3]<=DCE_Addr;
                LS_Buf_Data[3]<=DCE_MemData;
                LS_Buf_PhyAddr[3]<=DCE_PhyAddr;   
            end else if(Shift_En[2])begin//data cache 没有正在处理的lw, lsbuffer有可能是满的
                LS_Buf_Valid[3]<=1'b0;
            end else if(LS_Buf_Valid[3]) begin
                LS_Buf_Valid[3]<=Valid_AfterFlush[3];
            end    
        end
    end
endmodule