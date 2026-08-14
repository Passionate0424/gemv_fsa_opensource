#include <stdio.h> 
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "ConvFuncs.h"
#include "weights.h"
#include "test_image.h"
#include "common_func.h"


//BSP板级支持包所需全局变量
unsigned long UART_BASE = 0xbf000000;					//UART16550的虚地址
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;			//CONFREG计数器的虚地址
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;		//CONFREG时钟频率
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;			//处理器核时钟频率

int start = 0;


void InterruptInit(void)
{
    // Enable button and timer Interrupt
	RegWrite(0xbf20f004,0x0f);//edge
	RegWrite(0xbf20f008,0x1f);//pol
	RegWrite(0xbf20f00c,0x1f);//clr
	RegWrite(0xbf20f000,0x1f);//en
}

void HWI0_IntrHandler(void)
{	
	unsigned int int_state;
	int_state = RegRead(0xbf20f014);

	if(int_state & 0xf){
		Button_IntrHandler(int_state & 0xf);
	}
}

void Button_IntrHandler(unsigned char button_state)
{
	if((button_state & 0b0001) == 0b0001){
		start = 1;
		RegWrite(0xbf20f00c,0x1);//clr
	}
}


int compare(int32_t* dut, int32_t* ref, int size) {
	for (int i = 0; i < size; i++) {
		if (dut[i] != ref[i]) {
			printf("Error at index %d: expected %d, got %d, %x\n", i, ref[i], dut[i], (uint32_t)&dut[i]);
			return 1;
		}
	}
	return 0;
}

void printImage(int8_t* image, int height, int width) {
	for (int i = 0; i < height; i++) {
		for (int j = 0; j < width; j++) {
			printf("%d ", image[i * width + j] != -1);
		}
		printf("\n");
	}
	printf("\n");	
}

void flush_dcache(int size) {
	for (int i = 0; i < size; i++) {
		int index = size << 4;
		init_dcache_line(index);
	}
}

int  simu_flag;

int main(int argc, char** argv) {
	InterruptInit();
	simu_flag = RegRead(0xbf20f500);

	int32_t conv1_out[6][28][28] = { 0 };
	int32_t pool1_out[6][14][14] = { 0 };
	int32_t conv2_out[16][12][12] = { 0 };
	int32_t pool2_out[16][6][6] = { 0 };
	int32_t fc1_out[10] = { 0 };
	int acc = 0;
	int begin_clk, end_clk;

	int32_t accel_conv1_out[6][28][28];
	int32_t accel_pool1_out[6][14][14] = { 0 };
	int32_t accel_conv2_out[16][12][12] = { 0 };
	int32_t accel_pool2_out[16][6][6] = { 0 };
	int32_t accel_fc1_out[10] = { 0 };

	int test_idx = 0;
	int test_num = 0;

	printf("image num: %d\n", TEST_IMAGE_SIZE);

	int clk, ret;
	while (1) {
		if(!simu_flag) delay_ms(200);
		if (start | simu_flag) {
			start = 0;
			printf("start\n");
			int gold_clk = 0;
			if (!simu_flag) {
				printImage(test_image[test_idx], 28, 28);

				flush_dcache(256);

				gold_clk = clock();
				conv_func(test_image[test_idx], w_conv1, b_conv1, conv1_out, 0, 28, 28, 1, 1, 6, 3, 3);
				relu_int(&conv1_out, 6 * 28 * 28);
				pool_func(conv1_out, pool1_out, 6, 28, 28);
				conv_func(pool1_out, w_conv2, b_conv2, conv2_out, 2, 14, 14, 0, 6, 16, 3, 3);
				relu_int(&conv2_out, 16 * 12 * 12);
				pool_func(conv2_out, pool2_out, 16, 12, 12);
				linear_func(pool2_out, w_fc1, b_fc1, fc1_out, 576, 10);
				gold_clk = clock() - gold_clk;

				flush_dcache(256);

			}

			clk = clock();
			accel_conv_func(test_image[test_idx], w_conv1, b_conv1, accel_conv1_out, 0, 28, 28, 1, 1, 6, 3, 3, 1);
			accel_pool_func(accel_conv1_out, accel_pool1_out, 2, 6, 28, 28);
			accel_conv_func(accel_pool1_out, w_conv2_rev, b_conv2, accel_conv2_out, 2, 14, 14, 0, 6, 16, 3, 3, 1);
			accel_pool_func(accel_conv2_out, accel_pool2_out, 2, 16, 12, 12);
			accel_linear_func(accel_pool2_out, w_fc1, b_fc1, accel_fc1_out, 576, 10);
			clk = clock() - clk;

			int index = 0;
			float max = accel_fc1_out[0];
			for (int j = 1; j < 10; j++) {
				if (accel_fc1_out[j] > max) {
					index = j;
					max = accel_fc1_out[j];
				}
			}
			printf("recognized number: %d\n", index);
			if (index == test_target[test_idx]) acc++;
			test_num++;
			test_idx = (test_idx + 1) % TEST_IMAGE_SIZE;
			if (simu_flag) {
				printf("Accuracy: %d/%d, clk: %d\n", 
						acc, test_num, clk);
			} else {
				printf("Accuracy: %d/%d, gold_clk: %d, clk: %d speedup: %f\n", 
						acc, test_num, gold_clk, clk, (float)gold_clk/(float)clk);
			}
            if (simu_flag) break;
		}
	}

	return 0;
}