#include <stdio.h> 
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include "common_func.h"
#include "dvi.h"
#include "seg7.h"
#include "led.h"
#include "core_time.h"

//BSP板级支持包所需全局变量
unsigned long UART_BASE = 0xbf000000;					//UART16550的虚地址
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;			//CONFREG计数器的虚地址
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;		//CONFREG时钟频率
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;			//处理器核时钟频率


int Ball_x = 400;
int Ball_y = 100;
int Ball_r = 5;

volatile int Plane_x = 400;
int Plane_y = 400;
int Plane_l = 100;
int Plane_w = 5;

// ball move direction
int Ball_dx = 2;
int Ball_dy = 2;

// ball move direction
int Plane_dx = 20;

int score = 0;

volatile int delay_time = 0;

void Timer_IntrHandler(void);
void Button_IntrHandler(unsigned char button_state);

void showGameOver(void);

int chooseFlag = 1;

volatile int flag = 1;

void InterruptInit(void)
{
    // Enable button and timer Interrupt
	RegWrite(0xbf20f004,0x0f);//edge
	RegWrite(0xbf20f008,0x1f);//pol
	RegWrite(0xbf20f00c,0x1f);//clr
	RegWrite(0xbf20f000,0x1f);//en

	RegWrite(0xbf20f104,25000000);//timercmp 500ms
	RegWrite(0xbf20f108,0x1);//timeren
}

void showGameOver(void);

void chooseTime(void)
{
	printf("Please Choosetime !!\n");
    while (flag);
	printf("Choosetime:%d\n",delay_time);
    chooseFlag = 0;
    setSegNum(0,0,0,0);
}

int main(int argc, char** argv)
{
	InterruptInit();

	chooseTime();

	while (1) {

        DVI_Draw_Rect(Plane_x,Plane_y,Plane_l,Plane_w);

        DVI_Draw_SQU(Ball_x,Ball_y,Ball_r);
        
        delay_ms(delay_time);

        // refresh place
        Ball_x += Ball_dx;
        Ball_y += Ball_dy;

        delay_ms(delay_time);

        if(Ball_y < 2)
        {
            Ball_y = 2;
            Ball_dy = -Ball_dy;
        }

        if(Ball_y > 600)
        {
            Ball_y = 600;
            Ball_dy = -Ball_dy;
        }

        if(Ball_x < 2)
        {
            Ball_x = 2;
            Ball_dx = -Ball_dx;
        }

        if(Ball_x > 800)
        {
            Ball_x = 800;
            Ball_dx = -Ball_dx;
        }

        if( Ball_y > 410 )
            break;

        if((Plane_y - Ball_y) < 2 && (Ball_x > (Plane_x - Plane_l)) && (Ball_x < (Plane_x + Plane_l))) 
        {
            Ball_dy = -Ball_dy;
            score++;
        }
        
    }

    showGameOver();

    return 0;

}

void HWI0_IntrHandler(void)
{	
	unsigned int int_state;
	int_state = RegRead(0xbf20f014);

	if((int_state & 0x10) == 0x10){
		Timer_IntrHandler();
	}
	else if(int_state & 0xf){
		Button_IntrHandler(int_state & 0xf);
	}
}

void Timer_IntrHandler(void)
{
	if (!chooseFlag)
    {
        // refreshing the DVI output
        if (score > 9)
        {
            setSegNum(1,score/10,1,score%10);
        }else{
            setSegNum(0,0,1,score);
        }
    }
	RegWrite(0xbf20f108,0);
	RegWrite(0xbf20f108,1);
}

void Button_IntrHandler(unsigned char button_state)
{
	if (chooseFlag)
    {
        if (button_state & 0b1)
        {
            delay_time++;        
        
            if (delay_time > 20)
            {
                delay_time = 20;
            }
			printf("button1\n");
			RegWrite(0xbf20f00c,0x1);//clr

        }else if (button_state & 0b1000)
        {
            delay_time--;
            if (delay_time < 1)
            {
                delay_time = 1;
            }
			printf("button4\n");
			RegWrite(0xbf20f00c,0x8);//clr
        }else if (button_state & 0b100)
        {
            flag = 0;
			printf("button3\n");
			RegWrite(0xbf20f00c,0x4);//clr
        }else{
			printf("button2\n");
			RegWrite(0xbf20f00c,0x2);//clr
		}

        setSegNum(1,delay_time/10,1,delay_time%10);

    }
    
    if (!chooseFlag)
    {

        if (button_state & 0b1)
        {
            Plane_x += Plane_dx;
            if (Plane_x + Plane_l > 800)
            {
                Plane_x = 800 - Plane_l;
            }
			RegWrite(0xbf20f00c,0x1);//clr
        }else if (button_state & 0b1000)
        {
            Plane_x -= Plane_dx;
            if (Plane_x - Plane_l < 0)
            {
                Plane_x = Plane_l;
            }
			RegWrite(0xbf20f00c,0x8);//clr
        }else if (button_state & 0b0100){
			RegWrite(0xbf20f00c,0x4);//clr
		}else if (button_state & 0b0010){
			RegWrite(0xbf20f00c,0x2);//clr
		}
    }
}

void showGameOver(void)
{

	printf("GameOver\n");

    while (1)
    {
        setLedPin(0b1000000000000001);delay_ms(50);
        setLedPin(0b1100000000000011);delay_ms(50);
        setLedPin(0b1110000000000111);delay_ms(50);
        setLedPin(0b1111000000001111);delay_ms(50);
        setLedPin(0b1111100000011111);delay_ms(50);
        setLedPin(0b1111110000111111);delay_ms(50);
        setLedPin(0b1111111001111111);delay_ms(50);
        setLedPin(0b1111111111111111);delay_ms(50);
        setLedPin(0b1111111001111111);delay_ms(50);
        setLedPin(0b1111110000111111);delay_ms(50);
        setLedPin(0b1111100000011111);delay_ms(50);
        setLedPin(0b1111000000001111);delay_ms(50);
        setLedPin(0b1110000000000111);delay_ms(50);
        setLedPin(0b1100000000000011);delay_ms(50);
        setLedPin(0b1000000000000001);delay_ms(50);
    }
}
