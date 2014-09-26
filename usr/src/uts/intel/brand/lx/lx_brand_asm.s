/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Copyright 2010 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 * Copyright 2014 Joyent, Inc.  All rights reserved.
 */

#if defined(__lint)

#include <sys/systm.h>

#else	/* __lint */

#include <sys/controlregs.h>
#include "genassym.h"
#include "../common/brand_asm.h"

#endif	/* __lint */

#ifdef	__lint

void
lx_brand_int80_callback(void)
{
}

void
lx_brand_syscall_callback(void)
{
}

#else	/* __lint */

#if defined(__amd64)

/*
 * syscall handler for 32-bit Linux user processes:
 * See "64-BIT INTERPOSITION STACK" in brand_asm.h.
 */
ENTRY(lx_brand_int80_callback)
	GET_PROCP(SP_REG, 0, %r15)
	movq	P_ZONE(%r15), %r15		/* grab the zone pointer */
	/* grab the 'max syscall num' for this process from 'zone brand data' */
	movq	ZONE_BRAND_DATA(%r15), %r15	/* grab the zone brand ptr */
	movl	LXZD_MAX_SYSCALL(%r15), %r15d	/* get the 'max sysnum' word */
	cmpq	%r15, %rax			/* is 0 <= syscall <= MAX? */
	jbe	0f				/* yes, syscall is OK */
	xorl    %eax, %eax			/* no, zero syscall number */
0:

.lx_brand_int80_patch_point:
	jmp	.lx_brand_int80_notrace

.lx_brand_int80_notrace:
	CALC_TABLE_ADDR(%r15, L_HANDLER)
1:
	movq	%r15, %rax
	GET_V(%rsp, 0, V_SSP, %rsp)	/* restore intr. stack pointer */
	xchgq	(%rsp), %rax		/* swap %rax and return addr */
	jmp	sys_sysint_swapgs_iret

.lx_brand_int80_trace:
	/*
	 * If tracing is active, we vector to an alternate trace-enabling
	 * handler table instead.
	 */
	CALC_TABLE_ADDR(%r15, L_TRACEHANDLER)
	jmp	1b
SET_SIZE(lx_brand_int80_callback)

#define	PATCH_POINT80	_CONST(.lx_brand_int80_patch_point + 1)
#define	PATCH_VAL80	_CONST(.lx_brand_int80_trace - .lx_brand_int80_notrace)

ENTRY(lx_brand_int80_enable)
	movl	$1, lx_systrace_brand_enabled(%rip)
	movq	$PATCH_POINT80, %r8
	movb	$PATCH_VAL80, (%r8)
	ret
SET_SIZE(lx_brand_int80_enable)

ENTRY(lx_brand_int80_disable)
	movq	$PATCH_POINT80, %r8
	movb	$0, (%r8)
	movl	$0, lx_systrace_brand_enabled(%rip)
	ret
SET_SIZE(lx_brand_int80_disable)


/*
 * syscall handler for 64-bit user processes:
 *
 * We're running on the kernel's %gs.
 *
 * We return directly to userland, bypassing the update_sregs() logic, so
 * this routine must NOT do anything that could cause a context switch.
 *
 * %rax - syscall number
 *
 * When called, all general registers, except for %r15, are as they were when
 * the user process made the system call.  %r15 is available to the callback as
 * a scratch register. If the callback returns to the kernel path, %r15 does
 * not have to be restored to the user value.
 *
 * To 'return' to our user-space handler, we just need to place its address
 * into %rcx. The original return address is passed back in %rax.
 *
 * Since this is the common syscall path for all 64-bit code (both Linux and
 * native libc) in the branded zone (unlike the int80 path), we have to do a
 * bit more checking to see if interpositioning is in effect (i.e. syscalls
 * from the native ld.so.1 are not interposed since the emulation has not yet
 * been installed, or the emulation is in native syscall mode).
 */
ENTRY(lx_brand_syscall_callback)
	/* callback prologue */
	GET_PROCP(SP_REG, 0, %r15)
	mov	__P_BRAND_DATA(%r15), %r15	/* get p_brand_data */
	cmp	$0, %r15			/* null ptr? */
	je	2f				/* yes, take normal ret path */
	cmp	$0, L_HANDLER(%r15)		/* handler installed? */
	je	2f				/* no, take normal ret path */

	/* check for native vs. Linux syscall */
	GET_V(SP_REG, 0, V_LWP, %r15);		/* get lwp pointer */
	movq	LWP_BRAND(%r15), %r15		/* grab lx lwp data pointer */
	movl	BR_LIBC_SYSCALL(%r15), %r15d	/* grab syscall src flag */
	cmp	$1, %r15			/* check for native syscall */
	je	2f				/* is native, stay in kernel */

	/* Linux syscall - subsequent emul. syscalls will use native mode */
	GET_V(SP_REG, 0, V_LWP, %r15);		/* get lwp pointer */
	movq	LWP_BRAND(%r15), %r15		/* grab lx lwp data pointer */
	movl	$1, BR_LIBC_SYSCALL(%r15)	/* set native syscall flag */

	/* check if we have to restore native fsbase */
	GET_V(SP_REG, 0, V_LWP, %r15);		/* get lwp pointer */
	movq	LWP_BRAND(%r15), %r15		/* grab lx lwp data pointer */
	movq	BR_NTV_FSBASE(%r15), %r15	/* grab native fsbase */
	cmp	$0, %r15			/* native fsbase not saved? */
	je	3f				/* yes, skip loading */

	/* switch fsbase from Linux value back to native value */
	subq	$24, %rsp			/* make room for 3 regs */
	movq	%rax, 0x0(%rsp)			/* save regs used by wrmsr */
	movq	%rcx, 0x8(%rsp)
	movq	%rdx, 0x10(%rsp)
	movq	%r15, %rax			/* native fsbase to %rax */
	movq	%rax, %rdx			/* setup regs for wrmsr */
	shrq	$32, %rdx			/* fix %edx; %eax already ok */
	movl	$MSR_AMD_FSBASE, %ecx		/* fsbase msr */
	wrmsr					/* set fsbase from edx:eax */
	movq	0x0(%rsp), %rax			/* restore regs */
	movq	0x8(%rsp), %rcx
	movq	0x10(%rsp), %rdx
	addq	$24, %rsp
