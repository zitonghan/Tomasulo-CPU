`timescale 1ps/1ps
module Divider(
    input Clk,
    input Resetb,
    input [31:0] PhyReg_DivRsData,
    input [31:0] PhyReg_DivRtData,
    input [4:0] Iss_RobTag,
    input Iss_Div,
    output reg [5:0] Div_RdPhyAddr,//
    output reg Div_RdWrite,//register
    input [5:0] Iss_RdPhyAddr,// incoming form issue queue, need to be carried as Iss_RobTag
    input Iss_RdWrite,//用于当指令到达cdb时，只有是regwrite的指令，才有资格帮助junior
    input  Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth,
    output Div_Done,//告知cdb,自己算好结果了
    output reg [4:0] Div_RobTag,
    output [31:0] Div_Rddata,//{reminder, quotient}
    output Div_ExeRdy//通知issue unit，当前时钟可以schedule 新的div指令
);
    integer i;
    reg [15:0] Quotient, Reminder;
    ///////////////////////////////////////
    //16 bit divider
    //7-clock divider with a input register
    //重点：为什么需要input register？
    //因为当iss_div激活时，此时发送指令的entry会release，那么下一个时钟，issue queue的输出端口会变化，但是divider不是pipelined，因此我们只能有一个input register来保持当前正在处理的data的数据
    //因此当前正在进行的除法需要考虑cdb flush的问题
    reg [5:0] Div_Valid;//总共6个reg,因为div需要一个input reg，同时计算需要6个clock,需要5个reg
    reg [15:0] Dividend, Divisor;
    ///////////////////////
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            Div_Valid<='b0;
            Div_RobTag<='bx;
            Dividend<='bx;
            Divisor<='bx;
            Div_RdPhyAddr<='bx;
            Div_RdWrite<='bx;
        end else begin
            Div_Valid<={Div_Valid[4:0],Iss_Div};//只要issue就不会被cdb flush
            if(Cdb_Flush&&Div_RobTag-Rob_TopPtr>Cdb_RobDepth)begin
                Div_Valid[5:1]<='b0;
                //valid[0]的更新由issue queue控制，因此flush发生时，只需要将正在进行中的valid bit清零即可。
            end
            /////////////////////////////////////
            //the input register will accept the input only if iss_div is activated
            if(Iss_Div)begin
                Div_RobTag<=Iss_RobTag;
                Dividend<=PhyReg_DivRsData[15:0];
                Divisor<=PhyReg_DivRtData[15:0];
                Div_RdPhyAddr<=Iss_RdPhyAddr;
                Div_RdWrite<=Iss_RdWrite;
            end
        end
    end
    ///////////////////////////////////////////////////////////
    //division combinational logic
    always@(*)begin
        if(Divisor==0)begin//重点：illegal input divisor
            Quotient=16'hffff;
            Reminder=16'hffff;
        end else begin
            Reminder=0;
            for(i=0;i<16;i=i+1)begin
                Reminder=Reminder<<1;
                Reminder={Reminder[15:1],Dividend[15-i]};
                if(Reminder>=Divisor)begin
                    Quotient[15-i]=1'b1;
                    Reminder=Reminder-Divisor;
                end else begin
                    Quotient[15-i]=1'b0;
                    Reminder=Reminder;
                end
            end
        end
        
    end
    /////////////////////////////////////////////
    assign Div_Rddata={Reminder, Quotient};
    assign Div_Done=Div_Valid[5]&&(!Cdb_Flush||Cdb_Flush&&Div_RobTag-Rob_TopPtr<Cdb_RobDepth);
    //当数值已经到达最后一个clock并且当前没有flush发生，或者没有flush掉当前正在处理的div，那么激活done信号
    assign Div_ExeRdy=Div_Done||(|Div_Valid&&Cdb_Flush&&Div_RobTag-Rob_TopPtr>Cdb_RobDepth)||!(|Div_Valid);
    //重点：什么时候告知issue unit可以允许下一个div的发射？
    //当指令已经到达最后一个clock并且有效时，或者当前divider中有有效的指令，但是flush发生，而当前正在处理的指令被flush
    //那么下一个clock时，valid[0]由iss——div更新，而【5:1】全部为零。
    //又或者当前是空闲的
endmodule