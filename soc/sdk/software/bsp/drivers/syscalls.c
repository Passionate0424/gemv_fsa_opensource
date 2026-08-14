// 裸机系统调用桩（替代libsemihost的sbrk/read实现）
// 供“脱离调试器单板独立跑”的app共用（如runc_board/runc_hwsw_comp）；
// 仿真环境(SIMU=1)一般由仿真器/JTOG接管libsemihost的默认半主机I/O，无需引用本文件。
#include <stddef.h>
#include <stdint.h>
#include <errno.h>

extern char __heap_start;
extern char __heap_end;
extern unsigned long UART_BASE;

// 使用libsemihost中已有的uart_getchar（板上验证已确认可用）
extern unsigned char uart_getchar(void);

// picolibc库自带的sbrk()实现里，堆指针是 `static char *brk = __heap_start;`——
// 带非零初值的static变量只能落进.data段，而这块板子的.data段只在烧录时写一次，
// 复位（不重新烧录）时不会被重置，导致堆指针跨复位持续增长、最终耗尽堆。
// 这里用零初值的heap_ptr（天然落进.bss，每次复位都会被start.S清零）自己实现
// sbrk()，覆盖掉库里那个有问题的版本，确保每次复位堆都能真正从__heap_start重新起跳。
// 注意：必须叫“sbrk”而不是“_sbrk”——picolibc的malloc实际调用的符号就是sbrk。
static char *heap_ptr = 0;

void *sbrk(ptrdiff_t incr) {
    if (heap_ptr == 0)
        heap_ptr = &__heap_start;

    if (incr < 0) {
        if ((size_t)(heap_ptr - &__heap_start) < (size_t)(-incr)) {
            errno = ENOMEM;
            return (void *)-1;
        }
    } else {
        if ((size_t)(&__heap_end - heap_ptr) < (size_t)incr) {
            errno = ENOMEM;
            return (void *)-1;
        }
    }

    char *prev = heap_ptr;
    heap_ptr += incr;
    return (void *)prev;
}

// _read: fgets/stdin最终调用此函数
// 从UART逐字符读取，遇到\r或\n结束，回显字符
int _read(int fd, char *buf, int len) {
    if (fd != 0) return -1;  // 只支持stdin
    int i;
    for (i = 0; i < len; i++) {
        char c = uart_getchar();
        if (c == '\r' || c == '\n') {
            buf[i] = '\n';
            // 回显换行
            extern int _write(int, const char*, int);
            char nl[] = "\r\n";
            _write(1, nl, 2);
            return i + 1;
        }
        buf[i] = c;
        // 回显输入字符
        extern int _write(int, const char*, int);
        _write(1, &c, 1);
    }
    return i;
}
