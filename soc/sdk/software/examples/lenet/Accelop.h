#ifndef __ACCEL__OP__H__
#define __ACCEL__OP__H__
#include <stdint.h>
// #define LACC_OP

typedef struct {
	union {
		struct {
			uint32_t buf_refresh: 1;
			uint32_t wadd: 1;
			uint32_t padding_valid: 4;
			uint32_t weight_size: 2;
			uint32_t buf_size: 2;
			uint32_t kernel_width: 3;
			uint32_t kernel_height: 3;
			uint32_t buf_width: 5;
			uint32_t buf_height: 4;
			uint32_t stride: 2;
			uint32_t kernel_num: 3;
			uint32_t padding: 2;
		};
		uint32_t val;
	};
}accel_conf_t;

#define MAX_KERNEL_NUM 3
#define MAx_KERNEL_WIDTH 3
#define MAX_KERNEL_HEIGHT 3
#define MAX_BUF_WIDTH 32
#define MAX_BUF_HEIGHT 8

void inst_conf_buf(uint32_t addr, uint32_t para) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x0, $r0, %[addr], %[para], 0x0\n\t"
		::[addr]"r"(addr), [para]"r"(para)
	);
#else
	asm volatile (
		"move $r5, %[addr]\n\t"
		"move $r6, %[para]\n\t"
		".word 0xc00018a0\n\t"
		::[addr]"r"(addr),[para]"r"(para)
		:"$r5", "$r6"
	);
#endif
}

void inst_conf_res_addr(uint32_t waddr, uint32_t idx) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x1, $r0, %[addr], %[idx], 0x5\n\t"
		::[addr]"r"(waddr), [idx]"r"(idx)
	);
#else
	asm volatile (
		"move $r5, %[addr]\n\t"
		"move $r6, %[idx]\n\t"
		".word 0xc04298a0\n\t"
		::[addr]"r"(waddr), [idx]"r"(idx)
		:"$r5", "$r6"
	);
#endif
}

void inst_conf_res_bias(uint32_t bias, uint32_t idx) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x1, $r0, %[bias], %[idx], 0x2\n\t"
		::[bias]"r"(bias), [idx]"r"(idx)
	);
#else
	asm volatile (
		"move $r5, %[addr]\n\t"
		"move $r6, %[idx]\n\t"
		".word 0xc04118a0\n\t"
		::[addr]"r"(bias), [idx]"r"(idx)
		:"$r5", "$r6"
	);
#endif
}

typedef void (*inst_conv_ptr_t)(uint32_t);

void inst_conv(uint32_t weight_addr) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x2, $r0, %[addr], $r0, 0x1\n\t"
		::[addr]"r"(weight_addr)
	);
#else
	asm volatile (
		"move $r5, %[addr]\n\t"
		".word 0xc08080a0\n\t"
		::[addr]"r"(weight_addr)
		: "$r5"
	);
#endif
}

void inst_conv_relu(uint32_t weight_addr) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x2, $r0, %[addr], $r0, 0x5\n\t"
		::[addr]"r"(weight_addr)
	);
#else
	asm volatile (
		"move $r5, %[addr]\n\t"
		".word 0xc08280a0\n\t"
		::[addr]"r"(weight_addr)
		: "$r5"
	);
#endif
}

#define POOL_MODE_MIN 0
#define POOL_MODE_MAX 1
#define POOL_MODE_AVG 2

void inst_pool(int pool_mode) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x2, $r0, %[pool_mode], $r0, 0x2\n\t"
		::[pool_mode]"r"(pool_mode)
	);
#else
	asm volatile (
		"move $r5, %[pool_mode]\n\t"
		".word 0xc08100a0\n\t"
		::[pool_mode]"r"(pool_mode)
		:"$r5"
	);
#endif
}

void inst_conf_offset(uint32_t buf_offset, uint32_t res_offset) {
#ifdef LACC_OP
	asm volatile (
		"lacc 0x3, $r0, %[buf_offset], %[res_offset], 0x0\n\t"
		::[buf_offset]"r"(buf_offset), [res_offset]"r"(res_offset)
	);
#else
	asm volatile (
		"move $r5, %[buf_offset]\n\t"
		"move $r6, %[res_offset]\n\t"
		".word 0xc0c018a0"
		::[buf_offset]"r"(buf_offset),[res_offset]"r"(res_offset)
		:"$r5", "$r6"
	);
#endif
}

#endif