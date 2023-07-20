`timescale 1ps/1ps
module SAB(
    input Clk,
    input Resetb,
    output AddrBuffFull,//buffer full
    output AddrMatch0,//each entry of LSQ will compare with all entries of SAB
    output AddrMatch1,
    output AddrMatch2,
    output AddrMatch3,
    output AddrMatch4,
    output AddrMatch5,
    output AddrMatch6,
    output AddrMatch7,

    output reg [2:0] AddrMatch0Num,//used to indicate when the lw in LSQ could leave
    output reg [2:0] AddrMatch1Num,
    output reg [2:0] AddrMatch2Num,
    output reg [2:0] AddrMatch3Num,
    output reg [2:0] AddrMatch4Num,
    output reg [2:0] AddrMatch5Num,
    output reg [2:0] AddrMatch6Num,
    output reg [2:0] AddrMatch7Num,
            
    input [31:0] ScanAddr0,//scan address (address of entries in lsq) --signal from LSQ
    input [31:0] ScanAddr1,
    input [31:0]  ScanAddr2,
    input [31:0] ScanAddr3,
    input [31:0] ScanAddr4,//scan address (address of entries in lsq)
    input [31:0] ScanAddr5,
    input [31:0] ScanAddr6,
    input [31:0] ScanAddr7,

    input [36:0] LsqSwAddr,//ld/sw address 5bit rob tag +32bit address
    input SWAddr_Valid,//indicate current input sw address is valid
    input Cdb_Flush,//misbranch 
    input [4:0] Rob_TopPtr,//calculate depth used for flush
    input [4:0] Cdb_RobDepth,//used to compare with the sw in SAB
    input SB_FlushSw,//flush store 
    input [1:0] SB_FlushSwTag,//provided by sb which is the SB_TAG of the currently leaving sw from SB
    input [1:0] SBTag_counter,//当sw进入store buffer，分配的sb_tag，而上面的信号用于sw离开sb时进行福flush	
    //Interface with ROB
    input Rob_CommitMemWrite
);
    //SAB regsiters
    reg [7:0] BufValid;//valid bit for store word instruction
    reg [31:0] BufAddr [7:0];//sw addr
    reg [4:0] BufROB [7:0];//rob tag
    reg [1:0] BufSBTag [7:0];//store buffer tag, 在sw离开store buffer时会用到
    reg [7:0] BufTagSel;//valid bit for SB tag;
    ///////////////////////////////
    integer i;
    
    //combinational signals
    reg [6:0] Shift_En;
    reg [7:0] Flush, Valid_AfterFlush;
    ////////////////////////
    //当所有enrty都是valid,并且没有被cdb flush，并且当前没有sb flush，那么SAB是真full
    assign AddrBuffFull=(&Valid_AfterFlush)&&!SB_FlushSw;
    //generate flush, valid_afterflush以及shift_en信号
    always@(*)begin
        Flush='b0;//default assignment
        if(Cdb_Flush)begin
            for(i=0;i<8;i=i+1)begin
                if(BufValid[i]&&(BufROB[i]-Rob_TopPtr>Cdb_RobDepth)&&!BufTagSel[i])begin//要flush首先指令必须是有效的，并且还没有进入SB中
                    Flush[i]=1'b1;
                end
            end  
        end
        //////////
        //valid_afterflush
        for(i=0;i<8;i=i+1)begin
           Valid_AfterFlush[i]=BufValid[i]&&!Flush[i];
        end
        //////////////////
        //shift enable signals
        //如果enable=1，表示上面的指令可以向下移
        //location 0变成空的三个原因：
        //1. 指令本来就是空的
        //2。被cdb flush 掉
        //3. 从sb中离开
        ////////////////////////////////
        //重点：这里的shift logic与int queue中有些不同，在int queue中，如果指令想优先于其下方的指令先issue，那么下方的指令一定是
        //not ready的，因此需要考虑这个条件，但是在sb中，sw在rob是按序离开的，那么如果sb tag match,那么其下方一定没有其他sw了
        Shift_En[0]=!Valid_AfterFlush[0]||Valid_AfterFlush[0]&&BufTagSel[0]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[0];//
        Shift_En[1]=Shift_En[0]||!Valid_AfterFlush[1]||Valid_AfterFlush[1]&&BufTagSel[1]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[1];
        Shift_En[2]=Shift_En[1]||!Valid_AfterFlush[2]||Valid_AfterFlush[2]&&BufTagSel[2]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[2];
        Shift_En[3]=Shift_En[2]||!Valid_AfterFlush[3]||Valid_AfterFlush[3]&&BufTagSel[3]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[3];
        Shift_En[4]=Shift_En[3]||!Valid_AfterFlush[4]||Valid_AfterFlush[4]&&BufTagSel[4]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[4];
        Shift_En[5]=Shift_En[4]||!Valid_AfterFlush[5]||Valid_AfterFlush[5]&&BufTagSel[5]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[5];
        Shift_En[6]=Shift_En[5]||!Valid_AfterFlush[6]||Valid_AfterFlush[6]&&BufTagSel[6]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[6];
    end
    ////////////////////////////////////////
    //generate memory address matched number
    always@(*)begin
        AddrMatch0Num=3'd0;
        AddrMatch1Num=3'd0;
        AddrMatch2Num=3'd0;
        AddrMatch3Num=3'd0;
        AddrMatch4Num=3'd0;
        AddrMatch5Num=3'd0;
        AddrMatch6Num=3'd0;
        AddrMatch7Num=3'd0;
        for(i=0;i<8;i=i+1)begin
            if(Valid_AfterFlush[i])begin
                if(BufAddr[i]==ScanAddr0)begin
                    AddrMatch0Num=AddrMatch0Num+1;
                end
                if(BufAddr[i]==ScanAddr1)begin
                    AddrMatch1Num=AddrMatch1Num+1;
                end
                if(BufAddr[i]==ScanAddr2)begin
                    AddrMatch2Num=AddrMatch2Num+1;
                end
                if(BufAddr[i]==ScanAddr3)begin
                    AddrMatch3Num=AddrMatch3Num+1;
                end
                if(BufAddr[i]==ScanAddr4)begin
                    AddrMatch4Num=AddrMatch4Num+1;
                end
                if(BufAddr[i]==ScanAddr5)begin
                    AddrMatch5Num=AddrMatch5Num+1;
                end
                if(BufAddr[i]==ScanAddr6)begin
                    AddrMatch6Num=AddrMatch6Num+1;
                end
                if(BufAddr[i]==ScanAddr7)begin
                    AddrMatch7Num=AddrMatch7Num+1;
                end
            end
        end
    end
    assign AddrMatch0=|AddrMatch0Num;
    assign AddrMatch1=|AddrMatch1Num;
    assign AddrMatch2=|AddrMatch2Num;
    assign AddrMatch3=|AddrMatch3Num;
    assign AddrMatch4=|AddrMatch4Num;
    assign AddrMatch5=|AddrMatch5Num;
    assign AddrMatch6=|AddrMatch6Num;
    assign AddrMatch7=|AddrMatch7Num;

    ////////////////////////////////////////
    //SAB 每一个entry中内容的更新逻辑，需要考虑shift发生和不发生两种情况下，每一个entry应该如何更新
    //很容易引起注意的点是:shift发生时，每一个entry如何更新，但是别忘记了，不移动时，entry也需要更新
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            BufValid<='b0;
            BufTagSel<='bx;//没有必要初始化，当第一条指令写入时会专门写入0，之后下移即可
            for(i=0;i<8;i=i+1)begin
                BufAddr[i]<='bx;
                BufROB[i]<='bx;
                BufSBTag[i]<='bx;
            end
        end else begin
            //valid, SBtag, Tagsel在移动过程中会发生变化，其他内容直接移动即可
            //toppest entry的更新逻辑也单独写
            //重点：存在bug,当前我们只描述了shift发生时valid，tag_sel以及tag如何更新，但是不能移动时，这些内容也会更新
            //因此需要将这部分内容也补齐才可以
            for(i=1;i<8;i=i+1)begin
                if(Shift_En[i-1])begin
                    BufAddr[i-1]<=BufAddr[i];
                    BufROB[i-1]<=BufROB[i];
                    BufValid[i-1]<=Valid_AfterFlush[i]&&!(BufTagSel[i]&&SB_FlushSw&&SB_FlushSwTag==BufSBTag[i]);
                    //指令有效并且当前写入SB的指令在这个entry中，那么将更新的内容写入，否则就将原内容写入即可
                    if(Valid_AfterFlush[i]&&!BufTagSel[i]&&Rob_CommitMemWrite&&Rob_TopPtr==BufROB[i])begin
                        BufTagSel[i-1]<=1'b1;
                        BufSBTag[i-1]<=SBTag_counter;
                    end else begin
                        BufTagSel[i-1]<=BufTagSel[i];
                        BufSBTag[i-1]<= BufSBTag[i];
                    end
                end else begin//如果当前entry[i]不能向下移，但么则原地更新或保持
                //重点：对于validbit而言，如果不能shift，那么首先其下面一层的指令没有移动或消除，并且当前entry中的指令也是有效的，并且没有被flush或者离开，那么保持即可
                //而SBtag以及tagselect信号需要更新
                    if(Valid_AfterFlush[i-1]&&!BufTagSel[i-1]&&Rob_CommitMemWrite&&Rob_TopPtr==BufROB[i-1])begin
                        BufTagSel[i-1]<=1'b1;
                        BufSBTag[i-1]<=SBTag_counter;
                    end else begin
                        BufTagSel[i-1]<=BufTagSel[i-1];
                        BufSBTag[i-1]<= BufSBTag[i-1];
                    end
                end
            end
            //entry 7 update
            if(SWAddr_Valid)begin//只要是valid,就说明没有被flush，因为如果flush,那么lsq会确保不会激活ready issue
                BufValid[7]<=1'b1;
                BufAddr[7]<=LsqSwAddr[31:0];
                BufROB[7]<=LsqSwAddr[36:32];
                BufTagSel[7]<=1'b0;
            end else if(Shift_En[6]) begin//存在rob已经满了的可能，但此时一定没满，entry7原来的内容还是依靠上面的逻辑更新
                BufValid[7]<=1'b0;
                BufTagSel[7]<=1'b0;
            end else if(BufValid[7]) begin//此时entry7可能是空的，如果时空的，那么变没有更新sbtag和sel bit的必要
                BufValid[7]<=Valid_AfterFlush[7];//此时SAB是满的，那么valid的更新自然不用考虑sb flush的原因；
                //下面这种entry7更新sb tag的情况其实是不可能实现的，因为当前SAB是满的，但是sB buffer只有4个位置，显然不可能容纳到这一个sw
                //但是如果SB的大小扩大了，还是有可能的
                if(Valid_AfterFlush[7]&&!BufTagSel[7]&&Rob_CommitMemWrite&&Rob_TopPtr==BufROB[7])begin
                    BufTagSel[7]<=1'b1;
                    BufSBTag[7]<=SBTag_counter;
                end 
            end
        end
    end
endmodule