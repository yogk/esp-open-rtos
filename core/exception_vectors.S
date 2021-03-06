/* Xtensa Exception (ie interrupt) Vectors & low-level handler code
 *
 * Core exception handler code is placed in the .vecbase section, which gets
 * picked up specially in the linker script and placed at beginning of IRAM.
 *
 * The actual VecBase symbol should be the first thing in .vecbase (this is not
 * strictly important as it gets set by symbol lookup not by hardcoded address,
 * but having it at 0x40100000 means that the exception vectors have memorable
 * offsets, which match the default Boot ROM vector offsets. So convenient for
 * human understanding.
 *
 * Part of esp-open-rtos
 * Original vector contents Copyright (C) 2014-2015 Espressif Systems
 * Additions Copyright (C) Superhouse Automation Pty Ltd and Angus Gratton
 * BSD Licensed as described in the file LICENSE
 */

#include "led_debug.s"

/* Some UserException causes, see table Table 4–64 in ISA reference */

#define CAUSE_SYSCALL 1
#define CAUSE_LOADSTORE 3
#define CAUSE_LVL1INT 4

        .section .bss

NMIHandlerStack:                # stack space for NMI handler
        .skip   4*0x100
.LNMIHandlerStackTop:
NMIRegisterSaved:               # register space for saving NMI registers
        .skip   4*(16 + 6)

LoadStoreErrorHandlerStack:
        .word   0       # a0
        .word   0       # (unused)
        .word   0       # a2
        .word   0       # a3
        .word   0       # a4

/***************************** Exception Vectors *****************************/

        .section .vecbase.text, "x"

/* Note: Exception vectors must be aligned on a 256-byte (0x100) boundary or
 * they will not function properly.  (This is taken care of in the linker
 * script by ensuring .vecbase.text is aligned properly, and putting VecBase
 * right at the beginning of .vecbase.text) */
        .org    0
VecBase:
        .global VecBase
        /* IMPORTANT: exception vector literals will go here, but we
         * can't have more than 4 otherwise we push DebugExceptionVector past
         * offset 0x10 relative to VecBase. There should be ways to avoid this,
         * and also keep the VecBase offsets easy to read, but this works for
         * now. */
        .literal_position

        .org    VecBase + 0x10
DebugExceptionVector:
        .type   DebugExceptionVector, @function

        wsr     a0, excsave2
        call0   sdk_user_fatal_exception_handler
        rfi     2

        .org    VecBase + 0x20
NMIExceptionVector:
        .type   NMIExceptionVector, @function

        wsr     a0, excsave3
        call0   CallNMIExceptionHandler
        rfi     3  # Should never be reached

        .org    VecBase + 0x30
KernelExceptionVector:
        .type   KernelExceptionVector, @function

        break   1, 0
        call0   sdk_user_fatal_exception_handler
        rfe

        .org    VecBase + 0x50
UserExceptionVector:
        .type   UserExceptionVector, @function

        wsr     a1, excsave1
        rsr     a1, exccause
        beqi    a1, CAUSE_LOADSTORE, LoadStoreErrorHandler
        j       UserExceptionHandler

        .org    VecBase + 0x70
DoubleExceptionVector:
        .type   DoubleExceptionVector, @function

        break   1, 4
        call0   sdk_user_fatal_exception_handler

/* Reset vector at offset 0x80 is unused, as vecbase gets reset to mask ROM
 * vectors on chip reset. */

/*************************** LoadStoreError Handler **************************/

        .section .vecbase.text, "x"

/* Xtensa "Load/Store Exception" handler:
 * Completes L8/L16 load instructions from Instruction address space, for which
 * the architecture only supports 32-bit reads.
 *
 * Called from UserExceptionVector if EXCCAUSE is LoadStoreErrorCause
 *
 * (Fast path (no branches) is for L8UI)
 */
        .literal_position

        .balign 4
