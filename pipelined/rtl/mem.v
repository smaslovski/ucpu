// asynchronous ROM

module rom (abus, dbus);

input  wire  [7:0] abus;
output wire [11:0] dbus;

reg [11:0] mem[0:255];

assign dbus = mem[abus];

initial
  $readmemh("fib.hex", mem, 0, 255);

endmodule


// asynchronous read, synchronous write RAM

module ram (clk, abus, dbus_i, dbus_o, wr_en);

input  wire clk, wr_en;
input  wire [7:0] abus;
input  wire [7:0] dbus_i;
output wire [7:0] dbus_o;

reg [7:0] mem[0:255];

always @(posedge clk)
  if (wr_en)
    mem[abus] <= dbus_i;

assign dbus_o = mem[abus];

initial
  $readmemh("null.hex", mem, 0, 255);

endmodule
