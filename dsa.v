`timescale 1ns / 1ps

// ASSUMPTION: latency of fp32_muladd <= 16
//             latency of fp32_less   <= 2 

module dsa(
    input             clk,
    input             rst,
    
    input             en,
    input             we,
    input      [31:0] datai,
    output     [31:0] datao,
    output reg        ready
);

localparam NUM_FIRST_NEURONS = 784;
localparam NUM_MID_NEURONS = 48;  // must be >= 17
localparam NUM_LAST_NEURONS = 10;  // must be >= 9

/*
localparam NUM_FIRST_NEURONS = 3;
localparam NUM_MID_NEURONS = 20;  // must be >= 17
localparam NUM_LAST_NEURONS = 10;  // must be >= 9
*/

// ========== io ==========
reg io_waiting_result;
(* mark_debug = "true" *) wire io_ready_to_read;
// ---------- io ----------

// ========== fifo ==========
wire [31:0] fifo_din;
wire fifo_wr_en;
wire fifo_rd_en;
wire [31:0] fifo_dout;
wire fifo_full;
wire fifo_empty;

reg fifo_wr_pending;
reg [31:0] fifo_din_pending;
// ---------- fifo ----------

// ========== feeder ==========
localparam FEED_INIT           = 0,
           FEED_MID_BIA        = 1,
           FEED_LAST_BIA       = 2,
           FEED_MID_NEU        = 3,
           FEED_MID_WEI        = 4,
           FEED_MID_WEI_SYNC   = 5,
           FEED_MID_RELU       = 6,
           FEED_MID_RELU_SYNC  = 7,
           FEED_LAST_WEI       = 8,
           FEED_LAST_WEI_WAIT  = 9,
           FEED_LAST_WEI_SYNC  = 10,
           FEED_LAST_RELU      = 11,
           FEED_LAST_RELU_SYNC = 12,
           FEED_LAST_CMP       = 13,
           FEED_LAST_CMP_WAIT  = 14,
           FEED_DONE           = 15;

reg [3:0] feed_state;
reg [31:0] feed_first_neuron;

reg [$clog2(NUM_FIRST_NEURONS)-1:0] feed_first_counter;
reg [$clog2(NUM_MID_NEURONS)-1:0] feed_mid_counter;
reg [$clog2(NUM_LAST_NEURONS)-1:0] feed_last_counter;

// ========== muladd ==========
wire muladd_valid;
wire [31:0] muladd_a;
wire [31:0] muladd_b;
wire [31:0] muladd_c;
wire muladd_done;
wire [31:0] muladd_result;
// ---------- muladd ----------

// ========== less ==========
wire less_valid;
wire [31:0] less_a;
wire [31:0] less_b;
wire less_done;
wire [7:0] less_result;
// ---------- less ----------

// ========== receiver ==========
localparam RECV_INIT      = 0,
           RECV_MID_BIA   = 1,
           RECV_LAST_BIA  = 2,
           RECV_MID_MAC   = 3,
           RECV_MID_RELU  = 4,
           RECV_LAST_MAC  = 5,
           RECV_LAST_RELU = 6,
           RECV_LAST_CMP  = 7,
           RECV_DONE      = 8;

reg [3:0] recv_state;
reg [31:0] recv_mid_neurons [0:NUM_MID_NEURONS-1];
(* mark_debug = "true" *) reg [31:0] recv_last_neurons [0:NUM_LAST_NEURONS-1];

reg [$clog2(NUM_LAST_NEURONS)-1:0] recv_pred_result;
reg [31:0] recv_max;

reg [$clog2(NUM_FIRST_NEURONS)-1:0] recv_first_counter;
reg [$clog2(NUM_MID_NEURONS)-1:0] recv_mid_counter;
reg [$clog2(NUM_LAST_NEURONS)-1:0] recv_last_counter;
// ---------- receiver ----------

// <----- END OF DECLARATION ----->

// ========== io ==========
assign datao = recv_pred_result;

always @(posedge clk)
    ready <= (fifo_wr_en || io_ready_to_read);

always @(posedge clk) begin
    if (rst)
        io_waiting_result <= 0;
    else if (en && !we)
        io_waiting_result <= 1;
    else if (io_ready_to_read)
        io_waiting_result <= 0;
end

assign io_ready_to_read = (io_waiting_result && recv_state == RECV_DONE);
// ---------- io ----------

// ========== fifo ==========
assign fifo_din = (en && we) ? datai : fifo_din_pending;
assign fifo_wr_en = ((en && we) || fifo_wr_pending) && !fifo_full;
assign fifo_rd_en = (feed_state == FEED_MID_BIA || feed_state == FEED_LAST_BIA ||
                     feed_state == FEED_MID_NEU || feed_state == FEED_MID_WEI ||
                     feed_state == FEED_LAST_WEI) && !fifo_empty;

fifo_generator_0 fifo_generator_0_0 (
    .clk(clk),
    .srst(rst),
    .din(fifo_din),
    .wr_en(fifo_wr_en),
    .rd_en(fifo_rd_en),
    .dout(fifo_dout),
    .full(fifo_full),
    .empty(fifo_empty)
);

always @(posedge clk) begin
    if (rst) begin
        fifo_wr_pending <= 0;
    end else if (en && we && fifo_full) begin
        fifo_wr_pending <= 1;
        fifo_din_pending <= datai;
    end else if (fifo_wr_en) begin
        fifo_wr_pending <= 0;
    end
end
// ---------- fifo ----------

// ========== feeder ==========
always @(posedge clk) begin
    if (rst) begin
        feed_state <= FEED_INIT;
    end else case (feed_state)
        FEED_INIT: begin
            feed_state <= FEED_MID_BIA;
            feed_first_counter <= 0;
            feed_mid_counter <= 0;
            feed_last_counter <= 0;
        end
        FEED_MID_BIA: begin
            if (!fifo_empty) begin
                if (feed_mid_counter == NUM_MID_NEURONS - 1) begin
                    feed_state <= FEED_LAST_BIA;
                    feed_mid_counter <= 0;
                end else begin
                    feed_mid_counter <= feed_mid_counter + 1;
                end
            end
        end
        FEED_LAST_BIA: begin
            if (!fifo_empty) begin
                if (feed_last_counter == NUM_LAST_NEURONS - 1) begin
                    feed_state <= FEED_MID_NEU;
                    feed_last_counter <= 0;
                end else begin
                    feed_last_counter <= feed_last_counter + 1;
                end
            end
        end
        FEED_MID_NEU: begin
            if (!fifo_empty) begin
                feed_state <= FEED_MID_WEI;
                feed_first_neuron <= fifo_dout;
            end
        end
        FEED_MID_WEI: begin
            if (!fifo_empty) begin
                if (feed_mid_counter == NUM_MID_NEURONS - 1) begin
                    if (feed_first_counter == NUM_FIRST_NEURONS - 1) begin
                        feed_state <= FEED_MID_WEI_SYNC;
                        feed_mid_counter <= 0;
                    end else begin
                        feed_state <= FEED_MID_NEU;
                        feed_first_counter <= feed_first_counter + 1;
                        feed_mid_counter <= 0;
                    end
                end else begin
                    feed_mid_counter <= feed_mid_counter + 1;
                end
            end
        end
        FEED_MID_WEI_SYNC: begin
            if (recv_state == RECV_MID_RELU)
                feed_state <= FEED_MID_RELU;
        end
        FEED_MID_RELU: begin
            if (feed_mid_counter == NUM_MID_NEURONS - 1) begin
                feed_state <= FEED_MID_RELU_SYNC;
                feed_mid_counter <= 0;
            end else begin
                feed_mid_counter <= feed_mid_counter + 1;
            end
        end
        FEED_MID_RELU_SYNC: begin
            if (recv_state == RECV_LAST_MAC)
                feed_state <= FEED_LAST_WEI;
        end
        FEED_LAST_WEI: begin
            if (!fifo_empty)
                feed_state <= FEED_LAST_WEI_WAIT;
        end
        FEED_LAST_WEI_WAIT: begin
            if (feed_last_counter == NUM_LAST_NEURONS - 1) begin
                if (feed_mid_counter == NUM_MID_NEURONS - 1)
                    feed_state <= FEED_LAST_WEI_SYNC;
                else
                    feed_state <= FEED_LAST_WEI;
                feed_mid_counter <= feed_mid_counter + 1;
                feed_last_counter <= 0;
            end else begin
                feed_state <= FEED_LAST_WEI;
                feed_last_counter <= feed_last_counter + 1;
            end
        end
        FEED_LAST_WEI_SYNC: begin
            if (recv_state == RECV_LAST_RELU)
                feed_state <= FEED_LAST_RELU;
        end
        FEED_LAST_RELU: begin
            if (feed_last_counter == NUM_LAST_NEURONS - 1) begin
                feed_state <= FEED_LAST_RELU_SYNC;
                feed_last_counter <= 1;
            end else begin
                feed_last_counter <= feed_last_counter + 1;
            end
        end
        FEED_LAST_RELU_SYNC: begin
            if (recv_state == RECV_LAST_CMP)
                feed_state <= FEED_LAST_CMP;
        end
        FEED_LAST_CMP: begin
            if (feed_last_counter == NUM_LAST_NEURONS - 1)
                feed_state <= FEED_DONE;
            else
                feed_state <= FEED_LAST_CMP_WAIT;
            feed_last_counter <= feed_last_counter + 1;
        end
        FEED_LAST_CMP_WAIT: begin
            if (less_done)
                feed_state <= FEED_LAST_CMP;
        end
        FEED_DONE: begin
            if (ready)
                feed_state <= FEED_INIT;
        end
    endcase
end
// ---------- feeder ----------

// ========== muladd ==========
assign muladd_valid = ((feed_state == FEED_MID_WEI || feed_state == FEED_LAST_WEI) && !fifo_empty);
assign muladd_a = (feed_state == FEED_LAST_WEI ? recv_mid_neurons[feed_mid_counter] : feed_first_neuron);
assign muladd_b = fifo_dout;
assign muladd_c = (feed_state == FEED_LAST_WEI ? recv_last_neurons[feed_last_counter] : recv_mid_neurons[feed_mid_counter]);

fp32_muladd fp32_muladd_0 (
    .aclk(clk),
    .s_axis_a_tvalid(muladd_valid),
    .s_axis_a_tdata(muladd_a),
    .s_axis_b_tvalid(muladd_valid),
    .s_axis_b_tdata(muladd_b),
    .s_axis_c_tvalid(muladd_valid),
    .s_axis_c_tdata(muladd_c),
    .m_axis_result_tvalid(muladd_done),
    .m_axis_result_tdata(muladd_result)
);
// ---------- muladd ----------

// ========== less ==========
assign less_valid = (feed_state == FEED_MID_RELU || feed_state == FEED_LAST_RELU ||
                     feed_state == FEED_LAST_CMP);
assign less_a = (feed_state == FEED_MID_RELU ? recv_mid_neurons[feed_mid_counter] : recv_last_neurons[feed_last_counter]);
assign less_b = (feed_state == FEED_LAST_CMP ? recv_max : 32'h00000000 /* 0.0f */);

fp32_less fp32_less_0 (
  .aclk(clk),
  .s_axis_a_tvalid(less_valid),
  .s_axis_a_tdata(less_a),
  .s_axis_b_tvalid(less_valid),
  .s_axis_b_tdata(less_b),
  .m_axis_result_tvalid(less_done),
  .m_axis_result_tdata(less_result)
);
// ---------- less ----------

// ========== receiver ==========
integer i;
always @(posedge clk) begin
    if (rst) begin
        recv_state <= RECV_INIT;
    end else case (recv_state)
        RECV_INIT: begin
            recv_state <= RECV_MID_BIA;
            recv_pred_result <= 0;
            recv_first_counter <= 0;
            recv_mid_counter <= 0;
            recv_last_counter <= 0;
        end
        RECV_MID_BIA: begin
            if (!fifo_empty) begin
                if (recv_mid_counter == NUM_MID_NEURONS - 1) begin
                    recv_state <= RECV_LAST_BIA;
                    recv_mid_counter <= 0;
                end else begin
                    recv_mid_counter <= recv_mid_counter + 1;
                end
                recv_mid_neurons[recv_mid_counter] <= fifo_dout;
            end
        end
        RECV_LAST_BIA: begin
            if (!fifo_empty) begin
                if (recv_last_counter == NUM_LAST_NEURONS - 1) begin
                    recv_state <= RECV_MID_MAC;
                    recv_last_counter <= 0;
                end else begin
                    recv_last_counter <= recv_last_counter + 1;
                end
                recv_last_neurons[recv_last_counter] <= fifo_dout;
            end
        end
        RECV_MID_MAC: begin
            if (muladd_done) begin
                if (recv_mid_counter == NUM_MID_NEURONS - 1) begin
                    if (recv_first_counter == NUM_FIRST_NEURONS - 1) 
                        recv_state <= RECV_MID_RELU;
                    recv_first_counter <= recv_first_counter + 1;
                    recv_mid_counter <= 0;
                end else begin
                    recv_mid_counter <= recv_mid_counter + 1;
                end
                recv_mid_neurons[recv_mid_counter] <= muladd_result;
            end
        end
        RECV_MID_RELU: begin
            if (less_done) begin
                if (recv_mid_counter == NUM_MID_NEURONS - 1) begin
                    recv_state <= RECV_LAST_MAC;
                    recv_mid_counter <= 0;
                end else begin
                    recv_mid_counter <= recv_mid_counter + 1;
                end
                if (less_result[0])
                    recv_mid_neurons[recv_mid_counter] <= 32'h00000000;  // 0.0f
            end
        end
        RECV_LAST_MAC: begin
            if (muladd_done) begin
                if (recv_last_counter == NUM_LAST_NEURONS - 1) begin
                    if (recv_mid_counter == NUM_MID_NEURONS - 1) 
                        recv_state <= RECV_LAST_RELU;
                    recv_mid_counter <= recv_mid_counter + 1;
                    recv_last_counter <= 0;
                end else begin
                    recv_last_counter <= recv_last_counter + 1;
                end
                recv_last_neurons[recv_last_counter] <= muladd_result;
            end
        end
        RECV_LAST_RELU: begin
            if (less_done) begin
                if (recv_last_counter == NUM_LAST_NEURONS - 1) begin
                    recv_state <= RECV_LAST_CMP;
                    recv_last_counter <= 1;
                end else begin
                    recv_last_counter <= recv_last_counter + 1;
                end
                if (less_result[0])
                    recv_last_neurons[recv_last_counter] <= 32'h00000000;  // 0.0f
                recv_max <= recv_last_neurons[0];
            end
        end
        RECV_LAST_CMP: begin
            if (less_done) begin
                if (recv_last_counter == NUM_LAST_NEURONS - 1)
                    recv_state <= RECV_DONE;
                if (!less_result[0]) begin
                    recv_pred_result <= recv_last_counter;
                    recv_max <= recv_last_neurons[recv_last_counter];
                end
                recv_last_counter <= recv_last_counter + 1;
            end
        end
        RECV_DONE: begin
            if (ready)
                recv_state <= RECV_INIT;
        end
    endcase
end
// ---------- receiver ----------

endmodule
