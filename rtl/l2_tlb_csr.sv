// =============================================================
// L2 TLB CSR Block (APB Interface)
// - One-stage internal pipeline (control-safe)
// - Clean flush pulse generation
// - Synthesizable and timing-safe
// =============================================================
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
  // Status Inputs
  // -------------------------------
  input  logic              tlb_hit_i,
  input  logic              tlb_miss_i,
  input  logic              ptw_error_i,
  input  logic              mshr_full_i,

  // -------------------------------
  // CSR Outputs
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

  // Raw flush registers
  logic flush_all_reg;
  logic flush_asid_reg_valid;
  logic [ASID_W-1:0] flush_asid_reg;

  // =============================================================
  // APB Write Strobe (REGISTERED)
  // =============================================================
  logic wr_en_q;

  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i)
      wr_en_q <= 1'b0;
    else
      wr_en_q <= psel_i && penable_i && pwrite_i;
  end

  // =============================================================
  // APB WRITE LOGIC
  // =============================================================
  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i) begin
      asid_reg              <= '0;
      enable_reg            <= 1'b0;
      flush_all_reg         <= 1'b0;
      flush_asid_reg_valid  <= 1'b0;
      flush_asid_reg        <= '0;
    end
    else if (wr_en_q) begin
      case (paddr_i)
        12'h000: enable_reg <= pwdata_i[0];
        12'h004: asid_reg   <= pwdata_i;
        12'h008: flush_all_reg <= pwdata_i[0];
        12'h00C: begin
          flush_asid_reg_valid <= pwdata_i[0];
          flush_asid_reg       <= pwdata_i;
        end
        default: ;
      endcase
    end
  end

  // =============================================================
  // FLUSH PULSE GENERATION (1-cycle)
  // =============================================================
  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i) begin
      csr_flush_all_o        <= 1'b0;
      csr_flush_asid_valid_o <= 1'b0;
    end else begin
      csr_flush_all_o        <= flush_all_reg;
      csr_flush_asid_valid_o <= flush_asid_reg_valid;

      // auto-clear after one cycle
      flush_all_reg         <= 1'b0;
      flush_asid_reg_valid  <= 1'b0;
    end
  end

  assign csr_flush_asid_o = flush_asid_reg;

  // =============================================================
  // PERFORMANCE COUNTERS (already pipelined)
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
  // APB READ LOGIC (REGISTERED MUX)
  // =============================================================
  always_ff @(posedge pclk_i or negedge presetn_i) begin
    if (!presetn_i)
      prdata_o <= '0;
    else begin
      case (paddr_i)
        12'h000: prdata_o <= {31'b0, enable_reg};
        12'h004: prdata_o <= asid_reg;
        12'h010: prdata_o <= hit_cnt_o;
        12'h014: prdata_o <= miss_cnt_o;
        12'h018: prdata_o <= err_cnt_o;
        12'h01C: prdata_o <= {31'b0, mshr_full_i};
        default: prdata_o <= '0;
      endcase
    end
  end

  // =============================================================
  // CSR OUTPUTS
  // =============================================================
  assign csr_asid_o   = asid_reg;
  assign csr_enable_o = enable_reg;

  // =============================================================
  // APB RESPONSES
  // =============================================================
  assign pready_o  = 1'b1;   // zero-wait
  assign pslverr_o = 1'b0;

endmodule
 