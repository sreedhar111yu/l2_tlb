`timescale 1ns/1ps

module read_response_rx #(
  parameter int VPN_W   = 32,
  parameter int PPN_W   = 32,
  parameter int REQID_W = 4,
  parameter int TYPE_W  = 2,
  parameter int PG_W    = 2
)(
  input  logic clk,
  input  logic rst_n,

  // From PTW
  input  logic               ptw_resp_valid,
  input  logic [PPN_W-1:0]   ptw_resp_ppn,
  input  logic [REQID_W-1:0] ptw_resp_req_id,
  input  logic [PG_W-1:0]    ptw_resp_pgsize,
  input  logic               ptw_resp_error,
  input  logic [TYPE_W-1:0]  ptw_resp_type,
  input  logic               ptw_resp_dirty_upd,

  // To MSHR
  output logic               mshr_resp_valid,
  output logic [REQID_W-1:0] mshr_resp_req_id,
  output logic [PPN_W-1:0]   mshr_resp_ppn,
  output logic [PG_W-1:0]    mshr_resp_pgsize,
  output logic               mshr_resp_error,
  output logic               mshr_resp_dirty_upd
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mshr_resp_valid     <= 1'b0;
      mshr_resp_req_id    <= '0;
      mshr_resp_ppn       <= '0;
      mshr_resp_pgsize    <= '0;
      mshr_resp_error     <= 1'b0;
      mshr_resp_dirty_upd <= 1'b0;
    end else begin
      mshr_resp_valid <= ptw_resp_valid;
      
      if (ptw_resp_valid) begin
        mshr_resp_req_id    <= ptw_resp_req_id;
        mshr_resp_ppn       <= ptw_resp_ppn;
        mshr_resp_pgsize    <= ptw_resp_pgsize;
        mshr_resp_error     <= ptw_resp_error;
        mshr_resp_dirty_upd <= ptw_resp_dirty_upd;
      end
    end
  end

endmodule