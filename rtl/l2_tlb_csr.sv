// =============================================================
// L2 TLB CSR Block (APB Interface) - FINAL, 600MHz SAFE
// - Zero Wait-State APB Compliant
// - Single-Driver Auto-Clearing Flush Registers
// =============================================================
`timescale 1ns/1ps

module l2_tlb_csr #(
  parameter int ASID_W = 32,
  parameter int ADDR_W = 12,
  parameter int CNT_W  = 32
)(
  input  logic              pclk_i,
  input  logic              presetn_i,

  // -------------------------------
  // APB Interface
  // -------------------------------
  input  logic              psel_i,
  input  logic              penable_i,
  input  logic              pwrite_i,
  input  logic [ADDR_W-1:0] paddr_i,
  input  logic [31:0]       pwdata_i,
  output logic [31:0]       prdata_o,
  output logic              pready_o,
  output logic              pslverr_o,

  // -------------------------------
  // Status Inputs (from Core)
  // -------------------------------
  input  logic              tlb_hit_i,
  input  logic              tlb_miss_i,
  input  logic              ptw_error_i,
  input  logic              mshr_full_i,

  // -------------------------------
  // CSR Outputs (to Core)
  // -------------------------------
  output logic [ASID_W-1:0] csr_asid_o,
  output logic              csr_flush_all_o,
  output logic              csr_flush_asid_valid_o,
  output logic [ASID_W-1:0] csr_flush_asid_o,
  output logic              csr_enable_o,

  // -------------------------------
  // Performance Counters
  // -------------------------------
  output logic [CNT_W-1:0]  hit_cnt_o,
  output logic [CNT_W-1:0]  miss_cnt_o,
  output logic [CNT_W-1:0]  err_cnt_o
);

  // =============================================================
  // Internal CSR Registers
  // =============================================================
  logic [ASID_W-1:0] asid_reg;
  logic              enable_reg;

  // =============================================================
  // APB Write Trigger (Combinational for Zero-Wait-State APB)
  // =============================================================
  // APB writes happen exactly when SEL, ENABLE, and WRITE are all high.
  logic apb_write_en;
  assign apb_write_en = psel_i && penable_i && pwrite_i;

  // =============================================================
  // APB WRITE & FLUSH PULSE LOGIC (Single State Machine)
  // =============================================================
  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i) begin
      asid_reg               <= '0;
      enable_reg             <= 1'b0;
      csr_flush_all_o        <= 1'b0;
      csr_flush_asid_valid_o <= 1'b0;
      csr_flush_asid_o       <= '0;
    end 
    else begin
      // 1. Default Auto-Clear for Flush Pulses (Ensures they are exactly 1 cycle)
      csr_flush_all_o        <= 1'b0;
      csr_flush_asid_valid_o <= 1'b0;

      // 2. Synchronous APB Writes
      if (apb_write_en) begin
        case (paddr_i)
          12'h000: enable_reg <= pwdata_i[0];
          12'h004: asid_reg   <= pwdata_i;
          12'h008: csr_flush_all_o <= pwdata_i[0]; // Drives high for exactly 1 cycle
          12'h00C: begin
            csr_flush_asid_valid_o <= pwdata_i[0];
            csr_flush_asid_o       <= pwdata_i;
          end
          default: ; // Safely ignore invalid addresses
        endcase
      end
    end
  end

  // =============================================================
  // PERFORMANCE COUNTERS
  // Note: Assuming tlb_hit_i is a 1-cycle pulse synchronized to pclk_i
  // =============================================================
  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i) begin
      hit_cnt_o  <= '0;
      miss_cnt_o <= '0;
      err_cnt_o  <= '0;
    end else begin
      if (tlb_hit_i)   hit_cnt_o  <= hit_cnt_o  + 1'b1;
      if (tlb_miss_i)  miss_cnt_o <= miss_cnt_o + 1'b1;
      if (ptw_error_i) err_cnt_o  <= err_cnt_o  + 1'b1;
    end
  end

  // =============================================================
  // APB READ LOGIC (Combinational MUX for Zero-Wait-State)
  // =============================================================
  always_comb begin
    prdata_o = '0; // Default zero to avoid latches
    
    // Only drive read data if a read transaction is occurring
    if (psel_i && !pwrite_i) begin
      case (paddr_i)
        12'h000: prdata_o = {31'b0, enable_reg};
        12'h004: prdata_o = asid_reg;
        12'h010: prdata_o = hit_cnt_o;
        12'h014: prdata_o = miss_cnt_o;
        12'h018: prdata_o = err_cnt_o;
        12'h01C: prdata_o = {31'b0, mshr_full_i};
        default: prdata_o = '0;
      endcase
    end
  end

  // =============================================================
  // CSR STATIC OUTPUTS
  // =============================================================
  assign csr_asid_o   = asid_reg;
  assign csr_enable_o = enable_reg;

  // =============================================================
  // APB RESPONSES
  // =============================================================
  assign pready_o  = 1'b1;   // Zero-wait-state accepted
  assign pslverr_o = 1'b0;   // No slave errors generated

endmodule