`timescale 1ns/1ps
module l2_tlb_mshr
  import l2_tlb_pkg::*;
#(
  parameter int MSHR_DEPTH   = 16,
  parameter int L1_ID_WIDTH  = 2,
  parameter int REQ_ID_WIDTH = 4
)(
  input  logic clk_i,
  input  logic rstn_i,

  // Miss request
  input  logic                     req_valid_i,
  input  logic [VPN_WIDTH-1:0]      req_vpn_i,
  input  logic [ASID_WIDTH-1:0]     req_asid_i,
  input  logic [L1_ID_WIDTH-1:0]    req_l1_id_i,
  input  logic                     req_dbit_update_i,
  output logic                     mshr_full_o,

  // ---- Issue vectors to read_request_gen ----
  output logic [MSHR_DEPTH-1:0]      mshr_valid_o,
  output logic [MSHR_DEPTH-1:0]      mshr_issue_elig_o,
  output logic [VPN_WIDTH-1:0]       mshr_vpn_o      [MSHR_DEPTH],
  output logic [REQ_ID_WIDTH-1:0]    mshr_req_id_o   [MSHR_DEPTH],
  input  logic [MSHR_DEPTH-1:0]      mshr_issue_grant_i,

  // ---- PTW response from read_response_rx ----
  input  logic                     mshr_resp_valid_i,
  input  logic [REQ_ID_WIDTH-1:0]   mshr_resp_id_i,
  input  logic [PPN_WIDTH-1:0]      mshr_resp_ppn_i,
  input  logic                     mshr_resp_error_i,

  // Response to FIFO
  output logic                     rsp_valid_o,
  output logic [PPN_WIDTH-1:0]      rsp_ppn_o,
  output logic [L1_ID_WIDTH-1:0]    rsp_l1_id_o,
  output logic                     rsp_error_o,
  input  logic                     rsp_ready_i,

  input  logic                     flush_i
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
    logic [3:0]            req_map;
  } entry_t;

  entry_t entries [MSHR_DEPTH];

  // =============================================================
  // Priority encoder (SAFE)
  // =============================================================
  function automatic [L1_ID_WIDTH-1:0] first_one(input logic [3:0] v);
    for (int k = 0; k < 4; k++)
      if (v[k]) return k[L1_ID_WIDTH-1:0];
    return '0;
  endfunction

  // =============================================================
  // Export issue vectors (combinational)
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

  // =============================================================
  // Allocation / state update logic
  // =============================================================
  integer i;
  logic alloc_done;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i || flush_i) begin
      for (i = 0; i < MSHR_DEPTH; i++)
        entries[i].state <= IDLE;
    end else begin

      // -------------------------------
      // Allocate new miss (SAFE loop)
      // -------------------------------
      alloc_done = 1'b0;
      if (req_valid_i) begin
        for (i = 0; i < MSHR_DEPTH; i++) begin
          if (!alloc_done && entries[i].state == IDLE) begin
            entries[i].state   <= ISSUE;
            entries[i].vpn     <= req_vpn_i;
            entries[i].asid    <= req_asid_i;
            entries[i].req_map <= 4'b0001 << req_l1_id_i;
            alloc_done = 1'b1;
          end
        end
      end

      // -------------------------------
      // Grant from read_request_gen
      // -------------------------------
      for (i = 0; i < MSHR_DEPTH; i++) begin
        if (mshr_issue_grant_i[i])
          entries[i].state <= WAIT;
      end

      // -------------------------------
      // PTW response
      // -------------------------------
      if (mshr_resp_valid_i &&
          entries[mshr_resp_id_i].state == WAIT) begin
        entries[mshr_resp_id_i].ppn   <= mshr_resp_ppn_i;
        entries[mshr_resp_id_i].error <= mshr_resp_error_i;
        entries[mshr_resp_id_i].state <= FANOUT;
      end
    end
  end

  // =============================================================
  // Fanout logic (SAFE and fast)
  // =============================================================
  logic fan_active;
  logic [REQ_ID_WIDTH-1:0] fan_idx;
  logic [L1_ID_WIDTH-1:0]  fan_l1id;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i)
      fan_active <= 1'b0;
    else if (!fan_active && rsp_ready_i) begin
      for (i = 0; i < MSHR_DEPTH; i++)
        if (entries[i].state == FANOUT && entries[i].req_map != 0) begin
          fan_active <= 1'b1;
          fan_idx    <= i;
          fan_l1id   <= first_one(entries[i].req_map);
          break;
        end
    end
    else if (fan_active && rsp_ready_i) begin
      fan_active <= 1'b0;
      entries[fan_idx].req_map <=
        entries[fan_idx].req_map & ~(4'b0001 << fan_l1id);

      if ((entries[fan_idx].req_map &
           ~(4'b0001 << fan_l1id)) == 0)
        entries[fan_idx].state <= IDLE;
    end
  end

  // =============================================================
  // Outputs
  // =============================================================
  assign rsp_valid_o = fan_active;
  assign rsp_ppn_o   = entries[fan_idx].ppn;
  assign rsp_l1_id_o = fan_l1id;
  assign rsp_error_o = entries[fan_idx].error;

endmodule
 