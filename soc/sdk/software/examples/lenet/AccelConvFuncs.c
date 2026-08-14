#include "AccelConvFuncs.h"

void accel_conv_func(int8_t* d_i, int8_t* weight, int32_t* bias, int32_t* d_o, int8_t di_type,
                int height, int width, int padding, int channel, int out_channel, 
                int kernel_width, int kernel_height, int with_relu) {
    accel_conf_t accel_conf;
    accel_conf.buf_size = di_type;
    accel_conf.weight_size = 0;
    accel_conf.padding = padding;
    accel_conf.stride = 1;
    accel_conf.kernel_height = kernel_height;
    accel_conf.kernel_width = kernel_width;

    int size_mul = di_type == 0b10 ? 4 :
                   di_type == 0b01 ? 2 : 1;
    int buf_mul = di_type == 0b10 ? 1 :
                  di_type == 0b01 ? 2 : 4;

    int del_h = kernel_height - 1;
    int del_w = (kernel_width - 1) * size_mul;

    int size_sft = size_mul >> 1;
    int buf_sft = buf_mul >> 1;
    int width_i = width * size_mul;
    int height_o = (height - kernel_height + padding * 2) + 1;
    int width_o = ((width - kernel_width + padding * 2) + 1);


    int h_append = 0;
    int res_h = 0;
    for (int h = 0; h < height; h += h_append) {
        int h_eq_0 = h == 0;
        h_append = h_eq_0 ? MAX_BUF_HEIGHT : MAX_BUF_HEIGHT - del_h;
        int h_remain = height - h;
        int buf_h_end = h_remain <= h_append;
        int buf_h;
        int begin_h = h_eq_0 ? 0 : h - del_h;
        if (buf_h_end) {
            if (h_eq_0) buf_h = h_remain;
            else buf_h = h_remain + del_h;
        } else {
            buf_h = MAX_BUF_HEIGHT;
        }
        accel_conf.buf_height = buf_h - 1;
        int res_h_append = (buf_h - kernel_height + (h_eq_0 + buf_h_end) * padding) + 1;

        int w_append = 0;
        int res_w = 0;
        for (int w = 0; w < width_i; w += w_append) {
            int w_eq_0 = w == 0;
            w_append = w_eq_0 ? MAX_BUF_WIDTH : MAX_BUF_WIDTH - del_w;
            int w_remain = width_i - w;
            int buf_w_end = w_remain <= w_append;
            int buf_w;
            int begin_w = w_eq_0 ? 0 : w - del_w;
            if (buf_w_end) {
                if (w_eq_0) {
                    buf_w = w_remain;
                } else { 
                    buf_w = (w_remain + del_w);
                }
            } else {
                buf_w = MAX_BUF_WIDTH;
            }
            int padding_valid = (w_eq_0) |
                                (buf_w_end << 1) |
                                (h_eq_0 << 2) |
                                (buf_h_end << 3);
            int buf_offset = width_i - buf_w;
            int res_w_append = ((buf_w >> size_sft) - kernel_width + (w_eq_0 + buf_w_end) * padding) + 1;
            int res_offset = (width_o - res_w_append) << size_sft;
            int res_buf_info = ((res_w_append - 1) << 16) | res_offset;
            inst_conf_offset(buf_offset, res_buf_info);

            accel_conf.buf_width = buf_w - 1;
            accel_conf.padding_valid = padding_valid;
            for (int k = 0; k < channel; k++) {
                accel_conf.buf_refresh = 1;
                accel_conf.wadd = k != 0;
                for (int c = 0; c < out_channel; c += MAX_KERNEL_NUM) {
                    int valid_kernel_num = c + MAX_KERNEL_NUM > out_channel ? out_channel - c : MAX_KERNEL_NUM;
                    accel_conf.kernel_num = valid_kernel_num - 1;
                    inst_conf_buf((uint32_t)&d_i[(k * height + begin_h) * width_i + begin_w], accel_conf.val);
                    for (int vc = 0; vc < valid_kernel_num; vc++) {
                        int ca = c + vc;
                        inst_conf_res_addr(&d_o[(ca * height_o + res_h) * width_o + res_w], vc);
                        
                        if (k == 0) {
                            inst_conf_res_bias(bias[ca], vc);
                            // for (int m = 0; m < res_h_append; m++) {
                            //     for (int n = 0; n < res_w_append; n++) {
                            //         d_o[(ca * height_o + res_h + m) * width_o + res_w + n] = bias[ca];
                            //     }
                            // }
                        }
                    }
                    if (k == channel - 1 && with_relu) {
                        inst_conv_relu(&weight[(k * out_channel + c) * kernel_height * kernel_width]);
                    } else {
                        inst_conv(&weight[(k * out_channel + c) * kernel_height * kernel_width]);
                    }
                    accel_conf.buf_refresh = 0;
                }
            }
            res_w += res_w_append;
        }
        res_h += res_h_append;
    }
}

// height and width must align 2
void accel_pool_func(int32_t* d_i, int32_t* d_o, int pool_mode, int channel, int height, int width) {
    accel_conf_t conf;
    conf.buf_refresh = 1;
    conf.wadd = 0;
    conf.padding_valid = 0;
    conf.weight_size = 2;
    conf.buf_size = 2;
    conf.kernel_width = 2;
    conf.kernel_height = 2;
    conf.stride = 2;
    conf.kernel_num = 0;
    conf.padding = 0;

    int max_width_word = MAX_BUF_WIDTH >> 2;

    // for (int i = 0; i < height; i++) {
    //     for(int j = 0; j < width; j++) {
    //         printf("%x ", d_i[i * width + j]);
    //     }
    //     printf("\n");
    // }

    int width_o = width >> 1;
    int height_o = height >> 1;

    for (int c = 0; c < channel; c++) {
        int h_append;
        int res_h = 0;
        for (int h = 0; h < height; h += h_append) {
            h_append = height - h < MAX_BUF_HEIGHT ? height - h : MAX_BUF_HEIGHT;
            int buf_h = h_append;
            conf.buf_height = buf_h - 1;
            int res_h_append = buf_h >> 1;

            int w_append;
            int res_w = 0;
            for (int w = 0; w < width; w += w_append) {
                int w_remain = width - w;
                w_append = w_remain < max_width_word ? w_remain : max_width_word;
                int buf_w = w_append;
                conf.buf_width = (buf_w << 2) - 1;

                inst_conf_buf((uint32_t)&d_i[(c * height + h) * width + w], conf.val);
                inst_conf_res_addr((uint32_t)&d_o[(c * height_o + res_h) * width_o + res_w], 0);
                int buf_offset = (width - buf_w) << 2;
                int res_w_append = (buf_w >> 1);
                int res_offset = (width_o - res_w_append) << 2;
                int res_buf_info = ((res_w_append - 1) << 16) | res_offset;
                inst_conf_offset(buf_offset, res_buf_info);
                inst_pool(pool_mode);

                res_w += res_w_append;
            }
            res_h += res_h_append;
        }
    }
}

void accel_linear_func(int32_t* d_i, int8_t* weight, int32_t* bias, 
                        int32_t* output, int input_size, int output_size) {
    // 线性层的瓶颈在于访存，cpu可以处理计算
    	for (int i = 0; i < output_size; i++) {
		output[i] = bias[i];
		for (int j = 0; j < input_size; j++) {
			output[i] += d_i[j] * weight[i * input_size + j];
		}
	}
}