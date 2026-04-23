`timescale 1ns/1ps

module axi_rd_req_rx_l2_tlb (
  input  logic        clk_i,
  input  logic        rstn_i,

  // AXI4 Read Address Channel
  input  logic        axi_arvalid_i,
  input  logic [31:0] axi_araddr_i,
  input  logic [2:0]  axi_aruser_i,
  input  logic [4:0]  axi_arid_i,
  output logic        axi_arready_o,

  // To L2 TLB Core (PIPELINED)
  output logic        l2_tlb_req_valid_o,
  output logic [31:0] l2_tlb_req_vpn_o,
  output logic [2:0]  l2_tlb_req_perm_o,
  output logic [4:0]  l2_tlb_req_id_o,
  input  logic        l2_tlb_req_ready_i
);

  // 600MHz FIX: Zero-Bubble Skid Buffer Logic
  // Allows back-to-back transfers while keeping AXI Ready registered.
  
  logic load_req;
  assign load_req = axi_arvalid_i && axi_arready_o;
  
  // Ready if our output is empty, OR if the core is taking the current data
  assign axi_arready_o = !l2_tlb_req_valid_o || l2_tlb_req_ready_i;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      l2_tlb_req_valid_o <= 1'b0;
    end else begin
      if (load_req) begin
        l2_tlb_req_valid_o <= 1'b1;
      end else if (l2_tlb_req_ready_i) begin
        l2_tlb_req_valid_o <= 1'b0;
      end
    end
  end

  // Data path flops
  always_ff @(posedge clk_i) begin
    if (load_req) begin
      l2_tlb_req_vpn_o  <= axi_araddr_i; 
      l2_tlb_req_perm_o <= axi_aruser_i; 
      l2_tlb_req_id_o   <= axi_arid_i;
    end
  end

endmodule