LoadStoreErrorHandler:
        .type   LoadStoreErrorHandler, @function

        /* Registers are saved in the address corresponding to their register
         * number times 4.  This allows a quick and easy mapping later on when
         * needing to store the value to a particular register number. */
        movi    sp, LoadStoreErrorHandlerStack
        s32i    a0, sp, 0
        s32i    a2, sp, 0x08
        s32i    a3, sp, 0x0c
        s32i    a4, sp, 0x10
        rsr     a0, sar         # Save SAR in a0 to restore later

        /* Examine the opcode which generated the exception */
        /* Note: Instructions are in this order to avoid pipeline stalls. */
        rsr     a2, epc1
        movi    a3, ~3
        ssa8l   a2              # sar is now correct shift for aligned read
        and     a2, a2, a3      # a2 now 4-byte aligned address of instruction
        l32i    a4, a2, 0
        l32i    a2, a2, 4
        movi    a3, 0x00700F    # opcode mask for l8ui/l16si/l16ui
        src     a2, a2, a4      # a2 now instruction that failed
        and     a3, a2, a3      # a3 is masked instruction
        bnei    a3, 0x000002, .LSE_check_l16

        /* Note: At this point, opcode could technically be one of two things:
         *   xx0xx2 (L8UI)
         *   xx8xx2 (Reserved (invalid) opcode)
         * It is assumed that we'll never get to this point from an illegal
         * opcode, so we don't bother to check for that case and presume this
         * is always an L8UI. */

        movi    a4, ~3
        rsr     a3, excvaddr    # read faulting address
        and     a4, a3, a4      # a4 now word aligned read address

        l32i    a4, a4, 0       # perform the actual read
        ssa8l   a3              # sar is now shift to extract a3's byte
        srl     a3, a4          # shift right correct distance
        extui   a4, a3, 0, 8    # mask off bits we need for an l8

.LSE_post_fetch:
        /* We jump back here after either the L8UI or the L16*I routines do the
         * necessary work to read the value from memory.
         * At this point, a2 holds the faulting instruction and a4 holds the
         * correctly read value.

         * Restore original SAR value (saved in a0) and update EPC so we'll
         * return back to the instruction following the one we just emulated */

        /* Note: Instructions are in this order to avoid pipeline stalls */
        rsr     a3, epc1
        wsr     a0, sar
        addi    a3, a3, 0x3
        wsr     a3, epc1

        /* Stupid opcode tricks: The jumptable we use later on needs 16 bytes
         * per entry (so we can avoid a second jump by just doing a RFE inside
         * each entry).  Unfortunately, however, Xtensa doesn't have an addx16
         * operation to make that easy for us.  Luckily, all of the faulting
         * opcodes we're processing are guaranteed to have bit 3 be zero, which
         * means if we just shift the register bits of the opcode down by 3
         * instead of 4, we will get the register number multiplied by 2.  This
         * combined with an addx8 will give us an effective addx16 without
         * needing any extra shift operations. */
        extui   a2, a2, 3, 5    # a2 is now destination register 0-15 times 2

        bgei    a2, 10, .LSE_assign_reg     # a5..a15 use jumptable
        beqi    a2, 2, .LSE_assign_a1       # a1 uses a special routine

        /* We're storing into a0 or a2..a4, which are all saved in our "stack"
         * area.  Calculate the correct address and stick the value in there,
         * then just do our normal restore and RFE (no jumps required, which
         * actually makes a0..a4 substantially faster). */
        addx2   a2, a2, sp
        s32i    a4, a2, 0

        /* Restore all regs and return */
        l32i    a0, sp, 0
        l32i    a2, sp, 0x08
        l32i    a3, sp, 0x0c
        l32i    a4, sp, 0x10
        rsr     a1, excsave1    # restore a1 saved by UserExceptionVector
        rfe

.LSE_assign_reg:
        /* At this point, a2 contains the register number times 2, a4 is the
         * read value. */

        /* Calculate the jumptable address, and restore all regs except a2 and
         * a4 so we have less to do after jumping. */
        /* Note: Instructions are in this order to avoid pipeline stalls. */
        movi    a3, .LSE_jumptable_base
        l32i    a0, sp, 0
        addx8   a2, a2, a3      # a2 is now the address to jump to
        l32i    a3, sp, 0x0c

        jx      a2

        .balign 4
