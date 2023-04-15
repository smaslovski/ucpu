///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Minimalistic Harvard architecture uCPU with reduced instruction set
// (C) 2022-2023, Stanislav Maslovski <stanislav.maslovski@gmail.com>
//
// Features:
//
//      - 12-bit instructions (4 bit opcode / 8 bit imm data or addr)
//      - 8-bit program counter (programs up to 256 instructions long)
//      - 8-bit accumulator with carry and zero flags
//      - up to 250 8-bit externally addressed data registers (RAM)
//      - two index registers with autoincrement / decrement
//      - 3-stage instruction execution pipeline 
//      - executes 1 instruction per cycle (when pipeline is not stalled)
//
// Instruction word format:
//
//        ,--------------.
//        |  1         0 |
//        | 109876543210 |
//        +--------------+
//        | cccixxxxxxxx |
//        '--------------´
//
// where c - opcode bits, i - reg/imm bit, x - data or reg/addr bits.
//
// Instruction set mnemonics / encoding table:
//
//    ,-----+---------+---------+------------------------------+-----+-------.
//    | ccc |  i = 0  |  i = 1  |          Description         | Flg |  hex  |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 000 | ANA reg | ANI imm | Acc & reg/imm to Acc         |  Z  | 0 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 001 | XRA reg | XRI imm | Acc ^ reg/imm to Acc         |  Z  | 2 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 010 | ADA reg | ADI imm | Acc + reg/imm to Acc         | C,Z | 4 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 011 | SBA reg | CPI imm | Acc - reg/imm to Acc or none | C,Z | 6 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 100 | BNC adr | BNZ adr | Branch to address if C/Z = 0 |     | 8 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 101 | JPR reg | JMP adr | Jump to address in reg / adr |     | A + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 110 | LDA reg | LDI imm | Load accum from reg / imm    |     | C + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 111 | STA reg | ******* | Store accum to reg           |     | E + i |
//    `-----+---------+---------+------------------------------+-----+-------´
//
// Combination ccci = 1111 is reserved for extensions.
//
// Accessing registers F8 - FF invokes special addressing modes.
//
// Regs F8 / F9 are shadow index registers aliased IX / IY with support
// for autoincrement and decrement operation.
//
// Actual addressing modes when the reg field is in the range F8 - FF:
//
//    ,------+----+----+------+------+-------+-------+-------+-------.
//    |  reg | F8 | F9 |  FA  |  FB  |  FC   |  FD   |   FE  |   FF  |
//    +------+----+----+------+------+-------+-------+-------+-------+
//    | mode | IX | IY | (IX) | (IY) | (IX)+ | (IY)+ | -(IX) | -(IY) |
//    '------+----+----+------+------+-------+-------+-------+-------'
//
// Command execution in this version of uCPU is pipelined as is shown in the following diagram:
//
//  ----->|<----- Stage 1 ----->|<-------------- Stage 2 ---------------->|<--------------- Stage 3 -------------------
//
//
//                                            ,------------[bypass idx]------<<-----{Acc}-------<<-------.
//                                           |                  ^                                        |
//                                           v                  |                                        |
//  (PC) -> ROM access -> (IR) -> Decode & idx logic -> (CW,ID,IX,IY,EA) -> RAM access & ALU op -> (Acc/M, ZF, CF) --,
//    ^                                      v                                        v                  v           v
//    |                                      |                                        |                  |           |
//    |                                {JMP, BNC, BNZ}                       {JPR, alu_z, alu_c}      {CF, ZF}    {++PC}
//    |                                      |                                        |                  |           |
//    o---------------<<--------------[Branch logic]---------------<<-----------[bypass flags]-----------´           |
//    |                                                                                                              |
//    |                                                                                                              |
//    `------------------------------------------------<<------------------------------------------------------------'
//
// where the parenthesised elements correspond to registers used or updated in each stage:
//
//   PC     - program counter
//   IR     - instruction register
//   CW     - control word register
//   ID     - immediate data register
//   IX, IY - shadow index registers
//   EA     - executive address register
//   Acc/M  - accumulator or memory
//   ZF, CF - flag registers
//
// Bypass logic resolves pipeline hazards associated with
//   a) conditional jumps and instructions that change flags; b) index registers and STA IX/IY instructions.
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module uCPU (clk, rom_addr, rom_data, ram_addr, ram_data_i, ram_data_o, wr_en, rst);

