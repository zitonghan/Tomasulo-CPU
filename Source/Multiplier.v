`timescale 1ns/1ns
module Multiplier(
    input Clk,
	input Resetb,
	input Iss_Mult,//from issue unit
	input [31:0] PhyReg_MultRsData,//from issue queue mult
	input [31:0] PhyReg_MultRtData,//from issue queue mult
	input [4:0] Iss_RobTag ,// from issue queue mult
    ////////////////////////////////////////////////////////////////////	
    output [5:0] Mul_RdPhyAddr ,// -- output to CDB required
	output Mul_RdWrite,
	input [5:0]Iss_RdPhyAddr,// incoming form issue queue, need to be carried as Iss_RobTag
	input Iss_RdWrite,
    ////////////////////////////////////////////////////////////////////
	output reg [31:0] Mul_RdData,// output to CDB unit (to CDB Mux)
	output [4:0] Mul_RobTag	,// output to CDB unit (to CDB Mux)
	output Mul_Done,// output to CDB unit ( to control Mux selection)
	input Cdb_Flush,
    input [4:0] Rob_TopPtr,
    input [4:0] Cdb_RobDepth 
);
    integer i,j;
    //4 stage pipelined multiplier with a wrapper, so that when misprediction occurs, the wrong path mul instruction can be flushed in the multiplier
    //16bit 乘法
    wire [15:0] MD1, MR1; 
    ///////////////////////////////////////////////////////
    reg [15:0] Int_Product1, Int_Product2, Int_Product3;//internal product in each stage
    //partial product generated at different stage
    reg [5:0] Product0to5;
    reg [4:0] Product6to10, Product11to15;
    reg [15:0] Product16to31;

    reg [15:0] S_A_M1;//Sum_after_multiplication and carry after sum, it is 0 for the first sum operation
    reg [14:0] C_A_S1;
    ////////////////////////////////////////////
    //stage register
    reg [15:0] S_A_M2, S_A_M3, S_A_M4;
    reg [14:0] C_A_S2, C_A_S3, C_A_S4;//combinational signal
    reg [15:0] S_A_M2_reg, S_A_M3_reg, S_A_M4_reg;
    reg [14:0] C_A_S2_reg, C_A_S3_reg, C_A_S4_reg;//registers
    ////////////////////////////////////////////
    reg [5:0] Product_S1;
    reg [10:0] Product_S2;
    reg [15:0] Product_S3;
    //input data for other stages
    reg [15:0] MD2; 
    reg [9:0] MR2;
    reg [15:0] MD3; 
    reg [4:0] MR3;
    /////////////////////////////////////////////
    //stage register for dealing with flush
    reg Valid_S2, Valid_S3, Valid_S4;
    reg [4:0] Rob_Tag_S2, Rob_Tag_S3, Rob_Tag_S4;
    reg [5:0] RdPhyAddr_S2, RdPhyAddr_S3, RdPhyAddr_S4;
    reg RdWrite_S2, RdWrite_S3, RdWrite_S4;
    /////////////////////////////////////////////
    assign MD1=PhyReg_MultRsData[15:0];
    assign MR1=PhyReg_MultRtData[15:0];
    //stage1 combinatinal logic , generate product[5:0]
    always@(*)begin
        C_A_S1=0;
        S_A_M1=MD1&{16{MR1[0]}};//first multiplication
        for(i=0;i<5;i=i+1)begin
            Product0to5[i]= S_A_M1[0];//最后一个bit因为不用做乘法，因此之间看作时乘积的一部分
            Int_Product1=MD1&{16{MR1[i+1]}};
            for(j=1;j<16;j=j+1)begin//generaete the next sam[14:0]
                S_A_M1[j-1]=Int_Product1[j-1]^S_A_M1[j]^C_A_S1[j-1];//每次算完乘积做加法时，都是从上一次运算剩下的sum[15:1]于新的product[15:0]以及上一次的进位[14:0]进行计算的
                //由于product的最高位没有相应的bit与之相加，因此直接传给新的sum的最高bit,而product【14:0】会与上一次的sum[15:1]进行相加，但是得到的carry只有15bit，但是需要向前移动一位，
                //例如bit1相加产生的进位适用于bit2相加时使用的
                C_A_S1[j-1]=Int_Product1[j-1]&&S_A_M1[j]||Int_Product1[j-1]&&C_A_S1[j-1]||S_A_M1[j]&&C_A_S1[j-1];
            end
            S_A_M1[15]=Int_Product1[15];
        end    
        Product0to5[5]=S_A_M1[0];
    end
    ////////////////////////////////////////////
    //stage2
    always@(*)begin
        S_A_M2=S_A_M2_reg;
        C_A_S2=C_A_S2_reg;
        for(i=0;i<5;i=i+1)begin
            Int_Product2=MD2&{16{MR2[i]}};
            for(j=1;j<16;j=j+1)begin//generaete the next sam[14:0]
                S_A_M2[j-1]=Int_Product2[j-1]^S_A_M2[j]^C_A_S2[j-1];
                C_A_S2[j-1]=Int_Product2[j-1]&&S_A_M2[j]||Int_Product2[j-1]&&C_A_S2[j-1]||S_A_M2[j]&&C_A_S2[j-1];
            end
            S_A_M2[15]=Int_Product2[15];
            Product6to10[i]=S_A_M2[0];
        end    
    end
    //stage3
    always@(*)begin
        S_A_M3=S_A_M3_reg;
        C_A_S3=C_A_S3_reg;
        for(i=0;i<5;i=i+1)begin
            Int_Product3=MD3&{16{MR3[i]}};
            for(j=1;j<16;j=j+1)begin//generaete the next sam[14:0]
                S_A_M3[j-1]=Int_Product3[j-1]^S_A_M3[j]^C_A_S3[j-1];
                C_A_S3[j-1]=Int_Product3[j-1]&&S_A_M3[j]||Int_Product3[j-1]&&C_A_S3[j-1]||S_A_M3[j]&&C_A_S3[j-1];
            end
            S_A_M3[15]=Int_Product3[15];
            Product11to15[i]=S_A_M3[0];
        end    
    end
    //stage4
    always @(*) begin//最后一个stage已经没有internal product可以相加了，因此将最后一次产生的sum和carry相加即可
        S_A_M4=S_A_M4_reg;
        C_A_S4=C_A_S4_reg;
    //因为传到这一stage的sum是15:1，这好与15bit进位的位置相匹配，因此补零相加即可
        Product16to31=S_A_M4^{1'b0,C_A_S4};
        Mul_RdData={Product16to31,Product_S3};
    end
    /////////////////////////////////
    //stage regsiter update
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            Product_S1<='bx;
            Product_S2<='bx;
            Product_S3<='bx;
            S_A_M2_reg<='bx;
            S_A_M3_reg<='bx; 
            S_A_M4_reg<='bx; 
            C_A_S2_reg<='bx;
            C_A_S3_reg<='bx;
            C_A_S4_reg<='bx;
            MD2<='bx;
            MR2<='bx;
            MD3<='bx; 
            MR3<='bx;
        end else begin
            Product_S1<=Product0to5;
            Product_S2<={Product6to10,Product_S1};
            Product_S3<={Product11to15,Product_S2};
            S_A_M2_reg<=S_A_M1;
            S_A_M3_reg<=S_A_M2;
            S_A_M4_reg<={1'b0, S_A_M3[15:1]};
            C_A_S2_reg<=C_A_S1;
            C_A_S3_reg<=C_A_S2;
            C_A_S4_reg<=C_A_S3;
            MD2<=MD1;
            MD3<=MD2;
            MR2<=MR1[15:6];
            MR3<=MR2[9:5];
        end
    end
    //////////////////////////////////////////////////////////////////////////
    //由于issue queue会care发射指令时，指令被flush的情况，因此我们只需要考虑剩余三个stage的flush问题，需要三个validbit，以及rob tag保存信息
    always@(posedge Clk, negedge Resetb)begin
        if(!Resetb)begin
            Valid_S2<=1'b0;
            Valid_S3<=1'b0;
            Valid_S4<=1'b0;
            Rob_Tag_S2<='bx;
            Rob_Tag_S3<='bx;
            Rob_Tag_S4<='bx;
            RdPhyAddr_S2<='bx;
            RdPhyAddr_S3<='bx; 
            RdPhyAddr_S4<='bx;
            RdWrite_S2<='bx; 
            RdWrite_S3<='bx; 
            RdWrite_S4<='bx;
        end else begin
            //updata valid bit
            //重点：注意flush时是将下一个stage的valid bit清零，而不是清空自己的
            Valid_S2<=Iss_Mult;
            Valid_S3<=Valid_S2;
            Valid_S4<=Valid_S3;
            if(Cdb_Flush)begin
                if(Valid_S2&&Rob_Tag_S2-Rob_TopPtr>Cdb_RobDepth)begin
                    Valid_S3<=~Valid_S2;
                end 
                if(Valid_S3&&Rob_Tag_S3-Rob_TopPtr>Cdb_RobDepth)begin
                    Valid_S4<=~Valid_S3;
                end  
            end
            /////////////////////////////////////
            Rob_Tag_S2<=Iss_RobTag;
            Rob_Tag_S3<=Rob_Tag_S2;
            Rob_Tag_S4<=Rob_Tag_S3;
            ///////////////////////////////////
            RdPhyAddr_S2<=Iss_RdPhyAddr;
            RdPhyAddr_S3<=RdPhyAddr_S2; 
            RdPhyAddr_S4<=RdPhyAddr_S3;
            RdWrite_S2<=Iss_RdWrite; 
            RdWrite_S3<= RdWrite_S2; 
            RdWrite_S4<=RdWrite_S3;
        end
    end
    //////////////////////////////////
    assign  Mul_RdPhyAddr=RdPhyAddr_S4;
	assign Mul_RdWrite=RdWrite_S4;
	assign Mul_RobTag=Rob_Tag_S4;
	assign Mul_Done=Valid_S4&&(!Cdb_Flush||Cdb_Flush&&(Rob_Tag_S4-Rob_TopPtr<Cdb_RobDepth));
endmodule