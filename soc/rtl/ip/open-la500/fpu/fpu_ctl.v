// FPU Control/Status Register (FCSR) & Floating-point Condition Codes (FCC)
// FCC[7:0] — 8 condition code bits, updated by fcmp.cond.s, read by bceqz/bcnez
//
// FCSR 软件读写 (movgr2fcsr/movfcsr2gr):
//   LoongArch FCSR 位布局: [28:24]=Cause, [20:16]=Flags{NV,DZ,OF,UF,NX},
//                          [9:8]=RM(舍入模式), [4:0]=Enables(陷阱使能)
//   注意: 内部喂给 CVFPU 的 rm 是 RISC-V 3-bit 编码, 与 LA 的 2-bit 编码不同,
//         读写时必须翻译 (见 la2cv_rm / cv2la_rm)。
module fpu_ctl(
    input         clk,
    input         reset,
    // FCC write (from async FPU response)
    input         fcc_we,
    input  [ 4:0] fcc_fj,       // fj register number (lower 5 bits determine FCC bit index)
    input         fcc_result,    // comparison result (0 or 1)
    // FCC read (from ID stage for bceqz/bcnez)
    input  [ 2:0] fcc_idx,      // which FCC bit to read
    output        fcc_val,       // FCC[fcc_idx]

    // [AI FPU Refactor] FCSR Extensions
    output [ 2:0] fcsr_rm,     // Rounding mode exposed to pipeline (CVFPU 3-bit 编码)
    input         fpu_flags_we,// Write enable for exception flags
    input  [ 4:0] fpu_flags,   // Exceptions: {NV, DZ, OF, UF, NX}

    // FCSR 软件读写 (movgr2fcsr 写 / movfcsr2gr 读, 均为 LA FCSR 布局)
    input         fcsr_we,     // 软件写使能 (movgr2fcsr)
    input  [31:0] fcsr_wdata,  // 软件写数据 (来自 GPR[rj])
    output [31:0] fcsr_rdata   // 软件读数据 (送往 GPR[rd])
);

reg [7:0] fcc;
reg [4:0] fcsr_cause;
reg [4:0] fcsr_flags;
reg [2:0] fcsr_rm_reg;
reg [4:0] fcsr_enables;

// LA 2-bit 舍入模式 → CVFPU 3-bit (RISC-V frm) 编码翻译
//   LA: 00=RNE, 01=RZ(向零), 10=RP(向+∞), 11=RM(向-∞)
//   CV: 000=RNE,001=RTZ,    011=RUP,      010=RDN
function [2:0] la2cv_rm(input [1:0] la);
    case (la)
        2'b00:   la2cv_rm = 3'b000; // RNE
        2'b01:   la2cv_rm = 3'b001; // RZ  -> RTZ
        2'b10:   la2cv_rm = 3'b011; // RP  -> RUP (+∞)
        2'b11:   la2cv_rm = 3'b010; // RM  -> RDN (-∞)
        default: la2cv_rm = 3'b000;
    endcase
endfunction

// CVFPU 3-bit → LA 2-bit 舍入模式 (movfcsr2gr 读回时用)
function [1:0] cv2la_rm(input [2:0] cv);
    case (cv)
        3'b000:  cv2la_rm = 2'b00; // RNE
        3'b001:  cv2la_rm = 2'b01; // RTZ -> RZ
        3'b011:  cv2la_rm = 2'b10; // RUP -> RP
        3'b010:  cv2la_rm = 2'b11; // RDN -> RM
        default: cv2la_rm = 2'b00;
    endcase
endfunction

always @(posedge clk) begin
    if (reset) begin
        fcc <= 8'b0;
        fcsr_cause <= 5'b0;
        fcsr_flags <= 5'b0;
        fcsr_rm_reg <= 3'b000; // Default to RNE (Round to Nearest, ties to Even)
        fcsr_enables <= 5'b0;
    end else begin
        if (fcc_we) begin
            // fcmp.cond.s writes result to FCC[fcc_fj[2:0]]
            fcc[fcc_fj[2:0]] <= fcc_result;
        end
        // 软件写 FCSR 优先级最高: id_stage 的 fcsr_stall 已串行化保证此刻无在途
        // FPU 响应, 故 fcsr_we 与 fpu_flags_we 不会同周期冲突。
        if (fcsr_we) begin
            fcsr_enables <= fcsr_wdata[ 4: 0];
            fcsr_rm_reg  <= la2cv_rm(fcsr_wdata[9:8]);
            fcsr_flags   <= fcsr_wdata[20:16];
            fcsr_cause   <= fcsr_wdata[28:24];
        end else if (fpu_flags_we) begin
            fcsr_cause <= fpu_flags;               // Cause = 本次运算异常
            fcsr_flags <= fcsr_flags | fpu_flags;  // Flags 为累积粘滞位
        end
    end
end

// write-first 旁路: fcc 为同步写, 而 id_stage 的 fcc_stall 会在 fcc_we 同周期放行 bceqz,
// 此时 fcc 寄存器尚未更新。与 fpu_regfile 的读旁路保持一致, 当本周期正在写入且
// 写入索引与读取索引相同时, 直接前递 fcc_result, 避免 bceqz 读到旧值。
assign fcc_val = (fcc_we && fcc_fj[2:0] == fcc_idx) ? fcc_result : fcc[fcc_idx];
assign fcsr_rm = fcsr_rm_reg;

// movfcsr2gr 读回, 组装成 LA FCSR 布局 (rm 翻译回 LA 2-bit)
assign fcsr_rdata = {3'b0, fcsr_cause, 3'b0, fcsr_flags, 6'b0,
                     cv2la_rm(fcsr_rm_reg), 3'b0, fcsr_enables};

endmodule