input  wire        clk, rst;
input  wire [11:0] rom_data;
input  wire  [7:0] ram_data_i;
output wire  [7:0] ram_data_o;
output wire        wr_en;
output wire  [7:0] rom_addr, ram_addr;

reg  [7:0] PC;      // program counter
reg [11:0] IR;      // instruction register
reg  [7:0] ID;      // immediate data / address
reg  [7:0] IX, IY;  // index registers
reg  [7:0] EA;      // executive address register
reg  [7:0] Acc;     // accumulator
reg        CF, ZF;  // flags

// uCPU bus

assign rom_addr = PC;
assign ram_addr = EA;
assign wr_en    = cw_sta & !skip_stage[3];
assign ram_data_o = Acc;

// Stage 1: instruction fetch -----------------------------------------------------------------------------------------

always @(posedge clk)
  if (rst)
    IR <= 12'hB00; // JMP 0
  else
    IR <= rom_data;

// Stage 2: instruction code fields

wire [2:0]      op = IR[11:9];
wire       imm_bit = IR[8];
wire [7:0] imm_dat = IR[7:0];

// Stage 2: instruction decoder logic and control signals -------------------------------------------------------------

wire alu_op =    ~op[2];
wire cpa_op =    alu_op &  &op[1:0] &  imm_bit;
wire bnc_op =     op[2] & ~|op[1:0] & ~imm_bit;
wire bnz_op =     op[2] & ~|op[1:0] &  imm_bit;
wire jpr_op =     op[2] &    ~op[1] &    op[0] & ~imm_bit;
wire jmp_op =     op[2] &    ~op[1] &    op[0] &  imm_bit;
wire lda_op =  &op[2:1] &    ~op[0];
wire sta_op =  &op[2:0] &  ~imm_bit;
wire ext_op =  &op[2:0] &   imm_bit;

wire ind_mod = ~imm_bit & ~bnc_op & &imm_dat[7:3] & |imm_dat[2:1];
wire inc_dec =  ind_mod &  imm_dat[2];
wire dec_mod =  inc_dec &  imm_dat[1];
wire inc_mod =  inc_dec & ~imm_dat[1];

// Stage 2: accumulator and flags write control signals ---------------------------------------------------------------

wire acc_wr = lda_op | (alu_op & ~cpa_op);
wire zf_wr =  alu_op;
wire cf_wr =  alu_op & op[1];

// Stage 2: control word signals passed to the next pipeline stage ----------------------------------------------------

`define CW     \
    cw_op0,    \
    cw_op1,    \
    cw_imm,    \
    cw_jpr,    \
    cw_lda,    \
    cw_sta,    \
    cw_acc_wr, \
    cw_zf_wr,  \
    cw_cf_wr

reg `CW ;

// Stage 2: instruction decoder sequential logic ----------------------------------------------------------------------

always @(posedge clk)
  if (rst)
    begin
      ID <= 8'b0;
      { `CW } <= 9'b0;
    end
  else if (!skip_stage[2])
    begin
      ID <= imm_dat;
      { `CW } <= {
        op[0],
        op[1],
        imm_bit,
        jpr_op,
        lda_op,
        sta_op,
        acc_wr,
        zf_wr,
        cf_wr
      };
    end

// Stage 2: IX and IY shadow registers logic --------------------------------------------------------------------------

