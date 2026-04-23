// =============================================================
// L2 TLB Response FIFO (PIPELINED, SAFE)
// - Accepts responses from TLB hit or MSHR miss
// - Priority: TLB > MSHR (as per Excel intent)
// - Registered output (no combinational memory read)
// - 600 MHz timing-friendly
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
  input  logic [ID_W-1:0]      l2_tlb_resp_id_i,
  input  logic [PPN_W-1:0]     l2_tlb_resp_ppn_i,
  input  logic [PERM_W-1:0]    l2_tlb_resp_perm_i,
  input  logic                 l2_tlb_resp_page_size_i,
  input  logic                 l2_tlb_resp_error_i,

  // -------------------------------
  // Inputs from L2 MSHR (Miss)
  // -------------------------------
  input  logic                 l2_mshr_resp_valid_i,
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

  logic [$clog2(DEPTH)-1:0] rd_ptr, wr_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;

  wire fifo_full  = (count == DEPTH);
  wire fifo_empty = (count == 0);

  // -------------------------------------------------
  // Push selection (priority: TLB > MSHR)
  // -------------------------------------------------
  logic push;
  resp_entry_t push_data;

  always_comb begin
    push      = 1'b0;
    push_data = '0;

    if (!fifo_full) begin
      if (l2_tlb_resp_valid_i) begin
        push = 1'b1;
        push_data = '{
          id        : l2_tlb_resp_id_i,
          ppn       : l2_tlb_resp_ppn_i,
          perm      : l2_tlb_resp_perm_i,
          page_size : l2_tlb_resp_page_size_i,
          error     : l2_tlb_resp_error_i
        };
      end
      else if (l2_mshr_resp_valid_i) begin
        push = 1'b1;
        push_data = '{
          id        : l2_mshr_resp_id_i,
          ppn       : l2_mshr_resp_ppn_i,
          perm      : l2_mshr_resp_perm_i,
          page_size : l2_mshr_resp_page_size_i,
          error     : l2_mshr_resp_error_i
        };
      end
    end
  end

  wire pop = !fifo_empty && resp_ready_i;

  // -------------------------------------------------
  // FIFO state update
  // -------------------------------------------------
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (push) begin
        mem[wr_ptr] <= push_data;
        wr_ptr <= wr_ptr + 1'b1;
      end

      if (pop) begin
        rd_ptr <= rd_ptr + 1'b1;
      end

      case ({push,pop})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase
    end
  end

  // -------------------------------------------------
  // Registered output stage
  // -------------------------------------------------
  resp_entry_t out_q;
  logic        out_valid_q;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      out_valid_q <= 1'b0;
    end else begin
      if (!out_valid_q && !fifo_empty) begin
        out_q       <= mem[rd_ptr];
        out_valid_q <= 1'b1;
      end
      else if (out_valid_q && resp_ready_i) begin
        out_valid_q <= 1'b0;
      end
    end
  end

  assign resp_valid_o     = out_valid_q;
  assign resp_id_o        = out_q.id;
  assign resp_ppn_o       = out_q.ppn;
  assign resp_perm_o      = out_q.perm;
  assign resp_page_size_o = out_q.page_size;
  assign resp_error_o     = out_q.error;

endmodule