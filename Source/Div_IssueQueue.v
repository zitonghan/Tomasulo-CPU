`timescale 1ps/1ps
module Div_IssueQueue(
    input Clk,
    input Resetb,
//Information to be captured from the Write port of Physical Register file
    input [5:0] Cdb_RdPhyAddr,
    input Cdb_PhyRegWrite,
//Information from the Dispatch Unit
    input Dis_Issquenable,
    input Dis_RsDataRdy,
    input Dis_RtDataRdy,
    input Dis_RegWrite,
    input [5:0] Dis_RsPhyAddr,
    input [5:0] Dis_RtPhyAddr,
    input [5:0] Dis_NewRdPhyAddr,
    input [4:0] Dis_RobTag,
    output Issque_DivQueueFull,
    output Issque_DivQueueTwoOrMoreVacant,
// Interface with the Issue Unit
    output IssDiv_Rdy,
    input Iss_Div,
//Interface with the Physical Register File
    output reg [5:0] Iss_RsPhyAddrDiv,
    output reg [5:0] Iss_RtPhyAddrDiv,
//Interface with the Execution unit
    output reg [5:0] Iss_RdPhyAddrDiv,
    output reg [4:0] Iss_RobTagDiv,
    output reg Iss_RegWriteDiv,
//Interface with ROB
    input Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth
);
    integer i;
    //Issue queue 主体
    reg [7:0] IssuequeInstrValReg, IssuequeRegWrite, IssuequeRtReadyReg, IssuequeRsReadyReg;
    reg [5:0] IssuequeRsPhyAddrReg [7:0];
    reg [5:0] IssuequeRtPhyAddrReg [7:0];
    reg [5:0] IssuequeRdPhyAddrReg [7:0];
    reg [4:0] IssuequeRobTag [7:0];
    ////////////////////////////////////////////
    //combinational logic
    reg [7:0] Flush, Valid_AfterFlush, Ready_Issue;
    reg [6:0] Shift_En;
    ////////////////////////////////////////////////////////
    wire Upper4_Full,Lower4_Full, Upper4_2More, Lower4_2More;
    assign Upper4_Full=&Valid_AfterFlush[7:4];
    assign Lower4_Full=&Valid_AfterFlush[3:0];
    assign Upper4_2More=!Valid_AfterFlush[7]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[5]||!Valid_AfterFlush[7]&&!Valid_AfterFlush[4]||!Valid_AfterFlush[5]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[6]||!Valid_AfterFlush[4]&&!Valid_AfterFlush[5];
    assign Lower4_2More=!Valid_AfterFlush[3]&&!Valid_AfterFlush[2]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[3]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[1]||!Valid_AfterFlush[2]&&!Valid_AfterFlush[0]||!Valid_AfterFlush[0]&&!Valid_AfterFlush[1];
    assign Issque_DivQueueTwoOrMoreVacant=!Upper4_Full&&Iss_Div||!Lower4_Full&&Iss_Div||!Upper4_Full&&!Lower4_Full||Lower4_2More||Upper4_2More;
    assign Issque_DivQueueFull=Upper4_Full&&Lower4_Full&&!Iss_Div;
    ///////////////////////////////////////////////////////
    assign IssDiv_Rdy=|Ready_Issue;
    ///////////////////////////////////////////////////////
    //generate above combinational logic signals
    always@(*)begin
        Flush='b0;
        Ready_Issue='b0;
        if(Cdb_Flush)begin
            for(i=0;i<8;i=i+1)begin
                if(IssuequeInstrValReg[i]&&(IssuequeRobTag[i]-Rob_TopPtr>Cdb_RobDepth))begin
                    Flush[i]=1'b1;
                end
            end
        end
        Valid_AfterFlush=IssuequeInstrValReg&(~Flush);
        /////////////////////////////////////////////////////
        //generate ready issue signal
        //重点：事实上ready issue的产生只需要将ready bit逻辑与一下即可，但是readybit并没有进行初始化，因为有效的data实际上都从entry7写入，我只要每次在entry7写入1或0，之后一次下移即可
        //但是这会导致一些entry的ready bit是x,而valid bit的更新在issue 后，会根据ready issue判断当前是否是自己issue，由于x的存在会导致valid更新为x
        //要注意ready issue的产生同样需要受到valid的控制，因为当指令issue时，我们只会清空valid bit,因此之前的readybit会保留下来，可能会造成误解
        for(i=0;i<8;i=i+1)begin
            if(Valid_AfterFlush[i]&&IssuequeRsReadyReg[i]&&IssuequeRtReadyReg[i])begin
                Ready_Issue[i]=1'b1;
            end
        end
        //////////////////////////////////////////////////////
        //generate shift enable signals
        Shift_En[0]=!Valid_AfterFlush[0]||Ready_Issue[0]&&Iss_Div;//valid_afterflush 在产生ready_issue时已经使用，这里就不用了
        Shift_En[1]=Shift_En[0]||!Valid_AfterFlush[1]||Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
        Shift_En[2]=Shift_En[1]||!Valid_AfterFlush[2]||Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
        Shift_En[3]=Shift_En[2]||!Valid_AfterFlush[3]||Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
        Shift_En[4]=Shift_En[3]||!Valid_AfterFlush[4]||Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
        Shift_En[5]=Shift_En[4]||!Valid_AfterFlush[5]||Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
        Shift_En[6]=Shift_En[5]||!Valid_AfterFlush[6]||Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&Iss_Div;
    end
    ////////////////////////////////////
    //entry update logic, 需要更新的内容有validbit， readybit
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            IssuequeInstrValReg<='b0;
            IssuequeRegWrite<='bx; 
            IssuequeRtReadyReg<='bx; 
            IssuequeRsReadyReg<='bx;
            for(i=0;i<8;i=i+1)begin
                IssuequeRsPhyAddrReg[i]<='bx;
                IssuequeRtPhyAddrReg[i]<='bx;
                IssuequeRdPhyAddrReg[i]<='bx;
                IssuequeRobTag[i]<='bx;
            end
        end else begin
            //entry0-6
            for(i=1;i<8;i=i+1)begin
                if(Shift_En[i-1])begin
                    IssuequeRegWrite[i-1]<=IssuequeRegWrite[i]; 
                    IssuequeRsPhyAddrReg[i-1]<=IssuequeRsPhyAddrReg[i];
                    IssuequeRtPhyAddrReg[i-1]<=IssuequeRtPhyAddrReg[i];
                    IssuequeRdPhyAddrReg[i-1]<=IssuequeRdPhyAddrReg[i];
                    IssuequeRobTag[i-1]<=IssuequeRobTag[i];
                    IssuequeRtReadyReg[i-1]<=IssuequeRtReadyReg[i]; 
                    IssuequeRsReadyReg[i-1]<=IssuequeRsReadyReg[i];
                    //update ready bit
                    if(Cdb_PhyRegWrite&&IssuequeRsPhyAddrReg[i]==Cdb_RdPhyAddr)begin
                        IssuequeRsReadyReg[i-1]<=1'b1;
                    end else begin
                        IssuequeRsReadyReg[i-1]<=IssuequeRsReadyReg[i];
                    end
                    if(Cdb_PhyRegWrite&&IssuequeRtPhyAddrReg[i]==Cdb_RdPhyAddr)begin
                        IssuequeRtReadyReg[i-1]<=1'b1;
                    end else begin
                        IssuequeRtReadyReg[i-1]<=IssuequeRtReadyReg[i];
                    end
                end else begin
                    if(Cdb_PhyRegWrite&&IssuequeRsPhyAddrReg[i-1]==Cdb_RdPhyAddr)begin
                        IssuequeRsReadyReg[i-1]<=1'b1;
                    end
                    if(Cdb_PhyRegWrite&&IssuequeRtPhyAddrReg[i-1]==Cdb_RdPhyAddr)begin
                        IssuequeRtReadyReg[i-1]<=1'b1;
                    end
                end
            end
            /////////////////////
            //entry0-6 valid bit update
            if(Shift_En[0])begin
                IssuequeInstrValReg[0]<=Valid_AfterFlush[1]&&(!Ready_Issue[1]||Ready_Issue[1]&&Ready_Issue[0]||Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
             if(Shift_En[1])begin
                IssuequeInstrValReg[1]<=Valid_AfterFlush[2]&&(!Ready_Issue[2]||Ready_Issue[2]&&(Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            if(Shift_En[2])begin
                IssuequeInstrValReg[2]<=Valid_AfterFlush[3]&&(!Ready_Issue[3]||Ready_Issue[3]&&(Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            if(Shift_En[3])begin
                IssuequeInstrValReg[3]<=Valid_AfterFlush[4]&&(!Ready_Issue[4]||Ready_Issue[4]&&(Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            if(Shift_En[4])begin
                IssuequeInstrValReg[4]<=Valid_AfterFlush[5]&&(!Ready_Issue[5]||Ready_Issue[5]&&(Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[5]&&!Ready_Issue[4]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            if(Shift_En[5])begin
                IssuequeInstrValReg[5]<=Valid_AfterFlush[6]&&(!Ready_Issue[6]||Ready_Issue[6]&&(Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            if(Shift_En[6])begin
                IssuequeInstrValReg[6]<=Valid_AfterFlush[7]&&(!Ready_Issue[7]||Ready_Issue[7]&&(Ready_Issue[6]||Ready_Issue[5]||Ready_Issue[4]||Ready_Issue[3]||Ready_Issue[2]||Ready_Issue[1]||Ready_Issue[0])||Ready_Issue[7]&&!Ready_Issue[6]&&!Ready_Issue[5]&&!Ready_Issue[3]&&!Ready_Issue[2]&&!Ready_Issue[1]&&!Ready_Issue[0]&&!Iss_Div);
            end
            ///////////////////////////////////////////////////////
            //entry 7 update
            if(Dis_Issquenable&&!Cdb_Flush||Dis_Issquenable&&Cdb_Flush&&Dis_RobTag-Rob_TopPtr<Cdb_RobDepth)begin
                IssuequeInstrValReg[7]<=1'b1;
                IssuequeRegWrite[7]<=Dis_RegWrite; 
                IssuequeRsPhyAddrReg[7]<=Dis_RsPhyAddr;
                IssuequeRtPhyAddrReg[7]<=Dis_RtPhyAddr;
                IssuequeRdPhyAddrReg[7]<=Dis_NewRdPhyAddr;
                IssuequeRobTag[7]<=Dis_RobTag;
                if(Dis_RsDataRdy||Cdb_PhyRegWrite&&Dis_RsPhyAddr==Cdb_RdPhyAddr)begin
                    IssuequeRsReadyReg[7]<=1'b1;
                end else begin
                    IssuequeRsReadyReg[7]<=1'b0;
                end
                if(Dis_RtDataRdy||Cdb_PhyRegWrite&&Dis_RtPhyAddr==Cdb_RdPhyAddr)begin
                    IssuequeRtReadyReg[7]<=1'b1; 
                end else begin
                    IssuequeRtReadyReg[7]<=1'b0; 
                end
            end else if(Shift_En[6])begin//invalid input or valid but flush
                IssuequeInstrValReg[7]<=1'b0;
                IssuequeRsReadyReg[7]<=1'b0;
                IssuequeRtReadyReg[7]<=1'b0;       
            end else if(IssuequeInstrValReg[7]) begin//如果是满的，更新valid,ready bit
                IssuequeInstrValReg[7]<=Valid_AfterFlush[7];
                if(Cdb_PhyRegWrite&&IssuequeRsPhyAddrReg[7]==Cdb_RdPhyAddr)begin
                    IssuequeRsReadyReg[7]<=1'b1; 
                end
                if(Cdb_PhyRegWrite&&IssuequeRtPhyAddrReg[7]==Cdb_RdPhyAddr)begin
                    IssuequeRtReadyReg[7]<=1'b1; 
                end      
            end
        end
    end
    //////////////////////////////////////////////////////////////
    //select output entry
    always @(*) begin
        casez(Ready_Issue)
            8'bzzzz_zz10:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[1];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[1];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[1];
                Iss_RobTagDiv=IssuequeRobTag[1];
                Iss_RegWriteDiv=IssuequeRegWrite[1];
            end
            8'bzzzz_z100:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[2];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[2];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[2];
                Iss_RobTagDiv=IssuequeRobTag[2];
                Iss_RegWriteDiv=IssuequeRegWrite[2];
            end
            8'bzzzz_1000:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[3];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[3];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[3];
                Iss_RobTagDiv=IssuequeRobTag[3];
                Iss_RegWriteDiv=IssuequeRegWrite[3];
            end
            8'bzzz1_0000:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[4];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[4];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[4];
                Iss_RobTagDiv=IssuequeRobTag[4];
                Iss_RegWriteDiv=IssuequeRegWrite[4];
            end
            8'bzz10_0000:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[5];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[5];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[5];
                Iss_RobTagDiv=IssuequeRobTag[5];
                Iss_RegWriteDiv=IssuequeRegWrite[5];
            end
            8'bz100_0000:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[6];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[6];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[6];
                Iss_RobTagDiv=IssuequeRobTag[6];
                Iss_RegWriteDiv=IssuequeRegWrite[6];
            end
            8'b1000_0000:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[7];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[7];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[7];
                Iss_RobTagDiv=IssuequeRobTag[7];
                Iss_RegWriteDiv=IssuequeRegWrite[7];
            end
            default:begin
                Iss_RsPhyAddrDiv=IssuequeRsPhyAddrReg[0];
                Iss_RtPhyAddrDiv=IssuequeRtPhyAddrReg[0];
                Iss_RdPhyAddrDiv=IssuequeRdPhyAddrReg[0];
                Iss_RobTagDiv=IssuequeRobTag[0];
                Iss_RegWriteDiv=IssuequeRegWrite[0];
            end
        endcase
    end
endmodule