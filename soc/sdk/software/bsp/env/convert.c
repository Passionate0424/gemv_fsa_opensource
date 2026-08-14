#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void binary_out(FILE* out,unsigned char* mem)
{
    char tmp;
    unsigned char num[8];
    num[0] = 1;
    num[1] = 2;
    num[2] = 4;
    num[3] = 8;
    num[4] = 16;
    num[5] = 32;
    num[6] = 64;
    num[7] = 128;
    for(int i=3;i>=0;i--)
    {
        for(int j=7;j>=0;j--)
        {
            if( (mem[i] & num[j] ) != 0)
                tmp = '1';
            else
                tmp = '0';
            fprintf(out,"%c",tmp);
        }
    }
    fprintf(out,"\n");
    return;
}

int main(int argc, char** argv)
{
	FILE *in;
	FILE *out;

	if(argc < 3){
		fprintf(stderr, "Usage: convert main.bin directory\n");
		return 1;
	}

	char str_bin[256];
	char str_coe[256], str_mif[256], str_vlog[256];
	char str_mif_base[256], str_mif_ext[256];
	char str_bin_base[256], str_bin_ext[256];
	strncpy(str_bin, argv[2], 256);
	strncpy(str_coe, argv[2], 256);
	strncpy(str_mif, argv[2], 256);
	strncpy(str_vlog,argv[2], 256);
	strncpy(str_mif_base, argv[2], 256);
	strncpy(str_mif_ext,  argv[2], 256);
	strncpy(str_bin_base, argv[2], 256);
	strncpy(str_bin_ext,  argv[2], 256);
	strncat(str_bin, argv[1], 255);
	strncat(str_coe, "axi_ram.coe", 255);
	strncat(str_mif, "axi_ram.mif", 255);
	strncat(str_vlog,"rom.vlog"   , 255);
	strncat(str_mif_base, "axi_ram_base.mif", 255);
	strncat(str_mif_ext,  "axi_ram_ext.mif" , 255);
	strncat(str_bin_base, "run_base.bin", 255);
	strncat(str_bin_ext,  "run_ext.bin" , 255);
	//printf("%s\n%s\n%s\n%s\n%s\n%s\n", str_bin, str_data, str_inst_coe, str_inst_mif, str_data_coe, str_data_mif);

	int i,j,k;
	unsigned char mem[32];
	FILE *out_base, *out_ext;
	FILE *outb_base, *outb_ext;   // 上板烧录用的二进制半片
	unsigned long word_idx = 0;   // 32 位字序号，偶数进 base、奇数进 ext

    in = fopen(str_bin, "rb");
    out = fopen(str_coe,"w");

	fprintf(out, "memory_initialization_radix = 16;\n");
	fprintf(out, "memory_initialization_vector =\n");
	while(!feof(in)) {
	    if(fread(mem,1,4,in)!=4) {
	        fprintf(out, "%02x%02x%02x%02x\n", mem[3], mem[2],	mem[1], mem[0]);
		break;
	     }
	    fprintf(out, "%02x%02x%02x%02x\n", mem[3], mem[2], mem[1],mem[0]);
        }
	fclose(in);
	fclose(out);

    // 两片外部 SRAM 并成一条 64 位总线后，BaseRAM 存偶数字、ExtRAM 存奇数字，
    // 各自是独立的 1M×32 位存储，仿真里由两个 sram_sp 模型分别加载，
    // 所以要产出两份 mif 而不是一份交织文件。字序：第 n 个 64 位 entry 的
    // 低 32 位（第 2n 个字）进 base，高 32 位（第 2n+1 个字）进 ext。
    in       = fopen(str_bin, "rb");
    out      = fopen(str_mif,"w");
    out_base = fopen(str_mif_base,"w");
    out_ext  = fopen(str_mif_ext,"w");
    // 同一趟循环里再产出两个 .bin：仿真用 mif（$readmemh 读文本），**上板烧录用 bin**。
    // 两者内容等价、只是格式不同，必须由同一次拆分产生，否则改了一边忘了另一边，
    // 板上和仿真就会跑在不同的镜像上。
    outb_base = fopen(str_bin_base,"wb");
    outb_ext  = fopen(str_bin_ext, "wb");

	while(!feof(in)) {
	    int last = (fread(mem,1,4,in)!=4);
            binary_out(out,mem);
            binary_out(word_idx & 1 ? out_ext : out_base, mem);
            // 二进制半片：原样写 4 字节，不做任何字节内重排（保持小端）
            fwrite(mem, 1, 4, word_idx & 1 ? outb_ext : outb_base);
            word_idx++;
	    if(last) break;
        }
    // bin 长度为奇数个字时 ext 会比 base 少一行，补零对齐两份的行数——
    // sram_sp 用 $readmemh 按行填充，行数不等只影响尾部未用区域，补齐更省心。
    // 二进制那两份同理：烧录工具按长度写，两片长度不等容易踩到边界。
    if (word_idx & 1) {
        unsigned char z[4] = {0,0,0,0};
        binary_out(out_ext, z);
        fwrite(z, 1, 4, outb_ext);
    }
	fclose(in);
	fclose(out);
	fclose(out_base);
	fclose(out_ext);
	fclose(outb_base);
	fclose(outb_ext);

    in = fopen(str_bin, "rb");
    out = fopen(str_vlog,"w");

    fprintf(out,"@1c000000\n");
    while(!feof(in)) {
        if (fread(mem,1,1,in) != 1) {
            fprintf(out,"%02x\n", mem[0]);
            break;
        }
        fprintf(out,"%02x\n", mem[0]);
    }
    fclose(in);
    fclose(out);

    return 0;
}
