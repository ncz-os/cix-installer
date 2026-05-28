#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdarg.h>
#include <linux/ioctl.h>
#include <sys/syscall.h>
static int fds[256]={0}; static unsigned long long ecnt=1;
static int nm(int f){return(f&O_CREAT)?1:0;}
static int(*ro)(const char*,int,...); int open(const char*p,int f,...){if(!ro)ro=dlsym(RTLD_NEXT,"open");va_list a;va_start(a,f);mode_t m=nm(f)?va_arg(a,mode_t):0;va_end(a);int fd=nm(f)?ro(p,f,m):ro(p,f);if(fd>=0&&fd<256&&p&&strstr(p,"/dev/aipu"))fds[fd]=1;return fd;}
static int(*roa)(int,const char*,int,...); int openat(int d,const char*p,int f,...){if(!roa)roa=dlsym(RTLD_NEXT,"openat");va_list a;va_start(a,f);mode_t m=nm(f)?va_arg(a,mode_t):0;va_end(a);int fd=nm(f)?roa(d,p,f,m):roa(d,p,f);if(fd>=0&&fd<256&&p&&strstr(p,"/dev/aipu"))fds[fd]=1;return fd;}
static const int ks[32]={[0]=424,[1]=128,[2]=56,[3]=32,[6]=128,[7]=48};
static const int kd[32]={[0]=2,[1]=2,[2]=3,[3]=1,[6]=1,[7]=3};
int ioctl(int fd,unsigned long req,...){va_list a;void*arg;va_start(a,req);arg=va_arg(a,void*);va_end(a);if(!(fd>=0&&fd<256&&fds[fd]&&_IOC_TYPE(req)==65))return syscall(29,fd,req,arg);
unsigned nr=_IOC_NR(req),usz=_IOC_SIZE(req);unsigned char*u=(unsigned char*)arg;
if(nr==0&&usz==200){char k[512]={0};long r=syscall(29,fd,_IOC(2,65,0,424),k);if(r==0){memcpy(u+0,k+0,8);if(*(unsigned*)(u+4)>4)*(unsigned*)(u+4)=4;memcpy(u+8,k+8,32);*(unsigned*)(u+40)=*(unsigned*)(k+264);*(unsigned long long*)(u+48)=*(unsigned long long*)(k+272);*(unsigned*)(u+56)=*(unsigned*)(k+280);*(unsigned*)(u+60)=*(unsigned*)(k+284);*(unsigned*)(u+64)=*(unsigned*)(k+288);memcpy(u+72,k+292,128);}return r;}
if(nr==2&&usz==80){char k[256]={0};unsigned char*kk=(unsigned char*)k;*(unsigned long long*)(kk+0)=*(unsigned long long*)(u+0);unsigned av=*(unsigned*)(u+24);*(unsigned*)(kk+8)=(av>=1&&av<=31)?(1u<<av):av;*(unsigned*)(kk+12)=*(unsigned*)(u+28);kk[16]=u[32];kk[17]=u[33];*(unsigned long long*)(kk+24)=*(unsigned long long*)(u+40);*(unsigned long long*)(kk+32)=*(unsigned long long*)(u+48);*(unsigned long long*)(kk+40)=*(unsigned long long*)(u+56);kk[48]=u[72];kk[49]=u[73];long r=syscall(29,fd,_IOC(3,65,2,56),k);if(r==0){*(unsigned long long*)(u+40)=*(unsigned long long*)(kk+24);*(unsigned long long*)(u+48)=*(unsigned long long*)(kk+32);*(unsigned long long*)(u+56)=*(unsigned long long*)(kk+40);*(unsigned long long*)(u+64)=ecnt++;u[72]=kk[48];u[73]=kk[49];}return r;}
if(nr<32&&ks[nr]>0&&usz!=ks[nr]){char k[512]={0};int m=usz>ks[nr]?usz:ks[nr];if(m>480)m=480;if(kd[nr]&1)memcpy(k,arg,usz);long r=syscall(29,fd,_IOC(kd[nr],65,nr,ks[nr]),k);if(r==0&&(kd[nr]&2))memcpy(arg,k,usz);return r;}
return syscall(29,fd,req,arg);}
