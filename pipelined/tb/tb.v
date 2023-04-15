`timescale 1 ns / 10 ps

module test;

reg         clk, rst;
wire        wr_en;
wire  [7:0] rom_abus;
wire [11:0] rom_dbus;
wire  [7:0] ram_abus;
wire  [7:0] ram_dbus_i;
wire  [7:0] ram_dbus_o;

// uCPU instance

uCPU uCPU0 (
    .clk(clk),
    .rom_addr(rom_abus),
    .rom_data(rom_dbus),
    .ram_addr(ram_abus),
    .ram_data_i(ram_dbus_o),
    .ram_data_o(ram_dbus_i),
    .wr_en(wr_en),
    .rst(rst));

// ROM instance

rom rom0 (
    .abus(rom_abus),
    .dbus(rom_dbus));

// RAM instance

ram ram0 (
    .clk(clk),
    .abus(ram_abus),
    .dbus_i(ram_dbus_i),
    .dbus_o(ram_dbus_o),
    .wr_en(wr_en));

// Clocks

always
    #10 clk <= ~clk;

// simulation

initial
    begin
	$monitor("%4d ns: rom_abus = %h, rom_dbus = %h, ram_abus = %h, ram_dbus_i = %h, ram_dbus_o = %h, wr_en = %b\nIR = %h, PC = %h, Acc = %h, IX = %h, IY = %h, CF = %b, ZF = %b | %h %h %h %h %h %h %h %h\n",
		    $time, rom_abus, rom_dbus, ram_abus, ram_dbus_i, ram_dbus_o, wr_en,
		    uCPU0.IR, uCPU0.PC, uCPU0.Acc, uCPU0.IX, uCPU0.IY, uCPU0.CF, uCPU0.ZF,
		    ram0.mem[0], ram0.mem[1], ram0.mem[2], ram0.mem[3], ram0.mem[4], ram0.mem[5], ram0.mem[6], ram0.mem[7]);
	rst = 1'b1;
	clk = 1'b0;
	#20 rst = 1'b0;
	#50000 $finish;
    end

endmodule
