`timescale 1ps/1ps
module Issue_Unit(
    input Clk,
    input Resetb,        
    // ready signals from each of the queues  
    input IssInt_Rdy,
    input IssMul_Rdy,
    input IssDiv_Rdy,
    input IssLsb_Rdy,                   
    // signal from the division execution unit to indicate that it is currently available
    input Div_ExeRdy,//it means the division execution unit can accept a div_request from div_queue
    //issue signals as acknowledgement from issue unit to each of the queues
    output Iss_Int,//decision of issuing instructions from instruction queues into execution unit
    output Iss_Mult,
    output Iss_Div,
    output Iss_Lsb  
);
    reg Arbiter_Grant;
    //since the lw,sw instruciton and integer instruction only takes one clock to finish,
    //when they are both ready issue at the same time, we use the arbiter to balance the conflict
    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    //since the longest div instruction needs seven clock to be executed, we use six valid regsiter to stand for the current status of eac hisntruction from different issue queue
    //So that we can schedule the issue of insctruction without causing structural hazard at the CDB
    reg [5:0] IU_Valid;
    //重点：issue unit中不支持cdb flush,也就是说，当前即使有一条div指令输入的valid1在这几个register间传播，但是这个div在结束之前flush了，那么我们并不会在issue unit将他引入的valid bit
    //清零，因为我们没有办法分辨哪一个是div引起的，哪一个是mul引起的，因此虽然可能会在成一定的性能损失，但是并不会引起错误
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            IU_Valid<='b0;
        end else begin
            IU_Valid[4]<=IU_Valid[5];
            IU_Valid[3]<=IU_Valid[4];
            IU_Valid[1]<=IU_Valid[2];
            IU_Valid[0]<=IU_Valid[1];
            //insert div instruciton
            if(Div_ExeRdy&&IssDiv_Rdy)begin
                IU_Valid[5]<=1'b1;
            end else begin
                IU_Valid[5]<=1'b0;
            end
            ////////////////////////////////
            //insert mul instruciton
            if(IssMul_Rdy&&!IU_Valid[3])begin
               IU_Valid[2]<=1'b1; 
            end else begin
                IU_Valid[2]<=IU_Valid[3];
            end
        end
    end
    //////////////////////////////
    //arbiter grant update
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            Arbiter_Grant<='b0;//default grant for int instruction first
        end else begin
            if(IssInt_Rdy&&IssLsb_Rdy)begin
                Arbiter_Grant<=~Arbiter_Grant;
            end
        end
    end
    /////////////////////////////////////////////////
    assign Iss_Div=Div_ExeRdy&&IssDiv_Rdy;
    assign Iss_Int=(IssInt_Rdy&&IssLsb_Rdy)?!IU_Valid[0]&&!Arbiter_Grant:!IU_Valid[0]&&IssInt_Rdy;
    assign Iss_Lsb=(IssInt_Rdy&&IssLsb_Rdy)?!IU_Valid[0]&&Arbiter_Grant:!IU_Valid[0]&&IssLsb_Rdy;
    assign Iss_Mult=!IU_Valid[3]&&IssMul_Rdy;
endmodule