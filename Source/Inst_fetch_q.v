`timescale 1ps/1ps
module inst_fetch_q(
    input Clk,
    input Resetb, 
    //////////////////
    //output to dispatch unit
    output reg [31:0] Ifetch_Instruction,
    output Ifetch_EmptyFlag,//该信号是支持dispatch是否激活read enable信号的依据之一，因此为了支持first word fall through，falg的产生应该考虑cache hit的情况
    output [31:0] Ifetch_PcPlusFour,
    ////////////////////
    //input from dispatch 
    input Dis_Ren,//read enable
    input [31:0] Dis_JmpBrAddr,
    input Dis_JmpBr,
    input Dis_JmpBrAddrValid,
    //output to cache unit
    output [31:0] Ifetch_WpPcIn,
    output Ifetch_ReadCache,
    output IFQ_Flush,
    //input from cache unit
    input [31:0] Cache_Cd0,
    input [31:0] Cache_Cd1,
    input [31:0] Cache_Cd2,
    input [31:0] Cache_Cd3,
    input Cache_ReadHit,
    input CPU_Run
);
    //////////////////////////
    //本module用于从cache line中读取data并传给dispatch unit，需要注意支持first word fall through
    reg [31:0] IFQ_ram [3:0] [3:0];//COLUMN  ROW
    reg [2:0] w_ptr; //IFQ read write pointer 
    reg [4:0] r_ptr;
    wire IFQ_full,IFQ_empty;
    /////////////
    reg [31:0] Ifetch_PC, Dispatch_PC;
    //////////////////////
    //重点：
    //因为instruction fetch pc和当前dispatch的指令的pc是不同步的，因此我们需要有两个reg分别记录，
    /////////////////////
    //indicate the IFQ is empty
    assign IFQ_empty=((w_ptr^r_ptr[4:2])==3'b000)?1'b1:1'b0;
    assign Ifetch_EmptyFlag=(!Cache_ReadHit&&IFQ_empty)?1'b1:1'b0;
    assign IFQ_full=((w_ptr^r_ptr[4:2])==3'b100)?1'b1:1'b0;
    //generate pc=4 for dispatch unit
    assign Ifetch_PcPlusFour=Dispatch_PC+4;
    assign Ifetch_WpPcIn={Ifetch_PC[31:4],4'b0000};
    assign IFQ_Flush=Dis_JmpBr&&Dis_JmpBrAddrValid;
    //重点：存在bug,如果当前instruction cache正在处理一个read,但是 IFQ由于jmp或者其他原因需要flush,那么下一个时钟IFQ清空，但是没有人通知IC，那么IC会读出旧的信息，并且写入IFQ中，
    //会引起错误，因此需要IFQ_flush信号来通知instruction cache
    assign Ifetch_ReadCache=!IFQ_full&&CPU_Run;
    //assign Ifetch_ReadCache=!IFQ_full||IFQ_full&&IFQ_Flush;
    //重点：design中由于IFQ_flush->read_cache->read hit->empty_flag->dis_ren->jmpvalid->IFQ_flush形成了combinational feedback,因此将IFQ flush取出，看似牺牲了性能，但实际并不是
    //因为当flush发生时，ifetch_pc会在下一个clock时更新，所以当前时钟没有必要激活read cache,下个时钟激活即可，因为flush后下一个clock IFQ一定不是满的
    /////////////
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            Ifetch_PC<='b0;
            Dispatch_PC<='b0;
            w_ptr<='b0;
            r_ptr<='b0;
        end else begin
            //flush应该拥有最高优先级，如果当前始终出现flush信号，则所有读取以及要写入IFQ的内容都应该丢弃
            if(Dis_JmpBr&&Dis_JmpBrAddrValid)begin//current dispatch unit has a jump instruction
                Ifetch_PC<=Dis_JmpBrAddr;
                Dispatch_PC<=Dis_JmpBrAddr;
                w_ptr<='b0;
                r_ptr<={3'b000,Dis_JmpBrAddr[3:2]};
            end else begin//如果不需要flush，则写入与读取分别进行
                if (Cache_ReadHit&&!IFQ_full)begin
                    Ifetch_PC<=Ifetch_PC+16;//read out a block of word
                    w_ptr<=w_ptr+1;
                    IFQ_ram[0][w_ptr[1:0]]<=Cache_Cd0;
                    IFQ_ram[1][w_ptr[1:0]]<=Cache_Cd1;
                    IFQ_ram[2][w_ptr[1:0]]<=Cache_Cd2;
                    IFQ_ram[3][w_ptr[1:0]]<=Cache_Cd3;
                end
                if(Dis_Ren)begin//由于IFQempty信号已经在产生dis_ren信号时考虑了，这里只需要dis_ren信号即可
                    r_ptr<=r_ptr+1;
                    Dispatch_PC<= Dispatch_PC+4;
                end
            end 
        end
    end
    //////////combination logic for first word fall through
    always@(*)begin
        Ifetch_Instruction=IFQ_ram[r_ptr[1:0]][r_ptr[3:2]];//means bubble
        //重点：可以将的设计上的细节
        //IFQ是直接与dispatch stage1的组合逻辑相连的，中间没有stage register
        if(IFQ_empty)begin
            if(Cache_ReadHit)begin
                case(r_ptr[1:0])
                    2'b00:Ifetch_Instruction=Cache_Cd0;
                    2'b01:Ifetch_Instruction=Cache_Cd1;
                    2'b10:Ifetch_Instruction=Cache_Cd2;
                    2'b11:Ifetch_Instruction=Cache_Cd3;
                    default:Ifetch_Instruction=IFQ_ram[r_ptr[1:0]][r_ptr[3:2]];
                endcase  
            end
        end 
    end
endmodule
					