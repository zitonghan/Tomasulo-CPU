`timescale 1ps/1ps
module ROB(
    input Clk,
    input Resetb,		  
    //Interface with CDB
    input Cdb_Valid,//signal to tell that the values coming on CDB is valid                             
    input [4:0] Cdb_RobTag,//Tag of the instruction which the the CDB is broadcasting
    input [31:0] Cdb_SwAddr,//to give the store wordaddr
    //Interface with Dispatch unit	
    input Dis_InstSw,//signal that tells that the signal being dispatched is a store word
    input Dis_RegWrite,//signal telling that the instruction is register writing instruction
    input Dis_InstValid,//Signal telling that Dispatch unit is giving valid information
    //not activated when current dispatching instruction is a JUMP or JR$!31
    input [4:0] Dis_RobRdAddr,//Actual Destination register number of the instruction being dispatched
    input [5:0] Dis_NewRdPhyAddr,// Current Physical Register number of dispatching instruction taken by the dispatch unit from the FRL
    input [5:0] Dis_PrevPhyAddr,// Previous Physical Register number of dispatch unit taken from CFC
    input [5:0] Dis_SwRtPhyAddr,// Physical Address number from where store word has to take the data
    output Rob_Full,// Whether the ROB is Full or not
    //output Rob_TwoOrMoreVacant 
    //not used anymore, since the write pointer will be updated at dipatch stage 1	  
                
    //Interface with store buffer
    input SB_Full,//Tells the ROB that the store buffer is full
    output [31:0] Rob_SwAddr,// The address in case of sw instruction
    output Rob_CommitMemWrite,//Signal to enable the memory for writing purpose  

    // Interface with FRL and CFC			  
    // Gives the value of TopPtr pointer of ROB
    output Rob_TopPtr_IntQ,
    output Rob_TopPtr_MulQ,
    output Rob_TopPtr_DivQ,
    output Rob_TopPtr_LSQ,
    output Rob_TopPtr_LSB,
    output Rob_TopPtr_Mul,
    output Rob_TopPtr_Div,
    output Rob_TopPtr_CFC,
    output Rob_TopPtr_DC,
    output Rob_TopPtr_CDB,
    output [4:0] Rob_BottomPtr,//Gives the Bottom Pointer of ROB
    output Rob_Commit,//FRL needs it to to add previously-mapped physical register to free list cfc needs it to remove the latest checkpointed copy
    output [4:0] Rob_CommitRdAddr,//Architectural register number of committing instruction
    output Rob_CommitRegWrite,//Indicates that the instruction that is being committed is a register writing instruction
    output[5:0]  Rob_CommitPrePhyAddr,// pre physical addr of committing inst to be added to FRL
    output [5:0] Rob_CommitCurrPhyAddr,// Current Register Address of committing instruction to update retirement rat			  
    input Cdb_Flush,//Flag indicating that current instruction is mispredicted or not
    input [4:0] Cfc_RobTag // Tag of the instruction that has the checkpoint
);
    reg [40:0] Rob_mem[31:0];//1bit complete,1bit register write, 5bit rd address, 6bit current rd tag, 6bit pre rd tag, 1bit store word, 21bit store address,
    reg [5:0] rd_ptr, wr_ptr;//32 location, n+1 bit pointer
    reg [5:0] Last_Wr_Ptr;
    reg  [1:0] Valid_InstSW_reg;//Valid_InstSW_reg[1] stands for the validity of last instruction, Valid_InstSW_reg[0] means sw
    integer i;
    //below register is used to decrease the fanout of the signal rob_topptr
    //since this signal has to feed to below submodules of the CPU, the load is really huge which will cause lots of net delay
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_IntQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_MulQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_DivQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_LSQ;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_LSB;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_Mul;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_Div;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_CFC;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_DC;
    (* EQUIVALENT_REGISTER_REMOVAL="NO" *) reg [5:0] Rob_TopPtr_CDB;
    /////////////////////////////
    wire [5:0] Next_rd_ptr;//the updated value of read pointer of the rob
    assign Next_rd_ptr=rd_ptr+1;
    //////////////////////////////
    always @(posedge Clk, negedge Resetb) begin
        if(!Resetb)begin
            //the entry of ROB 不需要reset,因为写入指令时会全部更新的
            rd_ptr<='b0;
            Rob_TopPtr_IntQ<='b0;
            Rob_TopPtr_MulQ<='b0;
            Rob_TopPtr_DivQ<='b0;
            Rob_TopPtr_LSQ<='b0;
            Rob_TopPtr_LSB<='b0;
            Rob_TopPtr_Mul<='b0;
            Rob_TopPtr_Div<='b0;
            Rob_TopPtr_CFC<='b0;
            Rob_TopPtr_DC<='b0;
            Rob_TopPtr_CDB<='b0;
            wr_ptr<='b0;
            Last_Wr_Ptr<='bx;
            Valid_InstSW_reg<=2'b00;//default value is 1, the Dis_PrevPhyAddr will be written into wr_ptr-1 if last instruction is not sw
        end else begin
                Last_Wr_Ptr<=wr_ptr;
                //since part of information of an instruction dispatched at the stage 1 of dispatch unit will enter rob in stage2,
                //the last wr_ptr is used to record the previous write pointer so that the rest of information can be written into the rob correctly
                //////////////////////////////////////////////////////////////////////////////////
                //cdb flush 与ROB commit应该是并行执行的，rob commit包括与store buffer之间的互动
                //cdb flush没有激活时才会考虑与dispatch unit之间的互动
                //write pointer update and entry contents update
                //当cdb flush时，rob entry中的complete bit等不需要置零，因为当新的指令写入时会置零的
                if(Cdb_Flush)begin
                    //注意：cfc_robtag是5bit, 而pointer是6bit,因此我们需要根据wr_ptr 的MSB确定cfc_rob_tag的MSB
                    //when cdb flush occurs, the cdb tells the cfc what the tag of this branch is, then cfc forward this tag to rob 
                    if(Cfc_RobTag<wr_ptr[4:0])begin
                        wr_ptr<={wr_ptr[5],Cfc_RobTag};
                    end else begin
                         wr_ptr<={!wr_ptr[5],Cfc_RobTag};
                    end
                    Valid_InstSW_reg<=2'b00;
                end else begin
                    Valid_InstSW_reg<={Dis_InstValid,Dis_InstSw};
                    if(Dis_InstValid)begin//只要有效，就占用一个entry
                        if(!Dis_InstSw)begin//只要指令不是sw，那么rd, cur tag，prev tag都要写入
                        //重点：并不是每一个写入rob的都是register write,这里的register write bit回用于写入FRL，因此需要分情况讨论
                            Rob_mem[wr_ptr[4:0]]<={1'b0,Dis_RegWrite,Dis_RobRdAddr,Dis_NewRdPhyAddr,6'dx,1'b0,21'dx};
                        end else begin
                            Rob_mem[wr_ptr[4:0]]<={1'b0,1'b0,5'dx,6'dx,6'dx,1'b1,21'dx};//Dis_SwRtPhyAddr is also one clock delay, currently it is not written into ROB
                        end
                        wr_ptr<=wr_ptr+1;//update write pointer
                    end
                    //重点：
                    //if register_write_reg is1, it means the last instruction must be valid
                    //if current cdb flush is active, it will not be written into rob 
                    if(Valid_InstSW_reg==2'b10)begin
                        Rob_mem[Last_Wr_Ptr[4:0]][22+:6]<=Dis_PrevPhyAddr;
                    end else if(Valid_InstSW_reg==2'b11) begin
                        Rob_mem[Last_Wr_Ptr[4:0]][28+:6]<=Dis_SwRtPhyAddr;//sw rt tag is written into current tag field
                    end
                    //重点：之前使用的是wr_ptr[4:0]-1来写入previous phy tag，但是存在问题，因为当wptr变成100000时，00000-1可能得到的并不是11111.
                    //通过额外的register来存放last wr_ptr
                end
                /////////////////////////////////////////
                //read pointer update
                if(Rob_Commit)begin//if commit=1
                    rd_ptr<=Next_rd_ptr;
                    Rob_TopPtr_IntQ<=Next_rd_ptr;
                    Rob_TopPtr_MulQ<=Next_rd_ptr;
                    Rob_TopPtr_DivQ<=Next_rd_ptr;
                    Rob_TopPtr_LSQ<=Next_rd_ptr;
                    Rob_TopPtr_LSB<=Next_rd_ptr;
                    Rob_TopPtr_Mul<=Next_rd_ptr;
                    Rob_TopPtr_Div<=Next_rd_ptr;
                    Rob_TopPtr_CFC<=Next_rd_ptr;
                    Rob_TopPtr_DC<=Next_rd_ptr;
                    Rob_TopPtr_CDB<=Next_rd_ptr;
                end
                //////////////////////////////////////////
                //when data comes out from the cdb, they should update the rob entry as well
                if(Cdb_Valid&&!Cdb_Flush)begin//需要注意JR$8类似的指令，并没有分配ROB entry，因此他们的rob_tag应该是无效的
                    Rob_mem[Cdb_RobTag][40]<=1'b1;//complete bit
                    if(Rob_mem[Cdb_RobTag][21])begin//if it is a store word instruction, then sw address will be written
                        Rob_mem[Cdb_RobTag][20:0]<=Cdb_SwAddr[20:0];//sw address 32bit，分为三部分写入rob,其rt phy rag 写在了current tag，32bit address 分别卸载【21：0】，rd register numebr and prevous phy tag
                        Rob_mem[Cdb_RobTag][22+:6]<=Cdb_SwAddr[26:21];// r
                        Rob_mem[Cdb_RobTag][38-:5]<=Cdb_SwAddr[31:27];//
                    end
                    
                end
        end
    end
    //first we check the complete bit, if it is one, then we check if it is a sw, if it is, then we check if the store buffer is full
    assign Rob_Commit=Rob_mem[rd_ptr[4:0]][40]?(Rob_mem[rd_ptr[4:0]][21]?(SB_Full?1'b0:1'b1):1'b1):1'b0;
    assign Rob_SwAddr={Rob_mem[rd_ptr[4:0]][38-:5],Rob_mem[rd_ptr[4:0]][22+:6],Rob_mem[rd_ptr[4:0]][20:0]};
    //重点：
    //Rob_CommitMemWrite是SB write pointer更新的唯一依据，因此需要确保指令已经完成，并且可以完成commit时才激活
    assign Rob_CommitMemWrite=Rob_Commit&&Rob_mem[rd_ptr[4:0]][21];
    /////////////////////
    //重点：即使当前时钟ROB 确实full,但是如果commit=1,那么dispatch可以继续
    assign Rob_Full=Rob_Commit?1'b0:(((wr_ptr^rd_ptr)==6'b100000)?1'b1:1'b0);
    ///////////////////////////////////////
    //1bit complete,1bit register write, 5bit rd address, 6bit current rd tag, 6bit pre rd tag, 1bit store word, 21bit store address,
    assign Rob_BottomPtr=wr_ptr[4:0];
    assign Rob_CommitRdAddr=Rob_mem[rd_ptr[4:0]][38-:5];
    assign Rob_CommitRegWrite=Rob_mem[rd_ptr[4:0]][39];
    assign Rob_CommitPrePhyAddr=Rob_mem[rd_ptr[4:0]][22+:6];//用于写入FRL
    assign Rob_CommitCurrPhyAddr=Rob_mem[rd_ptr[4:0]][28+:6];//用于更新RRAT
endmodule
