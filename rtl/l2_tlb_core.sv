// =============================================================
// L2 TLB CORE – FINAL, 600MHz SAFE, SYNTHESIS CLEAN
// Pipeline stages explicitly commented (Excel-aligned)
// =============================================================
module l2_tlb_core
  import l2_tlb_pkg::*;
(
  input  logic                     clk_i,
  input  logic                     rstn_i,

  // AXI Read Request
  input  logic                     req_valid_i,
  output logic                     req_ready_o,
  input  logic [VPN_WIDTH-1:0]     req_vpn_i,
  input  logic [PERM_WIDTH-1:0]    req_type_i,
  input  logic [4:0]               req_id_i,

  // CSR Interface
  input  logic                     csr_enable_i,
  input  logic [ASID_WIDTH-1:0]    csr_asid_i,
  input  logic                     csr_flush_all_i,
  input  logic                     csr_flush_asid_valid_i,
  input  logic [ASID_WIDTH-1:0]    csr_flush_asid_i,

  // MSHR Refill Interface
  input  logic                     mshr_refill_valid_i,
  input  logic [VPN_WIDTH-1:0]     mshr_vpn_i,
  input  logic [PPN_WIDTH-1:0]     mshr_ppn_i,
  input  logic [PERM_WIDTH-1:0]    mshr_perm_i,
  input  logic                     mshr_page_size_i,
  input  logic                     mshr_dirty_i,
  input  logic                     mshr_dbit_update_i,
  input  logic [SET_INDEX_WIDTH-1:0] mshr_set_idx_i,
  input  logic [$clog2(NUM_WAYS)-1:0] mshr_way_i,

  // Outputs
  output logic                     tlb_hit_o,
  output logic                     tlb_miss_o,
  output logic                     need_ptw_o,

  output logic                     resp_valid_o,
  output logic [PPN_WIDTH-1:0]     resp_ppn_o,
  output logic [PERM_WIDTH-1:0]    resp_perm_o,
  output logic                     resp_page_size_o,
  output logic                     resp_error_o,
  output logic [4:0]               resp_id_o,

  // PLRU Interface
  output logic [SET_INDEX_WIDTH-1:0]  plru_set_idx_o,
  output logic [NUM_WAYS-1:0]         plru_way_valid_o,
  output logic                        plru_hit_o,
  output logic [$clog2(NUM_WAYS)-1:0] plru_hit_way_idx_o,
  output logic                        plru_alloc_o,
  input  logic [$clog2(NUM_WAYS)-1:0] plru_victim_way_i
);

  // =============================================================
  // TAG & DATA STORAGE ARRAYS (SRAM or regfile)
  // =============================================================
  tlb_tag_t  tag_mem  [NUM_WAYS][NUM_SETS];
  tlb_data_t data_mem [NUM_WAYS][NUM_SETS];

  // =============================================================
  // GLOBAL FLUSH / ASID FLUSH (non-pipelined maintenance path)
  // =============================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i || csr_flush_all_i)
      for (int w=0; w<NUM_WAYS; w++)
        for (int s=0; s<NUM_SETS; s++)
          tag_mem[w][s].valid <= 1'b0;
    else if (csr_flush_asid_valid_i)
      for (int w=0; w<NUM_WAYS; w++)
        for (int s=0; s<NUM_SETS; s++)
          if (tag_mem[w][s].asid == csr_flush_asid_i)
            tag_mem[w][s].valid <= 1'b0;
  end

  // =============================================================
  // S0 – CLOCK C2
  // Request latch + ASID + SET index generation
  // =============================================================
  logic s0_valid;
  logic [VPN_WIDTH-1:0] s0_vpn;
  logic [PERM_WIDTH-1:0] s0_type;
  logic [4:0] s0_id;
  logic [ASID_WIDTH-1:0] s0_asid;
  logic [SET_INDEX_WIDTH-1:0] s0_set;

  assign req_ready_o = !s0_valid;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i)
      s0_valid <= 1'b0;
    else if (req_ready_o) begin
      s0_valid <= req_valid_i & csr_enable_i;
      if (req_valid_i & csr_enable_i) begin
        s0_vpn  <= req_vpn_i;
        s0_type <= req_type_i;
        s0_id   <= req_id_i;
        s0_asid <= csr_asid_i;
        s0_set  <= req_vpn_i[9:5];
      end
    end
  end

  // =============================================================
  // S1 – CLOCK C3
  // Read tag & data for ALL ways in selected set
  // =============================================================
  logic s1_valid;
  logic [VPN_WIDTH-1:0] s1_vpn;
  logic [PERM_WIDTH-1:0] s1_type;
  logic [4:0] s1_id;
  logic [ASID_WIDTH-1:0] s1_asid;
  logic [SET_INDEX_WIDTH-1:0] s1_set;

  tlb_tag_t s1_tag [NUM_WAYS];
  tlb_data_t s1_data[NUM_WAYS];

  always_ff @(posedge clk_i) begin
    s1_valid <= s0_valid;
    s1_vpn   <= s0_vpn;
    s1_type  <= s0_type;
    s1_id    <= s0_id;
    s1_asid  <= s0_asid;
    s1_set   <= s0_set;

    for (int w=0; w<NUM_WAYS; w++) begin
      s1_tag[w]  <= tag_mem[w][s0_set];
      s1_data[w] <= data_mem[w][s0_set];
    end
  end

  // =============================================================
  // S2 – CLOCK C4
  // Tag + ASID compare, hit detection, hit way selection
  // =============================================================
  logic s2_hit;
  logic [$clog2(NUM_WAYS)-1:0] s2_way;
  tlb_tag_t  s2_tag;
  tlb_data_t s2_data;

  always_comb begin
    s2_hit = 1'b0;
    s2_way = '0;
    for (int w=0; w<NUM_WAYS; w++)
      if (s1_tag[w].valid &&
          s1_tag[w].vpn  == s1_vpn &&
          s1_tag[w].asid == s1_asid) begin
        s2_hit = 1'b1;
        s2_way = w;
      end
  end

  always_ff @(posedge clk_i) begin
    s2_tag  <= s1_tag[s2_way];
    s2_data <= s1_data[s2_way];
  end

  // =============================================================
  // S3 – CLOCK C5
  // Permission check + final response + PLRU wrapper register
  // =============================================================
  logic perm_ok;

  assign perm_ok =
    (s1_type[0] & s2_tag.perm[0]) |
    (s1_type[1] & s2_tag.perm[1]) |
    (s1_type[2] & s2_tag.perm[2]);

  // ---- PLRU UPDATE REGISTER (breaks read/write same-cycle issue)
  logic plru_hit_q;
  logic plru_alloc_q;
  logic [SET_INDEX_WIDTH-1:0] plru_set_q;
  logic [$clog2(NUM_WAYS)-1:0] plru_way_q;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      tlb_hit_o    <= 1'b0;
      tlb_miss_o   <= 1'b0;
      need_ptw_o   <= 1'b0;
      resp_valid_o <= 1'b0;
      plru_hit_q   <= 1'b0;
      plru_alloc_q <= 1'b0;
    end else begin
      tlb_hit_o    <= s1_valid & s2_hit & perm_ok;
      tlb_miss_o   <= s1_valid & ~s2_hit;
      need_ptw_o   <= s1_valid & ~s2_hit;

      resp_valid_o     <= s1_valid & s2_hit & perm_ok;
      resp_ppn_o       <= s2_data.ppn;
      resp_page_size_o <= s2_data.page_size;
      resp_perm_o      <= s2_tag.perm;
      resp_error_o     <= s1_valid & ~perm_ok;
      resp_id_o        <= s1_id;

      // PLRU wrapper (registered)
      plru_hit_q   <= s1_valid & s2_hit;
      plru_alloc_q <= mshr_refill_valid_i;
      plru_set_q   <= s1_set;
      plru_way_q   <= s2_way;
    end
  end

  // =============================================================
  // PLRU VALID MASK GENERATION (combinational)
  // =============================================================
  always_comb
    for (int w=0; w<NUM_WAYS; w++)
      plru_way_valid_o[w] = tag_mem[w][s1_set].valid;

  assign plru_hit_o         = plru_hit_q;
  assign plru_alloc_o       = plru_alloc_q;
  assign plru_set_idx_o     = plru_set_q;
  assign plru_hit_way_idx_o = plru_way_q;

  // =============================================================
  // REFILL PATH – CLOCK C6+
  // (Non-critical path, after PTW response)
  // =============================================================
  always_ff @(posedge clk_i) begin
    if (mshr_refill_valid_i) begin
      logic [$clog2(NUM_WAYS)-1:0] w;
      w = mshr_dbit_update_i ? mshr_way_i : plru_victim_way_i;

      tag_mem[w][mshr_set_idx_i] <= '{
        valid : 1'b1,
        vpn   : mshr_vpn_i,
        asid  : csr_asid_i,
        perm  : mshr_perm_i,
        dirty : mshr_dirty_i
      };

      data_mem[w][mshr_set_idx_i] <= '{
        ppn       : mshr_ppn_i,
        page_size : mshr_page_size_i
      };
    end
  end

endmodule

 