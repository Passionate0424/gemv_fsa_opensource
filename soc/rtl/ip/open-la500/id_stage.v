`include "mycpu.h"

module id_stage(
    input                               clk           ,
    input                               reset         ,
    //allowin
    input                               es_allowin    ,
    output                              ds_allowin    ,
    //from fs
    input                               fs_to_ds_valid,
    input  [`FS_TO_DS_BUS_WD -1:0]      fs_to_ds_bus  ,
    //from es forward path
    input  [`ES_TO_DS_FORWARD_BUS -1:0] es_to_ds_forward_bus,
    input  [`MS_TO_DS_FORWARD_BUS -1:0] ms_to_ds_forward_bus,
    //to es
    output                              ds_to_es_valid,
    output [`DS_TO_ES_BUS_WD -1:0]      ds_to_es_bus  ,
    //to fs
    output [`BR_BUS_WD       -1:0]      br_bus        ,
    //exception
    input                               excp_flush    ,
    input                               ertn_flush    ,
    input                               refetch_flush ,
    input                               icacop_flush  ,
    //idle
    input                               idle_flush    ,
    //tlb ins
    input                               es_tlb_inst_stall,
    input                               ms_tlb_inst_stall,
    input                               ws_tlb_inst_stall,
    //interrupt
    input                               has_int       ,
    //csr
    output [13:0]                       rd_csr_addr   ,
    input  [31:0]                       rd_csr_data   ,
    input  [ 1:0]                       csr_plv       ,
    //timer 64
    input  [63:0]                       timer_64      ,
    input  [31:0]                       csr_tid       ,
    //llbit
    input                               ds_llbit      ,
    //every stage valid sign
    input                               es_to_ds_valid,
    input                               ms_to_ds_valid,
    input                               ws_to_ds_valid,
    //from axi
    input                               write_buffer_empty,
    //from dcache 
	input 							    dcache_empty      ,
    //to btb
    output                              btb_operate_en    ,
    output                              btb_pop_ras       ,
    output                              btb_push_ras      ,
    output                              btb_add_entry     ,
    output                              btb_delete_entry  ,
    output                              btb_pre_error     ,
    output                              btb_pre_right     ,
    output                              btb_target_error  ,
    output                              btb_right_orien   ,
    output [31:0]                       btb_right_target  ,    
    output [31:0]                       btb_operate_pc    ,
    output [ 4:0]                       btb_operate_index ,
 
    //debug
    input                               infor_flag,
    input  [ 4:0]                       reg_num,
    output [31:0]                       debug_rf_rdata1,

    //to rf: for write back
    input  [`WS_TO_RF_BUS_WD -1:0]      ws_to_rf_bus,
    //to fpr: for FPU write back
    input  [`WS_TO_FPR_BUS_WD -1:0]     ws_to_fpr_bus,
    //from fpu_top: standalone FPU write back
    input                               fpu_rsp_valid,
    input                               fpu_rsp_tag, // [AI FPU Refactor] Epoch tag from FPU
    input  [ 4:0]                       fpu_rsp_dest ,
    input  [31:0]                       fpu_rsp_result,
    input  [ 4:0]                       fpu_rsp_flags,
    input                               fpu_rsp_is_fcmp,
    //from fpu_ctl: FCC read for bceqz/bcnez
    input                               fcc_val,
    output [ 2:0]                       fcc_idx,
    output                              ds_fpu_epoch, // [AI FPU Refactor] Epoch tag to EX
    //to fpu_ctl: FCC async write back
    output                              fcc_we_o,
    output [ 4:0]                       fcc_fj_o,
    output                              fcc_result_o,
    output                              fpu_flags_we_o,
    output [ 4:0]                       fpu_flags_o,
    //FCSR software read/write (movgr2fcsr / movfcsr2gr)
    input  [31:0]                       fcsr_rdata,    //from fpu_ctl: movfcsr2gr 读数据
    output                              fcsr_we_o,     //to fpu_ctl: movgr2fcsr 写使能
    output [31:0]                       fcsr_wdata_o   //to fpu_ctl: movgr2fcsr 写数据(GPR[rj])
    `ifdef DIFFTEST_EN
    ,
    // difftest
    output [31:0]                       rf_to_diff [31:0]
    `endif
);

reg         ds_valid   ;
wire        ds_ready_go;