.LSE_check_l16:
        /* At this point, a2 contains the opcode, a3 is masked opcode */
        movi    a4, 0x001002    # l16si or l16ui opcode after masking
        bne     a3, a4, .LSE_wrong_opcode

        /* Note: At this point, the opcode could be one of two things:
         *   xx1xx2 (L16UI)
         *   xx9xx2 (L16SI)
         * Both of these we can handle. */

        movi    a4, ~3
        rsr     a3, excvaddr    # read faulting address
        and     a4, a3, a4      # a4 now word aligned read address

        l32i    a4, a4, 0       # perform the actual read
        ssa8l   a3              # sar is now shift to extract a3's bytes
        srl     a3, a4          # shift right correct distance
        extui   a4, a3, 0, 16   # mask off bits we need for an l16

        bbci    a2, 15, .LSE_post_fetch  # Not a signed op
        bbci    a4, 15, .LSE_post_fetch  # Value does not need sign-extension

        movi    a3, 0xFFFF0000
        or      a4, a3, a4      # set 32-bit sign bits
        j       .LSE_post_fetch

.LSE_wrong_opcode:
        /* If we got here it's not an opcode we can try to fix, so bomb out.
         * Restore registers so any dump the fatal exception routine produces
         * will have correct values */
        wsr     a0, sar
        l32i    a0, sp, 0
        l32i    a2, sp, 0x08
        l32i    a3, sp, 0x0c
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        call0   sdk_user_fatal_exception_handler

        .balign 4
.LSE_assign_a1:
        /* a1 is saved in excsave1, so just update that with the value, */
        wsr     a4, excsave1
        /* Then restore all regs and return */
        l32i    a0, sp, 0
        l32i    a2, sp, 0x08
        l32i    a3, sp, 0x0c
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .balign 4
.LSE_jumptable:
        /* The first 5 entries (80 bytes) of this table are unused (registers
         * a0..a4 are handled separately above).  Rather than have a whole bunch
         * of wasted space, we just pretend that the table starts 80 bytes
         * earlier in memory. */
        .set    .LSE_jumptable_base, .LSE_jumptable - (16 * 5)

        .org    .LSE_jumptable_base + (16 * 5)
        mov     a5, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 6)
        mov     a6, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 7)
        mov     a7, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 8)
        mov     a8, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 9)
        mov     a9, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 10)
        mov     a10, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 11)
        mov     a11, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 12)
        mov     a12, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 13)
        mov     a13, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 14)
        mov     a14, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

        .org    .LSE_jumptable_base + (16 * 15)
        mov     a15, a4
        l32i    a2, sp, 0x08
        l32i    a4, sp, 0x10
        rsr     a1, excsave1
        rfe

/****************************** call_user_start ******************************/

        .section .vecbase.text, "x"

/* This is the first entrypoint called from the ROM after loading the image
 * into IRAM.  It just sets up the VECBASE register to point at our own
 * exception vectors and then calls sdk_user_start() */

        .literal_position

        .balign 4
call_user_start:
        .global call_user_start
        .type   call_user_start, @function

        movi    a2, VecBase
        wsr     a2, vecbase
        call0   sdk_user_start

/*************************** NMI Exception Handler ***************************/

        .section .vecbase.text, "x"

/* Save register relative to a0 */
.macro SAVE_REG register, regnum
        s32i \register, a0, (4 * (\regnum + 6))
.endm

/* Load register relative to sp */
.macro LOAD_REG register, regnum
        l32i \register, sp, (4 * (\regnum + 6))
.endm

        .literal_position

        .balign  16
