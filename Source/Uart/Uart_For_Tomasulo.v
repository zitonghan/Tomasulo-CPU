//-----------------------------------------------------------------------------
//
//  Copyright (c) 2009 Xilinx Inc.
//
//  Project  : Programmable Wave Generator
//  Module   : wave_gen.v
//  Parent   : None
//  Children : Many
//
//  Description:
//
//  Parameters:
//     BAUD_RATE:     Desired Baud rate for both RX and TX
//     CLOCK_RATE_RX: Clock rate for the RX domain
//     CLOCK_RATE_TX: Clock rate for the TX domain
//
//  Local Parameters:
//
//  Notes       :
//

`timescale 1ns/1ps


module uart_tomasulo (
  input            clk_sys,      // Clock input (from pin)
  input            rst_clk,        // Active HIGH reset (from pin)

  // RS232 signals
  input            rxd_i,        // RS232 RXD pin
  output           txd_o,        // RS232 RXD pin
  output reg       LED0,
  output reg       LED1,
  output reg       LED2,
  output reg       LED3,
  output reg       LED4,
  output reg       Bram_we1,//dc
  output reg       Bram_we2,//ic
  output reg       [5:0] Bram_WrAddr,
  output reg       [6:0] Bram_RdAddr1,
  output reg       [6:0] Bram_RdAddr2,//we need the bram_rdaddr=64 as a flag to recognize the sending process is done
  output reg       [127:0] Data_OneRow,
  input            [31:0] Bram_Dout1,
  input            [127:0] Bram_Dout2,
  // // button L
  input            BTNL, //used for debug,
  output           btnl_scen
);
// function integer max;
// input integer a,b;
// begin
//   max = (a>b)? a : b;
// end
// endfunction

// function integer max8;
// input integer a,b,c,d,e,f,g,h;
// begin
//   max8 = max(max(max(a,b),max(c,d)),max(max(e,f),max(g,h)));
// end
// endfunction

//***************************************************************************
// Parameter definitions
//***************************************************************************

  parameter BAUD_RATE           = 115_200;

  parameter CLOCK_RATE_RX       = 100_000_000;
  parameter CLOCK_RATE_TX       = 100_000_000;
  parameter DATA_WIDTH          = 32;
  parameter NumOfRow            = 64;
  parameter NumOfFile           = 2;//for tomasulo test we need to load IC and DC seperately
  parameter OutFileName1         = 40'h5465737431;//expected output file name out_test1
  parameter OutFileName2         = 40'h5465737432;//expected output file name out_test2
  localparam
      ACK = 8'h06,
      SOH = 8'h01,
      EOT = 8'h03,
      SOT = 8'h02,
      EOM = 8'h19,
      CR = 8'h0d,
      LF = 8'h0a,
      EOF = 8'h04,
      SPACE = 8'h20,
      COM = 8'h2c;
  // To/From IBUFG/OBUFG
  // No pin for clock - the IBUFG is internal to clk_gen
//   wire        rst_i;
//   wire        rxd_i;
//   wire        txd_o;

  // From Clock Generator
//   wire        clk_sys;         // Receive clock

  // From Reset Generator
//   wire        rst_clk;     // Reset, synchronized to clk_rx

  // From the RS232 receiver
  wire        rxd_clk_rx;     // RXD signal synchronized to clk_rx
  wire        rx_data_rdy;    // New character is ready
  wire        rx_data_rdy_reg;
  wire [7:0]  rx_data;        // New character
  wire        rx_lost_data;   // Rx data lost

  // // From the debouncer module
  // wire        btnl_scen;        // SCEN of btnl
//   wire        btnr_scen;
  // From the UART transmitter
  wire        tx_fifo_full;  // Pop signal to the char FIFO

  // From the sending file module
  wire          send_fifo_full;     // the input fifo of this module is full
  wire          send_finish;        // the sending process has finished; 1 clock wide
  wire [7:0]    tx_din_send_module; // data to the tx module
  wire          tx_write_en_send_module;        // write enable signal to the tx module
  wire          rx_read_en_send_module;         // pop signal to the rx module

  // From the receiving file module
  wire          rx_read_en_receive_module;
  wire [7:0]    tx_din_receive_module;
  wire          tx_write_en_receive_module;
  wire [7:0]    receive_fifo_dout;          // the received data flow
  wire          receive_data_rdy;           // received data ready
  wire [7:0]    reg_addr;                   // reg address
  wire [7:0]    reg_pointer;                // reg pointer content
  wire          reg_ready;                  // reg information ready signal

  // Given in the current module
  // to the tx module
  wire [7:0]    tx_din;     // data to be sent in tx
  wire          tx_write_en;    // send signal to tx
  wire [7:0]    char_fifo_dout; //registered received data for chipscope
  // to the rx module
  wire          rx_read_en;     // pop an entry in the rx fifo
  wire [7:0]    rx_data_reg; //registered received data for chipscope
  // to the send file module
  reg [7:0]     send_fifo_din;      // the input data to the send module
  wire          send_fifo_we;       // signal to send data
  wire          start_send_file;         // start send signal
  // to the receive file module
  wire          receive_fifo_re;        // pop information from receive file module
  // decide if current is rx or tx
  wire           receive_sendbar;       // 1 means currently is receiving data; 0 mean currently is sending data
  ///////////////////////
  //signals for receive file from Uart
  reg [7:0] File_ID;//2 character, each caracter is converted to 4 digits
  reg Wait_for_EOF;//since after the FPGA sends out the last row of a  file, it needs one extra clock to send EOF
  //above ID is specified in .ark file
  reg [$clog2(DATA_WIDTH*4/4):0] nibble_cnt;//since we can receive only 4bit data from the uart, but one row of data for data cache need 32bit and 128bit for inst cache
  //so we use this signal to locate where this newly received 4bit should be filled in.  we set this variable to 6bits. sicne the data stored in IC is 128bit
  reg [$clog2(NumOfRow)-1:0] Row_Pointer;//the row address for bram
  reg [$clog2(NumOfFile):0] File_cnt;//used to count how many files need to be transfered 
  reg [3:0] cnt_send; //used during sending data back to pc, before sending the content of the file, we have to send the file name to pc, the cunter is used to indicate when we can send the real data of a file to pc
  /////////////////////////////////
//***************************************************************************
// Code
//***************************************************************************
  
  // Instantiate input/output buffers
//   IBUF IBUF_rst_i0      (.I (rst_pin),      .O (rst_clk));
//   BUFG BUFG_CLK       (.I(clk_pin),      .O(clk_sys));

    // This function takes the lower 7 bits of a character and converts them
    // to a hex digit. It returns 5 bits - the upper bit is set if the character
    // is not a valid hex digit (i.e. is not 0-9,a-f, A-F), and the remaining
    // 4 bits are the digit
    function [4:0] to_val;//used to convert 0-9 a-f to value in hex
        input [6:0] char;
        begin
            if ((char >= 7'h30) && (char <= 7'h39)) // 0-9
            begin
                to_val[4]   = 1'b0;
                to_val[3:0] = char[3:0];
            end
            else if (((char >= 7'h41) && (char <= 7'h46)) || // A-F
                ((char >= 7'h61) && (char <= 7'h66)) )  // a-f
            begin
                to_val[4]   = 1'b0;
                to_val[3:0] = char[3:0] + 4'h9; // gives 10 - 15
            end
            else
            begin
                to_val      = 5'b1_0000;
            end
        end
    endfunction

    function [7:0] to_char;
        input [3:0] val;
        begin
            if ((val >= 4'h0) && (val <= 4'h9)) // 0-9
            begin
                to_char = {4'h3, val};
            end
            else
            begin
                to_char = val + 8'h37; // gives 10 - 15
            end
        end
    endfunction

  // Instantiate the reset generator
//   rst_gen rst_gen_i0 (
//     .clk_i          (clk_sys),          // Receive clock
//     .rst_i           (rst_i),           // Asynchronous input - from IBUF
//     .rst_o      (rst_clk)      // Reset, synchronized to clk_rx
//   );

  // // Debouncing module for BTNL
  ee201_debouncer debouncer_i0(
      .CLK          (clk_sys),
      .RESET        (rst_clk),
      .PB           (BTNL),
      .DPB          (),
      .SCEN         (btnl_scen),
      .MCEN         (),
      .CCEN         ()
  );
  // file sending module
  send_file send_file_i0 (
      // for debug
      .state                (),
      // clock and reset
      .clk                  (clk_sys),
      .reset                (rst_clk),
      // communication with user
      .start_send           (start_send_file),     // start signal
      .send_fifo_din        (send_fifo_din),                // data input to the input fifo
      .send_fifo_we         (send_fifo_we),                 //write enable to the input fifo
      .send_fifo_full       (send_fifo_full),              // input fifo is full
      .finish_send          (send_finish),        // send finishes

      // communication with tx fifo
      .tx_fifo_full         (tx_fifo_full),           // tx fifo is full
      .tx_fifo_din          (tx_din_send_module),  // send data to the tx fifo
      .tx_fifo_we           (tx_write_en_send_module),           // write enable to tx fifo

      // communication with rx module
      .rx_data              (rx_data),  // Character to be parsed
      .rx_data_rdy          (rx_data_rdy), // Ready signal for rx_data
      .rx_read_en           (rx_read_en_send_module) // Pop entry from rx fifo
  );

  // file receiving module
  receive_file receive_file_i0(
      .state                (),     //for debug
      // clk and reset
      .clk                  (clk_sys),         // Clock input
      .reset                (rst_clk),     // Active HIGH reset - synchronous to clk_rx

      // communication with rx module
      .rx_data              (rx_data),        // Character to be parsed
      .rx_data_rdy          (rx_data_rdy),         // Ready signal for rx_data
      .rx_read_en           (rx_read_en_receive_module),       // pop entry in rx fifo

      // communication with tx module
      .tx_fifo_full         (tx_fifo_full),     // the tx fifo is full
      .tx_din               (tx_din_receive_module),         // data to be sent
      .tx_write_en          (tx_write_en_receive_module),          // write enable to tx

      // communication with user
      .receive_fifo_dout    (receive_fifo_dout),      // data output of the fifo
      .receive_data_rdy     (receive_data_rdy),         // there is data ready at the output fifo
      .receive_fifo_re      (receive_fifo_re),            // pop entry in the receive fifo

      // register information
      .reg_addr             (reg_addr),       // register address of the specifier
      .reg_pointer          (reg_pointer),    // content of the specifier
      .reg_ready            (reg_ready)      // indication when the reg data is available. It's available only
                                          // after both the address and the content is ready.
      );


  // Instantiate the UART receiver
  uart_rx #(
    .BAUD_RATE   (BAUD_RATE),
    .CLOCK_RATE  (CLOCK_RATE_RX)
  ) uart_rx_i0 (
  //system configuration:
    .clk_rx      (clk_sys),              // Receive clock
    .rst_clk_rx  (rst_clk),          // Reset, synchronized to clk_rx
    .rxd_i       (rxd_i),               // RS232 receive pin
    .rxd_clk_rx  (rxd_clk_rx),          // RXD pin after sync to clk_rx

  //user interface:
    .read_en     (rx_read_en),                    // input to the module: pop an element from the internal fifo
    .rx_data_rdy (rx_data_rdy),         // New data is ready
	 .rx_data_rdy_reg (rx_data_rdy_reg),
    .rx_data     (rx_data),             // New data
    .lost_data   (rx_lost_data),                    // fifo is full but new data still comes in, resulting in data lost
    .frm_err     (),                     // Framing error (unused)
	.rx_store_qual      (),
    .rx_frame_indicator (),
    .rx_bit_indicator   (),
    .rx_data_reg        ()

  );

  // Instantiate the UART transmitter
  uart_tx #(
    .BAUD_RATE    (BAUD_RATE),
    .CLOCK_RATE   (CLOCK_RATE_TX)
  ) uart_tx_i0 (
  //system configuration:
    .clk_tx             (clk_sys),          // Clock input
    .rst_clk_tx         (rst_clk),      // Reset - synchronous to clk_tx
    .txd_tx             (txd_o),           // The transmit serial signal

  //user interface:
    .write_en           (tx_write_en), // signal to send to data out
    .tx_din             (tx_din), // data to be sent
    .tx_fifo_full       (tx_fifo_full),  // the internal fifo is full, should stop sending data
	.tx_store_qual      (),
    .tx_frame_indicator (),
    .tx_bit_indicator   (),
    .char_fifo_dout     ()
  );

  // mux for input to rx and tx module
  //before send data back, the tx module will receive the response symbol like  ACK from receive file module, to forward receiving complete file from pc
  assign tx_din = receive_sendbar ? tx_din_receive_module : tx_din_send_module;
  assign tx_write_en = receive_sendbar ? tx_write_en_receive_module : tx_write_en_send_module;
  assign rx_read_en = receive_sendbar ? rx_read_en_receive_module : rx_read_en_send_module;


//   fifo IO with division:
  localparam
    IDLE = 4'b0000,
    WAIT_RECV = 4'b0001,     // wait for the SOT signal for X
    RECV = 4'b0011,
    COMP = 4'b0101,
    SEND = 4'b0110,
	  WAIT_SEND_DONE = 4'b1000,
    DONE = 4'b1001;

  reg [3:0]         state;
  wire [4:0]        char_to_digit = to_val(receive_fifo_dout[6:0]);      // the hex result of the received data

    // combinational logic
    //the connection between rx,tx,receive_file,send_file modules
  assign receive_fifo_re = (state == WAIT_RECV || state == RECV) && receive_data_rdy;
  assign start_send_file = (state == SEND);
  assign send_fifo_we = (state == SEND) && (~send_fifo_full);
  assign receive_sendbar = (state == IDLE || state == WAIT_RECV || state == RECV);

  //FSM used to conmunicate with user inferface
  //below FSM are used to receive two files from the uart then go to the COMP state, we can do some computation based on the receive data during this state
  //then through press the btnl button, we can begin send the processed data back to pc
  always @(posedge clk_sys) begin
      if(rst_clk)begin
          state <=IDLE;
          Bram_we1<=1'b0;
          Bram_we2<=1'b0;
          File_cnt<=NumOfFile-1;
          LED0<='b0;
          LED1<='b0;
          LED2<='b0;
          LED3<='b0;
          LED4<='b0;
          Wait_for_EOF<=1'b1;
      end else begin
        //bram write address update
        //since if the value of row_pointer will be updated at the next rising clock edge, the date to be written into the bram will also be ready at the next edge
        //so wo should delay the update of bram address for one clock 
        Bram_WrAddr<=Row_Pointer;
        ////////////////////////////////////
        if(Bram_we1)begin//the bram write enable signals will be activated just for one clock
            Bram_we1<=!Bram_we1;
        end 
        if(Bram_we2)begin
            Bram_we2<=!Bram_we2;
        end 
        ///IDLE, WAIT_REC, RECV, COMP, SEND, WAIT_FOR_SEND
        case(state)
          IDLE:begin
            if(reg_ready && reg_pointer == 8'h00)begin//when the receive_file module receive a valid file, the reg_ready signal will be activated  for one clock
            //if the FSM detect this signal, we can go to the wait_rec state to receive the data from uart
              state <= WAIT_RECV;
              File_ID<= reg_addr;//file identifier, we can use the identifier to store the file contents into different bram
              nibble_cnt<='b0;//reset the index used to fill up one row of data for bram
              Row_Pointer<='b0;
              Bram_RdAddr1<='b0;
              Bram_RdAddr2<='b0;
              cnt_send<='b0;//counter used for counting when sending file name to the pc
            end
          end
          WAIT_RECV:begin
            if (receive_data_rdy && receive_fifo_dout == SOT) begin//the start of the file
                state <= RECV; // ignore any non-SOT characters
                if(File_ID==8'h00)begin
                    LED0<=1'b1;//used to indicate current received file is file1
                end else if(File_ID==8'h01)begin
                    LED1<=1'b1;//used to indicate current received file is file2
                end
            end
          end
          RECV:begin//current just receive one file from the pc and store it into a bram
            if (receive_data_rdy && (~char_to_digit[4])) begin//char_to_digit[4]==0 indicate that current data is a valid character
                if(File_ID==8'h00)begin//load the first file, since the lengh of one row data in these two files are different, so we have to deal with them seperately
                    Data_OneRow[DATA_WIDTH-nibble_cnt*4-1 -: 4]<=char_to_digit[3:0];
                end else if(File_ID==8'h01)begin
                    Data_OneRow[DATA_WIDTH*4-nibble_cnt*4-1 -: 4]<=char_to_digit[3:0];
                end
                if(Row_Pointer<6'b111111)begin//it is not the last row of the file
                    if(File_ID==8'h00)begin
                        if (nibble_cnt < 6'b00_0111) begin//the conditon of reseting the nibble_cnt signal is different for these two files
                            nibble_cnt <= nibble_cnt+1;   
                        end else begin//one row of data is ready to be written into a bram in the next cycle
                            nibble_cnt <= 6'b00_0000;//then we reset the nibble cnt and activate the write enable signal and update the bram write address
                            Bram_we1<=!Bram_we1;
                            Row_Pointer<=Row_Pointer+1;
                        end
                    end else if (File_ID==8'h01) begin
                        if (nibble_cnt < 6'b01_1111) begin
                            nibble_cnt <= nibble_cnt+1;   
                        end else begin//one row of data is ready to be written into a bram in the next cycle
                            nibble_cnt <= 6'b00_0000;
                            Bram_we2<=!Bram_we2;
                            Row_Pointer<=Row_Pointer+1;
                        end
                    end
                end else begin//last row
                    if(File_ID==8'h00)begin
                        if (nibble_cnt < 6'b00_0111) begin
                            nibble_cnt <= nibble_cnt+1;   
                        end else begin//one row of data is ready to be written into a bram in the next cycle
                            Bram_we1<=!Bram_we1;//assign 1
                            state<=IDLE;//if the last row of the fisrt file has been received, then we go back to the IDLE state to wait for another file
                        end
                    end else if(File_ID==8'h01)begin
                        if (nibble_cnt < 6'b01_1111) begin
                            nibble_cnt <= nibble_cnt+1;   
                        end else begin//one row of data is ready to be written into a bram in the next cycle
                            Bram_we2<=!Bram_we2;//assign 1
                            state<=COMP;//the last file has been received, then we go to he COMP state
                            nibble_cnt<='b0;//get ready for sending data out frm bram
                            LED2<=1'b1;//LED0 will be one when data is fully received from pc
                        end
                    end
                end
            end
          end
          //start process the data receive from the pc
          COMP:begin//current this state is empty, we can process the data stored in the bram during this process
            if(btnl_scen)begin//for debug start send data back to pc
              state<=SEND;
            end
          end
          SEND:begin//start send the data back to pc
              if(!send_fifo_full)begin//we can forward data to send_file module as long as its fifo is not full, the write enable will be acticated at the same time, then update bram read pointer
                if(cnt_send<4'b1000)begin//when cnt_send is 8 that means currently the first row of data in bram is sending
                  cnt_send<=cnt_send+1;
                end else begin
                    if(File_cnt)begin//count how many file need to be sent back
                        if(nibble_cnt<6'b00_1001)begin//the reason why the condition here is 001001 is that besides the 8 4-bit data which represent one row of data in bram, we also have to send CR and LF to indicate it is the end of a row in a file
                            nibble_cnt<=nibble_cnt+1;
                            if(nibble_cnt==6'b00_1000)begin//重点：:notice the one clock delay for read out a data from bram, next cycle nibble cnt =1001, the last 4bit has been read out and new adddress is applied to the bram, next cycle, new data comes out, nibble cnt is reset to 0
                            //so that we can start accessing a new row of data in bram
                                Bram_RdAddr1<=Bram_RdAddr1+1;
                            end
                        end else begin
                            if(Bram_RdAddr1==NumOfRow)begin//during sending the content of the first file back to pc, once the last row of the first file has been fully processed, we have to wait for another clock to send the EOF flag to PC
                            //so We use this wait_for_EOF to implement this function
                               if(Wait_for_EOF)begin//currently the LF is sending out from FPGA
                                    Wait_for_EOF<=!Wait_for_EOF;
                                end else begin//currently the EOF is sending out from FPGA, next clock, a new file can be sent out
                                    nibble_cnt<='b0;
                                    File_cnt<=File_cnt-1;
                                    cnt_send<='b0;//reset the cnt , so the second file will be started to be sent back to pc
                                    Wait_for_EOF<=!Wait_for_EOF;
                                    LED3<=1'b1;//used led3 to indicate this point of time
                                end 
                            end else begin//if current row is not the last row of the first file, then we reset the nibble cnt to get ready for the next row
                                nibble_cnt<='b0;
                            end                          
                        end
                    end else begin//the last file to send to pc
                        if(nibble_cnt<6'b10_0001)begin
                            nibble_cnt<=nibble_cnt+1;
                            if(nibble_cnt==6'b10_0000)begin//notice the one clock delay for read out a data from bram, next cycle nibble cnt =7, the last 4bit has been read out and new adddress is applied to the bram, next cycle, new data comes out, nibble cnt is set to 0
                                Bram_RdAddr2<=Bram_RdAddr2+1;
                            end
                        end else begin
                            nibble_cnt<='b0;
                            if(Bram_RdAddr2==NumOfRow)begin//the last row of bram has been send out to the pc, the send process is done, then go to the wait satate
                                state<=WAIT_SEND_DONE;
                            end
                        end
                    end
                end
              end
          end
          WAIT_SEND_DONE:	begin
            if (send_finish == 1'b1) begin
              state <= IDLE;
              LED4<=1'b1;//when entire send process is done, LED1 will be on
            end
          end
          // Wait for the entire sending process to finish;
				  // After that go back to the receive mode (IDLE state)    
        endcase
      end
  end
    ///////////////////
    //Bram for initializing DC

  // the logic for input to the send buffer. This is the entire character flow of sending a file, including controling characters
  always @ (*) //
  begin
    if (state == SEND)
    begin
        if (cnt_send == 0) send_fifo_din = SOH;
        else if (cnt_send == 1) send_fifo_din = (File_cnt? OutFileName1[39:32]: OutFileName2[39:32]);
        else if (cnt_send == 2) send_fifo_din = (File_cnt? OutFileName1[31:24]: OutFileName2[31:24]);//file name is not cared by the pc
        else if (cnt_send == 3) send_fifo_din = (File_cnt? OutFileName1[23:16]: OutFileName2[23:16]);
        else if (cnt_send == 4) send_fifo_din = (File_cnt? OutFileName1[15: 8]: OutFileName2[15: 8]);
        else if (cnt_send == 5) send_fifo_din = (File_cnt? OutFileName1[ 7: 0]: OutFileName2[ 7: 0]);
        else if (cnt_send == 6) send_fifo_din = EOT;
        else if (cnt_send == 7) send_fifo_din = SOT;
        else if (cnt_send == 8 )begin
            if(File_cnt)begin
                if(!(Bram_RdAddr1==NumOfRow&&nibble_cnt==6'b00_1001))begin
                    if (nibble_cnt<6'b00_1000) send_fifo_din = to_char(Bram_Dout1[DATA_WIDTH-nibble_cnt*4-1 -: 4]);
                    else if (nibble_cnt==6'b00_1000) send_fifo_din = CR; // line ending
                    else if (nibble_cnt==6'b00_1001) send_fifo_din = LF;
                    else send_fifo_din = 8'hXX;
                end else begin
                    send_fifo_din = EOF;//all contents in the bram has been send out to the pc
                end
            end else begin
                if(!(Bram_RdAddr2==NumOfRow&&nibble_cnt==6'b10_0001))begin
                    if (nibble_cnt<6'b10_0000) send_fifo_din = to_char(Bram_Dout2[DATA_WIDTH*4-nibble_cnt*4-1 -: 4]);
                    else if (nibble_cnt==6'b10_0000) send_fifo_din = CR; // line ending
                    else if (nibble_cnt==6'b10_0001) send_fifo_din = LF;
                    else send_fifo_din = 8'hXX;
                end else begin
                    send_fifo_din = EOF;//all contents in the bram has been send out to the pc
                end
            end
        end
    end
  end

endmodule
