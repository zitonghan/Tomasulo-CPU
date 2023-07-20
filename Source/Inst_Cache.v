`timescale 1ps/1ps
module Inst_Cache (
    input Clk,
    input Clk_uart,//clock signal used for uart
    input Resetb,
    input [31:0] Ifetch_WpPcIn,
    input Ifetch_ReadCache,//始终�?1
    input IFQ_Flush,//IFQ flush is sent from IFQ and it is used to indicate the inst cache to ignore the current processing instruction and make the busy flag to 0 
    //input from cache unit
    output [31:0] Cache_Cd0,
    output [31:0] Cache_Cd1,
    output [31:0] Cache_Cd2,
    output [31:0] Cache_Cd3,
    output Cache_ReadHit,
    input Cache_Init,//signals used for muxtiplexing the memory input signals during cache initialization phase
    input Send_DataBack,//signals used for muxtiplexing the memory input signals during sending operating results back tp pc phase
    input Uart_InstCache_WE,//below signals are sent from uart to cache memory
    input [5:0] Uart_Cache_InitAddr,
    input [5:0] Uart_InstCache_RdAddr,
    input [127:0] Uart_Cache_InitData,
    output [127:0] InstCache_BackData
);
    //  parameter Inst_Type="ADD",
    //            Init_File_ADD="./Inst_test_stream/Inst_Cache_InitFile_ADD.txt",
    //            Init_File_JMP="./Inst_test_stream/Inst_Cache_InitFile_JMP.txt",
    //            Init_File_MUL="./Inst_test_stream/Inst_Cache_InitFile_MUL.txt",
    //            Init_File_DIV="./Inst_test_stream/Inst_Cache_InitFile_DIV.txt",
    //            Init_File_JAL="./Inst_test_stream/Inst_Cache_InitFile_JAL.txt",
    //            Init_File_LW="./Inst_test_stream/Inst_Cache_InitFile_LW.txt",
    //            Init_File_LWSW="./Inst_test_stream/Inst_Cache_InitFile_LWSW.txt",
    //            Init_File_Factorial="./Inst_test_stream/Inst_Cache_InitFile_Factorial.txt",
    //            Init_File_Factorial_Simple="./Inst_test_stream/Inst_Cache_InitFile_Factorial_Simple.txt",
    //            Init_File_SW_Bypass="./Inst_test_stream/Inst_Cache_InitFile_SW_Bypass.txt",
    //            Init_File_MEM_Disambiguation="./Inst_test_stream/Inst_Cache_InitFile_MEM_Disambiguation.txt",
    //            Init_File_MEM_Disambiguation2="./Inst_test_stream/Inst_Cache_InitFile_MEM_Disambiguation2.txt",
    //            Init_File_MEM_Disambiguation3="./Inst_test_stream/Inst_Cache_InitFile_MEM_Disambiguation3.txt",
    //            Init_File_Selective_Flush="./Inst_test_stream/Inst_Cache_InitFile_Selective_Flush.txt",
    //            Init_File_Selective_Flush_Plus_MEM_Disambiguation="./Inst_test_stream/Inst_Cache_InitFile_Selective_Flush_Plus_MEM_Disambiguation.mem",
    //            Init_File_Find_Min="./Inst_test_stream/Inst_Cache_InitFile_Find_Min.txt";
    //64 location, each 128bits, 4 words
    // reg [127:0] ICache_RAM [63:0];
    reg [3:0] Latency_Cnt;//used to simulate the memory access latency
    reg IC_Read_Busy;//if cache currently is processing a read request, the busy flag will be active
    wire [127:0] Rom_dataout;//memory data out for CPU
    ////////////////////////////////////////
    //signals for inst cache initialization
    wire [5:0] InstCache_RdAddr;
    wire [127:0] InstCache_Dout;
    //multiplexing logic
    assign InstCache_RdAddr=Send_DataBack?Uart_InstCache_RdAddr:Ifetch_WpPcIn[9:4];
    assign Rom_dataout=InstCache_Dout;//notice that the instcache_dout is an output of inst cache, its output can directly be connected with the dataout for CPU and UART
    assign InstCache_BackData=InstCache_Dout;
    //ROM ip instantiate
    // dist_mem_gen_0 ICache_RAM (
    // .a(Ifetch_WpPcIn[9:4]),      // input wire [5 : 0] a
    // .spo(Rom_dataout)  // output wire [127 : 0] spo
    // );
    ///////////////////////////
    //clock signals after global mux
    wire Clk2IC_Bram;
    //global clock mux used for muxtiplexing the clock signals for the bram since the uart and cpu are running under different 
    BUFGMUX BUFGMUX_IC (
    .O(Clk2IC_Bram),   // 1-bit output: Clock output
    .I0(Clk), // 1-bit input: Clock input (S=0)
    .I1(Clk_uart), // 1-bit input: Clock input (S=1)
    .S(Cache_Init|Send_DataBack)    // 1-bit input: Clock select
    );
    ///////////////////////////
    //bram used as memory body of cache
    Uart_Bram #(.DATA_WIDTH(128)) Inst_Cache(
        .clk(Clk2IC_Bram),
        .we(Uart_InstCache_WE),
        .din(Uart_Cache_InitData),//write data in
        .addra(Uart_Cache_InitAddr),//port for write
        .addrb(InstCache_RdAddr),//port for read
        .dout(InstCache_Dout)
    );
    // initial begin
    //     if(Inst_Type=="ADD")begin
    //         $readmemh(Init_File_ADD, ICache_RAM);
    //     end else if(Inst_Type=="JMP") begin
    //         $readmemh(Init_File_JMP, ICache_RAM);
    //     end else if(Inst_Type=="MUL")begin
    //         $readmemh(Init_File_MUL, ICache_RAM);
    //     end else if(Inst_Type=="DIV")begin
    //         $readmemh(Init_File_DIV, ICache_RAM);
    //     end else if(Inst_Type=="JAL")begin
    //         $readmemh(Init_File_JAL, ICache_RAM);
    //     end else if(Inst_Type=="LW")begin
    //         $readmemh(Init_File_LW, ICache_RAM);
    //     end else if(Inst_Type=="LWSW")begin
    //         $readmemh(Init_File_LWSW, ICache_RAM);
    //     end else if(Inst_Type=="Factorial")begin
    //         $readmemh(Init_File_Factorial, ICache_RAM);
    //     end else if(Inst_Type=="Factorial_Simple")begin
    //         $readmemh(Init_File_Factorial_Simple, ICache_RAM);
    //     end else if(Inst_Type=="SW_Bypass")begin
    //         $readmemh(Init_File_SW_Bypass, ICache_RAM);
    //     end else if(Inst_Type=="MEM_Disambiguation")begin
    //         $readmemh(Init_File_MEM_Disambiguation, ICache_RAM);
    //     end else if(Inst_Type=="MEM_Disambiguation2")begin
    //         $readmemh(Init_File_MEM_Disambiguation2, ICache_RAM);
    //     end else if(Inst_Type=="MEM_Disambiguation3")begin
    //         $readmemh(Init_File_MEM_Disambiguation3, ICache_RAM);
    //     end else if(Inst_Type=="Selective_Flush")begin
    //         $readmemh(Init_File_Selective_Flush, ICache_RAM);
    //     end else if(Inst_Type=="Selective_Flush_Plus_MEM_Disambiguation")begin
    //         $readmemh(Init_File_Selective_Flush_Plus_MEM_Disambiguation, ICache_RAM);
    //     end
        
    // end
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            IC_Read_Busy<=1'b0;
            Latency_Cnt<='bx;
        end else begin
            if(IFQ_Flush)begin
                //�?要注意，即使当IFQ_flush信号�?1时，instruction不是busy，也应该保持，因为当前时钟IFQ还会发�?�read cache信号，如果不控制，read busy会升�?
                if(IC_Read_Busy)begin
                    IC_Read_Busy<=~IC_Read_Busy;
                end
            end else begin
                if(Ifetch_ReadCache&&!IC_Read_Busy)begin
                    Latency_Cnt<=Ifetch_WpPcIn[5:4];
                    IC_Read_Busy<=~IC_Read_Busy; 
                end
                if(IC_Read_Busy)begin
                    //当前时钟flush=1,下一个时钟pc才会更新，因此当前时钟我向busy中写�?0即可
                    if(Latency_Cnt>0)begin
                        Latency_Cnt<=Latency_Cnt-1;
                    end else begin
                        IC_Read_Busy<=~IC_Read_Busy;
                    end                
                end
            end
        end
    end
    assign Cache_ReadHit=Ifetch_ReadCache&&IC_Read_Busy&&Latency_Cnt==0;//since we use a bram here as the memory body of the cache, every read operation has to have a clock latency
    //so the cache busy flag will always be turned to 1, hence the readhit signals will be activated when busy flag is 1 and latency cnt is 0;
    assign Cache_Cd0=Rom_dataout[31:0];
    assign Cache_Cd1=Rom_dataout[63:32];
    assign Cache_Cd2=Rom_dataout[95:64];
    assign Cache_Cd3=Rom_dataout[127:96];
endmodule