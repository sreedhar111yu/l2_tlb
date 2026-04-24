l2_tlb_mshr
`timescale 1ns/1ps
module l2_tlb_mshr
  import l2_tlb_pkg::*;
#(
  parameter int MSHR_DEPTH   = 16,
  parameter int REQ_ID_WIDTH = 4
)(
  input  logic clk_i,
  input  logic rstn_i,
  // Miss request
  input  logic                     req_valid_i,
  input  logic [VPN_WIDTH-1:0]      req_vpn_i,
  input  logic [ASID_WIDTH-1:0]     req_asid_i,
  input  logic [PERM_WIDTH-1:0]     req_type_i,
  input  logic [4:0]                req_axi_id_i,
  input  logic                     req_dbit_update_i,
  output logic                     mshr_full_o,
  // PTW issue
  output logic [MSHR_DEPTH-1:0]      mshr_valid_o,
  output logic [MSHR_DEPTH-1:0]      mshr_issue_elig_o,
  output logic [VPN_WIDTH-1:0]       mshr_vpn_o [MSHR_DEPTH],
  output logic [REQ_ID_WIDTH-1:0]    mshr_req_id_o [MSHR_DEPTH],
  output logic [PERM_WIDTH-1:0]      mshr_type_o [MSHR_DEPTH],
  input  logic [MSHR_DEPTH-1:0]      mshr_issue_grant_i,
  // PTW response
  input  logic                     mshr_resp_valid_i,
  input  logic [REQ_ID_WIDTH-1:0]   mshr_resp_id_i,
  input  logic [PPN_WIDTH-1:0]      mshr_resp_ppn_i,
  input  logic [PERM_WIDTH-1:0]     mshr_resp_perm_i,
  input  logic                     mshr_resp_page_size_i,
  input  logic                     mshr_resp_dirty_i,
  input  logic                     mshr_resp_error_i,
  // Refill
  output logic                     mshr_refill_valid_o,
  output logic [VPN_WIDTH-1:0]      mshr_refill_vpn_o,
  output logic [PPN_WIDTH-1:0]      mshr_refill_ppn_o,
  output logic [PERM_WIDTH-1:0]     mshr_refill_perm_o,
  output logic                     mshr_refill_page_size_o,
  output logic                     mshr_refill_dirty_o,
  output logic                     mshr_refill_dbit_update_o,
  output logic [SET_INDEX_WIDTH-1:0] mshr_refill_set_idx_o,
  output logic [$clog2(NUM_WAYS)-1:0] mshr_refill_way_o,
  // Fanout
  output logic                     rsp_valid_o,
  output logic [4:0]               rsp_axi_id_o,
  output logic [PPN_WIDTH-1:0]      rsp_ppn_o,
  output logic [PERM_WIDTH-1:0]     rsp_perm_o,
  output logic                     rsp_page_size_o,
  output logic                     rsp_error_o,
  input  logic                     rsp_ready_i,
  input  logic                     flush_i
);
  typedef enum logic [1:0] { IDLE, ISSUE, WAIT, FANOUT } state_e;
  typedef struct packed {
    state_e                state;
    logic [VPN_WIDTH-1:0]  vpn;
    logic [ASID_WIDTH-1:0] asid;
    logic [PPN_WIDTH-1:0]  ppn;
    logic [PERM_WIDTH-1:0] perm;
    logic                  page_size;
    logic                  dirty;
    logic                  error;
    logic                  dbit_update;
    logic [PERM_WIDTH-1:0] req_perm_agg;
    logic [3:0]            req_map;
    logic [19:0]           req_id_map;
    logic [11:0]           perm_map;
  } entry_t;
  entry_t entries [MSHR_DEPTH];
  function automatic [1:0] first_one(input logic [3:0] v);
    for (int k = 0; k < 4; k++)
      if (v[k]) return k[1:0];
    return 2'd0;
  endfunction
  // Full detect
  always_comb begin
    mshr_full_o = 1'b1;
    for (int i = 0; i < MSHR_DEPTH; i++)
      if (entries[i].state == IDLE)
        mshr_full_o = 1'b0;
  end
  // PTW issue
  generate
    for (genvar g = 0; g < MSHR_DEPTH; g++) begin
      assign mshr_valid_o[g]      = (entries[g].state == ISSUE);
      assign mshr_issue_elig_o[g] = (entries[g].state == ISSUE);
      assign mshr_vpn_o[g]        = entries[g].vpn;
      assign mshr_req_id_o[g]     = g[REQ_ID_WIDTH-1:0];
      assign mshr_type_o[g]       = entries[g].req_perm_agg;
    end
  endgenerate
  logic fan_active;
  logic [REQ_ID_WIDTH-1:0] fan_idx;
  logic [1:0] fan_slot;
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i || flush_i) begin
      for (int i = 0; i < MSHR_DEPTH; i++)
        entries[i] <= '0;
      fan_active <= 1'b0;
      mshr_refill_valid_o <= 1'b0;
    end else begin
      mshr_refill_valid_o <= 1'b0;
      // ISSUE → WAIT
      for (int i = 0; i < MSHR_DEPTH; i++)
        if (entries[i].state == ISSUE && mshr_issue_grant_i[i])
          entries[i].state <= WAIT;
      // Allocation / merge (ONLY ISSUE or WAIT, block if PTW resp)
      if (req_valid_i && !mshr_full_o && !mshr_resp_valid_i) begin
        bit done = 0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
          if (!done &&
              (entries[i].state == ISSUE || entries[i].state == WAIT) &&
              entries[i].vpn  == req_vpn_i &&
              entries[i].asid == req_asid_i &&
              entries[i].req_map != 4'b1111) begin
            int s = first_one(~entries[i].req_map);
            entries[i].req_map[s]        <= 1'b1;
            entries[i].req_id_map[s*5 +: 5] <= req_axi_id_i;
            entries[i].perm_map[s*3 +: 3]   <= req_type_i;
            entries[i].req_perm_agg     <= entries[i].req_perm_agg | req_type_i;
            entries[i].dbit_update      <= entries[i].dbit_update | req_dbit_update_i;
            done = 1;
          end
        end
        if (!done)
          for (int i = 0; i < MSHR_DEPTH; i++)
            if (entries[i].state == IDLE) begin
              entries[i] <= '{
                state: ISSUE,
                vpn: req_vpn_i,
                asid: req_asid_i,
                ppn: '0,
                perm: '0,
                page_size: 1'b0,
                dirty: 1'b0,
                error: 1'b0,
                dbit_update: req_dbit_update_i,
                req_perm_agg: req_type_i,
                req_map: 4'b0001,
                req_id_map: {15'b0, req_axi_id_i},
                perm_map: {9'b0, req_type_i}
              };
              break;
            end
      end
      // PTW response
      if (mshr_resp_valid_i) begin
        entries[mshr_resp_id_i].ppn   <= mshr_resp_ppn_i;
        entries[mshr_resp_id_i].perm  <= mshr_resp_perm_i;
        entries[mshr_resp_id_i].page_size <= mshr_resp_page_size_i;
        entries[mshr_resp_id_i].dirty <= mshr_resp_dirty_i;
        entries[mshr_resp_id_i].error <= mshr_resp_error_i;
        entries[mshr_resp_id_i].state <= FANOUT;
        mshr_refill_valid_o <= 1'b1;
        mshr_refill_vpn_o   <= entries[mshr_resp_id_i].vpn;
        mshr_refill_ppn_o   <= mshr_resp_ppn_i;
        mshr_refill_perm_o  <= mshr_resp_perm_i;
        mshr_refill_page_size_o <= mshr_resp_page_size_i;
        mshr_refill_dirty_o <= mshr_resp_dirty_i;
        mshr_refill_dbit_update_o <= entries[mshr_resp_id_i].dbit_update;
        mshr_refill_set_idx_o <= entries[mshr_resp_id_i].vpn[9:5];
        mshr_refill_way_o <= mshr_resp_id_i[$clog2(NUM_WAYS)-1:0];
      end
      // Fanout
      if (!fan_active && rsp_ready_i)
        for (int i = 0; i < MSHR_DEPTH; i++)
          if (entries[i].state == FANOUT && entries[i].req_map != 0) begin
            fan_idx <= i;
            fan_slot <= first_one(entries[i].req_map);
            fan_active <= 1'b1;
            break;
          end
      else if (fan_active && rsp_ready_i) begin
        entries[fan_idx].req_map[fan_slot] <= 1'b0;
        fan_active <= 1'b0;
        if (entries[fan_idx].req_map == (1'b1 << fan_slot))
          entries[fan_idx] <= '0;
      end
    end
  end
  assign rsp_valid_o     = fan_active;
  assign rsp_axi_id_o    = entries[fan_idx].req_id_map[fan_slot*5 +: 5];
  assign rsp_ppn_o       = entries[fan_idx].ppn;
  assign rsp_page_size_o = entries[fan_idx].page_size;
  assign rsp_error_o     = entries[fan_idx].error;
  assign rsp_perm_o      = entries[fan_idx].perm &
                           entries[fan_idx].perm_map[fan_slot*3 +: 3];
endmodule`timescale 1ns/1ps
module l2_tlb_mshr
  import l2_tlb_pkg::*;
