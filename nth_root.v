//=============================================================================
// nth_root.v
//
// Fixed-point Nth root using bit-by-bit binary search (successive
// approximation), generalized from the classic non-restoring fixed-point
// square-root algorithm.
//
// Formats:
//   A      : 64-bit unsigned fixed point, 32.32 (32 integer, 32 fractional)
//   N      : 4-bit unsigned root degree, valid range 1..15 (0 folds to 1)
//   result : 64-bit unsigned fixed point, 32.32  ( = A ^ (1/N) )
//
// No multiplier/divider/root IP cores are used anywhere in this file -
// only the plain Verilog '*' operator (inferred LUT/DSP fabric logic),
// reused sequentially by a small FSM.
//=============================================================================

//-----------------------------------------------------------------------
// fixed_mul64: combinational 32.32 x 32.32 -> 32.32 unsigned multiplier
//-----------------------------------------------------------------------
module fixed_mul64 (
    input  wire [63:0] a,       // 32.32 unsigned fixed point
    input  wire [63:0] b,       // 32.32 unsigned fixed point
    output wire [63:0] result,  // 32.32 unsigned fixed point (truncated)
    output wire        overflow // 1 if true product needs >32 integer bits
);
    wire [127:0] prod;

    assign prod     = a * b;          // exact 64x64 -> 128-bit product (64.64)
    assign overflow = |prod[127:96];  // nonzero upper 32 bits => doesn't fit 32.32
    assign result   = prod[95:32];    // re-normalize 64.64 -> 32.32

endmodule


//-----------------------------------------------------------------------
// nth_root_fsm: R = A^(1/N) via bit-by-bit binary search
//-----------------------------------------------------------------------
module nth_root_fsm (
    input  wire        clk,
    input  wire        rst_n,     // active-low synchronous reset
    input  wire        start,     // 1-cycle pulse to begin a computation
    input  wire [63:0] A,         // operand, 32.32 unsigned fixed point
    input  wire [3:0]  N,         // root degree, 1-15 (0 is folded to 1)
    output reg  [63:0] result,    // 32.32 unsigned fixed point result
    output reg         done,      // 1-cycle pulse when result is valid
    output reg         busy,
    output reg undefined
);

    localparam S_IDLE     = 4'd0,
               S_SET_BIT   = 4'd1,
               S_MUL_SETUP = 4'd2,
               S_MUL_LATCH = 4'd3,
               S_CHECK     = 4'd4,
               S_NEXT_BIT  = 4'd5,
               S_DONE      = 4'd6;

    reg [3:0]  state;

    reg [5:0]  bit_idx;     // 63 downto 0 : which bit of R is being trialed
    reg [63:0] R;           // accumulated (converged) result so far
    reg [63:0] R_test;                         // R with the current candidate bit set
    reg [63:0] P;           // running power accumulator: R_test^pow_cnt
    reg [3:0]  n_reg;       // latched, guarded root degree (>=1)
    reg [63:0] a_reg;       // latched operand
    reg [3:0]  pow_cnt;     // number of factors of R_test folded into P so far
    reg        ovf_sticky;  // sticky overflow flag for this bit's power chain
    reg zeroflag;
    reg prev;
    // Single shared combinational multiplier, driven sequentially.
    reg  [63:0] mul_a, mul_b;
    wire [63:0] mul_p;
    wire        mul_ovf;

    fixed_mul64 u_mul (
        .a        (mul_a),
        .b        (mul_b),
        .result   (mul_p),
        .overflow (mul_ovf)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            busy       <= 1'b0;
            result     <= 64'd0;
            bit_idx    <= 6'd0;
            R          <= 64'd0;
            R_test     <= 64'd0;
            P          <= 64'd0;
            n_reg      <= 4'd1;
            a_reg      <= 64'd0;
            pow_cnt    <= 4'd0;
            ovf_sticky <= 1'b0;
            mul_a      <= 64'd0;
            mul_b      <= 64'd0;
        end else begin
            done <= 1'b0; // default: single-cycle pulse
            
            case (state)
                //-------------------------------------------------------
                S_IDLE: begin
                    if (start && !prev) begin
                        a_reg   <= A;
                        // 0th root is mathematically undefined; fold to
                        // 1 (identity) instead of producing a bad result.
                        n_reg   <=  N;
                        R       <= 64'd0;
                        bit_idx <= 6'd63;
                        busy    <= 1'b1;
                        undefined <= 0;
                        // Special case: A == 0.
                        // Any nonzero candidate R_test has a true (exact)
                        // R_test^N > 0, but if R_test is small enough that
                        // R_test^N underflows below the 32.32 resolution
                        // (2^-32), fixed_mul64 truncates it to exactly 0.
                        // The comparison "0 <= 0" would then wrongly accept
                        // that bit, so the search would converge to a tiny
                        // nonzero garbage value instead of 0. Skip the
                        // search entirely in this one case, since 0 is the
                        // only root where every nonzero candidate must be
                        // rejected.
                        if (N == 0)begin
                            undefined <= 1;
                            state <= S_DONE;
                            
                        end    
                        else if (A == 64'd0)
                            state <= S_DONE;
                        else
                            state <= S_SET_BIT;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                //-------------------------------------------------------
                S_SET_BIT: begin
                    R_test     <= R | (64'd1 << bit_idx);
                    P          <= R | (64'd1 << bit_idx); // = R_test^1
                    pow_cnt    <= 4'd1;
                    ovf_sticky <= 1'b0;
                    // n_reg==1  => P already equals R_test^1, skip mult chain
                    state      <= (n_reg == 4'd1) ? S_CHECK : S_MUL_SETUP;
                end

                //-------------------------------------------------------
                S_MUL_SETUP: begin
                    // Load the shared multiplier: P <- P * R_test (next edge)
                    mul_a <= P;
                    mul_b <= R_test;
                    state <= S_MUL_LATCH;
                end

                //-------------------------------------------------------
                S_MUL_LATCH: begin
                    // mul_p/mul_ovf are now valid (combinational, settled
                    // since mul_a/mul_b were registered last cycle)
                    P          <= mul_p;
                    ovf_sticky <= ovf_sticky | mul_ovf;
                    pow_cnt    <= pow_cnt + 4'd1;
                    if (pow_cnt + 4'd1 == n_reg)
                        state <= S_CHECK;
                    else
                        state <= S_MUL_SETUP;
                end

                //-------------------------------------------------------
                S_CHECK: begin
                    if (!ovf_sticky && (P <= a_reg))
                        R <= R_test;
                    state <= S_NEXT_BIT;
                end

                //-------------------------------------------------------
                S_NEXT_BIT: begin
                    if (bit_idx == 6'd0) begin
                        state <= S_DONE;
                    end else begin
                        bit_idx <= bit_idx - 6'd1;
                        state   <= S_SET_BIT;
                    end
                end

                //-------------------------------------------------------
                S_DONE: begin
                    result <= R;
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
            prev <= start;
        end
    end

endmodule