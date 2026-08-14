#ifndef __ACCEL__CONV__FUNCS__H__
#define __ACCEL__CONV__FUNCS__H__
#include "Accelop.h"

void accel_conv_func(int8_t* d_i, int8_t* weight, int32_t* bias, int32_t* d_o, int8_t di_type,
                int height, int width, int padding, int channel, int out_channel, 
                int kernel_width, int kernel_height, int with_relu);

void accel_pool_func(int32_t* d_i, int32_t* d_o, int pool_mode, int channel, int height, int width);

void accel_linear_func(int32_t* d_i, int8_t* weight, int32_t* bias, 
                        int32_t* output, int input_size, int output_size);

#endif