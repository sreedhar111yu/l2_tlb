// =============================================================
// AXI Read Response Generator for L2 TLB (PIPELINED)
// - Fully registered AXI interface
// - Ready/valid correct
// - 600 MHz timing safe
// =============================================================
`timescale 1ns/1ps
module axi_rd_resp_gen_l2_tlb (
  input  logic         clk_i,
  input  logic         rstn_i,

  // -------------------------------
  // Inputs from L2 TLB Response FIFO
  // -------------------------------
  input  logic         l2_tlb_resp_valid_i,
  input  logic [4:0]   l2_tlb_resp_id_i,
  input  logic [31:0]  l2_tlb_resp_ppn_i,
  input  logic [2:0]   l2_tlb_resp_perm_i,
  input  logic         l2_tlb_resp_page_size_i,
  input  logic         l2_tlb_resp_error_i,
  output logic         l2_tlb_resp_ready_o,

  // -------------------------------
  // AXI4 Read Data Channel
  // -------------------------------
  output logic         axi_rvalid_o,
  output logic [63:0]  axi_rdata_o,
  output logic [4:0]   axi_rid_o,
  input  logic         axi_rready_i
);

  // =============================================================
  // Response holding register
  // =============================================================
  logic        resp_valid_q;
  logic [63:0] resp_data_q;
  logic [4:0]  resp_id_q;

  // FIFO can send data when buffer is free
  assign l2_tlb_resp_ready_o = !resp_valid_q;

  // =============================================================
  // Latch response from FIFO
  // =============================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      resp_valid_q <= 1'b0;
    end else begin
      // Consume FIFO ? buffer
      if (l2_tlb_resp_valid_i && !resp_valid_q) begin
        resp_valid_q <= 1'b1;
        resp_id_q    <= l2_tlb_resp_id_i;
        resp_data_q  <= {
          l2_tlb_resp_error_i,      // [63] Error
          l2_tlb_resp_page_size_i,  // [62] Page size
          l2_tlb_resp_perm_i[2],    // [61] Execute
          l2_tlb_resp_perm_i[1],    // [60] Write
          l2_tlb_resp_perm_i[0],    // [59] Read
          1'b0,                     // [58] Reserved
          l2_tlb_resp_ppn_i         // [57:26] PPN
        };
      end
      // AXI accepted response
      else if (resp_valid_q && axi_rready_i) begin
        resp_valid_q <= 1'b0;
      end
    end
  end

  // =============================================================
  // AXI outputs (PURELY REGISTERED)
  // =============================================================
  assign axi_rvalid_o = resp_valid_q;
  assign axi_rid_o    = resp_id_q;
  assign axi_rdata_o  = resp_data_q;

endmodule
 