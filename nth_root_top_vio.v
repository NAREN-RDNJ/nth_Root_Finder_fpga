//=============================================================================
// nth_root_top_vio.v
//
// Top level: Xilinx VIO IP <-> nth_root_fsm core.
//
// The VIO IP itself must be generated separately in the Vivado IP Catalog
// (IP Catalog -> Debug & Verification -> VIO (Virtual Input/Output)),
// with an instance/component name of "vio_0" and the following probes:
//
//   PROBE_OUT0  width 64   -> operand A        (32.32 unsigned fixed point)
//   PROBE_OUT1  width 4    -> root degree N    (1-15)
//   PROBE_OUT2  width 1    -> start (pulse)
//   PROBE_IN0   width 64   <- result           (32.32 unsigned fixed point)
//   PROBE_IN1   width 1    <- done
//   PROBE_IN2   width 1    <- busy
//
// Only VIO (a debug/IO utility, not a math/root/divider core) is used as
// an IP; the actual Nth-root computation is pure HDL (see nth_root.v).
//=============================================================================

module nth_root_top_vio (
    input wire clk
);

    wire [63:0] probe_A;
    wire [3:0]  probe_N;
    wire        probe_start;

    wire [63:0] probe_result;
    wire        probe_done;
    wire        probe_busy;
    wire undefined;

    // ---------------------------------------------------------------
    // VIO instance - generated via Vivado IP Catalog, instance "vio_0"
    // ---------------------------------------------------------------
    vio_0 u_vio (
        .clk        (clk),
        .probe_out0 (probe_A),
        .probe_out1 (probe_N),
        .probe_out2 (probe_start),
        .probe_in0  (probe_result),
        .probe_in1  (probe_done),
        .probe_in2  (probe_busy),
        .probe_in3 (undefined)
    );

    // ---------------------------------------------------------------
    // Nth-root core (pure HDL, no IP cores)
    // ---------------------------------------------------------------
    nth_root_fsm u_root (
        .clk    (clk),
        .rst_n  (1'b1),        // tie off, or connect to another VIO probe
        .start  (probe_start),
        .A      (probe_A),
        .N      (probe_N),
        .result (probe_result),
        .done   (probe_done),
        .busy   (probe_busy),
        .undefined(undefined)
    );

endmodule