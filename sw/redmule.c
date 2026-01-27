// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

#include <stdint.h>
#include "redmule_utils.h"
#include "archi_redmule.h"
#include "hal_redmule.h"

// Conditional MX format data includes
#ifdef MX_ENABLE
  #include "x_input_mx.h"  // Packed FP8 data
  #include "w_input_mx.h"
  #include "x_exp_mx.h"    // Shared exponents
  #include "w_exp_mx.h"
#else
  #include "x_input.h"     // Normal FP16 data
  #include "w_input.h"
#endif

#include "y_input.h"
#include "z_output.h"
#include "golden.h"
#ifdef MX_ENABLE
#include "golden_mx.h"
#endif

int main() {

  printf("[DEBUG] Main started\n");

  uint16_t m_size = M_SIZE;
  uint16_t n_size = N_SIZE;
  uint16_t k_size = K_SIZE;

  uint16_t *x = x_inp;
  uint16_t *w = w_inp;
  uint16_t *y = y_inp;
  uint16_t *z = z_oup; // golden_out //1c010000
#ifdef MX_ENABLE
  uint8_t *x_exp_ptr = x_exp;
  uint8_t *w_exp_ptr = w_exp;
#else
  uint8_t *x_exp_ptr = NULL;
  uint8_t *w_exp_ptr = NULL;
#endif

  volatile int errors = 0;

#ifdef COMPLEX_OFFLOADER

  uint32_t x_addr = *(uint32_t *)&x;
  uint32_t w_addr = *(uint32_t *)&w;
  uint32_t y_addr = *(uint32_t *)&y;
  uint32_t cfg_reg0 = ((k_size << 16) | (m_size << 0));
  uint32_t cfg_reg1 = (n_size << 0);
  asm volatile("addi t0, %0, 0" ::"r"(x_addr));
  asm volatile("addi t1, %0, 0" ::"r"(w_addr));
  asm volatile("addi t2, %0, 0" ::"r"(y_addr));
  asm volatile("addi t3, %0, 0" ::"r"(cfg_reg0));
  asm volatile("addi t4, %0, 0" ::"r"(cfg_reg1));

  /* mcnfig instruction */
  // asm volatile(
  //      ".word (0x0       << 25) | \     /* Empty */
  //             (0b11101   << 20) | \     /* Rs2 */
  //             (0b11100   << 15) | \     /* Rs1 */
  //             (0x00      <<  7) | \     /* Empty */
  //             (0b0001011 <<  0)   \n"); /* OpCode */

  asm volatile(".word (0x0       << 25) | \
              (0b11101   << 20) | \
              (0b11100   << 15) | \
              (0x00      <<  7) | \
              (0b0001011 <<  0)   \n");
  /* marith instruction */
  // sm volatile(
  //     ".word (0b00111   << 27) | \     /* Rs3 */
  //            (0b00      << 25) | \     /* Empty*/
  //            (0b00110   << 20) | \     /* Rs2 */
  //            (0b00101   << 15) | \     /* Rs1 */
  //            (0b0       << 14) | \     /* Custom format enable/disable */
  //            (0b0       << 13) | \     /* Widening enable/disable */
  //            (0b001     << 10) | \     /* Operation selection */
  //            (0b001     <<  7) | \     /* Data format */
  //            (0b0101011 <<  0)   \n"); /* OpCode */

  asm volatile(".word (0b00111   << 27) | \
              (0b00      << 25) | \
              (0b00110   << 20) | \
              (0b00101   << 15) | \
              (0b0       << 14) | \
              (0b0       << 13) | \
              (0b001     << 10) | \
              (0b001     <<  7) | \
              (0b0101011 <<  0)   \n");

  asm volatile("wfi" ::: "memory");

#ifdef MX_ENABLE
  errors = redmule8_compare_int((uint32_t *)y, (uint32_t *)golden_mx,
                                m_size * k_size / 4);
#else
  errors = redmule16_compare_int(y, golden, m_size * k_size / 2);
#endif

#else // COMPLEX_OFFLOADER not defined

  uint8_t float_fmt = (SRC_FMT == FP8)       ? (uint8_t)Float8
                      : (SRC_FMT == FP8ALT)  ? (uint8_t)Float8Alt
                      : (SRC_FMT == FP16)    ? (uint8_t)Float16
                      : (SRC_FMT == FP16ALT) ? (uint8_t)Float16Alt
                                             : (uint8_t)Float16;

  int gold_sum = 0, check_sum = 0;
  int i, j;

  int offload_id_tmp, offload_id;

  // Enable RedMulE
  hwpe_cg_enable();

  hwpe_soft_clear();

  while ((offload_id_tmp = hwpe_acquire_job()) < 0)
    ;

  redmule_cfg((unsigned int)x, (unsigned int)w, (unsigned int)y,
              (unsigned int)x_exp_ptr, (unsigned int)w_exp_ptr,
              m_size, n_size, k_size, (uint8_t)gemm_ops, float_fmt);

  // Start RedMulE operation and sleeping until the end of computation
  printf("Triggering accelerator and going to sleep...\n");
  hwpe_trigger_job();

  asm volatile("wfi" ::: "memory");

  // At the end of accelerator's computation, we resume and check on results
  printf("Resumed!\n");

  // Disable RedMulE
  hwpe_cg_disable();

#ifdef MX_ENABLE
  errors = redmule8_compare_int((uint32_t *)y, (uint32_t *)golden_mx,
                                m_size * k_size / 4);
#else
  if (float_fmt == Float16 || float_fmt == Float16Alt)
    errors = redmule16_compare_int((uint32_t *)y, (uint32_t *)golden, m_size * k_size / 2);
  else if (float_fmt == Float8 || float_fmt == Float8Alt)
    errors = redmule8_compare_int((uint32_t *)y, (uint32_t *)golden, m_size * k_size / 4);
#endif

#endif // #ifded COMPLEX_OFFLOADER

  *(int *)0x80000000 = errors;

  tfp_printf("Terminated test with %d errors. See you!\n", errors);

  return errors;
}
