// asynchronous ROM

module rom (abus, dbus, en);

input  wire en;
input  wire  [7:0] abus;
output wire [11:0] dbus;

reg [11:0] mem[0:255];

assign dbus = en ? mem[abus] : 12'bz;

initial
  $readmemh("fib.hex", mem, 0, 255);

endmodule


// asynchronous read, synchronous write RAM

module ram (clk, abus, dbus, wr_en);

input wire clk, wr_en;
input wire [7:0] abus;
inout wire [7:0] dbus;

reg [7:0] mem[0:255];

always @(posedge clk)
  if (wr_en)
    mem[abus] <= dbus;

assign dbus = wr_en ? 8'bz : mem[abus];

initial
  $readmemh("null.hex", mem, 0, 255);

endmodule
