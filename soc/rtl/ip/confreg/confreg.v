/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/
`define CONFREG_INT_ADDR    16'hf000 //1f20_f000
`define TIMER_ADDR          16'hf100 //1f20_f100
`define DIGITAL_ADDR        16'hf200 //1f20_f200
`define LED_ADDR            16'hf300 //1f20_f300
`define SWITCH_ADDR         16'hf400 //1f20_f400
`define SIMU_FLAG_ADDR      16'hf500 //1f20_f500 

module confreg #(
    parameter   SIMULATION=1'b0
)
(
    input           aclk,
    input           aresetn,

    input           cpu_clk,
    input           cpu_resetn,

    input  [4 :0]   s_awid,
    input  [31:0]   s_awaddr,
    input  [7 :0]   s_awlen,
    input  [2 :0]   s_awsize,
    input  [1 :0]   s_awburst,
    input           s_awlock,
    input  [3 :0]   s_awcache,
    input  [2 :0]   s_awprot,
    input           s_awvalid,
    output          s_awready,
    input  [4 :0]   s_wid,
    input  [63:0]   s_wdata_i,
    input  [7 :0]   s_wstrb_i,
    input           s_wlast,
    input           s_wvalid,
    output reg      s_wready,
    output [4 :0]   s_bid,
    output [1 :0]   s_bresp,
    output reg      s_bvalid,
    input           s_bready,
    input  [4 :0]   s_arid,
    input  [31:0]   s_araddr,
    input  [7 :0]   s_arlen,
    input  [2 :0]   s_arsize,
    input  [1 :0]   s_arburst,
    input           s_arlock,
    input  [3 :0]   s_arcache,
    input  [2 :0]   s_arprot,
    input           s_arvalid,
    output          s_arready,
    output [4 :0]   s_rid,
    output [63:0]   s_rdata_o,
    output [1 :0]   s_rresp,
    output reg      s_rlast,
    output reg      s_rvalid,
    input           s_rready,

    output     [15:0] led,
    output      [7:0] dpy0,
    output      [7:0] dpy1,
    input      [31:0] switch,
    input      [3 :0] touch_btn,
    input             dma_finish,
    input             fft_finish,
    output            confreg_int
);

// 总线 64 位而本模块按 32 位寄存器组织。它只服务单拍寄存器访问，位宽适配退化成"选半字"：
// 写侧用 wstrb 判断数据落在哪半（与数据同拍到达，不依赖 AW/W 两通道的先后），
// 读侧两半填同值、由 master 按 addr[2] 取。
wire        w_hi = |s_wstrb_i[7:4];
wire [31:0] s_wdata = w_hi ? s_wdata_i[63:32] : s_wdata_i[31:0];
reg  [31:0] s_rdata;
assign s_rdata_o = {s_rdata, s_rdata};

wire [3:0] touch_btn_data;//按键中断信号，上升沿触发
reg  [31:0] led_data;
wire [31:0] switch_data;
reg  [31:0] simu_flag;

reg [31:0] confreg_int_en,confreg_int_edge,confreg_int_pol,confreg_int_clr,confreg_int_set;
wire [31:0] confreg_int_state;

reg [31:0] sys_timer,sys_timer_cmp;
reg sys_timer_en;
reg timer_int;//定时器中断信号，高电平触发

reg [31:0] digital_ctrl;
reg [31:0] digital_data;


reg busy,write,R_or_W;

wire ar_enter = s_arvalid & s_arready;
wire r_retire = s_rvalid & s_rready & s_rlast;
wire aw_enter = s_awvalid & s_awready;
wire w_enter  = s_wvalid & s_wready & s_wlast;
wire b_retire = s_bvalid & s_bready;

assign s_arready = ~busy & (!R_or_W| !s_awvalid);
assign s_awready = ~busy & ( R_or_W| !s_arvalid);