3:

	/* Linux syscall - validate syscall number */
	GET_PROCP(SP_REG, 0, %r15)
	movq	P_ZONE(%r15), %r15		/* grab the zone pointer */
	/* grab the 'max syscall num' for this process from 'zone brand data' */
	movq	ZONE_BRAND_DATA(%r15), %r15	/* grab the zone brand ptr */
	movl	LXZD_MAX_SYSCALL(%r15), %r15d	/* get the 'max sysnum' word */
	cmp	%r15, %rax			/* is 0 <= syscall <= MAX? */
	ja	2f				/* no, take normal ret path */

.lx_brand_syscall_patch_point:
	jmp	.lx_brand_syscall_notrace
.lx_brand_syscall_notrace:

	CALC_TABLE_ADDR(%r15, L_HANDLER)
1:
	mov	%rcx, %rax;	/* save orig return addr in syscall_reg */
	mov	%r15, %rcx;		/* place new return addr in %rcx */
	mov	%gs:CPU_RTMP_R15, %r15;	/* restore scratch register */
	mov	V_SSP(SP_REG), SP_REG	/* restore user stack pointer */
	jmp	nopop_sys_syscall_swapgs_sysretq

2:	/* no emulation, continue normal system call flow */
	retq

.lx_brand_syscall_trace:
	/*
	 * If tracing is active, we vector to an alternate trace-enabling
	 * handler table instead.
	 */
	CALC_TABLE_ADDR(%r15, L_TRACEHANDLER)
	jmp	1b
SET_SIZE(lx_brand_syscall_callback)

#define	PATCH_POINT_SC	_CONST(.lx_brand_syscall_patch_point + 1)
#define	PATCH_VAL_SC	\
	_CONST(.lx_brand_syscall_trace - .lx_brand_syscall_notrace)

ENTRY(lx_brand_syscall_enable)
	movl	$1, lx_systrace_brand_enabled(%rip)
	movq	$PATCH_POINT_SC, %r8
	movb	$PATCH_VAL_SC, (%r8)
	ret
SET_SIZE(lx_brand_syscall_enable)

ENTRY(lx_brand_syscall_disable)
	movq	$PATCH_POINT_SC, %r8
	movb	$0, (%r8)
	movl	$0, lx_systrace_brand_enabled(%rip)
	ret
SET_SIZE(lx_brand_syscall_disable)


#elif defined(__i386)

/*
 * See "32-BIT INTERPOSITION STACK" in brand_asm.h.
 */
ENTRY(lx_brand_int80_callback)
	GET_PROCP(SP_REG, 0, %ebx)
	movl	P_ZONE(%ebx), %ebx		/* grab the zone pointer */
	/* grab the 'max syscall num' for this process from 'zone brand data' */
	movl	ZONE_BRAND_DATA(%ebx), %ebx	/* grab the zone brand data */
	movl	LXZD_MAX_SYSCALL(%ebx), %ebx	/* get the max sysnum */

	cmpl	%ebx, %eax 			/* is 0 <= syscall <= MAX? */
	jbe	0f				/* yes, syscall is OK */
	xorl    %eax, %eax		     	/* no, zero syscall number */	
0:

.lx_brand_int80_patch_point:
	jmp	.lx_brand_int80_notrace

.lx_brand_int80_notrace:
	CALC_TABLE_ADDR(%ebx, L_HANDLER)

1:
	movl	%ebx, %eax
	GET_V(%esp, 0, V_U_EBX, %ebx)		/* restore scratch register */
	addl	$V_END, %esp		/* restore intr. stack ptr */
	xchgl	(%esp), %eax		/* swap new and orig. return addrs */
	jmp	nopop_sys_rtt_syscall

.lx_brand_int80_trace:
	CALC_TABLE_ADDR(%ebx, L_TRACEHANDLER)
	jmp	1b
SET_SIZE(lx_brand_int80_callback)


#define	PATCH_POINT	_CONST(.lx_brand_int80_patch_point + 1)
#define	PATCH_VAL	_CONST(.lx_brand_int80_trace - .lx_brand_int80_notrace)

ENTRY(lx_brand_int80_enable)
	pushl	%ebx
	pushl	%eax
	movl	$1, lx_systrace_brand_enabled
	movl	$PATCH_POINT, %ebx
	movl	$PATCH_VAL, %eax
	movb	%al, (%ebx)
	popl	%eax
	popl	%ebx
	ret
SET_SIZE(lx_brand_int80_enable)

ENTRY(lx_brand_int80_disable)
	pushl	%ebx
	movl	$PATCH_POINT, %ebx
	movb	$0, (%ebx)
	movl	$0, lx_systrace_brand_enabled
	popl	%ebx
	ret
SET_SIZE(lx_brand_int80_disable)

#endif	/* __i386 */
#endif	/* __lint */
