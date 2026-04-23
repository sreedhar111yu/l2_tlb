// =============================================================
// L2 TLB PLRU – FINAL, SYNTHESIS SAFE
// =============================================================
module l2_tlb_plru #(
  parameter int SETS = 32
)(
  input  logic       clk_i,
  input  logic       rstn_i,

  input  logic [4:0] set_idx_i,
  input  logic [7:0] way_valid_i,
  output logic [2:0] replace_way_o,

  input  logic       upd_en_i,
  input  logic [2:0] upd_way_i
);

  logic [6:0] plru_tree [SETS-1:0];

  always_comb begin
    if      (!way_valid_i[0]) replace_way_o = 0;
    else if (!way_valid_i[1]) replace_way_o = 1;
    else if (!way_valid_i[2]) replace_way_o = 2;
    else if (!way_valid_i[3]) replace_way_o = 3;
    else if (!way_valid_i[4]) replace_way_o = 4;
    else if (!way_valid_i[5]) replace_way_o = 5;
    else if (!way_valid_i[6]) replace_way_o = 6;
    else if (!way_valid_i[7]) replace_way_o = 7;
    else begin
      replace_way_o[2] = plru_tree[set_idx_i][6];
      replace_way_o[1] = replace_way_o[2] ? plru_tree[set_idx_i][4]
                                          : plru_tree[set_idx_i][5];
      replace_way_o[0] = replace_way_o[1] ? plru_tree[set_idx_i][2]
                                          : plru_tree[set_idx_i][3];
    end
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i)
      for (int i=0;i<SETS;i++)
        plru_tree[i] <= 7'b0;
    else if (upd_en_i) begin
      plru_tree[set_idx_i][6] <= ~upd_way_i[2];
      if (!upd_way_i[2]) begin
        plru_tree[set_idx_i][5] <= ~upd_way_i[1];
        if (!upd_way_i[1])
          plru_tree[set_idx_i][3] <= ~upd_way_i[0];
        else
          plru_tree[set_idx_i][2] <= ~upd_way_i[0];
      end else begin
        plru_tree[set_idx_i][4] <= ~upd_way_i[1];
        if (!upd_way_i[1])
          plru_tree[set_idx_i][1] <= ~upd_way_i[0];
        else
          plru_tree[set_idx_i][0] <= ~upd_way_i[0];
      end
    end
  end
endmodule