always@(posedge aclk)
    if(~aresetn) busy <= 1'b0;
    else if(ar_enter|aw_enter) busy <= 1'b1;
    else if(r_retire|b_retire) busy <= 1'b0;

reg [4 :0] buf_id;
reg [31:0] buf_addr;
reg [7 :0] buf_len;
reg [2 :0] buf_size;
reg [1 :0] buf_burst;
reg        buf_lock;
reg [3 :0] buf_cache;
reg [2 :0] buf_prot;

always@(posedge aclk)
    if(~aresetn) begin
        R_or_W      <= 1'b0;
        buf_id      <= 'b0;
        buf_addr    <= 'b0;
        buf_len     <= 'b0;
        buf_size    <= 'b0;
        buf_burst   <= 'b0;
        buf_lock    <= 'b0;
        buf_cache   <= 'b0;
        buf_prot    <= 'b0;
    end
    else
    if(ar_enter | aw_enter) begin
        R_or_W      <= ar_enter;
        buf_id      <= ar_enter ? s_arid   : s_awid   ;
        buf_addr    <= ar_enter ? s_araddr : s_awaddr ;
        buf_len     <= ar_enter ? s_arlen  : s_awlen  ;
        buf_size    <= ar_enter ? s_arsize : s_awsize ;
        buf_burst   <= ar_enter ? s_arburst: s_awburst;
        buf_lock    <= ar_enter ? s_arlock : s_awlock ;
        buf_cache   <= ar_enter ? s_arcache: s_awcache;
        buf_prot    <= ar_enter ? s_arprot : s_awprot ;
    end

always@(posedge aclk)
    if(~aresetn) write <= 1'b0;
    else if(aw_enter) write <= 1'b1;
    else if(ar_enter)  write <= 1'b0;

always@(posedge aclk)
    if(~aresetn) s_wready <= 1'b0;
    else if(aw_enter) s_wready <= 1'b1;
    else if(w_enter & s_wlast) s_wready <= 1'b0;

