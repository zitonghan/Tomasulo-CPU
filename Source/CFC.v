`timescale 1ps/1ps
module CFC(
    input Clk,//Global Clock Signal
	input Resetb,//Global Reset Signal
	//interface with dispatch unit
	input Dis_InstValid,//Flag indicating if the instruction dispatched is valid or not
	input [4:0] Dis_CfcBranchTag,//ROB Tag of the branch instruction 
	input [4:0] Dis_CfcRdAddr,//Rd Logical Address
	input [4:0] Dis_CfcRsAddr,//Rs Logical Address
	input [4:0] Dis_CfcRtAddr,//Rt Logical Address
	input [5:0] Dis_CfcNewRdPhyAddr,//New Physical Register Address assigned to Rd by Dispatch
	input Dis_CfcRegWrite,//Flag indicating whether current instruction being dispatched is register writing or not
	input Dis_CfcBranch,//Flag indicating whether current instruction being dispatched is branch or not
	input Dis_Jr31Inst,//Flag indicating if the current instruction is Jr 31 or not
		
	output [5:0] Cfc_RdPhyAddr,//Previous Physical Register Address of Rd
	output [5:0] Cfc_RsPhyAddr,//Latest Physical Register Address of Rs
	output [5:0] Cfc_RtPhyAddr,//Latest Physical Register Address of Rt
	output Cfc_Full,//Flag indicating whether checkpoint table is full or not
						
	//interface with ROB
	input [4:0] Rob_TopPtr,//ROB tag of the intruction at the Top
	input Rob_Commit ,//Flag indicating whether instruction is committing in this cycle or not
	input [4:0] Rob_CommitRdAddr,//Rd Logical Address of committing instruction
	input Rob_CommitRegWrite,//Indicates if instruction is writing to register or not
	input [5:0] Rob_CommitCurrPhyAddr,//Physical Register Address of Rd of committing instruction			
		
	//signals from cfc to ROB in case of CDB flush
	output [4:0] Cfc_RobTag,//Rob Tag of the instruction to which rob_bottom is moved after branch misprediction (also to php)
	
	//interface with FRL
	input [4:0]Frl_HeadPtr,//Head Pointer of the FRL when a branch is dispatched
	output reg [4:0]Cfc_FrlHeadPtr,//Value to which FRL has to jump on CDB Flush
 		
	//interface with CDB
	input Cdb_Flush ,//Flag indicating that current instruction is mispredicted or not
	input [4:0] Cdb_RobTag,//ROB Tag of the mispredicted branch
	input [4:0] Cdb_RobDepth
);
    //dirty flag array decleration
    reg [7:0] DFA_Rs [31:0];//sicne we want to search the entire row of the DFA, so the number of column should be declared at the left side
    reg [7:0] DFA_Rt [31:0];
    reg [7:0] DFA_Rd [31:0];
    ///////////////
    //Tag Array decleration
    //each entry contains 5bit rob tag and 1 valid bit, indexed by head,tail pointer
    reg [5:0] ROB_tag [7:0]; 
    //FRL FIFO decleration
    //enach entry contains 6bit PR tag, indexed by head,tail pointer
    reg [5:0] FRL_CheckPints [7:0];
    //instantiate BRAMs for RRAT,32*6bits
    reg [2:0] Head_ptr, Tail_ptr;
    assign Cfc_Full=((Head_ptr-Tail_ptr)%8==7)?1'b1:1'b0;
    ///////////////////
    integer i,j;
    ////////////////////
    reg [2:0] read_index_rs,read_index_rt,read_index_rd;//generated after searching the dirty bit array
    reg rs_find,rt_find,rd_find;//three flags used to indicate the tag is found in the check points
    ///////////////////////
    //head_ptr and tail_ptr update logic and FRL fifo update
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            Head_ptr<='b0;
            Tail_ptr<='b0;
        end else begin
            //update head pointer first
            //cdb FLUSH should has the highest priority then current dispatching instruction
            if(Cdb_Flush)begin
                for (i=0;i<8;i=i+1)begin
                    if(ROB_tag[i][4:0]==Cdb_RobTag&&ROB_tag[i][5]) begin
                        Head_ptr<=i;
                    end
                end
            end else if(Dis_InstValid&&(Dis_CfcBranch||Dis_Jr31Inst))begin//branch and jr$31 instrcution both cause the CFC activate another check points
                Head_ptr<=Head_ptr+1;
            end
            ////update tail pointer
            if(Rob_Commit&&Rob_TopPtr==ROB_tag[Tail_ptr][4:0]&&ROB_tag[Tail_ptr][5])begin
                Tail_ptr<=Tail_ptr+1;
            end
        end
    end
    /////////////
    //update dirty flag array
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            for (i=0;i<32;i=i+1)begin
                DFA_Rd[i]<='b0;
                DFA_Rs[i]<='b0;
                DFA_Rt[i]<='b0;
            end
        end else begin
            if(Cdb_Flush)begin
                for(i=0;i<8;i=i+1)begin
                    if(ROB_tag[i][5])begin//if the distance between rob tag and the rob toppest pointer is geater than the mispredicted branch, then flush
                        if(ROB_tag[i][4:0]-Rob_TopPtr>Cdb_RobDepth)begin
                            for (j=0;j<32;j=j+1)begin
                                DFA_Rd[j][i]<='b0;
                                DFA_Rs[j][i]<='b0;
                                DFA_Rt[j][i]<='b0;
                            end 
                        end
                    end    
                end
                //不能只通过简单的对比rob depth进行清零，当前的head pointer所指向的位置也需要清零
                for (i=0;i<32;i=i+1)begin
                    DFA_Rd[i][Head_ptr]<='b0;
                    DFA_Rs[i][Head_ptr]<='b0;
                    DFA_Rt[i][Head_ptr]<='b0;
                end 
            end else begin
                if(Dis_CfcRegWrite&&Dis_InstValid)begin
                    DFA_Rd[Dis_CfcRdAddr][Head_ptr]<=1'b1;
                    DFA_Rs[Dis_CfcRdAddr][Head_ptr]<=1'b1;
                    DFA_Rt[Dis_CfcRdAddr][Head_ptr]<=1'b1;
                end
            end
            //////////////
            //when a branch comes out from the top of the rob, the DFA should also be updated
            if(Rob_Commit&&Rob_TopPtr==ROB_tag[Tail_ptr][4:0]&&ROB_tag[Tail_ptr][5])begin
                for (i=0;i<32;i=i+1)begin
                    DFA_Rd[i][Tail_ptr]<='b0;
                    DFA_Rs[i][Tail_ptr]<='b0;
                    DFA_Rt[i][Tail_ptr]<='b0;
                end 
            end
        end
    end
    ///////////////////
    //update rob tag
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            for(i=0;i<8;i=i+1)begin
                ROB_tag[i][5]<=1'b0;
            end
        end else begin
            //most logic as the update of head and tail pointer
            if(Cdb_Flush)begin
                for (i=0;i<8;i=i+1)begin
                    if(ROB_tag[i][5])begin
                        if(ROB_tag[i][4:0]-Rob_TopPtr>=Cdb_RobDepth)begin//it is a little different from the logic of flush dirty bit, since the rob tag of the entry indexed by the updated head pointer should also be cleared
                            ROB_tag[i][5]<=1'b0;
                        end
                    end
                end
            end else if(Dis_InstValid&&(Dis_CfcBranch||Dis_Jr31Inst))begin//branch and jr$31 instrcution both cause the CFC activate another check points
                ROB_tag[Head_ptr]<={1'b1,Dis_CfcBranchTag};
            end
            ////update tail pointer
            if(Rob_Commit&&Rob_TopPtr==ROB_tag[Tail_ptr][4:0]&&ROB_tag[Tail_ptr][5])begin
                ROB_tag[Tail_ptr][5]<=1'b0;
            end
        end
    end
    ///////////////////
    //write a new tag into CFC
    reg wea_rrat;
    reg [4:0] waddr_rrat;
    reg [5:0] rrat_tag_in;
    //read out a rag from CFC
    wire [5:0] rrat_rs_tag_out, rrat_rt_tag_out, rrat_rd_tag_out;
    ///////////////////
    ///////////////////
    //RRAT update logic
    always @(*) begin
        wea_rrat=1'b0;
        waddr_rrat= Rob_CommitRdAddr;
        rrat_tag_in=Rob_CommitCurrPhyAddr;
        //default assignment
        if(Rob_Commit&&Rob_CommitRegWrite)begin
            wea_rrat=1'b1;
        end
    end
    ////////////////
    BRAM #(.ADDR_WIDTH($clog2(32)), .ID(2)) RRAT_Rs(
        .clk(Clk),
        .wea(wea_rrat),
        .addra(waddr_rrat), 
        .addrb(Dis_CfcRsAddr),//读取时，rrat和check point同时进行读取，只不过根据search得到结果从二者之中选择其一即可
        .dina(rrat_tag_in),
        .doutb(rrat_rs_tag_out)
    );
    BRAM #(.ADDR_WIDTH($clog2(32)), .ID(2)) RRAT_Rt(
        .clk(Clk),
        .wea(wea_rrat),
        .addra( waddr_rrat), 
        .addrb(Dis_CfcRtAddr),
        .dina(rrat_tag_in),
        .doutb(rrat_rt_tag_out)
    );
    BRAM #(.ADDR_WIDTH($clog2(32)), .ID(2)) RRAT_Rd(
        .clk(Clk),
        .wea(wea_rrat),
        .addra( waddr_rrat), 
        .addrb(Dis_CfcRdAddr),
        .dina(rrat_tag_in),
        .doutb(rrat_rd_tag_out)
    );
    /////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////
    //signals for BRAM check points
    reg wea_CP;
    reg [7:0] waddr_CP;
    reg [5:0] CP_tag_in;
    //read out a rag from CFC
    wire [7:0] raddr_CP_rs, raddr_CP_rt, raddr_CP_rd;
    wire [5:0] CP_rs_tag_out, CP_rt_tag_out, CP_rd_tag_out;
    ////////////////////
    //update check points
    always@(*)begin
        wea_CP=1'b0;
        waddr_CP={Head_ptr,Dis_CfcRdAddr};//head pointer +number of architectural register
        CP_tag_in=Dis_CfcNewRdPhyAddr;
        if(Dis_CfcRegWrite&&Dis_InstValid&&!Cdb_Flush)begin//重点：check points需要注意，只有当前时钟没有flush且dispatch 一个register write类型的指令时才会写入
            wea_CP=1'b1;
        end
    end
    //*********************************************************************//
    //check points and rrat reading rs,rt,rd logic
    always @(*) begin
        read_index_rs='b0;//all zeros means the newest tag is stored in the rrat
        rs_find=1'b0;
        for(i=0;i<8;i=i+1)begin
            if(i<=Head_ptr)begin
                if(DFA_Rs[Dis_CfcRsAddr][i]==1'b1)begin
                    read_index_rs=i;
                    rs_find=1'b1;
                end
            end
        end
        if(!rs_find)begin
            for(i=0;i<8;i=i+1)begin
                if(i>=Tail_ptr)begin
                    if(DFA_Rs[Dis_CfcRsAddr][i]==1'b1)begin
                        read_index_rs=i;
                        rs_find=1'b1;
                    end
                end
            end
        end
       
    end
    always @(*) begin
        read_index_rt='b0;//all zeros means the newest tag is stored in the rrat
        rt_find=1'b0;
        for(i=0;i<8;i=i+1)begin
            if(i<=Head_ptr)begin
                if(DFA_Rt[Dis_CfcRtAddr][i]==1'b1)begin
                    read_index_rt=i;
                    rt_find=1'b1;
                end
            end
        end
        if(!rt_find)begin
            for(i=0;i<8;i=i+1)begin
                if(i>=Tail_ptr)begin
                    if(DFA_Rt[Dis_CfcRtAddr][i]==1'b1)begin
                        read_index_rt=i;
                        rt_find=1'b1;
                    end
                end
            end
        end
    end
    always @(*) begin
        read_index_rd='b0;//all zeros means the newest tag is stored in the rrat
        rd_find=1'b0;
        for(i=0;i<8;i=i+1)begin
            if(i<=Head_ptr)begin
                if(DFA_Rd[Dis_CfcRdAddr][i]==1'b1)begin
                    read_index_rd=i;
                    rd_find=1'b1;
                end
            end
        end
        if(!rd_find)begin
            for(i=0;i<8;i=i+1)begin
                if(i>=Tail_ptr)begin
                    if(DFA_Rd[Dis_CfcRdAddr][i]==1'b1)begin
                        read_index_rd=i;
                        rd_find=1'b1;
                    end
                end
            end
        end
    end
    //*********************************************************************//
    /////////////////////////////
    assign raddr_CP_rs={read_index_rs,Dis_CfcRsAddr};
    assign raddr_CP_rt={read_index_rt,Dis_CfcRtAddr};
    assign raddr_CP_rd={read_index_rd,Dis_CfcRdAddr};
    //////////////////////////////
    //3 BRAMS for checkpoints,8*32*6bits
    BRAM #(.ADDR_WIDTH($clog2(8*32)), .ID(1)) CFC_Rs(
        .clk(Clk),
        .wea( wea_CP),
        .addra(waddr_CP), 
        .addrb(raddr_CP_rs),
        .dina(CP_tag_in),
        .doutb(CP_rs_tag_out)
    );
    BRAM #(.ADDR_WIDTH($clog2(8*32)), .ID(1)) CFC_Rt(
        .clk(Clk),
        .wea( wea_CP),
        .addra(waddr_CP), 
        .addrb(raddr_CP_rt),
        .dina(CP_tag_in),
        .doutb(CP_rt_tag_out)
    );
    BRAM #(.ADDR_WIDTH($clog2(8*32)), .ID(1)) CFC_Rd(
        .clk(Clk),
        .wea( wea_CP),
        .addra(waddr_CP), 
        .addrb(raddr_CP_rd),
        .dina(CP_tag_in),
        .doutb(CP_rd_tag_out)
    );
    ////////////////
    //重点：
    //note that the rs/rt/rd_find signals are combinational logic,
    //during current clock, the find signals indicates that the data should be fetched from the rrat, however, due to the rrat is built by BRAN, there is
    //one clock delay, so the find signal should be registered
    reg rs_find_reg,rt_find_reg,rd_find_reg;
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            rs_find_reg<=1'b0;
            rt_find_reg<=1'b0;
            rd_find_reg<=1'b0;
        end else begin
            rs_find_reg<=rs_find;
            rt_find_reg<=rt_find;
            rd_find_reg<=rd_find;
        end
    end
    /////////////////
    //assignment of the output tag of rs,rt,rd registers
    assign Cfc_RsPhyAddr=rs_find_reg?CP_rs_tag_out:rrat_rs_tag_out;
	assign Cfc_RtPhyAddr=rt_find_reg?CP_rt_tag_out:rrat_rt_tag_out;
	assign Cfc_RdPhyAddr=rd_find_reg?CP_rd_tag_out:rrat_rd_tag_out;
    ////////////////
    //forward the mispredicted branch rob tag to rob
    assign Cfc_RobTag=Cdb_RobTag;
    ///////////////////////////////////////////////
    //FRL FIFO
    reg [4:0] FRL_mem [7:0];//eight locations fifo for storing frl pointer
    always @(posedge Clk) begin//FRL update logic
        if(!Cdb_Flush&&Dis_InstValid&&(Dis_CfcBranch||Dis_Jr31Inst))begin//if current dispatching insctruction is branch, however, cdb indicates a flush action, the fifo should not be written
            FRL_mem[Head_ptr]<=Frl_HeadPtr;
        end 
    end
    //由于FRL fifo是由head pointetr进行index，而当flush发生时，head pointer需要对比rob depth来判断复原的的位置，这需要rob tag array，而tag array中需要valid bit,因为
    //如果没有valid bit,不同entry中完全有可能出现相同的rob tag，例如经历过flush之后，因此需要valid bit指示哪一个entry中的内容是有效的。
    //因此frl fifo中不再需要这一valid bit
    always @(*) begin//combinatinal logic for assignment of Cfc_FrlHeadPtr
        Cfc_FrlHeadPtr='b0;
        if(Cdb_Flush)begin
            for (i=0;i<8;i=i+1)begin
                    if(ROB_tag[i][4:0]==Cdb_RobTag&&ROB_tag[i][5]) begin
                        Cfc_FrlHeadPtr=FRL_mem[i];
                    end
                end
        end
    end
endmodule