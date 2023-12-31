//-----------------------------------------------------------------------------
//  
//  Copyright (c) 2009 Xilinx Inc.
//
//  Project  : Programmable Wave Generator
//  Module   : uart_tx.v
//  Parent   : wave_gen.v 
//  Children : uart_tx_ctl.v uart_baud_gen.v .v
//
//  Description: 
//     Top level of the UART transmitter.
//     Brings together the baudrate generator and the actual UART transmit
//     controller
//
//  Parameters:
//     BAUD_RATE : Baud rate - set to 57,600bps by default
//     CLOCK_RATE: Clock rate - set to 50MHz by default
//
//  Local Parameters:
//
//  Notes       : 
//
//  Multicycle and False Paths
//     The uart_baud_gen module generates a 1-in-N pulse (where N is
//     determined by the baud rate and the system clock frequency), which
//     enables all flip-flops in the uart_tx_ctl module. Therefore, all paths
//     within uart_tx_ctl are multicycle paths, as long as N > 2 (which it
//     will be for all reasonable combinations of Baud rate and system
//     frequency).
//

`timescale 1ns/1ps

module uart_tx (
  input        clk_tx,          // Clock input
  input        rst_clk_tx,      // Active HIGH reset - synchronous to clk_tx

  input  [7:0] tx_din,              // Data to be sent tou
  input        write_en,     // to write into the internal fifo (meaning sending message)
  output       tx_fifo_full, // The internal fifo is full

  output       txd_tx,           // The transmit serial signal
  output           tx_store_qual,// storage qualification
  output [1:0] tx_frame_indicator, //frame indicator
  output           tx_bit_indicator, //bit indicator
  output [7:0] char_fifo_dout //registered received data for chipscope
);


//***************************************************************************
// Parameter definitions
//***************************************************************************

  parameter BAUD_RATE    = 57_600;              // Baud rate

  parameter CLOCK_RATE   = 50_000_000;

//***************************************************************************
// Reg declarations
//***************************************************************************

//***************************************************************************
// Wire declarations
//***************************************************************************

  wire             baud_x16_en;  // 1-in-N enable for uart_rx_ctl FFs
  
  wire             char_fifo_rd_en;
 // wire [7:0]       char_fifo_dout;
  wire             char_fifo_empty;
  
//***************************************************************************
// Code
//**************************************************************************

// The internal input fifo
  data_fifo_oneclk data_fifo_i0 (
	.din        (tx_din),
	.clk        (clk_tx),
	.rst        (rst_clk_tx),
	.wr_en      (write_en),
	.rd_en      (char_fifo_rd_en),
	.dout       (char_fifo_dout),
	.empty      (char_fifo_empty),
	.full       (tx_fifo_full)
	);

  uart_baud_gen #
  ( .BAUD_RATE  (BAUD_RATE),
    .CLOCK_RATE (CLOCK_RATE)
  ) uart_baud_gen_tx_i0 (
    .clk         (clk_tx),
    .rst         (rst_clk_tx),
    .baud_x16_en (baud_x16_en)
  );

  uart_tx_ctl uart_tx_ctl_i0 (
    .clk_tx	        (clk_tx),          // Clock input
    .rst_clk_tx	        (rst_clk_tx),      // Active HIGH reset

    .baud_x16_en        (baud_x16_en),     // 16x oversample enable

    .char_fifo_empty	(char_fifo_empty), // Empty signal from char FIFO (FWFT)
    .char_fifo_dout	(char_fifo_dout),  // Data from the char FIFO
    .char_fifo_rd_en	(char_fifo_rd_en), // Pop signal to the char FIFO

    .txd_tx	        (txd_tx),           // The transmit serial signal
	.tx_store_qual (tx_store_qual),
    .tx_frame_indicator (tx_frame_indicator), 
    .tx_bit_indicator (tx_bit_indicator)
  );

endmodule
