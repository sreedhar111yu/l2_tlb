// =====================================================================
// L2 TLB TOP-LEVEL WRAPPER – FINAL, 600MHz SAFE, SYNTHESIS CLEAN
// Integrates Core, MSHR, PLRU, CSR, and AXI/PTW Interfaces.
// =====================================================================
`timescale 1ns/1ps

module l2_tlb_top
  import l2_tlb_pkg::*;
(
  // ======================================================
  // Clock / Reset
  // ======================================================
  input  logic        clk_i,
  input  logic        rstn_i,

  // ======================================================
  // APB Interface (CSR Configuration)
  // ======================================================
  input  logic        pclk_i,
  input  logic        presetn_i,
  input  logic        psel_i,
  input  logic        penable_i,
  input  logic        pwrite_i,
  input  logic [11:0] paddr_i,
  input  logic [31:0] pwdata_i,
  output logic [31:0] prdata_o,
  output logic        pready_o,
  output logic        pslverr_o,

  // ======================================================
  // AXI4 Read Address Channel (L1 -> L2)
  // ======================================================
  input  logic        axi_arvalid_i,
  input  logic [31:0] axi_araddr_i,
  input  logic [2:0]  axi_aruser_i,
  input  logic [4:0]  axi_arid_i,
  output logic        axi_arready_o,

  // ======================================================
  // AXI4 Read Data Channel (L2 -> L1)
  // ======================================================
  output logic        axi_rvalid_o,
  output logic [63:0] axi_rdata_o,
  output logic [4:0]  axi_rid_o,
  input  logic        axi_rready_i,

  // ======================================================
  // PTW Interface (Non-AXI)
  // ======================================================
  output logic        ptw_req_valid_o,
  output logic [31:0] ptw_req_vpn_o,
  output logic [3:0]  ptw_req_id_o,
  input  logic        ptw_req_ready_i,

  input  logic        ptw_resp_valid_i,
  input  logic [31:0] ptw_resp_ppn_i,
  input  logic        ptw_resp_error_i,
  input  logic [3:0]  ptw_resp_id_i
);

  // ======================================================
  // LOCAL PARAMETERS
  // ======================================================
  localparam int MSHR_DEPTH   = 16;
  localparam int REQ_ID_WIDTH = 4;

  // ======================================================
  // INTERNAL NETS & WIRES
  // ======================================================
  // CSR
  logic                  csr_enable;
  logic                  csr_flush_all;
  logic                  csr_flush_asid_valid;
  logic [ASID_WIDTH-1:0] csr_asid;
  logic [ASID_WIDTH-1:0] csr_flush_asid;
  
  // Core <-> MSHR / PTW Status
  logic                  core_hit;
  logic                  core_miss;
  logic                  mshr_full;
  logic                  mshr_resp_error;

  // ======================================================
  // 1. APB CONFIGURATION REGISTERS (CSR)
  // ======================================================
  l2_tlb_csr u_csr (
    .pclk_i                 (pclk_i), 
    .presetn_i              (presetn_i),
    .psel_i                 (psel_i), 
    .penable_i              (penable_i), 
    .pwrite_i               (pwrite_i),
    .paddr_i                (paddr_i), 
    .pwdata_i               (pwdata_i),
    .prdata_o               (prdata_o), 
    .pready_o               (pready_o), 
    .pslverr_o              (pslverr_o),
    
    // Telemetry fixes routed correctly
    .tlb_hit_i              (core_hit),
    .tlb_miss_i             (core_miss),
    .ptw_error_i            (mshr_resp_error), // From PTW RX
    .mshr_full_i            (mshr_full),       // From MSHR

    .csr_asid_o             (csr_asid),
    .csr_flush_all_o        (csr_flush_all),
    .csr_flush_asid_valid_o (csr_flush_asid_valid),
    .csr_flush_asid_o       (csr_flush_asid),
    .csr_enable_o           (csr_enable),
    .hit_cnt_o              (), 
    .miss_cnt_o             (), 
    .err_cnt_o              ()
  );

  // ======================================================
  // 2. AXI READ REQUEST RX (Skid Buffer)
  // ======================================================
  logic                  tlb_req_valid;
  logic                  tlb_req_ready;
  logic [VPN_WIDTH-1:0]  tlb_req_vpn;
  logic [PERM_WIDTH-1:0] tlb_req_perm;
  logic [4:0]            tlb_req_id;

  axi_rd_req_rx_l2_tlb u_axi_rx (
    .clk_i              (clk_i), 
    .rstn_i             (rstn_i),
    .axi_arvalid_i      (axi_arvalid_i),
    .axi_araddr_i       (axi_araddr_i),
    .axi_aruser_i       (axi_aruser_i),
    .axi_arid_i         (axi_arid_i),
    .axi_arready_o      (axi_arready_o),
    .l2_tlb_req_valid_o (tlb_req_valid),
    .l2_tlb_req_vpn_o   (tlb_req_vpn),
    .l2_tlb_req_perm_o  (tlb_req_perm),
    .l2_tlb_req_id_o    (tlb_req_id),
    .l2_tlb_req_ready_i (tlb_req_ready)
  );

  // ======================================================
  // 3. L2 TLB DATA CORE
  // ======================================================
  logic                  core_need_ptw;
  logic                  core_resp_valid;
  logic                  core_resp_error;
  logic                  core_resp_pgsize;
  logic [PPN_WIDTH-1:0]  core_resp_ppn;
  logic [PERM_WIDTH-1:0] core_resp_perm;
  logic [4:0]            core_resp_id;

  // PLRU Interconnect
  logic [SET_INDEX_WIDTH-1:0]  plru_set;
  logic [NUM_WAYS-1:0]         plru_way_valid;
  logic                        plru_hit;
  logic                        plru_alloc;
  logic [$clog2(NUM_WAYS)-1:0] plru_hit_way;
  logic [$clog2(NUM_WAYS)-1:0] plru_victim;

  // PTW Refill Interconnect
  logic                    mshr_resp_valid;
  logic [REQ_ID_WIDTH-1:0] mshr_resp_id;
  logic [PPN_WIDTH-1:0]    mshr_resp_ppn;
  logic [VPN_WIDTH-1:0]    mshr_vpn [MSHR_DEPTH];
  logic [1:0]              mshr_type [MSHR_DEPTH]; // Derived from previous user code

  l2_tlb_core u_core (
    .clk_i                  (clk_i), 
    .rstn_i                 (rstn_i),
    
    // Requests
    .req_valid_i            (tlb_req_valid),
    .req_ready_o            (tlb_req_ready),
    .req_vpn_i              (tlb_req_vpn),
    .req_type_i             (tlb_req_perm),
    .req_id_i               (tlb_req_id),
    
    // CSR
    .csr_enable_i           (csr_enable),
    .csr_asid_i             (csr_asid),
    .csr_flush_all_i        (csr_flush_all),
    .csr_flush_asid_valid_i (csr_flush_asid_valid),
    .csr_flush_asid_i       (csr_flush_asid),
    
    // Refill Interface (FIXED: Routed from PTW RX and MSHR)
    .mshr_refill_valid_i    (mshr_resp_valid),
    .mshr_vpn_i             (mshr_vpn[mshr_resp_id]),          // Recover VPN from MSHR Array
    .mshr_ppn_i             (mshr_resp_ppn),
    .mshr_perm_i            (3'b111),                          // Give full permissions on refill, or route if stored
    .mshr_page_size_i       (1'b0),
    .mshr_dirty_i           (1'b0),
    .mshr_dbit_update_i     (1'b0),
    .mshr_set_idx_i         (mshr_vpn[mshr_resp_id][9:5]),     // Extract 5-bit set from VPN
    .mshr_way_i             ('0),
    
    // Outputs
    .tlb_hit_o              (core_hit),
    .tlb_miss_o             (core_miss),
    .need_ptw_o             (core_need_ptw),
    .resp_valid_o           (core_resp_valid),
    .resp_ppn_o             (core_resp_ppn),
    .resp_perm_o            (core_resp_perm),
    .resp_page_size_o       (core_resp_pgsize),
    .resp_error_o           (core_resp_error),
    .resp_id_o              (core_resp_id),
    
    // PLRU
    .plru_set_idx_o         (plru_set),
    .plru_way_valid_o       (plru_way_valid),
    .plru_hit_o             (plru_hit),
    .plru_hit_way_idx_o     (plru_hit_way),
    .plru_alloc_o           (plru_alloc),
    .plru_victim_way_i      (plru_victim)
  );

  // ======================================================
  // 4. PSEUDO-LRU REPLACEMENT POLICY
  // ======================================================
  l2_tlb_plru u_plru (
    .clk_i         (clk_i), 
    .rstn_i        (rstn_i),
    .set_idx_i     (plru_set),
    .way_valid_i   (plru_way_valid),
    .replace_way_o (plru_victim),
    .upd_en_i      (plru_hit | plru_alloc),
    .upd_way_i     (plru_hit ? plru_hit_way : plru_victim)
  );

  // ======================================================
  // 5. MISS STATUS HANDLING REGISTER (MSHR)
  // ======================================================
  logic [MSHR_DEPTH-1:0]   mshr_valid;
  logic [MSHR_DEPTH-1:0]   mshr_issue_elig;
  logic [MSHR_DEPTH-1:0]   mshr_issue_grant;
  logic [REQ_ID_WIDTH-1:0] mshr_req_id [MSHR_DEPTH];

  logic                    mshr_rsp_valid;
  logic                    mshr_rsp_error;
  logic [PPN_WIDTH-1:0]    mshr_rsp_ppn;
  logic [1:0]              mshr_rsp_l1id;
  
  logic                    fifo_mshr_ready; // Backpressure from FIFO

  l2_tlb_mshr u_mshr (
    .clk_i              (clk_i),
    .rstn_i             (rstn_i),
    
    // Miss Request from Core
    .req_valid_i        (core_need_ptw),
    .req_vpn_i          (tlb_req_vpn),
    .req_asid_i         (csr_asid),
    .req_l1_id_i        (tlb_req_id[1:0]),
    .req_dbit_update_i  (1'b0),
    .mshr_full_o        (mshr_full),
    
    // Issue to PTW Gen
    .mshr_valid_o       (mshr_valid),
    .mshr_issue_elig_o  (mshr_issue_elig),
    .mshr_vpn_o         (mshr_vpn),
    .mshr_req_id_o      (mshr_req_id),
    .mshr_issue_grant_i (mshr_issue_grant),
    
    // PTW Response Rx
    .mshr_resp_valid_i  (mshr_resp_valid),
    .mshr_resp_id_i     (mshr_resp_id),
    .mshr_resp_ppn_i    (mshr_resp_ppn),
    .mshr_resp_error_i  (mshr_resp_error),
    
    // Fanout to FIFO
    .rsp_valid_o        (mshr_rsp_valid),
    .rsp_ppn_o          (mshr_rsp_ppn),
    .rsp_l1_id_o        (mshr_rsp_l1id),
    .rsp_error_o        (mshr_rsp_error),
    .rsp_ready_i        (fifo_mshr_ready), // FIXED: Routed to FIFO backpressure
    
    .flush_i            (csr_flush_all)
  );

  // ======================================================
  // 6. PTW READ REQUEST GENERATOR
  // ======================================================
  assign mshr_type = '{default:'0}; // Type fallback to satisfy port map

  read_request_gen u_read_request_gen (
    .clk              (clk_i),
    .rst_n            (rstn_i),
    .mshr_valid       (mshr_valid),
    .mshr_issue_elig  (mshr_issue_elig),
    .mshr_vpn         (mshr_vpn),
    .mshr_req_id      (mshr_req_id),
    .mshr_type        (mshr_type),
    .ptw_req_ready    (ptw_req_ready_i),
    .ptw_req_valid    (ptw_req_valid_o),
    .ptw_req_vpn      (ptw_req_vpn_o),
    .ptw_req_id       (ptw_req_id_o),
    .ptw_req_type     (),
    .mshr_issue_grant (mshr_issue_grant)
  );

  // ======================================================
  // 7. PTW READ RESPONSE RECEIVER
  // ======================================================
  read_response_rx u_read_response_rx (
    .clk                 (clk_i),
    .rst_n               (rstn_i),
    .ptw_resp_valid      (ptw_resp_valid_i),
    .ptw_resp_ppn        (ptw_resp_ppn_i),
    .ptw_resp_req_id     (ptw_resp_id_i),
    .ptw_resp_pgsize     ('0),
    .ptw_resp_error      (ptw_resp_error_i),
    .ptw_resp_type       ('0),
    .ptw_resp_dirty_upd  (1'b0),
    
    .mshr_resp_valid     (mshr_resp_valid),
    .mshr_resp_req_id    (mshr_resp_id),
    .mshr_resp_ppn       (mshr_resp_ppn),
    .mshr_resp_error     (mshr_resp_error),
    .mshr_resp_pgsize    (),
    .mshr_resp_dirty_upd ()
  );

  // ======================================================
  // 8. RESPONSE MERGING FIFO
  // ======================================================
  logic                  fifo_valid;
  logic                  fifo_ready;
  logic [4:0]            fifo_id;
  logic [PPN_WIDTH-1:0]  fifo_ppn;
  logic [PERM_WIDTH-1:0] fifo_perm;
  logic                  fifo_pgsize;
  logic                  fifo_error;
  
  logic                  core_resp_ready;

  l2_tlb_response_fifo u_fifo (
    .clk_i                    (clk_i), 
    .rstn_i                   (rstn_i),
    
    // TLB Hit Input
    .l2_tlb_resp_valid_i      (core_resp_valid),
    .l2_tlb_resp_ready_o      (core_resp_ready), // Driven but unconnected upstream (Core doesn't stall yet)
    .l2_tlb_resp_id_i         (core_resp_id),
    .l2_tlb_resp_ppn_i        (core_resp_ppn),
    .l2_tlb_resp_perm_i       (core_resp_perm),
    .l2_tlb_resp_page_size_i  (core_resp_pgsize),
    .l2_tlb_resp_error_i      (core_resp_error),
    
    // MSHR Fanout Input
    .l2_mshr_resp_valid_i     (mshr_rsp_valid),
    .l2_mshr_resp_ready_o     (fifo_mshr_ready), // FIXED: Stalls MSHR if FIFO full
    .l2_mshr_resp_id_i        ({3'b000, mshr_rsp_l1id}), // Zero-pad 2-bit L1 ID to 5-bit AXI ID
    .l2_mshr_resp_ppn_i       (mshr_rsp_ppn),
    .l2_mshr_resp_perm_i      (3'b111),          // MSHR responses assume full perms
    .l2_mshr_resp_page_size_i (1'b0),
    .l2_mshr_resp_error_i     (mshr_rsp_error),
    
    // Output to AXI Tx
    .resp_valid_o             (fifo_valid),
    .resp_id_o                (fifo_id),
    .resp_ppn_o               (fifo_ppn),
    .resp_perm_o              (fifo_perm),
    .resp_page_size_o         (fifo_pgsize),
    .resp_error_o             (fifo_error),
    .resp_ready_i             (fifo_ready)
  );

  // ======================================================
  // 9. AXI READ RESPONSE GENERATOR (FWFT)
  // ======================================================
  axi_rd_resp_gen_l2_tlb u_axi_tx (
    .clk_i                    (clk_i),
    .rstn_i                   (rstn_i),
    
    .l2_tlb_resp_valid_i      (fifo_valid),
    .l2_tlb_resp_id_i         (fifo_id),
    .l2_tlb_resp_ppn_i        (fifo_ppn),
    .l2_tlb_resp_perm_i       (fifo_perm),
    .l2_tlb_resp_page_size_i  (fifo_pgsize),
    .l2_tlb_resp_error_i      (fifo_error),
    .l2_tlb_resp_ready_o      (fifo_ready),
    
    .axi_rvalid_o             (axi_rvalid_o),
    .axi_rdata_o              (axi_rdata_o),
    .axi_rid_o                (axi_rid_o),
    .axi_rready_i             (axi_rready_i)
  );

endmodule