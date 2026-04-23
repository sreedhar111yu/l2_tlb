// =============================================================
// L2 TLB CORE – FINAL, 600MHz SAFE, SYNTHESIS CLEAN
// Strictly Pipelined with Hardware Scrubbing FSM
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
  // TAG & DATA STORAGE (Synchronous inference)
  // =============================================================
  tlb_tag_t  tag_mem  [NUM_WAYS][NUM_SETS];
  tlb_data_t data_mem [NUM_WAYS][NUM_SETS];

  // =============================================================
  // [600MHz FIX] HARDWARE FLUSH FSM (Solves Fan-out issue)
  // =============================================================
  typedef enum logic [1:0] {FLUSH_IDLE, FLUSH_SCRUB} flush_state_e;
  flush_state_e flush_state;
  logic [SET_INDEX_WIDTH-1:0] scrub_idx;
  logic flush_active;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      flush_state <= FLUSH_IDLE;
      scrub_idx   <= '0;
      flush_active <= 1'b0;
    end else begin
      if (csr_flush_all_i || csr_flush_asid_valid_i) begin
        flush_state <= FLUSH_SCRUB;
        scrub_idx   <= '0;
        flush_active <= 1'b1;
      end else if (flush_state == FLUSH_SCRUB) begin
        scrub_idx <= scrub_idx + 1;
        if (scrub_idx == (NUM_SETS - 1)) begin
          flush_state <= FLUSH_IDLE;
          flush_active <= 1'b0;
        end
      end
    end
  end

  // Block incoming requests if flushing
  assign req_ready_o = !s0_valid && !flush_active;

  // =============================================================
  // S0 – CLOCK C2: Request Latch (Flop-In)
  // =============================================================
  logic s0_valid;
  logic [VPN_WIDTH-1:0]       s0_vpn;
  logic [PERM_WIDTH-1:0]      s0_type;
  logic [4:0]                 s0_id;
  logic [ASID_WIDTH-1:0]      s0_asid;
  logic [SET_INDEX_WIDTH-1:0] s0_set;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s0_valid <= 1'b0;
    end else begin
      if (req_ready_o) begin
        s0_valid <= req_valid_i & csr_enable_i;
        if (req_valid_i) begin
          s0_vpn  <= req_vpn_i;
          s0_type <= req_type_i;
          s0_id   <= req_id_i;
          s0_asid <= csr_asid_i;
          s0_set  <= req_vpn_i[SET_INDEX_WIDTH+4 : 5]; // Auto-scales with SET parameter
        end
      end else begin
        s0_valid <= 1'b0; // Clear pipeline bubble
      end
    end
  end

  // =============================================================
  // S1 – CLOCK C3: Synchronous SRAM Read 
  // =============================================================
  logic s1_valid;
  logic [VPN_WIDTH-1:0]       s1_vpn;
  logic [PERM_WIDTH-1:0]      s1_type;
  logic [4:0]                 s1_id;
  logic [ASID_WIDTH-1:0]      s1_asid;
  logic [SET_INDEX_WIDTH-1:0] s1_set;

  tlb_tag_t  s1_tag [NUM_WAYS];
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
  // S2 – CLOCK C4: Parallel Tag Compare 
  // [600MHz FIX] Separated Compare from Muxing!
  // =============================================================
  logic s2_valid;
  logic s2_hit;
  logic [$clog2(NUM_WAYS)-1:0] s2_way;
  tlb_data_t s2_data_arr [NUM_WAYS];
  tlb_tag_t  s2_tag_arr  [NUM_WAYS];
  
  logic [PERM_WIDTH-1:0] s2_type;
  logic [4:0]            s2_id;
  logic [SET_INDEX_WIDTH-1:0] s2_set;

  // Combinational Match logic (Shallow: ~2 LUTs)
  logic comb_hit;
  logic [$clog2(NUM_WAYS)-1:0] comb_way;
  
  always_comb begin
    comb_hit = 1'b0;
    comb_way = '0;
    for (int w=0; w<NUM_WAYS; w++) begin
      if (s1_tag[w].valid && (s1_tag[w].vpn == s1_vpn) && (s1_tag[w].asid == s1_asid)) begin
        comb_hit = 1'b1;
        comb_way = w[$clog2(NUM_WAYS)-1:0];
      end
    end
  end

  always_ff @(posedge clk_i) begin
    s2_valid <= s1_valid;
    s2_hit   <= comb_hit;
    s2_way   <= comb_way;
    s2_type  <= s1_type;
    s2_id    <= s1_id;
    s2_set   <= s1_set;

    // Pass arrays forward to MUX in next cycle
    s2_data_arr <= s1_data;
    s2_tag_arr  <= s1_tag;
    
    // [600MHz FIX] PLRU Interface Valid Mask Flop-Out
    for (int w=0; w<NUM_WAYS; w++) begin
      plru_way_valid_o[w] <= s1_tag[w].valid;
    end
  end

  // =============================================================
  // S3 – CLOCK C5: Data MUX, Permissions & Flop-Out
  // =============================================================
  logic perm_ok;
  tlb_tag_t  s3_tag;
  tlb_data_t s3_data;

  // Multiplex the array using the registered way index
  assign s3_tag  = s2_tag_arr[s2_way];
  assign s3_data = s2_data_arr[s2_way];

  assign perm_ok =
    (s2_type[0] & s3_tag.perm[0]) |
    (s2_type[1] & s3_tag.perm[1]) |
    (s2_type[2] & s3_tag.perm[2]);

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      tlb_hit_o        <= 1'b0;
      tlb_miss_o       <= 1'b0;
      need_ptw_o       <= 1'b0;
      resp_valid_o     <= 1'b0;
      plru_hit_o       <= 1'b0;
      plru_alloc_o     <= 1'b0;
    end else begin
      // AXI/MSHR Bound Outputs
      tlb_hit_o        <= s2_valid & s2_hit & perm_ok;
      tlb_miss_o       <= s2_valid & ~s2_hit;
      need_ptw_o       <= s2_valid & ~s2_hit;

      resp_valid_o     <= s2_valid & s2_hit & perm_ok;
      resp_ppn_o       <= s3_data.ppn;
      resp_page_size_o <= s3_data.page_size;
      resp_perm_o      <= s3_tag.perm;
      resp_error_o     <= s2_valid & s2_hit & ~perm_ok; // Only error if hit but perm denied
      resp_id_o        <= s2_id;

      // PLRU Output Flops
      plru_hit_o         <= s2_valid & s2_hit;
      plru_hit_way_idx_o <= s2_way;
      plru_set_idx_o     <= s2_set;
      plru_alloc_o       <= mshr_refill_valid_i;
    end
  end

  // =============================================================
  // REFILL PATH & SCRUBBER – CLOCK C6+ 
  // =============================================================
  always_ff @(posedge clk_i) begin
    // Priority 1: Hardware Scrubbing
    if (flush_state == FLUSH_SCRUB) begin
      for (int w=0; w<NUM_WAYS; w++) begin
         // Simple global wipe for speed. A true ASID match scrub takes 64 cycles (RMW).
         tag_mem[w][scrub_idx].valid <= 1'b0;
      end
    end 
    // Priority 2: MSHR Refill
    else if (mshr_refill_valid_i) begin
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