CallNMIExceptionHandler:
        .type   CallNMIExceptionHandler, @function

        movi    a0, NMIRegisterSaved
        SAVE_REG a2, 2
        SAVE_REG sp, 1
        SAVE_REG a3, 3
        rsr     a2, excsave3    # a2 is now former a0
        SAVE_REG a4, 4
        SAVE_REG a2, 0
        rsr     a3, epc1
        rsr     a4, exccause
        SAVE_REG a3, -5
        SAVE_REG a4, -4
        rsr     a3, excvaddr
        SAVE_REG a3, -3
        rsr     a3, excsave1
        SAVE_REG a3, -2
        SAVE_REG a5, 5
        SAVE_REG a6, 6
        SAVE_REG a7, 7
        SAVE_REG a8, 8
        SAVE_REG a9, 9
        SAVE_REG a10, 10
        SAVE_REG a11, 11
        SAVE_REG a12, 12
        SAVE_REG a13, 13
        SAVE_REG a14, 14
        SAVE_REG a15, 15
        movi    sp, .LNMIHandlerStackTop
        movi    a0, 0
        movi    a2, 0x23        # argument for handler
        wsr     a2, ps
        rsync
        rsr     a14, sar
        s32i    a14, sp, 0      # this is also NMIRegisterSaved+0
        call0   sdk_wDev_ProcessFiq
        l32i    a15, sp, 0
        wsr     a15, sar
        movi    a2, 0x33
        wsr     a2, ps
        rsync
        LOAD_REG a4, 4
        LOAD_REG a5, 5
        LOAD_REG a6, 6
        LOAD_REG a7, 7
        LOAD_REG a8, 8
        LOAD_REG a9, 9
        LOAD_REG a10, 10
        LOAD_REG a11, 11
        LOAD_REG a12, 12
        LOAD_REG a13, 13
        LOAD_REG a14, 14
        LOAD_REG a15, 15
        LOAD_REG a2, -5
        LOAD_REG a3, -4
        wsr     a2, epc1
        wsr     a3, exccause
        LOAD_REG a2, -3
        LOAD_REG a3, -2
        wsr     a2, excvaddr
        wsr     a3, excsave1
        LOAD_REG a0, 0
        /* set dport nmi status bit 0 (wDev_ProcessFiq clears & verifies this
         * bit stays cleared, see
         * http://esp8266-re.foogod.com/wiki/WDev_ProcessFiq_%28IoT_RTOS_SDK_0.9.9%29)
         */
        movi    a2, 0x3ff00000
        movi    a3, 0x1
        s32i    a3, a2, 0
        LOAD_REG a2, 2
        LOAD_REG a3, 3
        LOAD_REG a1, 1
        rfi     3

/*********************** General UserException Handler ***********************/

        .section .vecbase.text, "x"

/* Called by UserExceptionVector if EXCCAUSE is anything other than
 * LoadStoreCause. */

        .literal_position

        .balign  4
UserExceptionHandler:
        .type   UserExceptionHandler, @function
        xsr     a0, excsave1    # a0 now contains sp
        mov     sp, a0
        addi    sp, sp, -0x50
        s32i    a0, sp, 0x10
        rsr     a0, ps
        s32i    a0, sp, 0x08
        rsr     a0, epc1
        s32i    a0, sp, 0x04
        rsr     a0, excsave1
        s32i    a0, sp, 0x0c
        movi    a0, _xt_user_exit
        s32i    a0, sp, 0x0
        call0   sdk__xt_int_enter
        movi    a0, 0x23
        wsr     a0, ps
        rsync
        rsr     a2, exccause
        beqi    a2, CAUSE_LVL1INT, UserHandleInterrupt
        /* Any UserException cause other than level 1 interrupt should panic */
UserFailOtherExceptionCause:
        break   1, 1
        call0   sdk_user_fatal_exception_handler
UserHandleInterrupt:
        rsil    a0, 1
        rsr     a2, intenable
        rsr     a3, interrupt
        movi    a4, 0x3fff
        and     a2, a2, a3
        and     a2, a2, a4      # a2 = 0x3FFF & INTENABLE & INTERRUPT
UserHandleTimer:
        movi    a3, 0xffbf
        and     a3, a2, a3      # a3 = a2 with bit 6 cleared
        bnez    a3, UserTimerDone   # If any non-timer interrupt bits set
        movi    a3, 0x40
        sub     a12, a2, a3     # a12 = a2 - 0x40 -- Will be zero if bit 6 set
        call0   sdk__xt_timer_int  # tick timer interrupt
        mov     a2, a12         # restore a2 from a12, ie zero
        beqz    a2, UserIntDone
UserTimerDone:
        call0   _xt_isr_handler
        bnez    a2, UserHandleTimer
UserIntDone:
        beqz    a2, UserIntExit
        /* FIXME: this code will never be reached */
        break   1, 1
        call0   sdk_user_fatal_exception_handler
UserIntExit:
        call0   sdk__xt_int_exit  # jumps to _xt_user_exit. Never returns here

        .section .text

/* _xt_user_exit is used to exit interrupt context. */
/* TODO: Find a better place for this to live. */
_xt_user_exit:
        .global _xt_user_exit
        .type _xt_user_exit, @function

        l32i    a0, sp, 0x8
        wsr     a0, ps
        l32i    a0, sp, 0x4
        wsr     a0, epc1
        l32i    a0, sp, 0xc
        l32i    sp, sp, 0x10
        rsync
        rfe