reg  [`FS_TO_DS_BUS_WD -1:0] fs_to_ds_bus_r;

wire [31:0] ds_inst;
wire [31:0] ds_pc  ;
wire [ 3:0] ds_excp_num;
wire        ds_excp;
wire        ds_icache_miss;
wire        ds_btb_taken;
wire        ds_btb_en;
wire [ 4:0] ds_btb_index;
wire [31:0] ds_btb_target;

assign {ds_btb_target,  //108:77
        ds_btb_index,   //76:72
        ds_btb_taken,   //71:71
        ds_btb_en,      //70:70
        ds_icache_miss, //69:69
        ds_excp,        //68:68
        ds_excp_num,    //67:64
        ds_inst,        //63:32
        ds_pc           //31:0
       } = fs_to_ds_bus_r;

wire        rf_we   ;
wire [ 4:0] rf_waddr;
wire [31:0] rf_wdata;
assign {rf_we   ,  //37:37
        rf_waddr,  //36:32
        rf_wdata   //31:0
       } = ws_to_rf_bus;

`ifdef HAS_FPU
// [FIX] ws_to_fpr_bus destructuring: fpr_we = writeback-stage write enable
//       (wb_stage packs: bit37=fpr_we, bits36:32=waddr, bits31:0=wdata)
wire        fpr_we_from_ws;
wire [ 4:0] fpr_waddr;
wire [31:0] fpr_wdata;
assign {fpr_we_from_ws,
        fpr_waddr,
        fpr_wdata
       } = ws_to_fpr_bus;
`endif

//wire        idle_stall;
wire        br_taken;
wire [31:0] br_target;
wire        btb_pre_error_flush;
wire [31:0] btb_pre_error_flush_target;

//wire        jirl_br;
wire [13:0] alu_op;
wire [ 3:0] mul_div_op;
wire        mul_div_sign;
wire        src1_is_pc;
wire        src2_is_imm;
wire        src2_is_4;
wire        load_op;
wire        res_from_csr;
wire        csr_mask;
wire        mem_b_size;
wire        mem_h_size;
wire        mem_sign_exted;
wire        dst_is_r1;
wire        dst_is_rj;
wire        gr_we;
wire        store_op;
wire        csr_we;
wire        src_reg_is_rd;
wire [1: 0] mem_size;
wire [4: 0] dest;
wire [31:0] rj_value;
wire [31:0] rkd_value;
wire [31:0] ds_imm;

wire [ 5:0] op_31_26;
wire [ 3:0] op_25_22;
wire [ 1:0] op_21_20;
wire [ 4:0] op_19_15;
wire [ 4:0] rd;
wire [ 4:0] rj;
wire [ 4:0] rk;
wire [11:0] i12;
wire [13:0] i14;
wire [19:0] i20;
wire [15:0] i16;
wire [25:0] i26;
wire [13:0] csr_idx;

wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;
wire [31:0] rd_d;
wire [31:0] rj_d;
wire [31:0] rk_d;
  
wire inst_add_w; 
wire inst_sub_w;  
wire inst_slt;    
wire inst_sltu;   
wire inst_nor;    
wire inst_and;    
wire inst_or;     
wire inst_xor;     
wire inst_lu12i_w;
wire inst_addi_w;
wire inst_slti;
wire inst_sltui;
wire inst_pcaddi;
wire inst_pcaddu12i;
wire inst_andn;
wire inst_orn;
wire inst_andi;
wire inst_ori;
wire inst_xori;
wire inst_mul_w;
wire inst_mulh_w;
wire inst_mulh_wu;
wire inst_div_w;
wire inst_mod_w;
wire inst_div_wu;
wire inst_mod_wu;

wire inst_slli_w;  
wire inst_srli_w;  
wire inst_srai_w;  
wire inst_sll_w;
wire inst_srl_w;
wire inst_sra_w;

wire inst_jirl;   
wire inst_b;      
wire inst_bl;     
wire inst_beq;    
wire inst_bne; 
wire inst_blt;
wire inst_bge;
wire inst_bltu;
wire inst_bgeu;

wire inst_ll_w;
wire inst_sc_w;
wire inst_ld_b;
wire inst_ld_bu;
wire inst_ld_h;
wire inst_ld_hu;
wire inst_ld_w;
wire inst_st_b;
wire inst_st_h;
wire inst_st_w;

wire inst_syscall;
wire inst_break;
wire inst_csrrd;
wire inst_csrwr;
wire inst_csrxchg;
wire inst_ertn;
wire inst_cpucfg;

wire inst_rdcntid_w;
wire inst_rdcntvl_w;
wire inst_rdcntvh_w;
wire inst_idle;

wire inst_tlbsrch;
wire inst_tlbrd;
wire inst_tlbwr;
wire inst_tlbfill;
wire inst_invtlb;

wire inst_cacop;
wire inst_valid_cacop;
wire inst_preld;
wire inst_dbar;
wire inst_ibar;

wire inst_nop;

`ifdef HAS_FPU
// FPU instruction decode
wire inst_fadd_s;
wire inst_fsub_s;
wire inst_fmul_s;
wire inst_fdiv_s;
wire inst_fld_s;
wire inst_fst_s;
wire inst_movgr2fr_w;
wire inst_movfr2gr_s;
wire inst_ftint_w_s;
wire inst_ffint_s_w;
wire inst_bceqz;
wire inst_bcnez;
wire inst_movgr2fcsr;
wire inst_movfcsr2gr;
wire inst_fmov_s;
wire inst_fneg_s;
wire inst_frecip_s;
wire inst_fmadd_s;
wire inst_fmsub_s;
wire inst_fabs_s;        // 取绝对值(清符号位), 单源, 走 NONCOMP/SGNJ
wire inst_fcopysign_s;   // 拷贝符号(fj 取数值, fk 取符号), 双源, 走 NONCOMP/SGNJ
// 阶段2: fcmp 改广义匹配 (is_fpu_fcmp), cond 透传 inst[19:15], 不再逐条译码
// 阶段1: fsel (不走 CVFPU, 纯数据通路: FR[fd]=CFR[ca]?FR[fk]:FR[fj], ca 在 inst[17:15])
wire inst_fsel;
// 阶段2: 补齐手册单精度全集 (走 CVFPU 的运算/转换类)
wire inst_fsqrt_s;       // 开方, DIVSQRT/SQRT (TH32 原生开方通路)
wire inst_fmax_s;        // 数值最大, NONCOMP/MINMAX rm=RTZ
wire inst_fmin_s;
wire inst_fmaxa_s;   // 阶段2b: 绝对值最大 (本地覆盖旁路)
wire inst_fmina_s;   // 阶段2b: 绝对值最小
wire inst_fclass_s;  // 阶段2b: 分类 (本地判类)        // 数值最小, NONCOMP/MINMAX rm=RNE
wire inst_fnmadd_s;      // -(fj*fk+fa), CVFPU FNMSUB+op_mod=1
wire inst_fnmsub_s;      // -(fj*fk-fa), CVFPU FNMSUB+op_mod=0
// 阶段2b: fclass (需独立 class_mask 通路或本地判类, 与 fmaxa/fmina/FCC-mov 同批)
wire inst_ftintrm_w_s;   // 向-inf 取整, F2I 强制 rm
wire inst_ftintrp_w_s;   // 向+inf 取整
wire inst_ftintrne_w_s;  // 就近取整
wire is_fpu_inst;
wire is_fpu_arith;
wire is_fpu_unary;   // 单操作数浮点(fmov/fneg/frecip/fabs): 只读 fj, 写 fd
wire is_fpu_fma;     // 融合乘加(fmadd/fmsub, 4R 格式): 读 fj/fk/fa, 写 fd
wire is_fpu_fcmp;
wire is_fpu_branch;
wire [ 4:0] fpu_op;      // 阶段2: 4→5bit (编码数超 14)
wire [ 4:0] fcmp_cond;   // 阶段2: 3→5bit, 直接透传 inst[19:15] 手册 cond 原值
`endif

`ifdef HAS_LACC
// inst[31: 26] = 6'h30
// inst[25: 22] = op
// rk rj rd
wire lacc_req, lacc_valid;
`endif

wire need_ui5;
wire need_si12;
wire need_ui12;
wire need_si14_pc;
wire need_si16_pc;
wire need_si20;
wire need_si20_pc;
wire need_si26_pc;

wire [ 4:0] rf_raddr1;
wire [31:0] rf_rdata1;
wire [ 4:0] rf_raddr2;
wire [31:0] rf_rdata2;

wire        pipeline_no_empty;
wire        dbar_stall;
wire        ibar_stall;

wire        rj_eq_rd;
wire        rj_lt_rd_sign;
wire        rj_lt_rd_unsign;

wire        ms_forward_enable;
wire [ 4:0] ms_forward_reg;
wire [31:0] ms_forward_data;
wire        ms_dep_need_stall;
wire        es_dep_need_stall;
wire        es_forward_enable;
wire [ 4:0] es_forward_reg;
wire [31:0] es_forward_data;
wire        rf1_forward_stall;
wire        rf2_forward_stall;

wire        excp;
wire [ 8:0] excp_num;
wire        inst_valid;
wire        excp_ine;
wire        excp_ipe;
wire [31:0] csr_data;
wire        refetch;
wire        flush_sign;

`ifdef HAS_FPU
// Forward declarations for FPU signals (used before ds_to_es_bus pack)
wire [31:0] fpr_rdata1;
wire [31:0] fpr_rdata2;
wire [31:0] fpr_rdata3;   // fa (fmadd/fmsub), 在 ds_to_es_bus 打包处先于 regfile 段使用
wire [ 4:0] fpr_dest;
wire        fpr_write_intent;
wire        fpr1_stall;
wire        fpr2_stall;
wire        fpr3_stall;
wire        fcc_stall;
wire        fcsr_stall;        // movgr2fcsr/movfcsr2gr 串行化停顿 (等 FP 流水线排空)
wire [31:0] fj_or_fcsr_value;  // movfcsr2gr 时为 FCSR 读数据, 否则为 fpr_rdata1
`endif

wire        fs_excp;

wire        kernel_inst;

wire [31:0] rdcnt_result;
wire        rdcnt_en;

reg         branch_slot_cancel;

wire        tlb_inst_stall;

wire        br_inst;

reg         br_jirl;

wire        br_need_reg_data;
wire        br_to_btb;

wire        inst_need_rj;
wire        inst_need_rkd;

wire [31:0] rj_value_forward_es;
wire [31:0] rkd_value_forward_es;

// difftest
wire [7:0]  inst_ld_en;
wire [7:0]  inst_st_en;
wire        inst_csr_rstat_en;

assign br_bus       = {btb_pre_error_flush,           //32:32
                       btb_pre_error_flush_target     //31:0
                      };

assign ds_to_es_bus = {
                       `ifdef HAS_LACC
                       ds_inst[22 +: `LACC_OP_WIDTH],
                       lacc_req,
                       `endif
                       `ifdef HAS_FPU
                       fpr_rdata3       ,  // FPR read data 3 (fa_value, 仅 fmadd/fmsub)
                       fpr_rdata2       ,  // FPR read data 2 (fk_value)
                       fj_or_fcsr_value ,  // FPR read data 1 (fj_value); movfcsr2gr 时改送 FCSR 读数据
                       inst_fsel        ,  // 阶段1: fsel 标志(选中值已骑在 fj_value 槽位)
                       fpr_write_intent ,
                       fpr_dest         ,
                       fcmp_cond        ,
                       fpu_op           ,
                       inst_fld_s       ,
                       inst_fst_s       ,
                       is_fpu_fcmp      ,
                       is_fpu_inst      ,
                       `endif
                       inst_csr_rstat_en,  // 349:349 for difftest
                       inst_st_en       ,  // 348:341 for difftest
                       inst_ld_en       ,  // 340:333 for difftest
                       (inst_rdcntvl_w | inst_rdcntvh_w | inst_rdcntid_w), //332:332  for difftest
                       timer_64      ,  //331:268  for difftest
                       ds_inst       ,  //267:236  for difftest
                       inst_idle     ,  //235:235
                       btb_pre_error_flush, //234:234
                       br_to_btb     ,  //233:233
                       ds_icache_miss,  //232:232
                       br_inst       ,  //231:231
                       inst_preld    ,  //230:230
                       inst_valid_cacop,  //229:229
                       mem_sign_exted,  //228:228
                       inst_invtlb   ,  //227:227
                       inst_tlbrd    ,  //226:226
                       refetch       ,  //225:225
                       inst_tlbfill  ,  //224:224
                       inst_tlbwr    ,  //223:223
                       inst_tlbsrch  ,  //222:222
                       inst_sc_w     ,  //221:221
                       inst_ll_w     ,  //220:220
                       excp_num      ,  //219:211
                       csr_mask      ,  //210:210
                       csr_we        ,  //209:209
                       csr_idx       ,  //208:195
                       res_from_csr  ,  //194:194
                       csr_data      ,  //193:162
                       inst_ertn     ,  //161:161
                       excp          ,  //160:160
                       mem_size      ,  //159:158
                       mul_div_op    ,  //157:154
                       mul_div_sign  ,  //153:153
                       alu_op        ,  //152:139
                       load_op       ,  //138:138 bug2 load_op
                       src1_is_pc    ,  //137:137
                       src2_is_imm   ,  //136:136
                       src2_is_4     ,  //135:135
                       gr_we         ,  //134:134
                       store_op      ,  //133:133
                       dest          ,  //132:128
                       ds_imm        ,  //127:96
                       rj_value      ,  //95 :64
                       rkd_value     ,  //63 :32
                       ds_pc            //31 :0
                      };

assign flush_sign = excp_flush || ertn_flush || refetch_flush || icacop_flush || idle_flush;

assign fs_excp = fs_to_ds_bus[68];

//wait inst will stall at ds.
assign ds_ready_go    = !(rf2_forward_stall || rf1_forward_stall || fpr1_stall || fpr2_stall || fpr3_stall || fcc_stall || fcsr_stall /*|| idle_stall*/ || tlb_inst_stall || ibar_stall || dbar_stall) || excp;
assign ds_allowin     = !ds_valid || ds_ready_go && es_allowin;
assign ds_to_es_valid = ds_valid && ds_ready_go;
always @(posedge clk) begin   //bug1 no reset; branch no delay slot
    if (reset || flush_sign) begin
        ds_valid <= 1'b0;
    end
    else begin 
        if (ds_allowin) begin   //bug2 ??
            if ((btb_pre_error_flush && es_allowin) || branch_slot_cancel) begin
                ds_valid <= 1'b0;
            end
            else begin
                ds_valid <= fs_to_ds_valid;
            end
        end
    end

    if (fs_to_ds_valid && ds_allowin) begin
        fs_to_ds_bus_r <= fs_to_ds_bus;
    end
end

assign op_31_26  = ds_inst[31:26];
assign op_25_22  = ds_inst[25:22];
assign op_21_20  = ds_inst[21:20];
assign op_19_15  = ds_inst[19:15];

assign rd   = ds_inst[ 4: 0];
assign rj   = ds_inst[ 9: 5];
assign rk   = ds_inst[14:10];

assign i12  = ds_inst[21:10];
assign i14  = ds_inst[23:10];
assign i20  = ds_inst[24: 5];
assign i16  = ds_inst[25:10];
assign i26  = {ds_inst[ 9: 0], ds_inst[25:10]};

assign csr_idx = ds_inst[23:10];

decoder_6_64 u_dec0(.in(op_31_26 ), .out(op_31_26_d ));
decoder_4_16 u_dec1(.in(op_25_22 ), .out(op_25_22_d ));
decoder_2_4  u_dec2(.in(op_21_20 ), .out(op_21_20_d ));
decoder_5_32 u_dec3(.in(op_19_15 ), .out(op_19_15_d ));

decoder_5_32 u_dec4(.in(rd  ), .out(rd_d  ));
decoder_5_32 u_dec5(.in(rj  ), .out(rj_d  ));
decoder_5_32 u_dec6(.in(rk  ), .out(rk_d  ));

assign inst_add_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
assign inst_sub_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
assign inst_slt        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
assign inst_sltu       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
assign inst_nor        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
assign inst_and        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
assign inst_or         = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
assign inst_xor        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
assign inst_orn        = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0c];
assign inst_andn       = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0d];
assign inst_sll_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
assign inst_srl_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
assign inst_sra_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
assign inst_mul_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
assign inst_mulh_w     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
assign inst_mulh_wu    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
assign inst_div_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
assign inst_mod_w      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
assign inst_div_wu     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
assign inst_mod_wu     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];
assign inst_break      = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h14];
assign inst_syscall    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h16];
assign inst_slli_w     = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
assign inst_srli_w     = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
assign inst_srai_w     = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_idle       = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_invtlb     = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h13];
assign inst_dbar       = op_31_26_d[6'h0e] & op_25_22_d[4'h1] & op_21_20_d[2'h3] & op_19_15_d[5'h04];
assign inst_ibar       = op_31_26_d[6'h0e] & op_25_22_d[4'h1] & op_21_20_d[2'h3] & op_19_15_d[5'h05];
assign inst_slti       = op_31_26_d[6'h00] & op_25_22_d[4'h8];
assign inst_sltui      = op_31_26_d[6'h00] & op_25_22_d[4'h9];
assign inst_addi_w     = op_31_26_d[6'h00] & op_25_22_d[4'ha];
assign inst_andi       = op_31_26_d[6'h00] & op_25_22_d[4'hd];
assign inst_ori        = op_31_26_d[6'h00] & op_25_22_d[4'he];
assign inst_xori       = op_31_26_d[6'h00] & op_25_22_d[4'hf];
assign inst_ld_b       = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
assign inst_ld_h       = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
assign inst_ld_w       = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_b       = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
assign inst_st_h       = op_31_26_d[6'h0a] & op_25_22_d[4'h5];
assign inst_st_w       = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_ld_bu      = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
assign inst_ld_hu      = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
assign inst_cacop      = op_31_26_d[6'h01] & op_25_22_d[4'h8];
assign inst_preld      = op_31_26_d[6'h0a] & op_25_22_d[4'hb];
assign inst_jirl       = op_31_26_d[6'h13];
assign inst_b          = op_31_26_d[6'h14];
assign inst_bl         = op_31_26_d[6'h15];
assign inst_beq        = op_31_26_d[6'h16];
assign inst_bne        = op_31_26_d[6'h17];
assign inst_blt        = op_31_26_d[6'h18];
assign inst_bge        = op_31_26_d[6'h19];
assign inst_bltu       = op_31_26_d[6'h1a];
assign inst_bgeu       = op_31_26_d[6'h1b];
assign inst_lu12i_w    = op_31_26_d[6'h05] & ~ds_inst[25];
assign inst_pcaddi     = op_31_26_d[6'h06] & ~ds_inst[25];
assign inst_pcaddu12i  = op_31_26_d[6'h07] & ~ds_inst[25];
assign inst_csrxchg    = op_31_26_d[6'h01] & ~ds_inst[25] & ~ds_inst[24] & (~rj_d[5'h00] & ~rj_d[5'h01]);  //rj != 0,1
assign inst_ll_w       = op_31_26_d[6'h08] & ~ds_inst[25] & ~ds_inst[24];
assign inst_sc_w       = op_31_26_d[6'h08] & ~ds_inst[25] &  ds_inst[24];
assign inst_csrrd      = op_31_26_d[6'h01] & ~ds_inst[25] & ~ds_inst[24] & rj_d[5'h00];
assign inst_csrwr      = op_31_26_d[6'h01] & ~ds_inst[25] & ~ds_inst[24] & rj_d[5'h01];
assign inst_rdcntid_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & rk_d[5'h18] & rd_d[5'h00];
assign inst_rdcntvl_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & rk_d[5'h18] & rj_d[5'h00] & !rd_d[5'h00];
assign inst_rdcntvh_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & rk_d[5'h19] & rj_d[5'h00];
assign inst_ertn       = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & rk_d[5'h0e] & rj_d[5'h00] & rd_d[5'h00];
assign inst_tlbsrch    = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & rk_d[5'h0a] & rj_d[5'h00] & rd_d[5'h00];
assign inst_tlbrd      = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & rk_d[5'h0b] & rj_d[5'h00] & rd_d[5'h00];
assign inst_tlbwr      = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & rk_d[5'h0c] & rj_d[5'h00] & rd_d[5'h00];
assign inst_tlbfill    = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & rk_d[5'h0d] & rj_d[5'h00] & rd_d[5'h00];
assign inst_cpucfg     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & rk_d[5'h1b];

assign inst_valid_cacop = inst_cacop&&(dest[2:0]==3'b0||dest[2:0]==3'b1)&&(dest[4:3]==2'd0||dest[4:3]==2'd1||dest[4:3]==2'd2);
assign inst_nop = inst_cacop&&((dest[2:0]!=3'b0&&dest[2:0]!=3'b1)||(dest[4:3]==2'd3));

`ifdef HAS_LACC
    assign lacc_req = ds_inst[31] & ds_inst[30] & ~ds_inst[29] & ~ds_inst[28];
    assign lacc_valid = ds_inst[22 +: `LACC_OP_WIDTH] < `LACC_OP_SIZE;
`endif

`ifdef HAS_FPU
    // === FPU instruction decode — standard LoongArch ISA (Vol1 v1.10) ===
    //
    // 3R format (@fff): inst[31:15]=opcode, inst[14:10]=fk, inst[9:5]=fj, inst[4:0]=fd
    // 2R format (@fr/@rf): inst[31:10]=opcode, inst[9:5]=rj/fj, inst[4:0]=fd/rd
    // 2RI12 format (@fr_i12): inst[31:22]=opcode, inst[21:10]=si12, inst[9:5]=rj, inst[4:0]=fd
    // 1RI21 format: inst[31:26]=opcode, inst[25:10]=si16, inst[9:5]=rj, inst[4:0]=hint
    //
    // FPU arithmetic: op_31_26=6'h00, op_25_22=4'h4, op_21_20=2'h0
    //   op_19_15: 0x01=fadd.s, 0x05=fsub.s, 0x09=fmul.s, 0x0d=fdiv.s
    assign inst_fadd_s  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
    assign inst_fsub_s  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h05];
    assign inst_fmul_s  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
    assign inst_fdiv_s  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h0d];
    // FPU move: op_31_26=6'h00, op_25_22=4'h4, op_21_20=2'h1, op_19_15=5'h09
    //   rk_ext: 9 for movgr2fr.w, 13 for movfr2gr.s (LA32R ISA Vol1)
    assign inst_movgr2fr_w = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h09] & rk_d[5'h09];
    assign inst_movfr2gr_s = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h09] & rk_d[5'h0d];
    // FPU convert: FTINTRZ.W.S, FFINT.S.W
    //   op_31_26=6'h00, op_25_22=4'h4, op_21_20=2'h1
    //   FTINTRZ.W.S 的 rk 字段 = 5'h01 (手册附录B + QEMU insns.decode); 5'h02 是 FTINTRZ.W.D(双精度)。
    //   2026-06-26 修正: 原误用 5'h02(=.w.d), 经第二金标 QEMU 互对暴露, 见 doc/agent/FINDING_ftintrz_encoding.md。
    assign inst_ftint_w_s   = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h15] & rk_d[5'h01];
    assign inst_ffint_s_w   = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h1a] & rk_d[5'h04];
    // FCSR 软件读写: 与 movgr2fr 同组(op_19_15=0x09), rk_ext 区分: 0x10=movgr2fcsr, 0x12=movfcsr2gr
    //   movgr2fcsr fcsr,rj : GPR[rj]→FCSR (rj 在[9:5], fcsr 在[4:0])
    //   movfcsr2gr rd,fcsr : FCSR→GPR[rd] (fcsr 在[9:5], rd 在[4:0])
    assign inst_movgr2fcsr  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h09] & rk_d[5'h10];
    assign inst_movfcsr2gr  = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h09] & rk_d[5'h12];
    // FPU 单操作数运算 (手册附录B, 2R 格式, 仅源 fj→目的 fd):
    //   fmov.s   fd,fj : 与 mov* 同子组 op_19_15=0x09, rk_ext=0x05 → base 0x01149400 (纯位拷贝)
    //   fneg.s   fd,fj : op_19_15=0x08, rk_ext=0x05 → base 0x01141400 (翻转符号位)
    //   frecip.s fd,fj : op_19_15=0x08, rk_ext=0x15 → base 0x01145400 (1/fj 近似, 本实现走除法)
    assign inst_fmov_s      = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h09] & rk_d[5'h05];
    assign inst_fneg_s      = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h08] & rk_d[5'h05];
    assign inst_frecip_s    = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h08] & rk_d[5'h15];
    // 硬浮点 ABI(ilp32f) 编译必发但此前缺译的 6 条之 SGNJ 类(手册附录B + as 实测编码):
    //   fabs.s   fd,fj : op_19_15=0x08, rk_ext=0x01 → base 0x01140400 (清符号位, 单源, =RISCV fsgnjx fd,fj,fj)
    //   fcopysign.s fd,fj,fk : op_19_15=0x05(无 rk_ext, fk 在 rk 字段为操作数) → base 0x01128000
    //       (fd = {fk[31], fj[30:0]}, 即 fj 取数值/fk 取符号, =RISCV fsgnj fd,fj,fk)
    assign inst_fabs_s      = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h08] & rk_d[5'h01];
    assign inst_fcopysign_s = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
    // FPU 融合乘加 (手册附录B, 4R 格式: op[31:20] 为 12 位主码, [19:15]=fa [14:10]=fk [9:5]=fj [4:0]=fd):
    //   fmadd.s = 0x081 → op_31_26=0x02 op_25_22=0x0 op_21_20=0x1 (fj*fk+fa)
    //   fmsub.s = 0x085 → op_31_26=0x02 op_25_22=0x1 op_21_20=0x1 (fj*fk-fa)
    //   注意: 4R 格式 [19:15] 是 fa 寄存器号, 不可作操作码判别; 单/双精度由 op_21_20 区分(.d=0x2)。
    assign inst_fmadd_s     = op_31_26_d[6'h02] & op_25_22_d[4'h0] & op_21_20_d[2'h1];
    assign inst_fmsub_s     = op_31_26_d[6'h02] & op_25_22_d[4'h1] & op_21_20_d[2'h1];
    // FPU compare: op_31_26=6'h03, op_25_22=4'h0, op_21_20=2'h1
    //   cond in op_19_15(安静比较 quiet 变体, 汇编器对 fcmp.cond.s 实际发出的编码):
    //   0x02=clt, 0x04=ceq, 0x06=cle, 0x10=cne (注意: 0x05/0x11 是 signaling 变体 seq/sne, 勿用)
    // fcmp.cond.s: op6=0x03, op25_22=0x0, op21_20=0x1; cond 在 inst[19:15] (5-bit 手册原值)。
    //   阶段2: 从逐条译码改为广义匹配 (涵盖全部 22 种 cond), cond 直接透传给 fpu_top 按手册 case。
    //   旧的 8 个 inst_fcmp_* 信号已删除, is_fpu_fcmp/fcmp_cond 见下方。
    // 硬浮点编译常发的额外 4 个 fcmp 条件(手册 §3.2.1.4 表 + as 实测 cond[19:15]):
    // FPU load/store: op_31_26=6'h0a, op_25_22=4'hc=fld.s, op_25_22=4'hd=fst.s
    assign inst_fld_s   = op_31_26_d[6'h0a] & op_25_22_d[4'hc];
    assign inst_fst_s   = op_31_26_d[6'h0a] & op_25_22_d[4'hd];
    // FPU branches: op_31_26=6'h12, inst[9:8]=00 for bceqz, inst[9:8]=01 for bcenez
    assign inst_bceqz   = op_31_26_d[6'h12] & ~rj[4] & ~rj[3];
    assign inst_bcnez   = op_31_26_d[6'h12] & ~rj[4] &  rj[3];

    // 阶段1: fsel (纯数据通路, 不走 CVFPU/fpu_top, 不占 fpu_op 编码)
    //   编码由硬浮点工具链 as/objdump 实测核准 (chk_enc.S):
    //   fsel fd,fj,fk,ca : op_31_26=0x03, op_25_22=0x4 (与 fcmp 的 op_25_22=0x0 区分);
    //                      ca 在 inst[17:15], fk 在[14:10], fj 在[9:5], fd 在[4:0]。
    //                      语义(手册§3.2.4.2): FR[fd] = CFR[ca] ? FR[fk] : FR[fj]
    assign inst_fsel     = op_31_26_d[6'h03] & op_25_22_d[4'h4];

    // 阶段2: 新增走 CVFPU 的指令 (fpu_op 扩 5-bit)
    //   2R 单源组 (op25_22=0x4, op21_20=0x1, 靠 op19_15+rk 区分):
    assign inst_fsqrt_s     = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h08] & rk_d[5'h11];
    assign inst_ftintrm_w_s = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h14] & rk_d[5'h01];
    assign inst_ftintrp_w_s = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h14] & rk_d[5'h11];
    assign inst_ftintrne_w_s= op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h15] & rk_d[5'h11];
    //   3R 双源组 (op25_22=0x4, op21_20=0x0, fk 在 [14:10]):
    assign inst_fmax_s      = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
    assign inst_fmin_s      = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h15];
    //   fmaxa/fmina (绝对值最值, 3R op21_20=0): op19_15=0x19/0x1d。本地绝对值比较+原值选择(fpu_top alt 旁路)。
    assign inst_fmaxa_s     = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h19];
    assign inst_fmina_s     = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h0] & op_19_15_d[5'h1d];
    //   fclass (2R op21_20=1, op19_15=0x08 rk=0x0d): 本地判类(fpu_top alt 旁路)。
    assign inst_fclass_s    = op_31_26_d[6'h00] & op_25_22_d[4'h4] & op_21_20_d[2'h1] & op_19_15_d[5'h08] & rk_d[5'h0d];
    //   4R 融合乘加 (op6=0x02, op21_20=0x1, op25_22 区分): fnmadd=0x2, fnmsub=0x3
    assign inst_fnmadd_s    = op_31_26_d[6'h02] & op_25_22_d[4'h2] & op_21_20_d[2'h1];
    assign inst_fnmsub_s    = op_31_26_d[6'h02] & op_25_22_d[4'h3] & op_21_20_d[2'h1];
    //   FCC 搬运 (movfr2cf/movcf2fr/movgr2cf/movcf2gr) 拆到阶段2b-后续 (需新 FCC/GPR 写通路), 本阶段不译码。

    assign is_fpu_arith = inst_fadd_s | inst_fsub_s | inst_fmul_s | inst_fdiv_s | inst_ftint_w_s | inst_ffint_s_w |
                          inst_fsqrt_s | inst_fmax_s | inst_fmin_s | inst_fmaxa_s | inst_fmina_s | inst_fclass_s |
                          inst_ftintrm_w_s | inst_ftintrp_w_s | inst_ftintrne_w_s;
    // fcmp 广义匹配: 涵盖全部 22 种 cond (op6=0x03, op25_22=0x0, op21_20=0x1)
    assign is_fpu_fcmp  = op_31_26_d[6'h03] & op_25_22_d[4'h0] & op_21_20_d[2'h1];
    assign is_fpu_unary = inst_fmov_s | inst_fneg_s | inst_frecip_s | inst_fabs_s;
    assign is_fpu_fma   = inst_fmadd_s | inst_fmsub_s | inst_fnmadd_s | inst_fnmsub_s;
    assign is_fpu_branch = inst_bceqz | inst_bcnez;
    assign is_fpu_inst  = is_fpu_arith | is_fpu_fcmp | is_fpu_unary | is_fpu_fma | inst_movgr2fr_w | inst_movfr2gr_s |
                          inst_fld_s | inst_fst_s | is_fpu_branch | inst_fcopysign_s |
                          inst_movgr2fcsr | inst_movfcsr2gr | inst_fsel;

    // FPU opcode for fpu_top (5-bit, 与 fpu_top.sv localparam 一致)
    //   保持 00001~01110 十四条原编码不变(已验证), 新指令用扩展空间 01111~11001。
    assign fpu_op = {5{inst_fadd_s}} & 5'b00001 |
                    {5{inst_fsub_s}} & 5'b00010 |
                    {5{inst_fmul_s}} & 5'b00011 |
                    {5{inst_fdiv_s}} & 5'b00100 |
                    {5{inst_ftint_w_s}} & 5'b00101 |
                    {5{inst_ffint_s_w}} & 5'b00110 |
                    {5{is_fpu_fcmp}}    & 5'b00111 |
                    {5{inst_fmov_s}}    & 5'b01000 |
                    {5{inst_fneg_s}}    & 5'b01001 |
                    {5{inst_frecip_s}}  & 5'b01010 |
                    {5{inst_fmadd_s}}   & 5'b01011 |
                    {5{inst_fmsub_s}}   & 5'b01100 |
                    {5{inst_fabs_s}}      & 5'b01101 |
                    {5{inst_fcopysign_s}} & 5'b01110 |
                    {5{inst_fsqrt_s}}     & 5'b01111 |
                    {5{inst_fmax_s}}      & 5'b10000 |
                    {5{inst_fmin_s}}      & 5'b10001 |
                    {5{inst_fmaxa_s}}     & 5'b10010 |
                    {5{inst_fmina_s}}     & 5'b10011 |
                    {5{inst_fnmadd_s}}    & 5'b10100 |
                    {5{inst_fnmsub_s}}    & 5'b10101 |
                    {5{inst_fclass_s}}    & 5'b10110 |
                    {5{inst_ftintrm_w_s}} & 5'b10111 |
                    {5{inst_ftintrp_w_s}} & 5'b11000 |
                    {5{inst_ftintrne_w_s}}& 5'b11001;

    // fcmp_cond: 直接透传 inst[19:15] 手册原值(5-bit), fpu_top 按手册 cond case。
    //   涵盖全部 22 种 cond; 非 fcmp 指令时该字段无意义(fpu_op!=fcmp 时 fpu_top 不用它)。
    assign fcmp_cond = op_19_15;

    // FCC index: bceqz/bcnez read FCC[rj[2:0]]; fcmp writes FCC[rd[2:0]] (cd field)
    //   fsel 读 FCC[ca], ca 在 inst[17:15] → 复用 fcc_val 读取路径, 选择位来自此
    assign fcc_idx = inst_fsel ? ds_inst[17:15] : rj[2:0];
`endif

assign alu_op[ 0] = inst_add_w      |
                    inst_addi_w     |
                    inst_ld_b       |
                    inst_ld_h       |
                    inst_ld_w       |
                    inst_st_b       |
                    inst_st_h       |
                    inst_st_w       |
                    inst_ld_bu      |
                    inst_ld_hu      |
                    inst_ll_w       |
                    inst_sc_w       |
                    inst_jirl       |
                    inst_bl         |
                    inst_pcaddi     |
                    inst_pcaddu12i  |
                    inst_valid_cacop|
                    inst_preld
                    `ifdef HAS_FPU
                    | inst_fld_s | inst_fst_s  // FPU load/store 需要 ADD 计算地址
                    `endif
                    ;

assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt   | inst_slti;
assign alu_op[ 3] = inst_sltu  | inst_sltui;
assign alu_op[ 4] = inst_and   | inst_andi;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or    | inst_ori;
assign alu_op[ 7] = inst_xor   | inst_xori;
assign alu_op[ 8] = inst_sll_w | inst_slli_w;
assign alu_op[ 9] = inst_srl_w | inst_srli_w;
assign alu_op[10] = inst_sra_w | inst_srai_w;
assign alu_op[11] = inst_lu12i_w;
assign alu_op[12] = inst_andn;
assign alu_op[13] = inst_orn;

assign mul_div_op[ 0] = inst_mul_w;
assign mul_div_op[ 1] = inst_mulh_w | inst_mulh_wu;
assign mul_div_op[ 2] = inst_div_w  | inst_div_wu;
assign mul_div_op[ 3] = inst_mod_w  | inst_mod_wu;

assign mul_div_sign  =  inst_mul_w | inst_mulh_w | inst_div_w | inst_mod_w;

assign need_ui5      =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_si12     =  inst_addi_w     |
                        inst_ld_b       |
                        inst_ld_h       |
                        inst_ld_w       |
                        inst_st_b       |
                        inst_st_h       | 
                        inst_st_w       |
                        inst_ld_bu      |
                        inst_ld_hu      | 
                        inst_slti       | 
                        inst_sltui      |
                        inst_valid_cacop|
                        inst_preld
                        `ifdef HAS_FPU
                        | inst_fld_s | inst_fst_s
                        `endif
                        ;

assign need_ui12     =  inst_andi | inst_ori | inst_xori
                        `ifdef HAS_LACC
                        | lacc_req
                        `endif
                        ;
assign need_si14_pc  =  inst_ll_w | inst_sc_w;
assign need_si16_pc  =  inst_jirl |
                        inst_beq  |
                        inst_bne  |
                        inst_blt  |
                        inst_bge  |
                        inst_bltu |
                        inst_bgeu
                        `ifdef HAS_FPU
                        | inst_bceqz | inst_bcnez
                        `endif
                        ;

assign need_si20     =  inst_lu12i_w | inst_pcaddu12i;
assign need_si20_pc  =  inst_pcaddi;
assign need_si26_pc  =  inst_b | inst_bl;

assign ds_imm = ({32{need_ui5    }} & {27'b0, rk}               ) |
                ({32{need_si12   }} & {{20{i12[11]}}, i12}      ) |
                ({32{need_ui12   }} & {20'b0, i12}              ) |
                ({32{need_si14_pc}} & {{16{i14[13]}}, i14, 2'b0}) |
                ({32{need_si16_pc}} & {{14{i16[15]}}, i16, 2'b0}) |
                ({32{need_si20   }} & {i20, 12'b0}              ) |
                ({32{need_si20_pc}} & {{10{i20[19]}}, i20, 2'b0}) |
                ({32{need_si26_pc}} & {{ 4{i26[25]}}, i26, 2'b0}) ;

assign src_reg_is_rd = inst_beq    | 
                       inst_bne    | 
                       inst_blt    | 
                       inst_bltu   | 
                       inst_bge    | 
                       inst_bgeu   |
                       inst_st_b   |
                       inst_st_h   |
                       inst_st_w   |
                       inst_sc_w   |
                       inst_csrwr  |
                       inst_csrxchg;

assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddi | inst_pcaddu12i;

assign src2_is_imm   = inst_slli_w     |
                       inst_srli_w     |
                       inst_srai_w     |
                       inst_addi_w     |
                       inst_slti       |
                       inst_sltui      |
                       inst_andi       |
                       inst_ori        |
                       inst_xori       |
                       inst_pcaddi     |
                       inst_pcaddu12i  |
                       inst_ld_b       |
                       inst_ld_h       |
                       inst_ld_w       |
                       inst_ld_bu      |
                       inst_ld_hu      |
                       inst_st_b       |
                       inst_st_h       |
                       inst_st_w       |
                       inst_ll_w       |
                       inst_sc_w       |
                       inst_lu12i_w    |
                       inst_valid_cacop|
                       inst_preld
                       `ifdef HAS_FPU
                       | inst_fld_s | inst_fst_s
                       `endif
                       ;

assign src2_is_4     = inst_jirl | inst_bl;

assign load_op       = inst_ld_b | inst_ld_h | inst_ld_w | inst_ld_bu | inst_ld_hu | inst_ll_w
                       `ifdef HAS_FPU
                       | inst_fld_s
                       `endif
                       ;
assign mem_b_size    = inst_ld_b | inst_ld_bu | inst_st_b;
assign mem_h_size    = inst_ld_h | inst_ld_hu | inst_st_h;
assign mem_sign_exted= inst_ld_b | inst_ld_h;
assign dst_is_r1     = inst_bl;
assign gr_we         = ~inst_st_b       & 
                       ~inst_st_h       & 
                       ~inst_st_w       & 
                       ~inst_beq        & 
                       ~inst_bne        & 
                       ~inst_blt        & 
                       ~inst_bge        &
                       ~inst_bltu       &
                       ~inst_bgeu       &
                       ~inst_b          &
                       ~inst_syscall    &
                       ~inst_tlbsrch    &
                       ~inst_tlbrd      &
                       ~inst_tlbwr      &
                       ~inst_tlbfill    &
                       ~inst_invtlb     &
                       ~inst_valid_cacop&
                       ~inst_preld      &      
                       ~inst_dbar       &      
                       ~inst_ibar       &
					   ~inst_nop
					   `ifdef HAS_FPU
					   & ~inst_fst_s     &
					   ~is_fpu_arith   &
					   ~is_fpu_unary   &   // fmov/fneg/frecip/fabs 写 FPR 不写 GPR
					   ~is_fpu_fma     &   // fmadd/fmsub 写 FPR 不写 GPR
					   ~inst_fcopysign_s & // fcopysign 写 FPR 不写 GPR
					   ~inst_fld_s     &
					   ~is_fpu_fcmp    &
					   ~inst_movgr2fr_w &
					   ~inst_ftint_w_s &
					   ~inst_ffint_s_w &
					   ~is_fpu_branch  &
					   ~inst_fsel      &   // fsel 写 FPR 不写 GPR
					   ~inst_movgr2fcsr  // movgr2fcsr 写 FCSR 不写 GPR; movfcsr2gr 写 GPR 保持默认
					   `endif
                       ;

assign store_op      = inst_st_b | inst_st_h | inst_st_w | (inst_sc_w & ds_llbit)
                       `ifdef HAS_FPU
                       | inst_fst_s
                       `endif
                       ;

assign dest          = (dst_is_r1) ? 5'd1 :
                       (dst_is_rj) ? rj   : rd;

assign dst_is_rj     = inst_rdcntid_w;

`ifdef HAS_FPU
// Declarations moved to forward declaration area (line ~357)
assign fpr_dest      = rd;
assign fpr_write_intent = inst_movgr2fr_w | inst_fld_s | inst_fsel;  // decode-level: instruction will write FPR
`endif

assign {rdcnt_en, rdcnt_result} = ({33{inst_rdcntvl_w}} & {1'b1, timer_64[31: 0]}) |
                                  ({33{inst_rdcntvh_w}} & {1'b1, timer_64[63:32]}) |
                                  ({33{inst_rdcntid_w}} & {1'b1, csr_tid}); 

assign csr_data      = rdcnt_en  ? rdcnt_result      : 
                       inst_sc_w ? {31'b0, ds_llbit} : rd_csr_data;                      
                                                                        
assign res_from_csr  = inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid_w | inst_rdcntvh_w | inst_rdcntvl_w | inst_sc_w | inst_cpucfg;
assign csr_we        = inst_csrwr | inst_csrxchg;
assign csr_mask      = inst_csrxchg;

assign mem_size  = {mem_h_size, mem_b_size};

assign inst_need_rj = inst_add_w      |
                      inst_sub_w      |
                      inst_addi_w     |
                      inst_slt        |
                      inst_sltu       |
                      inst_slti       |
                      inst_sltui      |
                      inst_and        |
                      inst_or         |
                      inst_nor        |
                      inst_xor        |
                      inst_andi       |
                      inst_ori        |
                      inst_xori       |
                      inst_mul_w      |
                      inst_mulh_w     |
                      inst_mulh_wu    |
                      inst_div_w      |
                      inst_div_wu     |
                      inst_mod_w      |
                      inst_mod_wu     |
                      inst_sll_w      |
                      inst_srl_w      |
                      inst_sra_w      |
                      inst_slli_w     |
                      inst_srli_w     |
                      inst_srai_w     |
                      inst_beq        |
                      inst_bne        |
                      inst_blt        |
                      inst_bltu       |
                      inst_bge        |
                      inst_bgeu       |
                      inst_jirl       |
                      inst_ld_b       |
                      inst_ld_bu      |
                      inst_ld_h       |
                      inst_ld_hu      |
                      inst_ld_w       |
                      inst_st_b       |
                      inst_st_h       |
                      inst_st_w       |
                      inst_preld      |
                      inst_ll_w       |
                      inst_sc_w       |
                      inst_csrxchg    |
                      inst_valid_cacop|
                      `ifdef HAS_LACC
                      lacc_req         |
                      `endif
                      `ifdef HAS_FPU
                      inst_fld_s       |
                      inst_fst_s       |
                      inst_movgr2fr_w  |
                      inst_movgr2fcsr  |  // movgr2fcsr 写数据来自 GPR[rj], 需前递
                      `endif
                      inst_invtlb     ;

assign inst_need_rkd = inst_add_w   |
                       inst_sub_w   |
                       inst_slt     |
                       inst_sltu    |
                       inst_and     |
                       inst_or      |
                       inst_nor     |
                       inst_xor     |
                       inst_mul_w   |
                       inst_mulh_w  |
                       inst_mulh_wu |
                       inst_div_w   |
                       inst_div_wu  |
                       inst_mod_w   |
                       inst_mod_wu  |
                       inst_sll_w   |
                       inst_srl_w   |
                       inst_sra_w   |
                       inst_beq     |
                       inst_bne     |
                       inst_blt     |
                       inst_bltu    |
                       inst_bge     |
                       inst_bgeu    |
                       inst_st_b    |
                       inst_st_h    |
                       inst_st_w    |
                       inst_sc_w    |
                       inst_csrwr   |
                       inst_csrxchg |
                       `ifdef HAS_LACC
                       lacc_req      |
                       `endif
                       inst_invtlb  ;


assign rf_raddr1 = infor_flag?reg_num:rj;
assign rf_raddr2 = src_reg_is_rd ? rd : rk;
regfile u_regfile(
    .clk    (clk      ),
    .raddr1 (rf_raddr1),
    .rdata1 (rf_rdata1),
    .raddr2 (rf_raddr2),
    .rdata2 (rf_rdata2),
    .we     (rf_we    ),
    .waddr  (rf_waddr ),
    .wdata  (rf_wdata )
    `ifdef DIFFTEST_EN
    ,
    .rf_o   (rf_to_diff)
    `endif
    );

`ifdef HAS_FPU
// FPR read addresses
wire [ 4:0] fpr_raddr1;
wire [ 4:0] fpr_raddr2;
wire [ 4:0] fpr_raddr3;
// fpr_rdata1/2 已在顶部信号声明区(374/375, ifdef HAS_FPU内)声明，此处不再重复声明
wire        fpr_read1_en;
wire        fpr_read2_en;
wire        fpr_read3_en;

assign fpr_read1_en = is_fpu_arith | is_fpu_fcmp | is_fpu_unary | is_fpu_fma | inst_fst_s | inst_movfr2gr_s |
                       inst_ftint_w_s | inst_ffint_s_w | inst_fcopysign_s | inst_fsel;
// 注意: fmov/fneg/frecip/fabs 仅读 fj(端口1), 不读 fk; 故不并入 fpr_read2_en,
//       否则会对 rk 字段位(实为操作码一部分)指向的 FPR 产生虚假 RAW 停顿。
//       fmadd/fmsub 是真 3 源, fj/fk/fa 均要读, 故并入端口 2 与端口 3。
//       fcopysign 是真双源(fj 数值/fk 符号), fk 在 rk 字段为操作数, 须读端口 2。
assign fpr_read2_en = is_fpu_arith | is_fpu_fcmp | is_fpu_fma | inst_fcopysign_s | inst_fsel;
assign fpr_read3_en = is_fpu_fma;

// fst.s 存储数据来自 FPR[fd]（fd 在 rd 字段[4:0]），其余 FPU 指令读 fj 用 rj 字段
assign fpr_raddr1 = inst_fst_s ? rd : rj;
assign fpr_raddr2 = rk;          // fk is in rk field [14:10]
assign fpr_raddr3 = op_19_15;    // fa is in [19:15] (4R 格式, 仅 fmadd/fmsub 有意义)

fpu_regfile u_fpu_regfile(
    .clk    (clk        ),
    .raddr1 (fpr_raddr1 ),
    .rdata1 (fpr_rdata1 ),
    .raddr2 (fpr_raddr2 ),
    .rdata2 (fpr_rdata2 ),
    .raddr3 (fpr_raddr3 ),
    .rdata3 (fpr_rdata3 ),
    .we1    (fpr_we_from_ws),
    .waddr1 (fpr_waddr  ),
    .wdata1 (fpr_wdata  ),
    // 注意: fcmp 结果写的是 FCC 而非 FPR, 且其 dest=cd(fcc 索引)会与 FPR 编号冲突,
    //       必须用 !fpu_rsp_is_fcmp 过滤, 否则 fcmp.cond.s 会误写 FPR[cd] 冲掉浮点寄存器。
    //       与上方 clear_scoreboard2 的过滤条件保持一致。
    .we2    (valid_fpu_rsp && !fpu_rsp_is_fcmp),
    .waddr2 (fpu_rsp_dest ),
    .wdata2 (fpu_rsp_result)
);
`endif

`ifdef HAS_FPU
wire        es_fpr_we;
wire [ 4:0] es_fpr_dest;
`endif
// es_dep_need_stall/es_forward_* 已在顶部信号声明区(356/357/358/359)声明，此处仅做assign
assign {es_dep_need_stall, es_forward_enable, es_forward_reg, es_forward_data} = es_to_ds_forward_bus;

`ifdef HAS_FPU
wire        ms_fpr_we;
wire [ 4:0] ms_fpr_dest;
`endif
// ms_dep_need_stall/ms_forward_* 已在顶部信号声明区(355/352/353/354)声明，此处仅做assign
assign {ms_dep_need_stall, ms_forward_enable, ms_forward_reg, ms_forward_data} = ms_to_ds_forward_bus;

`ifdef HAS_FPU
// [AI FPU Refactor] Epoch Tag mechanism to prevent ghost writebacks on flush
reg fpu_epoch;
always @(posedge clk) begin
    if (reset) begin
        fpu_epoch <= 1'b0;
    end else if (flush_sign) begin
        fpu_epoch <= ~fpu_epoch;
    end
end
assign ds_fpu_epoch = fpu_epoch;

assign valid_fpu_rsp = fpu_rsp_valid && (fpu_rsp_tag == fpu_epoch);

// [AI FPU Refactor] FPR Scoreboard
reg [31:0] fpr_scoreboard;

wire fpu_write_fpr = is_fpu_arith | is_fpu_unary | is_fpu_fma | inst_fld_s | inst_movgr2fr_w | inst_ffint_s_w | inst_ftint_w_s | inst_fcopysign_s | inst_fsel;
wire set_scoreboard = ds_to_es_valid && es_allowin && fpu_write_fpr;
wire [4:0] set_dest = fpr_dest;

wire clear_scoreboard1 = fpr_we_from_ws;  // from ws_to_fpr_bus (Integer WB)
wire [4:0] clear_dest1 = fpr_waddr;
wire clear_scoreboard2 = valid_fpu_rsp && !fpu_rsp_is_fcmp;   // from standalone fpu_top (Filtered by Epoch Tag)
wire [4:0] clear_dest2 = fpu_rsp_dest;

wire [31:0] clear_mask = (clear_scoreboard1 ? (32'b1 << clear_dest1) : 32'b0) |
                         (clear_scoreboard2 ? (32'b1 << clear_dest2) : 32'b0);
wire [31:0] set_mask   = (set_scoreboard ? (32'b1 << set_dest) : 32'b0);

always @(posedge clk) begin
    if (reset || flush_sign) begin
        fpr_scoreboard <= 32'b0;
    end else begin
        // [AI FPU Refactor] Mask-based Scoreboard Update: Set > Clear priority
        fpr_scoreboard <= (fpr_scoreboard & ~clear_mask) | set_mask;
    end
end

wire sb_stall1 = fpr_scoreboard[fpr_raddr1] && !(clear_scoreboard1 && clear_dest1 == fpr_raddr1) && !(clear_scoreboard2 && clear_dest2 == fpr_raddr1);
wire sb_stall2 = fpr_scoreboard[fpr_raddr2] && !(clear_scoreboard1 && clear_dest1 == fpr_raddr2) && !(clear_scoreboard2 && clear_dest2 == fpr_raddr2);
wire sb_stall3 = fpr_scoreboard[fpr_raddr3] && !(clear_scoreboard1 && clear_dest1 == fpr_raddr3) && !(clear_scoreboard2 && clear_dest2 == fpr_raddr3);

assign fpr1_stall = fpr_read1_en && sb_stall1;
assign fpr2_stall = fpr_read2_en && sb_stall2;
assign fpr3_stall = fpr_read3_en && sb_stall3;

// is_fpu_branch 已在顶部(318)声明、并在619的HAS_FPU块内(693行)assign，此处的重复驱动删除

// [AI FPU Refactor] FCC Scoreboard
reg [7:0] fcc_scoreboard;

wire fpu_write_fcc = is_fpu_fcmp;
wire set_fcc_scoreboard = ds_to_es_valid && es_allowin && fpu_write_fcc;
wire [2:0] set_fcc_idx = rd[2:0];

wire clear_fcc_scoreboard = valid_fpu_rsp && fpu_rsp_is_fcmp;
wire [2:0] clear_fcc_idx = fpu_rsp_dest[2:0];

wire [7:0] clear_fcc_mask = clear_fcc_scoreboard ? (8'b1 << clear_fcc_idx) : 8'b0;
wire [7:0] set_fcc_mask   = set_fcc_scoreboard   ? (8'b1 << set_fcc_idx)   : 8'b0;

always @(posedge clk) begin
    if (reset || flush_sign) begin
        fcc_scoreboard <= 8'b0;
    end else begin
        fcc_scoreboard <= (fcc_scoreboard & ~clear_fcc_mask) | set_fcc_mask;
    end
end

// fsel 读 FCC[ca]、bceqz/bcnez 读 FCC[cj], 均须等待对应 FCC 位就绪(scoreboard 空或本周期被清)
assign fcc_stall = (is_fpu_branch | inst_fsel) && (
    fcc_scoreboard[fcc_idx] && !(clear_fcc_scoreboard && clear_fcc_idx == fcc_idx)
);

// FCC write back outputs
assign fcc_we_o     = valid_fpu_rsp && fpu_rsp_is_fcmp;
assign fcc_fj_o     = fpu_rsp_dest;
assign fcc_result_o = fpu_rsp_result[0];

// FPU flags write back output
assign fpu_flags_we_o = valid_fpu_rsp && (fpu_rsp_flags != 5'b0);
assign fpu_flags_o    = fpu_rsp_flags;

// ---- FCSR 软件读写 (movgr2fcsr / movfcsr2gr) ----
// movfcsr2gr 读: FCSR 读数据复用 movfr2gr 的 fj_value 通路写回 GPR (exe 级选 es_fj_value)
// fsel: 在 ID 完成选择 (FCR[ca]=fcc_val ? fk : fj), 选中值骑到 fj_value 槽位,
//       exe 用 es_fsel 让 fpr_write_data 取 es_fj_value 走 movgr2fr 旁路写 FPR。
assign fj_or_fcsr_value = inst_movfcsr2gr ? fcsr_rdata :
                          inst_fsel        ? (fcc_val ? fpr_rdata2 : fpr_rdata1) :
                                             fpr_rdata1;
// 串行化停顿: 两条 FCSR 指令在 ID 级等到 FP 流水线排空(记分板空且本周期无响应)再放行,
//   保证 movfcsr2gr 读到稳定的累积 flags、movgr2fcsr 改 rm/flags 不与在途 FP 竞争。
assign fcsr_stall = (inst_movgr2fcsr || inst_movfcsr2gr) &&
                    ((fpr_scoreboard != 32'b0) || (fcc_scoreboard != 8'b0) || valid_fpu_rsp);
// movgr2fcsr 写: 在 ID→EX 边界(本指令放行那一拍)写 FCSR, 数据取已前递的 GPR[rj]
//   !flush_sign 防止本指令在放行同周期被冲刷时仍误写 FCSR
assign fcsr_we_o    = ds_to_es_valid && es_allowin && inst_movgr2fcsr && !flush_sign;
assign fcsr_wdata_o = rj_value;
`else
wire fpr1_stall = 1'b0;
wire fpr2_stall = 1'b0;
wire fpr3_stall = 1'b0;
wire fcc_stall  = 1'b0;
wire fcsr_stall = 1'b0;
assign fcsr_we_o    = 1'b0;
assign fcsr_wdata_o = 32'b0;
`endif

//exe stage first forward
assign {rf1_forward_stall, rj_value, rj_value_forward_es} = ((rf_raddr1 == es_forward_reg) && es_forward_enable && inst_need_rj) ? {es_dep_need_stall, es_forward_data, es_forward_data} :
                                                            ((rf_raddr1 == ms_forward_reg) && ms_forward_enable && inst_need_rj) ? {ms_dep_need_stall || br_need_reg_data, ms_forward_data, rf_rdata1} :
                                                                                                                                   {1'b0, rf_rdata1, rf_rdata1}; 

assign {rf2_forward_stall, rkd_value, rkd_value_forward_es} = ((rf_raddr2 == es_forward_reg) && es_forward_enable && inst_need_rkd) ? {es_dep_need_stall, es_forward_data, es_forward_data} :
                                                              ((rf_raddr2 == ms_forward_reg) && ms_forward_enable && inst_need_rkd) ? {ms_dep_need_stall || br_need_reg_data, ms_forward_data, rf_rdata2} :
                                                                                                                                      {1'b0, rf_rdata2, rf_rdata2};

assign rj_eq_rd        = (rj_value_forward_es == rkd_value_forward_es);
assign rj_lt_rd_unsign = (rj_value_forward_es < rkd_value_forward_es);   //operate "<" has nice timing
assign rj_lt_rd_sign   = (rj_value_forward_es[31] && ~rkd_value_forward_es[31]) ? 1'b1 :
                         (~rj_value_forward_es[31] && rkd_value_forward_es[31]) ? 1'b0 : rj_lt_rd_unsign;                         
                                                            
assign br_taken  = (   inst_beq  &&  rj_eq_rd
                    || inst_bne  && !rj_eq_rd
                    || inst_blt  &&  rj_lt_rd_sign
                    || inst_bge  && !rj_lt_rd_sign
                    || inst_bltu &&  rj_lt_rd_unsign
                    || inst_bgeu && !rj_lt_rd_unsign
                    || inst_jirl
                    || inst_bl
                    || inst_b
                    `ifdef HAS_FPU
                    || inst_bceqz && !fcc_val
                    || inst_bcnez &&  fcc_val
                    `endif
                    ) && ds_valid && !ds_excp;

assign br_inst = br_need_reg_data || inst_bl || inst_b
                 `ifdef HAS_FPU
                 || inst_bceqz || inst_bcnez
                 `endif
                 ;

assign br_to_btb = inst_beq   ||
                   inst_bne   ||
                   inst_blt   ||
                   inst_bge   ||
                   inst_bltu  ||
                   inst_bgeu  ||
                   inst_bl    ||
                   inst_b     ||
                   inst_jirl
                   `ifdef HAS_FPU
                   || inst_bceqz || inst_bcnez
                   `endif
                   ;

assign br_need_reg_data = inst_beq   ||
                          inst_bne   ||
                          inst_blt   ||
                          inst_bge   ||
                          inst_bltu  ||
                          inst_bgeu  ||
                          inst_jirl
                          `ifdef HAS_FPU
                          || inst_bceqz || inst_bcnez
                          `endif
                          ;

assign br_target = ({32{inst_beq || inst_bne || inst_bl || inst_b ||
                    inst_blt || inst_bge || inst_bltu || inst_bgeu
                    `ifdef HAS_FPU
                    || inst_bceqz || inst_bcnez
                    `endif
                    }} & (ds_pc + ds_imm   ))            |
                   ({32{inst_jirl}}                                  & (rj_value_forward_es + ds_imm)) ;

//assign idle_stall = inst_idle & ds_valid & !has_int;

assign excp     = excp_ipe | inst_syscall | inst_break | ds_excp | excp_ine | has_int;
assign excp_num = {excp_ipe, excp_ine, inst_break, inst_syscall, ds_excp_num, has_int};

assign rd_csr_addr = inst_cpucfg ? (rj_value[13:0]+14'h00b0) : csr_idx;

//when cache operate icache, will refetch inst after this inst.
assign refetch = (inst_tlbwr || inst_tlbfill || inst_tlbrd || inst_invtlb || inst_ibar) && ds_valid;  //this inst will change addr trans 

assign tlb_inst_stall = es_tlb_inst_stall || ms_tlb_inst_stall || ws_tlb_inst_stall;

assign inst_valid = inst_add_w      |
                    inst_sub_w      |
                    inst_slt        |
                    inst_sltu       |
                    inst_nor        |
                    inst_and        |
                    inst_or         |
                    inst_xor        |
                    inst_sll_w      |
                    inst_srl_w      |
                    inst_sra_w      |
                    inst_mul_w      |
                    inst_mulh_w     |
                    inst_mulh_wu    |
                    inst_div_w      |
                    inst_mod_w      |
                    inst_div_wu     |
                    inst_mod_wu     |
                    inst_break      |
                    inst_syscall    |
                    inst_slli_w     |
                    inst_srli_w     |
                    inst_srai_w     |
                    inst_idle       |
                    inst_slti       |
                    inst_sltui      |
                    inst_addi_w     |
                    inst_andi       |
                    inst_ori        |
                    inst_xori       |
                    inst_ld_b       |
                    inst_ld_h       |
                    inst_ld_w       |
                    inst_st_b       |
                    inst_st_h       |
                    inst_st_w       |
                    inst_ld_bu      |
                    inst_ld_hu      |
                    inst_ll_w       |
                    inst_sc_w       |
                    inst_jirl       |
                    inst_b          |
                    inst_bl         |
                    inst_beq        |
                    inst_bne        |
                    inst_blt        |
                    inst_bge        |
                    inst_bltu       |
                    inst_bgeu       |
                    inst_lu12i_w    |
                    inst_pcaddu12i  |
                    inst_csrrd      |
                    inst_csrwr      |
                    inst_csrxchg    |
                    inst_rdcntid_w  |
                    inst_rdcntvh_w  |
                    inst_rdcntvl_w  |
                    inst_ertn       |
                    inst_valid_cacop|
                    inst_preld      |
                    inst_dbar       |
                    inst_ibar       |
                    inst_tlbsrch    |
                    inst_tlbrd      |
                    inst_tlbwr      |
                    inst_tlbfill    |
					inst_nop        |
                    inst_cpucfg     |
                    `ifdef HAS_LACC
                    lacc_req & lacc_valid |
                    `endif
                    `ifdef HAS_FPU
                    is_fpu_inst |
                    `endif
                    (inst_invtlb && (rd == 5'd0 ||
                                     rd == 5'd1 ||
                                     rd == 5'd2 ||
                                     rd == 5'd3 ||
                                     rd == 5'd4 ||
                                     rd == 5'd5 ||
                                     rd == 5'd6 ));  //invtlb valid op

assign excp_ine = ~inst_valid;

assign kernel_inst = inst_csrrd      |
                     inst_csrwr      |
                     inst_csrxchg    |
                     inst_valid_cacop & (rd[4:3] != 2'b10)|
                     inst_tlbsrch    |
                     inst_tlbrd      |
                     inst_tlbwr      |
                     inst_tlbfill    |
                     inst_invtlb     |
                     inst_ertn       |
                     inst_idle       ;

assign excp_ipe = kernel_inst && (csr_plv == 2'b11);

//branch slot cancel, need wait next valid inst after branch
//only valid br_taken sign can generate slot_cancel.
always @(posedge clk) begin
    if (reset || flush_sign) begin
    //flush signal need flush this buffer
        branch_slot_cancel <= 1'b0;
    end
    else if (btb_pre_error_flush && es_allowin && !fs_to_ds_valid) begin
        branch_slot_cancel <= 1'b1;
    end
    else if (branch_slot_cancel && fs_to_ds_valid) begin
        branch_slot_cancel <= 1'b0;
    end
end

assign btb_operate_en    = ds_valid && ds_ready_go && es_allowin && !ds_excp;
assign btb_operate_pc    = ds_pc;
assign btb_pop_ras       = inst_jirl; 
assign btb_push_ras      = inst_bl;
assign btb_add_entry     = br_to_btb && !ds_btb_en && br_taken;
assign btb_delete_entry  = !br_to_btb && ds_btb_en;
assign btb_pre_error     = br_to_btb && ds_btb_en && (ds_btb_taken ^ br_taken);
assign btb_target_error  = br_to_btb && ds_btb_en && (ds_btb_taken && br_taken) && (ds_btb_target != br_target);
assign btb_pre_right     = br_to_btb && ds_btb_en && !(ds_btb_taken ^ br_taken);
assign btb_right_orien   = br_taken;
assign btb_right_target  = br_target;
assign btb_operate_index = ds_btb_index;

assign btb_pre_error_flush = (btb_add_entry || btb_delete_entry || btb_pre_error || btb_target_error) && ds_valid && ds_ready_go && !ds_excp;
assign btb_pre_error_flush_target = br_taken ? br_target : ds_pc + 32'h4;

//ibar dbar
assign pipeline_no_empty = es_to_ds_valid || ms_to_ds_valid || ws_to_ds_valid || !write_buffer_empty || !dcache_empty;
assign dbar_stall = inst_dbar && pipeline_no_empty;
assign ibar_stall = inst_ibar && pipeline_no_empty;


// ll ldw ldhu ldh ldbu ldb
assign inst_ld_en = {2'b0, inst_ll_w, inst_ld_w, inst_ld_hu, inst_ld_h, inst_ld_bu, inst_ld_b};
// sc(llbit = 1) stw sth stb
assign inst_st_en = {4'b0, ds_llbit && inst_sc_w, inst_st_w, inst_st_h, inst_st_b};
assign inst_csr_rstat_en = (inst_csrrd || inst_csrwr || inst_csrxchg) && (csr_idx == 14'd5);

// debug
assign debug_rf_rdata1 = rf_raddr1;

endmodule