#(
  parameter int MSHR_DEPTH   = 16,
  parameter int REQ_ID_WIDTH = 4
)(
  input  logic clk_i,
  input  logic rstn_i,
  // Miss request
  input  logic                     req_valid_i,
  input  logic [VPN_WIDTH-1:0]      req_vpn_i,
  input  logic [ASID_WIDTH-1:0]     req_asid_i,
  input  logic [PERM_WIDTH-1:0]     req_type_i,
  input  logic [4:0]                req_axi_id_i,
  input  logic                     req_dbit_update_i,
  output logic                     mshr_full_o,
  // PTW issue
  output logic [MSHR_DEPTH-1:0]      mshr_valid_o,
  output logic [MSHR_DEPTH-1:0]      mshr_issue_elig_o,
  output logic [VPN_WIDTH-1:0]       mshr_vpn_o [MSHR_DEPTH],
  output logic [REQ_ID_WIDTH-1:0]    mshr_req_id_o [MSHR_DEPTH],
  output logic [PERM_WIDTH-1:0]      mshr_type_o [MSHR_DEPTH],
  input  logic [MSHR_DEPTH-1:0]      mshr_issue_grant_i,
  // PTW response
  input  logic                     mshr_resp_valid_i,
  input  logic [REQ_ID_WIDTH-1:0]   mshr_resp_id_i,
  input  logic [PPN_WIDTH-1:0]      mshr_resp_ppn_i,
  input  logic [PERM_WIDTH-1:0]     mshr_resp_perm_i,
  input  logic                     mshr_resp_page_size_i,
  input  logic                     mshr_resp_dirty_i,
  input  logic                     mshr_resp_error_i,
  // Refill
  output logic                     mshr_refill_valid_o,
  output logic [VPN_WIDTH-1:0]      mshr_refill_vpn_o,
  output logic [PPN_WIDTH-1:0]      mshr_refill_ppn_o,
  output logic [PERM_WIDTH-1:0]     mshr_refill_perm_o,
  output logic                     mshr_refill_page_size_o,
  output logic                     mshr_refill_dirty_o,
  output logic                     mshr_refill_dbit_update_o,
  output logic [SET_INDEX_WIDTH-1:0] mshr_refill_set_idx_o,
  output logic [$clog2(NUM_WAYS)-1:0] mshr_refill_way_o,
  // Fanout
  output logic                     rsp_valid_o,
  output logic [4:0]               rsp_axi_id_o,
  output logic [PPN_WIDTH-1:0]      rsp_ppn_o,
  output logic [VPN_WIDTH-1:0] rsp_vpn_o,
  output logic [PERM_WIDTH-1:0]     rsp_perm_o,
  output logic                     rsp_page_size_o,
  output logic                     rsp_error_o,
  input  logic                     rsp_ready_i,
  input  logic                     flush_i
);
  typedef enum logic [1:0] { IDLE, ISSUE, WAIT, FANOUT } state_e;
  typedef struct packed {
    state_e                state;
    logic [VPN_WIDTH-1:0]  vpn;
    logic [ASID_WIDTH-1:0] asid;
    logic [PPN_WIDTH-1:0]  ppn;
    logic [PERM_WIDTH-1:0] perm;
    logic                  page_size;
    logic                  dirty;
    logic                  error;
    logic                  dbit_update;
    logic [PERM_WIDTH-1:0] req_perm_agg;
    logic [3:0]            req_map;
    logic [19:0]           req_id_map;
    logic [11:0]           perm_map;
  } entry_t;
  entry_t entries [MSHR_DEPTH];
  function automatic [1:0] first_one(input logic [3:0] v);
    for (int k = 0; k < 4; k++)
      if (v[k]) return k[1:0];
    return 2'd0;
  endfunction
  // Full detect
  always_comb begin
    mshr_full_o = 1'b1;
    for (int i = 0; i < MSHR_DEPTH; i++)
      if (entries[i].state == IDLE)
        mshr_full_o = 1'b0;
  end
  // PTW issue
  generate
    for (genvar g = 0; g < MSHR_DEPTH; g++) begin
      assign mshr_valid_o[g]      = (entries[g].state == ISSUE);
      assign mshr_issue_elig_o[g] = (entries[g].state == ISSUE);
      assign mshr_vpn_o[g]        = entries[g].vpn;
      assign mshr_req_id_o[g]     = g[REQ_ID_WIDTH-1:0];
      assign mshr_type_o[g]       = entries[g].req_perm_agg;
    end
  endgenerate
  logic fan_active;
  logic [REQ_ID_WIDTH-1:0] fan_idx;
  logic [1:0] fan_slot;
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i || flush_i) begin
      for (int i = 0; i < MSHR_DEPTH; i++)
        entries[i] <= '0;
      fan_active <= 1'b0;
      mshr_refill_valid_o <= 1'b0;
    end else begin
      mshr_refill_valid_o <= 1'b0;
      // ISSUE → WAIT
      for (int i = 0; i < MSHR_DEPTH; i++)
        if (entries[i].state == ISSUE && mshr_issue_grant_i[i])
          entries[i].state <= WAIT;
      // Allocation / merge (ONLY ISSUE or WAIT, block if PTW resp)
      if (req_valid_i && !mshr_full_o && !mshr_resp_valid_i) begin
        bit done = 0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
          if (!done &&
              (entries[i].state == ISSUE || entries[i].state == WAIT) &&
              entries[i].vpn  == req_vpn_i &&
              entries[i].asid == req_asid_i &&
              entries[i].req_map != 4'b1111) begin
            int s = first_one(~entries[i].req_map);
            entries[i].req_map[s]        <= 1'b1;
            entries[i].req_id_map[s*5 +: 5] <= req_axi_id_i;
            entries[i].perm_map[s*3 +: 3]   <= req_type_i;
            entries[i].req_perm_agg     <= entries[i].req_perm_agg | req_type_i;
            entries[i].dbit_update      <= entries[i].dbit_update | req_dbit_update_i;
            done = 1;
          end
        end
        if (!done)
          for (int i = 0; i < MSHR_DEPTH; i++)
            if (entries[i].state == IDLE) begin
              entries[i] <= '{
                state: ISSUE,
                vpn: req_vpn_i,
                asid: req_asid_i,
                ppn: '0,
                perm: '0,
                page_size: 1'b0,
                dirty: 1'b0,
                error: 1'b0,
                dbit_update: req_dbit_update_i,
                req_perm_agg: req_type_i,
                req_map: 4'b0001,
                req_id_map: {15'b0, req_axi_id_i},
                perm_map: {9'b0, req_type_i}
              };
              break;
            end
      end
      // PTW response
      if (mshr_resp_valid_i) begin
        entries[mshr_resp_id_i].ppn   <= mshr_resp_ppn_i;
        entries[mshr_resp_id_i].perm  <= mshr_resp_perm_i;
        entries[mshr_resp_id_i].page_size <= mshr_resp_page_size_i;
        entries[mshr_resp_id_i].dirty <= mshr_resp_dirty_i;
        entries[mshr_resp_id_i].error <= mshr_resp_error_i;
        entries[mshr_resp_id_i].state <= FANOUT;
        mshr_refill_valid_o <= 1'b1;
        mshr_refill_vpn_o   <= entries[mshr_resp_id_i].vpn;
        mshr_refill_ppn_o   <= mshr_resp_ppn_i;
        mshr_refill_perm_o  <= mshr_resp_perm_i;
        mshr_refill_page_size_o <= mshr_resp_page_size_i;
        mshr_refill_dirty_o <= mshr_resp_dirty_i;
        mshr_refill_dbit_update_o <= entries[mshr_resp_id_i].dbit_update;
        mshr_refill_set_idx_o <= entries[mshr_resp_id_i].vpn[9:5];
        mshr_refill_way_o <= mshr_resp_id_i[$clog2(NUM_WAYS)-1:0];
      end
      // Fanout
      if (!fan_active && rsp_ready_i)
        for (int i = 0; i < MSHR_DEPTH; i++)
          if (entries[i].state == FANOUT && entries[i].req_map != 0) begin
            fan_idx <= i;
            fan_slot <= first_one(entries[i].req_map);
            fan_active <= 1'b1;
            break;
          end
      else if (fan_active && rsp_ready_i) begin
        entries[fan_idx].req_map[fan_slot] <= 1'b0;
        fan_active <= 1'b0;
        if (entries[fan_idx].req_map == (1'b1 << fan_slot))
          entries[fan_idx] <= '0;
      end
    end
  end
assign rsp_valid_o     = fan_active;
assign rsp_axi_id_o    = entries[fan_idx].req_id_map[fan_slot*5 +: 5];
assign rsp_ppn_o       = entries[fan_idx].ppn;
assign rsp_vpn_o       = fan_active ? entries[fan_idx].vpn : '0;
assign rsp_page_size_o = entries[fan_idx].page_size;
assign rsp_error_o     = entries[fan_idx].error;
assign rsp_perm_o      = entries[fan_idx].perm &
                         entries[fan_idx].perm_map[fan_slot*3 +: 3];
endmodule  
 
 