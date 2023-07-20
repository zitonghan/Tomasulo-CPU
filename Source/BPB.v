`timescale 1ps/1ps
module branch_predict_buffer(
    input  Clk,
    input Resetb,
    input  Dis_CdbUpdBranch,
    //该信号首先从CDB传入dispatch unit,然后传给BPB，应该是纯组合逻辑
    //branch不仅预测错的时候要更新，预测对的时候也要更新，每个entry都是一个state machine，只不过共用一个NSL
    input [2:0] Dis_CdbUpdBranchAddr,//branch address, 只有address[4:2]用于访问BPB
    input Dis_CdbBranchOutcome,//indiacates the outocome of the branch to the bpb: 0 means nottaken and 1 means taken 
    ////
    input [2:0] Dis_BpbBranchPCBits,//
    input Dis_BpbBranch,
    output  reg Bpb_BranchPrediction     
);
    reg [1:0] bpb_mem [7:0];
    //update the entry
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            bpb_mem[0]<=2'b01;
            bpb_mem[1]<=2'b10;
            bpb_mem[2]<=2'b01;
            bpb_mem[3]<=2'b10;
            bpb_mem[4]<=2'b01;
            bpb_mem[05]<=2'b10;
            bpb_mem[6]<=2'b01;
            bpb_mem[7]<=2'b10;
        end else begin
            if(Dis_CdbUpdBranch)begin
                if(Dis_CdbBranchOutcome&&bpb_mem[Dis_CdbUpdBranchAddr]!=2'b11)begin
                    bpb_mem[Dis_CdbUpdBranchAddr]<=bpb_mem[Dis_CdbUpdBranchAddr]+1;
                end
                if(!Dis_CdbBranchOutcome&&bpb_mem[Dis_CdbUpdBranchAddr]!=2'b00) begin
                    bpb_mem[Dis_CdbUpdBranchAddr]<=bpb_mem[Dis_CdbUpdBranchAddr]-1;
                end
                
            end
        end
    end
    //read out data from the buffer
    always @(*) begin
        Bpb_BranchPrediction=1'b0;
        if(Dis_BpbBranch)begin
            Bpb_BranchPrediction=bpb_mem[Dis_BpbBranchPCBits][1];
        end
    end
endmodule