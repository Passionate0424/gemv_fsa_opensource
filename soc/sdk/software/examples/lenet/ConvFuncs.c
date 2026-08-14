#include "ConvFuncs.h"

void conv_func(int8_t* d_i, int8_t* weight, int32_t* bias, int32_t* d_o, int8_t di_type,
                int height, int width, int padding, int channel, int out_channel, 
                int kernel_width, int kernel_height) {
	// 使用多重循环卷积(BUF_HEIGHT - KERNEL_SIZE + PADDING * 2) / STRIDE + 1
    int16_t* d_16 = (int16_t*)d_i;
    int32_t* d_32 = (int32_t*)d_i;
    int height_o = (height - kernel_height + padding * 2) + 1;
    int width_o = (width - kernel_width + padding * 2) + 1;
	for (int c = 0; c < out_channel; c++) {
		for (int h = -padding; h < (height - kernel_height + padding) + 1; h++) {
			for (int w = -padding; w < (width - kernel_width + padding) + 1; w++) {
                int32_t sum = 0;
                for(int k = 0; k < channel; k++) {
                    for (int m = 0; m < kernel_height; m++) {
                        for (int n = 0; n < kernel_width; n++) {
                            int h_m = h + m;
                            int w_n = w + n;
                            if (h_m >= 0 && h_m < height && w_n >= 0 && w_n < width) {
                                if(di_type == 0){
                                    sum += d_i[(k * height + h_m) * width + w_n] * 
                                        weight[((c * channel + k) * kernel_height + m) * kernel_width + n];
                                } else if (di_type == 1) {
                                    sum += d_16[(k * height + h_m) * width + w_n] * 
                                        weight[((c * channel + k) * kernel_height + m) * kernel_width + n];
                                } else if (di_type == 2) {
                                    sum += d_32[(k * height + h_m) * width + w_n] * 
                                        weight[((c * channel + k) * kernel_height + m) * kernel_width + n];
                                }
                            }
                        }
                    }
                }
                d_o[c * height_o * width_o + (h+padding) * width_o + w + padding] = sum + bias[c];
			}
		}
	}
}

void pool_func(int32_t* d_i, int32_t* d_o, int channel, int height, int width) {
	for (int c = 0; c < channel; c++) {
		for (int h = 0; h < height / 2; h++) {
			for (int w = 0; w < width / 2; w++) {
				int32_t sum = d_i[(c * height + (h << 1)) * width + (w << 1)] +
                              d_i[(c * height + (h << 1) + 1) * width + (w << 1)] +
                              d_i[(c * height + (h << 1)) * width + (w << 1) + 1] +
                              d_i[(c * height + (h << 1) + 1) * width + (w << 1) + 1];
				if(sum > 0) d_o[(c * height / 2 + h) * (width / 2) + w] = sum >> 2;
                else d_o[(c * height / 2 + h) * (width / 2) + w] = 0;
			}
		}
	}
}

void linear_func(
	int32_t* d_i, 
	int8_t* weight, 
	int32_t* bias, 
	int32_t* output, 
	int input_size, 
	int output_size) {
	
	for (int i = 0; i < output_size; i++) {
		output[i] = bias[i];
		for (int j = 0; j < input_size; j++) {
			output[i] += d_i[j] * weight[i * input_size + j];
		}
	}
}

void relu_int(int32_t *x, int size) {
    for (int i = 0; i < size; i++) {
        if (x[i] < 0) {
            x[i] = 0;
        }
    }
}

void softmax(int32_t *x, float *output, int size) {
    int32_t max = x[0];
    for (int i = 1; i < size; i++) {
        if (x[i] > max) {
            max = x[i];
        }
    }

    float sum = 0;
    for (int i = 0; i < size; i++) {
        output[i] = exp((float)(x[i] - max)) ;
        sum += output[i];
    }

    for (int i = 0; i < size; i++) {
        output[i] /= sum;
    }
}