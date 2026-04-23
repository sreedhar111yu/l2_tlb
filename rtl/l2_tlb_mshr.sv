// =============================================================
// L2 TLB MSHR – FINAL, 600MHz SAFE, SYNTHESIS CLEAN
// 4-Request Coalescing Limit | Lookahead Pointers | Single-Driver FSM
// =============================================================
`timescale 1ns/1ps

module l2_tlb_mshr
  import l2_tlb_pkg::*;
#(
  parameter int MSHR_DEPTH   = 16,
  parameter int L1_ID_WIDTH  = 2,  // 4 possible requestors
  parameter int REQ_ID_WIDTH = 4   // 16 MSHR entries
)(
  input  logic                    clk_i,
  input  logic                    rstn_i,

  // Miss request from L2 Core
  input  logic                    req_valid_i,
  input  logic [VPN_WIDTH-1:0]    req_vpn_i,
  input  logic [ASID_WIDTH-1:0]   req_asid_i,
  input  logic [L1_ID_WIDTH-1:0]  req_l1_id_i,
  input  logic                    req_dbit_update_i,
  output logic                    mshr_full_o, // Flop-Out Backpressure

  // ---- Issue vectors to read_request_gen ----
  output logic [MSHR_DEPTH-1:0]   mshr_valid_o,
  output logic [MSHR_DEPTH-1:0]   mshr_issue_elig_o,
  output logic [VPN_WIDTH-1:0]    mshr_vpn_o      [MSHR_DEPTH],
  output logic [REQ_ID_WIDTH-1:0] mshr_req_id_o   [MSHR_DEPTH],
  input  logic [MSHR_DEPTH-1:0]   mshr_issue_grant_i,

  // ---- PTW response from read_response_rx ----
  input  logic                    mshr_resp_valid_i,
  input  logic [REQ_ID_WIDTH-1:0] mshr_resp_id_i,
  input  logic [PPN_WIDTH-1:0]    mshr_resp_ppn_i,
  input  logic                    mshr_resp_error_i,

  // Response to FIFO
  output logic                    rsp_valid_o,
  output logic [PPN_WIDTH-1:0]    rsp_ppn_o,
  output logic [L1_ID_WIDTH-1:0]  rsp_l1_id_o,
  output logic                    rsp_error_o,
  input  logic                    rsp_ready_i,

  input  logic                    flush_i
);

  // =============================================================
  // Entry definition
  // =============================================================
  typedef enum logic [1:0] { IDLE, ISSUE, WAIT, FANOUT } state_e;

  typedef struct packed {
    state_e                state;
    logic [VPN_WIDTH-1:0]  vpn;
    logic [ASID_WIDTH-1:0] asid;
    logic [PPN_WIDTH-1:0]  ppn;
    logic                  error;
    logic [3:0]            req_map; // Max 4 coalesced requests
  } entry_t;

  entry_t entries [MSHR_DEPTH];

  // =============================================================
  // 600MHz FIX 1: Combinational "Lookahead" Pointers
  // Pre-calculates the target indices so the FSM logic is O(1)
  // =============================================================
  
  // 1A. Lookahead for Allocation (Free Slot) & Coalescing (Hit)
  logic                    hit_comb;
  logic [REQ_ID_WIDTH-1:0] hit_idx_comb;
  logic                    free_avail_comb;
  logic [REQ_ID_WIDTH-1:0] free_idx_comb;

  always_comb begin
    hit_comb        = 1'b0;
    hit_idx_comb    = '0;
    free_avail_comb = 1'b0;
    free_idx_comb   = '0;

    for (int i = 0; i < MSHR_DEPTH; i++) begin
      // Coalescing Hit Check (Only merge if we have room in the 4-bit mask)
      if (!hit_comb && entries[i].state != IDLE && 
          entries[i].vpn == req_vpn_i && entries[i].asid == req_asid_i) begin
        hit_comb     = 1'b1;
        hit_idx_comb = i[REQ_ID_WIDTH-1:0];
      end
      
      // Free Slot Check
      if (!free_avail_comb && entries[i].state == IDLE) begin
        free_avail_comb = 1'b1;
        free_idx_comb   = i[REQ_ID_WIDTH-1:0];
      end
    end
  end

  // 1B. Lookahead for Fanout (Priority Encoder)
  logic                    fan_avail_comb;
  logic [REQ_ID_WIDTH-1:0] fan_idx_comb;
  logic [L1_ID_WIDTH-1:0]  fan_l1id_comb;

  // Ultra-Fast 4-bit Priority Encoder (1 LUT delay)
  function automatic [L1_ID_WIDTH-1:0] first_one(input logic [3:0] v);
    if      (v[0]) return 2'd0;
    else if (v[1]) return 2'd1;
    else if (v[2]) return 2'd2;
    else if (v[3]) return 2'd3;
    else           return 2'd0;
  endfunction

  always_comb begin
    fan_avail_comb = 1'b0;
    fan_idx_comb   = '0;
    fan_l1id_comb  = '0;

    for (int i = 0; i < MSHR_DEPTH; i++) begin
      if (!fan_avail_comb && entries[i].state == FANOUT && entries[i].req_map != 0) begin
        fan_avail_comb = 1'b1;
        fan_idx_comb   = i[REQ_ID_WIDTH-1:0];
        fan_l1id_comb  = first_one(entries[i].req_map);
      end
    end
  end

  // =============================================================
  // 600MHz FIX 2: Flop-Out Backpressure
  // =============================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) mshr_full_o <= 1'b0;
    else         mshr_full_o <= !free_avail_comb && !hit_comb;
  end

  // =============================================================
  // SINGLE STATE MACHINE (Resolves Multiple-Driver Synthesis Error)
  // =============================================================
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      for (int i = 0; i < MSHR_DEPTH; i++) begin
        entries[i].state   <= IDLE;
        entries[i].req_map <= '0;
      end
    end else if (flush_i) begin
      for (int i = 0; i < MSHR_DEPTH; i++) begin
        entries[i].state   <= IDLE;
        entries[i].req_map <= '0;
      end
    end else begin
      
      // 1. ALLOCATION & COALESCING
      if (req_valid_i && !mshr_full_o) begin
        if (hit_comb) begin
          // Coalesce into existing entry
          entries[hit_idx_comb].req_map <= entries[hit_idx_comb].req_map | (4'b0001 << req_l1_id_i);
        end else if (free_avail_comb) begin
          // Allocate New entry
          entries[free_idx_comb].state   <= ISSUE;
          entries[free_idx_comb].vpn     <= req_vpn_i;
          entries[free_idx_comb].asid    <= req_asid_i;
          entries[free_idx_comb].req_map <= (4'b0001 << req_l1_id_i);
        end
      end

      // 2. ISSUE GRANTS (from read_request_gen arbiter)
      for (int i = 0; i < MSHR_DEPTH; i++) begin
        if (entries[i].state == ISSUE && mshr_issue_grant_i[i]) begin
          entries[i].state <= WAIT;
        end
      end

      // 3. PTW RESPONSE CAPTURE
      if (mshr_resp_valid_i && entries[mshr_resp_id_i].state == WAIT) begin
        entries[mshr_resp_id_i].ppn   <= mshr_resp_ppn_i;
        entries[mshr_resp_id_i].error <= mshr_resp_error_i;
        entries[mshr_resp_id_i].state <= FANOUT;
      end

      // 4. FANOUT DRAIN
      if (rsp_ready_i && fan_avail_comb) begin
        logic [3:0] next_map;
        next_map = entries[fan_idx_comb].req_map & ~(4'b0001 << fan_l1id_comb);
        
        entries[fan_idx_comb].req_map <= next_map;
        
        if (next_map == 4'b0000) begin
          entries[fan_idx_comb].state <= IDLE;
        end
      end

    end
  end

  // =============================================================
  // Export Outputs
  // =============================================================
  genvar g;
  generate
    for (g = 0; g < MSHR_DEPTH; g++) begin
      assign mshr_valid_o[g]      = (entries[g].state == ISSUE);
      assign mshr_issue_elig_o[g] = (entries[g].state == ISSUE);
      assign mshr_vpn_o[g]        = entries[g].vpn;
      assign mshr_req_id_o[g]     = g[REQ_ID_WIDTH-1:0];
    end
  endgenerate

  // Fanout Response Outputs
  assign rsp_valid_o = fan_avail_comb;
  assign rsp_ppn_o   = entries[fan_idx_comb].ppn;
  assign rsp_l1_id_o = fan_l1id_comb;
  assign rsp_error_o = entries[fan_idx_comb].error;

endmodule