wire sta_ix = wr_en & (EA == 8'hF8);
wire sta_iy = wr_en & (EA == 8'hF9);

wire ix_wr = sta_ix | (inc_dec & ~imm_dat[0]);
wire iy_wr = sta_iy | (inc_dec &  imm_dat[0]);

// note bypassing Acc value to stage 2 if stage 3 has STA IX/IY
wire [7:0] idx = imm_dat[0] ? (sta_iy ? Acc : IY) : (sta_ix ? Acc : IX);
reg  [7:0] idx_new;

always @*
  begin
    case (1'b1)
      inc_mod: idx_new = idx + 1'b1;
      dec_mod: idx_new = idx - 1'b1;
      default: idx_new = idx;
    endcase
  end

// Stage 2: new executive address logic -------------------------------------------------------------------------------

wire [7:0] ea_new = ind_mod ? ( dec_mod ? idx_new : idx ) : imm_dat;

// Stage 2: address registers sequential logic

always @(posedge clk)
  begin
    if (rst)
      begin
        EA <= 8'b0;
        IX <= 8'b0;
        IY <= 8'b0;
      end
    else if (!skip_stage[2])
      begin
        EA <= ea_new;
        if (ix_wr)
          IX <= idx_new;
        if (iy_wr)
          IY <= idx_new;
      end
  end

// Stage 2: immediate jump logic --------------------------------------------------------------------------------------

// note bypassing new flag values to stage 2 when they are going to be written in stage 3
wire imm_jmp = jmp_op | (bnc_op & ~(cw_cf_wr ? alu_c : CF)) | (bnz_op & ~(cw_zf_wr ? alu_z : ZF));

// Stages 2 and 3: pipe control FSM sequential logic ------------------------------------------------------------------

reg [2:3] skip_stage;

always @(posedge clk)
  if (rst)
    skip_stage <= 2'b00;
  else
    case (skip_stage)
      2'b00:
        if (cw_jpr)  // cw_jpr has priority over imm_jmp!
          skip_stage <= 2'b11; // will skip stage 2 and stage 3
        else if (imm_jmp)
          skip_stage <= 2'b10; // will skip stage 2
      2'b11:
        skip_stage <= 2'b01;   // will skip stage 3
      default:
        skip_stage <= 2'b00;   // no skip
    endcase

// Stages 2 and 3: next PC value logic --------------------------------------------------------------------------------

reg [7:0] next_pc;

always @*
  begin
    next_pc = PC + 1'b1;
    if (!skip_stage)
      if (cw_jpr)  // cw_jpr has priority over imm_jmp!
        next_pc = ram_data_i;
      else if (imm_jmp)
        next_pc = imm_dat;
  end

// Stage 3: ALU logic -------------------------------------------------------------------------------------------------

wire [7:0] alu_arg = cw_imm ? ID : ram_data_i;
reg  [7:0] alu_res;
reg        alu_c;

always @*
  begin
    alu_c = 1'b0;
    case ({cw_op1, cw_op0})
      2'b00: alu_res = Acc & alu_arg;
      2'b01: alu_res = Acc ^ alu_arg;
      2'b10: {alu_c, alu_res} = Acc + alu_arg;
      2'b11: {alu_c, alu_res} = Acc - alu_arg;
    endcase
  end

wire alu_z = ~|alu_res;

// Stage 3: acumulator input multiplexer ------------------------------------------------------------------------------

wire [7:0] acc_mux = cw_lda ? ( cw_imm ? ID : ram_data_i ) : alu_res;

// Stage 3: update uCPU state -----------------------------------------------------------------------------------------

always @(posedge clk)
  if (rst)
    begin
      PC <= 8'b0;
      Acc <= 8'b0;
      {CF, ZF} <= 2'b0;
    end
  else
    begin
      PC <= next_pc;
      if (!skip_stage[3])
        begin
          if (cw_acc_wr)
            Acc <= acc_mux;
          if (cw_zf_wr)
            ZF <= alu_z;
          if (cw_cf_wr)
            CF <= alu_c;
        end
    end

endmodule
