// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

timeunit 1ps; timeprecision 1ps;

import hci_package::*;

module redmule_tb

  import redmule_pkg::*;
#(
  parameter TCP = 1.0ns, // clock period, 1 GHz clock
  parameter TA  = 0.2ns, // application time
  parameter TT  = 0.8ns,  // test time
  parameter logic UseXif = 1'b0,
  parameter real  PROB_STALL = 0,
  parameter logic mx_enable = 1'b1
)(
  input logic clk_i,
  input logic rst_ni,
  input logic fetch_enable_i
);

  // parameters
  // MX test vector storage for data
  logic [255:0] mx_x_data_mem [0:255];
  logic [255:0] mx_w_data_mem [0:255];
  
  localparam int unsigned NC = 1;
  localparam int unsigned ID = 10;
  localparam int unsigned DW = redmule_pkg::DATA_W;
  localparam int unsigned MP = DW/32;
  localparam int unsigned MEMORY_SIZE = 192*1024;
  localparam int unsigned STACK_MEMORY_SIZE = 192*1024;
  localparam int unsigned PULP_XPULP = 1;
  localparam int unsigned FPU = 0;
  localparam int unsigned PULP_ZFINX = 0;
  localparam logic [31:0] BASE_ADDR = 32'h1c000000;
  localparam logic [31:0] HWPE_ADDR_BASE_BIT = 20;
  localparam bit          USE_ECC = 0;
  localparam int unsigned EW = (USE_ECC) ? 72 : DEFAULT_EW;
  localparam redmule_pkg::core_type_e CoreType = UseXif ? redmule_pkg::CV32X
                                                        : redmule_pkg::CV32P;

  localparam hci_package::hci_size_parameter_t HciRedmuleSize = '{
    DW:  DW,
    AW:  hci_package::DEFAULT_AW,
    BW:  hci_package::DEFAULT_BW,
    UW:  hci_package::DEFAULT_UW,
    IW:  hci_package::DEFAULT_IW,
    EW:  EW,
    EHW: hci_package::DEFAULT_EHW,
    default: '0
  };


  // global signals
  string stim_instr, stim_data, stack_init;
  string mx_dir_resolved; // Directory for MX vectors, derived from stim_data
  logic test_mode;
  logic [31:0] core_boot_addr;
  logic redmule_busy;
  logic core_sleep;
  int errors;

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  bit perf_enable;
  logic perf_active;
  longint unsigned perf_total_cycles;
  longint unsigned perf_busy_cycles;
  longint unsigned perf_encoder_blocks;
  longint unsigned perf_decoder_blocks;

  initial begin
    if (!$value$plusargs("PERF_ENABLE=%0d", perf_enable)) begin
      perf_enable = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      perf_active         <= 1'b0;
      perf_total_cycles   <= '0;
      perf_busy_cycles    <= '0;
      perf_encoder_blocks <= '0;
      perf_decoder_blocks <= '0;
    end else begin
      if (perf_enable && !perf_active && fetch_enable_i) begin
        perf_active <= 1'b1;
      end

      if (perf_active) begin
        perf_total_cycles <= perf_total_cycles + 1;
        if (i_dut.i_redmule_top.busy_o) begin
          perf_busy_cycles <= perf_busy_cycles + 1;
        end
        if (i_dut.i_redmule_top.mx_val_valid && i_dut.i_redmule_top.mx_val_ready) begin
          perf_encoder_blocks <= perf_encoder_blocks + 1;
        end
        if (i_dut.i_redmule_top.mx_dec_fp16_valid && i_dut.i_redmule_top.mx_dec_fp16_ready) begin
          perf_decoder_blocks <= perf_decoder_blocks + 1;
        end
      end

      if (perf_active && core_sleep && (errors != -1)) begin
        perf_active <= 1'b0;
      end
    end
  end
  logic scan_cg_en;

  // Helper: get directory name from path
  function automatic string dirname(input string path);
    int i;
    dirname = path;
    // find last '/'
    for (i = path.len()-1; i >= 0; i--) begin
      if (path.getc(i) == "/") begin
        dirname = path.substr(0, i-1);
        return dirname;
      end
    end
    // no slash -> current dir
    dirname = ".";
  endfunction

  hwpe_stream_intf_tcdm instr[0:0]  (.clk(clk_i));
  hwpe_stream_intf_tcdm stack[0:0]  (.clk(clk_i));
  hwpe_stream_intf_tcdm tcdm [MP:0] (.clk(clk_i));
  
  // MX exponent stream interface (encoder output)
  hwpe_stream_intf_stream #(.DATA_WIDTH(32)) mx_exp_stream (.clk(clk_i));
  
  // Simple exponent sink: always ready to accept exponents
  assign mx_exp_stream.ready = 1'b1;
  
  // MX exponent stream interfaces (decoder inputs for X and W)
  hwpe_stream_intf_stream #(.DATA_WIDTH(32)) x_mx_exp_stream (.clk(clk_i));
  hwpe_stream_intf_stream #(.DATA_WIDTH(32)) w_mx_exp_stream (.clk(clk_i));

  // MX test vector storage (increased size for large tests)
  logic [31:0] mx_x_exp_mem [0:19999];
  logic [31:0] mx_w_exp_mem [0:19999];
  integer mx_x_exp_idx = 0;
  integer mx_w_exp_idx = 0;
  logic [31:0] x_exp_data_reg, w_exp_data_reg;
  logic x_exp_valid_reg, w_exp_valid_reg;
  logic [31:0] x_exp_data_q, x_exp_data_d;
  logic [31:0] w_exp_data_q, w_exp_data_d;
  integer mx_x_exp_idx_q, mx_x_exp_idx_d;
  integer mx_w_exp_idx_q, mx_w_exp_idx_d;
  logic x_exp_valid_d, w_exp_valid_d;
  logic mx_enable_q;
  
  // stream output registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_exp_data_q    <= 32'h0;
      w_exp_data_q    <= 32'h0;
      x_exp_valid_reg <= 1'b0;
      w_exp_valid_reg <= 1'b0;
      mx_x_exp_idx_q  <= 0;
      mx_w_exp_idx_q  <= 0;
      mx_enable_q     <= 1'b0;
    end else begin
      x_exp_data_q    <= x_exp_data_d;
      w_exp_data_q    <= w_exp_data_d;
      x_exp_valid_reg <= x_exp_valid_d;
      w_exp_valid_reg <= w_exp_valid_d;
      mx_x_exp_idx_q  <= mx_x_exp_idx_d;
      mx_w_exp_idx_q  <= mx_w_exp_idx_d;
      mx_enable_q     <= mx_enable;
    end
  end

  // Combinational next-state logic for exponent streams
  always_comb begin
    // X exponent stream
    x_exp_data_d   = x_exp_data_q;
    mx_x_exp_idx_d = mx_x_exp_idx_q;
    x_exp_valid_d  = x_exp_valid_reg;
    if (!x_exp_valid_reg) begin
      // Initial load after reset or after stream exhausted
      if (mx_enable && (mx_x_exp_idx_q < $size(mx_x_exp_mem))) begin
        x_exp_data_d  = mx_x_exp_mem[mx_x_exp_idx_q];
        x_exp_valid_d = 1'b1;
      end else if (!mx_enable) begin
        x_exp_data_d  = 32'h0000_007f;
        x_exp_valid_d = 1'b1;
      end else begin
        x_exp_data_d  = 32'h0;
        x_exp_valid_d = 1'b0;
      end
    end else if (x_exp_valid_reg && x_mx_exp_stream.ready) begin
      // Handshake: advance index and load next data if available
      // Check if we just transitioned from bypass to MX mode
      if (mx_enable && !mx_enable_q) begin
        // Rising edge of mx_enable: reset index and load first element
        mx_x_exp_idx_d = 0;
        if ($size(mx_x_exp_mem) > 0) begin
          x_exp_data_d   = mx_x_exp_mem[0];
          x_exp_valid_d  = 1'b1;
        end else begin
          x_exp_data_d   = 32'h0;
          x_exp_valid_d  = 1'b0;
        end
      end else if (mx_enable && (mx_x_exp_idx_q+1 < $size(mx_x_exp_mem))) begin
        // Normal advance: load next element
        mx_x_exp_idx_d = mx_x_exp_idx_q + 1;
        x_exp_data_d   = mx_x_exp_mem[mx_x_exp_idx_q + 1];
        x_exp_valid_d  = 1'b1;
      end else begin
        x_exp_data_d   = 32'h0;
        x_exp_valid_d  = 1'b0;
      end
    end

    // W exponent stream
    w_exp_data_d   = w_exp_data_q;
    mx_w_exp_idx_d = mx_w_exp_idx_q;
    w_exp_valid_d  = w_exp_valid_reg;
    if (!w_exp_valid_reg) begin
      if (mx_enable && (mx_w_exp_idx_q < $size(mx_w_exp_mem))) begin
        w_exp_data_d  = mx_w_exp_mem[mx_w_exp_idx_q];
        w_exp_valid_d = 1'b1;
      end else if (!mx_enable) begin
        w_exp_data_d  = 32'h7f7f_7f7f;
        w_exp_valid_d = 1'b1;
      end else begin
        w_exp_data_d  = 32'h0;
        w_exp_valid_d = 1'b0;
      end
    end else if (w_exp_valid_reg && w_mx_exp_stream.ready) begin
      // Handshake: advance index and load next data if available
      // Check if we just transitioned from bypass to MX mode
      if (mx_enable && !mx_enable_q) begin
        // Rising edge of mx_enable: reset index and load first element
        mx_w_exp_idx_d = 0;
        if ($size(mx_w_exp_mem) > 0) begin
          w_exp_data_d   = mx_w_exp_mem[0];
          w_exp_valid_d  = 1'b1;
        end else begin
          w_exp_data_d   = 32'h0;
          w_exp_valid_d  = 1'b0;
        end
      end else if (mx_enable && (mx_w_exp_idx_q+1 < $size(mx_w_exp_mem))) begin
        // Normal advance: load next element
        mx_w_exp_idx_d = mx_w_exp_idx_q + 1;
        w_exp_data_d   = mx_w_exp_mem[mx_w_exp_idx_q + 1];
        w_exp_valid_d  = 1'b1;
      end else begin
        w_exp_data_d   = 32'h0;
        w_exp_valid_d  = 1'b0;
      end
    end
  end

  // --- Protocol Assertions for Exponent Streams ---
  // 1. Data must remain stable while valid=1 and ready=0
  logic [31:0] x_exp_data_last, w_exp_data_last;
  logic x_exp_stall_q, w_exp_stall_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_exp_data_last <= 32'h0;
      w_exp_data_last <= 32'h0;
      x_exp_stall_q   <= 1'b0;
      w_exp_stall_q   <= 1'b0;
    end else begin
      if (x_mx_exp_stream.valid && !x_mx_exp_stream.ready)
        x_exp_data_last <= x_mx_exp_stream.data;
      if (w_mx_exp_stream.valid && !w_mx_exp_stream.ready)
        w_exp_data_last <= w_mx_exp_stream.data;
      x_exp_stall_q <= x_mx_exp_stream.valid && !x_mx_exp_stream.ready;
      w_exp_stall_q <= w_mx_exp_stream.valid && !w_mx_exp_stream.ready;
    end
  end

  // Assert data is stable while valid=1 and ready=0
  always_ff @(posedge clk_i) begin
    if((x_mx_exp_stream.valid && !x_mx_exp_stream.ready) && x_exp_stall_q)
      assert(x_mx_exp_stream.data == x_exp_data_last)
        else $error("[TB][ASSERT] x_mx_exp_stream.data changed while valid=1 and ready=0");
    if ((w_mx_exp_stream.valid && !w_mx_exp_stream.ready) && w_exp_stall_q)
      assert(w_mx_exp_stream.data == w_exp_data_last)
        else $error("[TB][ASSERT] w_mx_exp_stream.data changed while valid=1 and ready=0");
  end

  // 2. Index must not overrun vector length
  always_ff @(posedge clk_i) begin
    if (mx_enable && x_mx_exp_stream.valid && x_mx_exp_stream.ready)
      assert(mx_x_exp_idx < $size(mx_x_exp_mem))
        else $error("[TB][ASSERT] mx_x_exp_idx overran mx_x_exp_mem size");
    if (mx_enable && w_mx_exp_stream.valid && w_mx_exp_stream.ready)
      assert(mx_w_exp_idx < $size(mx_w_exp_mem))
        else $error("[TB][ASSERT] mx_w_exp_idx overran mx_w_exp_mem size");
  end

  // 3. Only increment index on handshake (already implemented in always_ff)
  // 4. No multiple drivers: all assignments are in this always_ff and assign blocks

  // Connect registered outputs to interface
  assign x_mx_exp_stream.valid = x_exp_valid_reg;
  assign x_mx_exp_stream.data  = x_exp_data_q;
  assign x_mx_exp_stream.strb  = 4'hf;

  assign w_mx_exp_stream.valid = w_exp_valid_reg;
  assign w_mx_exp_stream.data  = w_exp_data_q;
  assign w_mx_exp_stream.strb  = 4'hf;
  
  // Optional: Monitor exponent stream for debugging
  // always_ff @(posedge clk_i) begin
  //   if (mx_exp_stream.valid && mx_exp_stream.ready) begin
  //     $display("[%0t] MX Exponent: 0x%02h", $time, mx_exp_stream.data[7:0]);
  //   end
  // end

  logic [NC-1:0][1:0]  evt;
  logic [MP-1:0]       tcdm_gnt;
  logic [MP-1:0][31:0] tcdm_r_data;
  logic [MP-1:0]       tcdm_r_valid;

  typedef struct packed {
    logic        req;
    logic [31:0] addr;
  } core_inst_req_t;

  typedef struct packed {
    logic        gnt;
    logic        valid;
    logic [31:0] data;
  } core_inst_rsp_t;

  typedef struct packed {
    logic req;
    logic we;
    logic [3:0] be;
    logic [31:0] addr;
    logic [31:0] data;
  } core_data_req_t;

  typedef struct packed {
    logic gnt;
    logic valid;
    logic [31:0] data;
  } core_data_rsp_t;

  hci_core_intf #(.DW(DW)) redmule_tcdm (.clk(clk_i));

  core_inst_req_t core_inst_req;
  core_inst_rsp_t core_inst_rsp;

  core_data_req_t core_data_req;
  core_data_rsp_t core_data_rsp;

  always_comb begin : bind_instrs
    instr[0].req  = core_inst_req.req;
    instr[0].add  = core_inst_req.addr;
    instr[0].wen  = 1'b1;
    instr[0].be   = '0;
    instr[0].data = '0;
    core_inst_rsp.gnt   = instr[0].gnt;
    core_inst_rsp.valid = instr[0].r_valid;
    core_inst_rsp.data  = instr[0].r_data;
  end

  always_comb begin : bind_stack
    stack[0].req  = core_data_req.req & (core_data_req.addr[31:16] == 16'h1c04) &
                    ~core_data_req.addr[HWPE_ADDR_BASE_BIT];
    stack[0].add  = core_data_req.addr;
    stack[0].wen  = ~core_data_req.we;
    stack[0].be   = core_data_req.be;
    stack[0].data = core_data_req.data;
  end

  logic other_r_valid;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni)
      other_r_valid <= '0;
    else
      other_r_valid <= core_data_req.req & (core_data_req.addr[31:24] == 8'h80);
  end

  for(genvar ii=0; ii<MP; ii++) begin : tcdm_binding
    assign tcdm[ii].req  = redmule_tcdm.req;
    assign tcdm[ii].add  = redmule_tcdm.add + ii*4;
    assign tcdm[ii].wen  = redmule_tcdm.wen;
    assign tcdm[ii].be   = redmule_tcdm.be[(ii+1)*4-1:ii*4];
    assign tcdm_gnt[ii]     = tcdm[ii].gnt;
    assign tcdm_r_valid[ii] = tcdm[ii].r_valid;
    assign tcdm_r_data[ii]  = tcdm[ii].r_data;
  end
  assign redmule_tcdm.gnt     = &tcdm_gnt;
  assign redmule_tcdm.r_data  = { >> {tcdm_r_data} };
  assign redmule_tcdm.r_valid = &tcdm_r_valid;
  assign redmule_tcdm.r_id    = '0;
  assign redmule_tcdm.r_opc   = '0;
  assign redmule_tcdm.r_user  = '0;

  if (USE_ECC) begin : gen_ecc
    logic [EW-1:0] tcdm_r_ecc;
    // RESPONSE PHASE ENCODING
    logic [MP-1:0][38:0] tcdm_r_data_enc;
    for(genvar ii=0; ii<MP; ii++) begin : gen_rdata_encoders
      hsiao_ecc_enc #(
        .DataWidth ( 32 )
      ) i_r_data_enc (
        .in  (tcdm_r_data[ii]),
        .out (tcdm_r_data_enc[ii])
      );
      assign tcdm_r_ecc[(ii+1)*7-1:ii*7] = tcdm_r_data_enc[ii][38:32];
    end
    assign tcdm_r_ecc[EW-1:(7*MP)] = '0;
    assign redmule_tcdm.r_ecc  = tcdm_r_ecc;

    // REQUEST PHASE DECODING
    for(genvar ii=0; ii<MP; ii++) begin : gen_data_decoders
      hsiao_ecc_dec #(
        .DataWidth ( 32 )
      ) i_data_dec (
        .in         ( { redmule_tcdm.ecc[(ii+1)*7-1+9:ii*7+9], redmule_tcdm.data[(ii+1)*32-1:ii*32] } ),
        .out        ( tcdm[ii].data ),
        .syndrome_o ( ),
        .err_o      ( )
      );
    end

    // FixMe: How should we drive these?
    // assign redmule_tcdm.egnt = '1;
    // assign redmule_tcdm.r_evalid = '0;

  end else begin: gen_no_ecc
    for(genvar ii=0; ii<MP; ii++)
      assign tcdm[ii].data = redmule_tcdm.data[(ii+1)*32-1:ii*32];

    assign redmule_tcdm.r_ecc = '0;
    assign redmule_tcdm.egnt = '1;
    assign redmule_tcdm.r_evalid = '0;
  end

  assign tcdm[MP].req  = core_data_req.req &
                         (core_data_req.addr[31:24] != '0) &
                         (core_data_req.addr[31:24] != 8'h80) &
                         ~core_data_req.addr[HWPE_ADDR_BASE_BIT];
  assign tcdm[MP].add  = core_data_req.addr;
  assign tcdm[MP].wen  = ~core_data_req.we;
  assign tcdm[MP].be   = core_data_req.be;
  assign tcdm[MP].data = core_data_req.data;

  assign core_data_rsp.gnt = stack[0].req ?
                             stack[0].gnt : tcdm[MP].req ?
                                            tcdm[MP].gnt : '1;

  assign core_data_rsp.data = stack[0].r_valid ? stack[0].r_data  :
                                                 tcdm[MP].r_valid ? tcdm[MP].r_data : '0;
  assign core_data_rsp.valid = stack[0].r_valid |
                               tcdm[MP].r_valid |
                               other_r_valid    ;

  tb_dummy_memory  #(
    .MP             ( MP + 1        ),
    .MEMORY_SIZE    ( MEMORY_SIZE   ),
    .BASE_ADDR      ( 32'h1c010000  ),
    .PROB_STALL     ( PROB_STALL    ),
    .TCP            ( TCP           ),
    .TA             ( TA            ),
    .TT             ( TT            )
  ) i_dummy_dmemory (
    .clk_i          ( clk_i         ),
    .rst_ni         ( rst_ni        ),
    .clk_delayed_i  ( '0            ),
    .randomize_i    ( 1'b0          ),
    .enable_i       ( 1'b1          ),
    .stallable_i    ( 1'b1          ),
    .tcdm           ( tcdm          )
  );

  tb_dummy_memory  #(
    .MP             ( 1           ),
    .MEMORY_SIZE    ( MEMORY_SIZE ),
    .BASE_ADDR      ( BASE_ADDR   ),
    .PROB_STALL     ( 0           ),
    .TCP            ( TCP         ),
    .TA             ( TA          ),
    .TT             ( TT          )
  ) i_dummy_imemory (
    .clk_i          ( clk_i       ),
    .rst_ni         ( rst_ni      ),
    .clk_delayed_i  ( '0          ),
    .randomize_i    ( 1'b0        ),
    .enable_i       ( 1'b1        ),
    .stallable_i    ( 1'b0        ),
    .tcdm           ( instr       )
  );

  tb_dummy_memory       #(
    .MP                  ( 1                 ),
    .MEMORY_SIZE         ( STACK_MEMORY_SIZE ),
    .BASE_ADDR           ( BASE_ADDR         ),
    .PROB_STALL          ( 0                 ),
    .TCP                 ( TCP               ),
    .TA                  ( TA                ),
    .TT                  ( TT                )
  ) i_dummy_stack_memory (
    .clk_i               ( clk_i             ),
    .rst_ni              ( rst_ni            ),
    .clk_delayed_i       ( '0                ),
    .randomize_i         ( 1'b0              ),
    .enable_i            ( 1'b1              ),
    .stallable_i         ( 1'b0              ),
    .tcdm                ( stack             )
  );

`ifdef TARGET_VERILATOR
  assign scan_cg_en = UseXif ? 1'b1 : 1'b0;
`else
  assign scan_cg_en = 1'b0;
`endif
  redmule_complex #(
    .CoreType           ( CoreType            ), // CV32E40P, CV32E40X, IBEX, SNITCH, CVA6
    .ID_WIDTH           ( ID                  ),
    .N_CORES            ( NC                  ),
    .NumIrqs            ( 1                   ),
    .AddrWidth          ( 32                  ),
    .HciRedmuleSize     ( HciRedmuleSize      ),
    .core_data_req_t    ( core_data_req_t     ),
    .core_data_rsp_t    ( core_data_rsp_t     ),
    .core_inst_req_t    ( core_inst_req_t     ),
    .core_inst_rsp_t    ( core_inst_rsp_t     )
  ) i_dut               (
    .clk_i              ( clk_i            ),
    .rst_ni             ( rst_ni           ),
    .test_mode_i        ( test_mode        ),
    .fetch_enable_i     ( fetch_enable_i   ),
    .scan_cg_en_i       ( scan_cg_en       ),
    .redmule_clk_en_i   ( 1'b1             ),
    .boot_addr_i        ( core_boot_addr   ),
    .irq_i              ( '0               ),
    .irq_id_o           (                  ),
    .irq_ack_o          (                  ),
    .core_sleep_o       ( core_sleep       ),
    .core_inst_rsp_i    ( core_inst_rsp    ),
    .core_inst_req_o    ( core_inst_req    ),
    .core_data_rsp_i    ( core_data_rsp    ),
    .core_data_req_o    ( core_data_req    ),
    .tcdm               ( redmule_tcdm     ),
    .mx_exp_stream      ( mx_exp_stream    ),
    .x_mx_exp_stream    ( x_mx_exp_stream  ),
    .w_mx_exp_stream    ( w_mx_exp_stream  )
  );

  integer f_x, f_W, f_y, f_tau;
  logic start;


  always_ff @(posedge clk_i)
  begin
    if((core_data_req.addr == 32'h80000000) &&
       (core_data_req.we & core_data_req.req == 1'b1)) begin
      errors = core_data_req.data;
    end
    if((core_data_req.addr == 32'h80000004 ) &&
       (core_data_req.we & core_data_req.req == 1'b1)) begin
      $write("%c", core_data_req.data);
    end
  end

  initial begin
    integer id;
    int cnt_rd, cnt_wr;

    errors = -1;
    if (!$value$plusargs("STIM_INSTR=%s", stim_instr)) stim_instr = "";
    if (!$value$plusargs("STIM_DATA=%s", stim_data)) stim_data = "";
    if (!$value$plusargs("STACK_INIT=%s", stack_init)) stack_init = "";
    $display("Please find STIM_INSTR loaded from %s", stim_instr);
    $display("Please find STIM_DATA loaded from %s", stim_data);
    $display("Please find STACK_INIT loaded from %s", stack_init);

    // MX: derive directory from stim_data
    if (mx_enable) begin
      // derive MX directory from stim_data absolute path
      mx_dir_resolved = dirname(stim_data);
      $display("[TB] MX dir derived from STIM_DATA: %s", mx_dir_resolved);

      // clear
      for (int i = 0; i < $size(mx_x_data_mem); i++) begin
        mx_x_data_mem[i] = '0;
        mx_w_data_mem[i] = '0;
      end
      for (int i = 0; i < $size(mx_x_exp_mem); i++) begin
        mx_x_exp_mem[i] = '0;
        mx_w_exp_mem[i] = '0;
      end

      // load from same folder as stim_data.txt
      $readmemh({mx_dir_resolved, "/mx_x_data.txt"}, mx_x_data_mem);
      $readmemh({mx_dir_resolved, "/mx_w_data.txt"}, mx_w_data_mem);
      $readmemh({mx_dir_resolved, "/mx_x_exp.txt"},  mx_x_exp_mem);
      $readmemh({mx_dir_resolved, "/mx_w_exp.txt"},  mx_w_exp_mem);
    end

    test_mode = 1'b0;
    core_boot_addr = 32'h1C000084;

    // Load instruction and data memory
    $readmemh(stim_instr, redmule_tb.i_dummy_imemory.memory);
    $readmemh(stim_data,  redmule_tb.i_dummy_dmemory.memory);
    $readmemh(stack_init, redmule_tb.i_dummy_stack_memory.memory);



    // End: WFI + returned != -1 signals end-of-computation
    while(~core_sleep || errors==-1) begin
      // Feed MX data to X and W buffers if enabled
      if (mx_enable) begin
        // Example: drive X and W buffer inputs from test vectors
        // (Replace with actual buffer interface as needed)
        // x_buffer_data_in = mx_x_data_mem[mx_x_data_idx];
        // w_buffer_data_in = mx_w_data_mem[mx_w_data_idx];
      end
      @(posedge clk_i);
    end
    cnt_rd = redmule_tb.i_dummy_dmemory.cnt_rd[0] +
             redmule_tb.i_dummy_dmemory.cnt_rd[1] +
             redmule_tb.i_dummy_dmemory.cnt_rd[2] +
             redmule_tb.i_dummy_dmemory.cnt_rd[3] +
             redmule_tb.i_dummy_dmemory.cnt_rd[4] +
             redmule_tb.i_dummy_dmemory.cnt_rd[5] +
             redmule_tb.i_dummy_dmemory.cnt_rd[6] +
             redmule_tb.i_dummy_dmemory.cnt_rd[7] +
             redmule_tb.i_dummy_dmemory.cnt_rd[8];

    cnt_wr = redmule_tb.i_dummy_dmemory.cnt_wr[0] +
             redmule_tb.i_dummy_dmemory.cnt_wr[1] +
             redmule_tb.i_dummy_dmemory.cnt_wr[2] +
             redmule_tb.i_dummy_dmemory.cnt_wr[3] +
             redmule_tb.i_dummy_dmemory.cnt_wr[4] +
             redmule_tb.i_dummy_dmemory.cnt_wr[5] +
             redmule_tb.i_dummy_dmemory.cnt_wr[6] +
             redmule_tb.i_dummy_dmemory.cnt_wr[7] +
             redmule_tb.i_dummy_dmemory.cnt_wr[8];

    $display("[TB] - cnt_rd=%-8d", cnt_rd);
    $display("[TB] - cnt_wr=%-8d", cnt_wr);
    if (perf_enable) begin
      real busy_ratio;
      busy_ratio = (perf_total_cycles != 0) ?
                   (100.0 * real'(perf_busy_cycles) / real'(perf_total_cycles)) : 0.0;
      $display("[PERF] total cycles    : %0d", perf_total_cycles);
      $display("[PERF] busy cycles     : %0d", perf_busy_cycles);
      $display("[PERF] busy ratio      : %0.2f %%", busy_ratio);
      $display("[PERF] MX blocks enc   : %0d", perf_encoder_blocks);
      $display("[PERF] MX blocks dec   : %0d", perf_decoder_blocks);
    end
    if(errors != 0) begin
      $display("[TB] - Fail!");
      $error("[TB] - errors=%08x", errors);
    end else begin
      $display("[TB] - Success!");
      $display("[TB] - errors=%08x", errors);
    end
    $finish;
  end

  // MX Encoder Output Capture for Verification
  integer mx_fp16_file, mx_fp8_file, mx_exp_file;
  initial begin
    mx_fp16_file = $fopen("mx_encoder_fp16_inputs.txt", "w");
    mx_fp8_file  = $fopen("mx_encoder_fp8_outputs.txt", "w");
    mx_exp_file  = $fopen("mx_encoder_exponents.txt", "w");
  end

  // Capture FP16 inputs when FIFO reads
  always @(posedge clk_i) begin
    if (i_dut.i_redmule_top.fifo_valid && i_dut.i_redmule_top.fifo_pop) begin
      $fwrite(mx_fp16_file, "%h\n", i_dut.i_redmule_top.fifo_data_out);
    end
  end

  // Capture FP8 outputs when encoder produces valid data
  always @(posedge clk_i) begin
    if (i_dut.i_redmule_top.mx_val_valid && i_dut.i_redmule_top.mx_val_ready) begin
      $fwrite(mx_fp8_file, "%h\n", i_dut.i_redmule_top.mx_val_data);
    end
  end

  // Capture shared exponents
  always @(posedge clk_i) begin
    if (i_dut.i_redmule_top.mx_exp_valid && i_dut.i_redmule_top.mx_exp_ready) begin
      $fwrite(mx_exp_file, "%h\n", i_dut.i_redmule_top.mx_exp_data);
    end
  end

  final begin
    $fclose(mx_fp16_file);
    $fclose(mx_fp8_file);
    $fclose(mx_exp_file);
    $display("[TB] - MX encoder outputs written to mx_encoder_*.txt");
  end

  // always_ff @(posedge clk_i or negedge rst_ni) begin
  //   if (!rst_ni) begin
  //     mx_x_exp_idx <= 0;
  //     mx_w_exp_idx <= 0;
  //   end else begin
  //     // Increment X index only on successful handshake
  //     if (mx_enable && x_mx_exp_stream.valid && x_mx_exp_stream.ready) begin
  //       mx_x_exp_idx <= mx_x_exp_idx + 1;
  //       //$display("[TB][X_EXP] Handshake: idx=%0d data=0x%08x", mx_x_exp_idx, mx_x_exp_mem[mx_x_exp_idx]);
  //     end

  //     // Increment W index only on successful handshake
  //     if (mx_enable && w_mx_exp_stream.valid && w_mx_exp_stream.ready) begin
  //       mx_w_exp_idx <= mx_w_exp_idx + 1;
  //       //$display("[TB][W_EXP] Handshake: idx=%0d data=0x%08x", mx_w_exp_idx, mx_w_exp_mem[mx_w_exp_idx]);
  //     end
  //   end
  // end

endmodule // redmule_tb
