// =============================================================
// L2 TLB Response FIFO – FINAL, 600MHz SAFE, BUBBLE-FREE
// - Zero-Bubble Registered Output (FWFT to Flop-Out)
// - Strict Backpressure to prevent data drops
// =============================================================
`timescale 1ns/1ps

module l2_tlb_response_fifo #(
  parameter int DEPTH  = 8,
  parameter int ID_W   = 5,
  parameter int PPN_W  = 32,
  parameter int PERM_W = 3
)(
  input  logic                 clk_i,
  input  logic                 rstn_i,

  // -------------------------------
  // Inputs from L2 TLB Core (Hit)
  // -------------------------------
  input  logic                 l2_tlb_resp_valid_i,
  output logic                 l2_tlb_resp_ready_o,  // FIX 1: Backpressure
  input  logic [ID_W-1:0]      l2_tlb_resp_id_i,
  input  logic [PPN_W-1:0]     l2_tlb_resp_ppn_i,
  input  logic [PERM_W-1:0]    l2_tlb_resp_perm_i,
  input  logic                 l2_tlb_resp_page_size_i,
  input  logic                 l2_tlb_resp_error_i,

  // -------------------------------
  // Inputs from L2 MSHR (Miss Fanout)
  // -------------------------------
  input  logic                 l2_mshr_resp_valid_i,
  output logic                 l2_mshr_resp_ready_o, // FIX 1: Backpressure
  input  logic [ID_W-1:0]      l2_mshr_resp_id_i,
  input  logic [PPN_W-1:0]     l2_mshr_resp_ppn_i,
  input  logic [PERM_W-1:0]    l2_mshr_resp_perm_i,
  input  logic                 l2_mshr_resp_page_size_i,
  input  logic                 l2_mshr_resp_error_i,

  // -------------------------------
  // Output to AXI Read Response Gen
  // -------------------------------
  output logic                 resp_valid_o,
  output logic [ID_W-1:0]      resp_id_o,
  output logic [PPN_W-1:0]     resp_ppn_o,
  output logic [PERM_W-1:0]    resp_perm_o,
  output logic                 resp_page_size_o,
  output logic                 resp_error_o,
  input  logic                 resp_ready_i
);

  typedef struct packed {
    logic [ID_W-1:0]   id;
    logic [PPN_W-1:0]  ppn;
    logic [PERM_W-1:0] perm;
    logic              page_size;
    logic              error;
  } resp_entry_t;

  resp_entry_t mem [DEPTH];

  logic [$clog2(DEPTH)-1:0]   rd_ptr, wr_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;

  wire fifo_full  = (count == DEPTH);
  wire fifo_empty = (count == 0);

  // =============================================================
  // 600MHz FIX 1: Safe Push Logic & Backpressure Arbitration
  // =============================================================
  
  // TLB has strict priority over MSHR
  assign l2_tlb_resp_ready_o  = !fifo_full;
  assign l2_mshr_resp_ready_o = !fifo_full && !l2_tlb_resp_valid_i; 

  logic        do_push;
  resp_entry_t push_data;

  always_comb begin
    do_push   = 1'b0;
    push_data = '0;

    // Evaluate TLB first, then MSHR based on Ready signals
    if (l2_tlb_resp_valid_i && l2_tlb_resp_ready_o) begin
      do_push   = 1'b1;
      push_data = '{ id: l2_tlb_resp_id_i, ppn: l2_tlb_resp_ppn_i, perm: l2_tlb_resp_perm_i, page_size: l2_tlb_resp_page_size_i, error: l2_tlb_resp_error_i };
    end 
    else if (l2_mshr_resp_valid_i && l2_mshr_resp_ready_o) begin
      do_push   = 1'b1;
      push_data = '{ id: l2_mshr_resp_id_i, ppn: l2_mshr_resp_ppn_i, perm: l2_mshr_resp_perm_i, page_size: l2_mshr_resp_page_size_i, error: l2_mshr_resp_error_i };
    end
  end

  // =============================================================
  // 600MHz FIX 2: Zero-Bubble "Lookahead" Output Stage
  // =============================================================
  logic        do_pop;
  resp_entry_t out_q;
  logic        out_valid_q;

  // Magic Formula: We pop from the SRAM if it's not empty AND 
  // (the output flop is currently empty OR the downstream AXI interface is taking the data right now)
  assign do_pop = !fifo_empty && (!out_valid_q || resp_ready_i);

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      out_valid_q <= 1'b0;
      out_q       <= '0;
    end else begin
      if (do_pop) begin
        out_valid_q <= 1'b1;
        out_q       <= mem[rd_ptr]; // Pull directly into flop
      end else if (resp_ready_i) begin
        out_valid_q <= 1'b0;        // Clear flop if downstream took it and FIFO is empty
      end
    end
  end

  // =============================================================
  // FIFO Core Pointers
  // =============================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (do_push) begin
        mem[wr_ptr] <= push_data;
        wr_ptr      <= wr_ptr + 1'b1;
      end

      if (do_pop) begin
        rd_ptr <= rd_ptr + 1'b1;
      end

      case ({do_push, do_pop})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ; // 11 or 00, count remains same
      endcase
    end
  end

  // =============================================================
  // Registered Output Assignments (Flop-Out Safe)
  // =============================================================
  assign resp_valid_o     = out_valid_q;
  assign resp_id_o        = out_q.id;
  assign resp_ppn_o       = out_q.ppn;
  assign resp_perm_o      = out_q.perm;
  assign resp_page_size_o = out_q.page_size;
  assign resp_error_o     = out_q.error;

endmodule