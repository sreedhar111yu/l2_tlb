`timescale 1ns/1ps

module read_request_gen #(
  parameter int MSHR_ENTRIES = 16,
  parameter int VPN_W        = 32,
  parameter int REQID_W      = 4,
  parameter int TYPE_W       = 2
)(
  input  logic clk,
  input  logic rst_n,

  // From MSHR
  input  logic [MSHR_ENTRIES-1:0] mshr_valid,
  input  logic [MSHR_ENTRIES-1:0] mshr_issue_elig,
  input  logic [VPN_W-1:0]        mshr_vpn     [MSHR_ENTRIES],
  input  logic [REQID_W-1:0]      mshr_req_id  [MSHR_ENTRIES],
  input  logic [TYPE_W-1:0]       mshr_type    [MSHR_ENTRIES],

  // From PTW
  input  logic ptw_req_ready,

  // To PTW
  output logic                ptw_req_valid,
  output logic [VPN_W-1:0]    ptw_req_vpn,
  output logic [REQID_W-1:0]  ptw_req_id,
  output logic [TYPE_W-1:0]   ptw_req_type,

  // Feedback to MSHR
  output logic [MSHR_ENTRIES-1:0] mshr_issue_grant
);

  localparam int IDX_W = $clog2(MSHR_ENTRIES);

  // Stage A: Arbitration (combinational)
  logic a_found;
  logic [IDX_W-1:0] a_sel_idx;

  always_comb begin
    a_found   = 1'b0;
    a_sel_idx = '0;
    for (int i = 0; i < MSHR_ENTRIES; i++) begin
      if (mshr_valid[i] && mshr_issue_elig[i] && !a_found) begin
        a_found   = 1'b1;
        a_sel_idx = i[IDX_W-1:0];
      end
    end
  end

  // Stage B: Register arbitration result
  logic b_valid;
  logic [IDX_W-1:0] b_sel_idx;
  logic ptw_fire;

  // 600MHz Protocol Fix: Fire when our valid and their ready overlap.
  assign ptw_fire = b_valid && ptw_req_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_valid   <= 1'b0;
      b_sel_idx <= '0;
    end else begin
      // Load new request if empty, OR if current request just fired
      if (a_found && (!b_valid || ptw_fire)) begin
        b_valid   <= 1'b1;
        b_sel_idx <= a_sel_idx;
      end else if (ptw_fire) begin
        b_valid   <= 1'b0; // Clear if fired and no new requests waiting
      end
    end
  end

  // Stage C: Drive PTW request (Protocol Compliant)
  assign ptw_req_valid = b_valid;  // VALID NO LONGER DEPENDS ON READY
  assign ptw_req_vpn   = mshr_vpn[b_sel_idx];
  assign ptw_req_id    = mshr_req_id[b_sel_idx];
  assign ptw_req_type  = mshr_type[b_sel_idx];

  // Feedback to MSHR (1-cycle pulse when transaction completes)
  always_comb begin
    mshr_issue_grant = '0;
    if (ptw_fire) mshr_issue_grant[b_sel_idx] = 1'b1;
  end

endmodule