wire [31:0] rdata_d =   buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h0)     ? confreg_int_en        : 
                        buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h4)     ? confreg_int_edge      : 
                        buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h8)     ? confreg_int_pol       : 
                        buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'hc)     ? confreg_int_clr       : 
                        buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h10)    ? confreg_int_set       : 
                        buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h14)    ? confreg_int_state     : 
                        buf_addr[15:0] == (`TIMER_ADDR + 16'h0)           ? sys_timer             : 
                        buf_addr[15:0] == (`TIMER_ADDR + 16'h4)           ? sys_timer_cmp         :
                        buf_addr[15:0] == (`TIMER_ADDR + 16'h8)           ? sys_timer_en          :
                        buf_addr[15:0] == (`DIGITAL_ADDR + 16'h0)         ? digital_ctrl          :
                        buf_addr[15:0] == (`DIGITAL_ADDR + 16'h4)         ? digital_data          :
                        buf_addr[15:0] == `LED_ADDR                       ? led_data              :
                        buf_addr[15:0] == `SWITCH_ADDR                    ? switch_data           :
                        buf_addr[15:0] == `SIMU_FLAG_ADDR                 ? simu_flag             :
                        32'd0;

always@(posedge aclk)
    if(~aresetn) begin
        s_rdata  <= 'b0;
        s_rvalid <= 1'b0;
        s_rlast  <= 1'b0;
    end
    else if(busy & !write & !r_retire)
    begin
        s_rdata <= rdata_d;
        s_rvalid <= 1'b1;
        s_rlast <= 1'b1; 
    end
    else if(r_retire)
    begin
        s_rvalid <= 1'b0;
    end

always@(posedge aclk)   
    if(~aresetn) s_bvalid <= 1'b0;
    else if(w_enter) s_bvalid <= 1'b1;
    else if(b_retire) s_bvalid <= 1'b0;

assign s_rid   = buf_id;
assign s_bid   = buf_id;
assign s_bresp = 2'b0;
assign s_rresp = 2'b0;


//-------------------------------{touch_btn}begin----------------------------//
// 按键进入中断路径前先做消抖，避免板级按键抖动导致重复中断。
genvar gi;
generate for(gi=0;gi<4;gi=gi+1) begin: generate_btn_debounce
    key_debounce u_key_debounce(
        .sys_clk(aclk),
        .key(touch_btn[gi]),
        .key_out(touch_btn_data[gi])
    );
end
endgenerate


//--------------------------------{touch_btn}end-----------------------------//

//-------------------------------{timer}begin----------------------------//

wire write_timer_cmp = w_enter & (buf_addr[15:0]==`TIMER_ADDR+16'h4);
wire write_timer_en  = w_enter & (buf_addr[15:0]==`TIMER_ADDR+16'h8);

always @(posedge aclk) begin
    if(!aresetn) begin
        sys_timer_cmp <= 32'h0;
    end
    else if (write_timer_cmp) begin
        sys_timer_cmp <= s_wdata;
    end
end

always @(posedge aclk) begin
    if(!aresetn) begin
        sys_timer_en <= 1'b0;
    end
    else if (write_timer_en) begin
        sys_timer_en <= s_wdata[0];
    end
end

always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        sys_timer <= 32'h0;
        timer_int <= 1'b0;
    end
    else if (sys_timer_en) begin
        if (sys_timer >= sys_timer_cmp - 1) begin
            sys_timer <= 32'h0;
            timer_int <= 1'b1;
        end else begin
            sys_timer <= sys_timer + 1'b1;
        end
    end
    else begin
        sys_timer <= 32'h0;
        timer_int <= 1'b0;
    end
end
//--------------------------------{timer}end-----------------------------//

//--------------------------------{led}begin-----------------------------//
//led display
//led_data[31:0]
wire write_led = w_enter & (buf_addr[15:0]==`LED_ADDR);
assign led = led_data[15:0];
always @(posedge aclk)
begin
    if(!aresetn)
    begin
        led_data <= 32'h0;
    end
    else if(write_led)
    begin
        led_data <= s_wdata[31:0];
    end
end
//---------------------------------{led}end------------------------------//

//-------------------------------{switch}begin---------------------------//
//switch data
//switch_data[31:0]
assign switch_data = switch;
//--------------------------------{switch}end----------------------------//


//---------------------------{digital number}begin-----------------------//
wire write_digital_ctrl   = w_enter & (buf_addr[15:0]==`DIGITAL_ADDR + 16'h0);
wire write_digital_data   = w_enter & (buf_addr[15:0]==`DIGITAL_ADDR + 16'h4);

always @(posedge aclk) begin
    if(!aresetn) begin
        digital_ctrl <= 32'd0;
    end
    else if (write_digital_ctrl) begin
        digital_ctrl <= s_wdata;
    end
end

always @(posedge aclk) begin
    if(!aresetn) begin
        digital_data <= 32'd0;
    end
    else if (write_digital_data) begin
        digital_data <= s_wdata;
    end
end

wire [31:0] digital_data_in = digital_data;
digitaltube_controller  u_digitaltube_controller (
    .control_reg             ( digital_ctrl   ),
    .clk                     ( aclk           ),
    .rst_n                   ( aresetn         ),

    .dpy0                    ( dpy0          ),
    .dpy1                    ( dpy1          ),

    .data_reg                ( digital_data_in      )
);

//----------------------------{digital number}end------------------------//

//--------------------------{simulation flag}begin-----------------------//
always @(posedge aclk)
begin
    if(!aresetn) begin
        simu_flag <= {32{SIMULATION}};
    end
    else begin
        simu_flag <= {32{SIMULATION}};
    end
end
//---------------------------{simulation flag}end------------------------//

//-------------------------------{int_ctrl}begin----------------------------//
// AXI write decode for interrupt controller registers.
wire write_int_en   = w_enter & (buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h0 ));
wire write_int_edge = w_enter & (buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h4 ));
wire write_int_pol  = w_enter & (buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h8 ));
wire write_int_clr  = w_enter & (buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'hc ));
wire write_int_set  = w_enter & (buf_addr[15:0] == (`CONFREG_INT_ADDR + 16'h10));

// int_in mapping:
// [3:0] = touch button interrupts, [4] = timer interrupt, others reserved.
// 暂时没有接入其他中断信号如fft和dma，目前只有四个button输入和一个timer输入，预留其他中断输入位以便后续扩展。
wire [31:0] int_in = {27'b0, timer_int, touch_btn_data};
wire [31:0] int_clr_pulse = write_int_clr ? s_wdata : 32'b0;
wire [31:0] int_set_pulse = write_int_set ? s_wdata : 32'b0;

reg  [31:0] int_in_d;
reg  [31:0] confreg_int_state_r;
integer i;

always @(posedge aclk) begin
    if(!aresetn) begin
        confreg_int_en      <= 32'b0;
        confreg_int_edge    <= 32'b0;
        confreg_int_pol     <= 32'b0;
        confreg_int_clr     <= 32'b0;
        confreg_int_set     <= 32'b0;
        confreg_int_state_r <= 32'b0;
        int_in_d            <= 32'b0;
    end
    else begin
        // Software-visible configuration registers.
        if(write_int_en) begin
            confreg_int_en <= s_wdata;
        end
        if(write_int_edge) begin
            confreg_int_edge <= s_wdata;
        end
        if(write_int_pol) begin
            confreg_int_pol <= s_wdata;
        end

        // clr/set are one-cycle write pulses. Readback shows last pulse value.
        confreg_int_clr <= int_clr_pulse;
        confreg_int_set <= int_set_pulse;

        // Previous sample for edge detection.
        int_in_d <= int_in;

        for(i = 0; i < 32; i = i + 1) begin
            if(!confreg_int_en[i]) begin
                confreg_int_state_r[i] <= 1'b0;
            end
            else if(confreg_int_edge[i]) begin
                // Edge-triggered source:
                //  - int_pol=1: rising edge
                //  - int_pol=0: falling edge
                // State is latched until clr pulse clears it.
                if(int_clr_pulse[i]) begin
                    confreg_int_state_r[i] <= 1'b0;
                end
                else if(int_set_pulse[i]) begin
                    confreg_int_state_r[i] <= 1'b1;
                end
                else if(confreg_int_pol[i]) begin
                    if(~int_in_d[i] & int_in[i]) begin
                        confreg_int_state_r[i] <= 1'b1;
                    end
                end
                else begin
                    if(int_in_d[i] & ~int_in[i]) begin
                        confreg_int_state_r[i] <= 1'b1;
                    end
                end
            end
            else begin
                // Level-triggered source:
                //  - int_pol=1: active high
                //  - int_pol=0: active low
                if(confreg_int_pol[i]) begin
                    confreg_int_state_r[i] <= int_in[i];
                end
                else begin
                    confreg_int_state_r[i] <= ~int_in[i];
                end
            end
        end
    end
end

assign confreg_int_state = confreg_int_state_r;

// Merge all active interrupt sources to one request and synchronize to cpu_clk.
wire confreg_int_req = |confreg_int_state_r;
reg confreg_int_meta, confreg_int_sync;
always @(posedge cpu_clk or negedge cpu_resetn) begin
    if(!cpu_resetn) begin
        confreg_int_meta <= 1'b0;
        confreg_int_sync <= 1'b0;
    end
    else begin
        confreg_int_meta <= confreg_int_req;
        confreg_int_sync <= confreg_int_meta;
    end
end

assign confreg_int = confreg_int_sync;

//--------------------------------{int_ctrl}end-----------------------------//

endmodule
