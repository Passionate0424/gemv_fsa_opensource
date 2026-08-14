#ifndef __CONV_FUNCS_H__
#define __CONV_FUNCS_H__
#include <stdint.h>

void conv_func(int8_t* d_i, int8_t* weight, int32_t* bias, int32_t* d_o, int8_t di_type,
                int height, int width, int padding, int channel, int out_channel, 
                int kernel_width, int kernel_height);

void pool_func(int32_t* d_i, int32_t* d_o, int channel, int height, int width);

void linear_func(int32_t* d_i, int8_t* weight, int32_t* bias, int32_t* output, int input_size, int output_size);

void relu_int(int32_t *x, int size);

void softmax(int32_t *x, float *output, int size);
#endif