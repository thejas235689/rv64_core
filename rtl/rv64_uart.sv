`timescale 1ns/1ps
// =============================================================================
// rv64_uart.sv -- 8N1 serial port, transmit and receive.
//
// One start bit, eight data bits (LSB first), one stop bit, at DIVISOR clocks
// per bit. Receive samples the line mid-bit, which is what makes it survive a
// small baud mismatch between the two ends.
//
// Control port (CSR window):
//   0 TXDATA   write: start transmitting the byte in [7:0]
//   1 RXDATA   read:  the last received byte; a WRITE to this address clears
//              rx_valid (the control port has no read strobe, so read-clear is
//              not expressible -- stated rather than silently not happening)
//   2 STATUS   read:  [0] tx_busy, [1] rx_valid, [2] rx_overrun
//   3 DIVISOR  read/write: clocks per bit (0 is treated as 1)
//   4 CTRL     [0] enable
// =============================================================================
`default_nettype none

module rv64_uart (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        csr_we,
  input  logic [3:0]  csr_addr,
  input  logic [63:0] csr_wdata,
  output logic [63:0] csr_rdata,

  output logic        tx,
  input  logic        rx
);

  logic [15:0] divisor;
  logic        enable;
  logic        tx_busy;
  logic [9:0]  tx_shift;      // {stop, data[7:0], start}
  logic [3:0]  tx_bit;
  logic [15:0] tx_cnt;
  logic [7:0]  rx_data;
  logic        rx_valid, rx_overrun;
  logic [3:0]  rx_bit;
  logic [15:0] rx_cnt;
  logic        rx_busy;
  logic [1:0]  rx_sync;

  wire [15:0] div_eff = (divisor == 16'd0) ? 16'd1 : divisor;

  assign tx = tx_busy ? tx_shift[0] : 1'b1;   // idle high

  // ---- two-flop synchroniser on the async input ---------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_sync <= 2'b11;
    else        rx_sync <= {rx_sync[0], rx};
  end

  // ---- transmit -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift <= 10'h3FF;
      tx_bit   <= 4'd0;
      tx_cnt   <= 16'd0;
      tx_busy  <= 1'b0;
    end else if (csr_we && csr_addr == 4'd0 && enable) begin
      tx_shift <= {1'b1, csr_wdata[7:0], 1'b0};
      tx_bit   <= 4'd0;
      tx_cnt   <= 16'd0;
      tx_busy  <= 1'b1;
    end else if (tx_busy) begin
      if (tx_cnt + 16'd1 >= div_eff) begin
        tx_cnt <= 16'd0;
        if (tx_bit == 4'd9) begin
          tx_busy <= 1'b0;
        end else begin
          tx_bit   <= tx_bit + 4'd1;
          tx_shift <= {1'b1, tx_shift[9:1]};
        end
      end else begin
        tx_cnt <= tx_cnt + 16'd1;
      end
    end
  end

  // ---- receive ------------------------------------------------------------
  // Wait for a falling edge (start bit), then sample each bit at mid-bit.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_busy    <= 1'b0;
      rx_bit     <= 4'd0;
      rx_cnt     <= 16'd0;
      rx_data    <= 8'd0;
      rx_valid   <= 1'b0;
      rx_overrun <= 1'b0;
    end else begin
      if (csr_we && csr_addr == 4'd1) rx_valid <= 1'b0;

      if (!rx_busy) begin
        if (enable && !rx_sync[1]) begin          // start bit
          rx_busy <= 1'b1;
          rx_bit  <= 4'd0;
          rx_cnt  <= {1'b0, div_eff[15:1]};       // half a bit: mid-bit sampling
        end
      end else begin
        if (rx_cnt + 16'd1 >= div_eff) begin
          rx_cnt <= 16'd0;
          // The first sample lands in the middle of the START bit and is not
          // data; samples 1..8 are bits 0..7. Without this the received byte
          // comes out shifted right by one.
          if (rx_bit == 4'd0) begin
            if (rx_sync[1]) rx_busy <= 1'b0;   // false start, abandon
            else            rx_bit  <= 4'd1;
          end else if (rx_bit == 4'd9) begin
            rx_busy <= 1'b0;
            if (rx_valid) rx_overrun <= 1'b1;
            rx_valid <= 1'b1;
          end else begin
            // samples 1..8 carry data bits 0..7; sample 9 is the stop bit
            if (rx_bit != 4'd8) rx_data[rx_bit[3:0] - 4'd1] <= rx_sync[1];
            else                rx_data[7] <= rx_sync[1];
            rx_bit <= rx_bit + 4'd1;
          end
        end else begin
          rx_cnt <= rx_cnt + 16'd1;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      divisor <= 16'd8;
      enable  <= 1'b0;
    end else if (csr_we) begin
      case (csr_addr)
        4'd3: divisor <= csr_wdata[15:0];
        4'd4: enable  <= csr_wdata[0];
        default: ;
      endcase
    end
  end

  always_comb begin
    csr_rdata = 64'd0;
    case (csr_addr)
      4'd1: csr_rdata = {56'd0, rx_data};
      4'd2: csr_rdata = {61'd0, rx_overrun, rx_valid, tx_busy};
      4'd3: csr_rdata = {48'd0, divisor};
      4'd4: csr_rdata = {63'd0, enable};
      default: csr_rdata = 64'd0;
    endcase
  end

endmodule
`default_nettype wire
