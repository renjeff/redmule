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
#include "golden_mx_exp.h"  // MX golden exponents (for future exponent verification)
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
  // Use exponent data directly from Makefile-generated headers
  // The Makefile's gen_mx_test_vectors.py generates x_exp[] and w_exp[] arrays
  uint8_t *x_exp_ptr = x_exp;
  uint8_t *w_exp_ptr = w_exp;

  printf("[DEBUG] X exp addr: 0x%08x, W exp addr: 0x%08x\n",
         (unsigned int)x_exp_ptr, (unsigned int)w_exp_ptr);
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
#if defined(MX_FORMAT) && (MX_FORMAT == 4)
  // E2M1 (FP4): 8 nibbles per 32-bit word
  errors = redmule8_compare_int((uint32_t *)z, (uint32_t *)golden_mx,
                                m_size * k_size / 8);
#elif defined(MX_FORMAT) && (MX_FORMAT == 2 || MX_FORMAT == 3)
  // E3M2/E2M3 (FP6): 6-bit elements packed tightly, compare 32-bit words
  {
    int total_bits = m_size * k_size * 6;
    int total_words = (total_bits + 31) / 32;
    errors = redmule8_compare_int((uint32_t *)z, (uint32_t *)golden_mx, total_words);
  }
#else
  errors = redmule8_compare_int((uint32_t *)z, (uint32_t *)golden_mx,
                                m_size * k_size / 4);
#endif
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
  // MX output goes to z_oup (via Z_OUT_ADDR register), not y
  // FP4 tight packing: 8 nibbles per 32-bit word. FP8: 4 bytes per word.
#if defined(MX_FORMAT) && (MX_FORMAT == 4)
  // E2M1 (FP4): compare at nibble granularity
  {
    int total_words = m_size * k_size / 8;  // 8 nibbles per word
    int errs = 0;
    for (int i = 0; i < total_words; i++) {
      uint32_t hw = ((uint32_t *)z)[i];
      uint32_t gm = ((uint32_t *)golden_mx)[i];
      if (hw != gm) {
        for (int n = 0; n < 8; n++) {
          uint8_t hn = (hw >> (n*4)) & 0xF;
          uint8_t gn = (gm >> (n*4)) & 0xF;
          if (hn != gn) errs++;
        }
      }
    }
    errors = errs;
  }
#else
  errors = redmule8_compare_int((uint32_t *)z, (uint32_t *)golden_mx,
                                m_size * k_size / 4);
#endif
  // Dump first 16 elements of rows 0, 32, 33 as hex bytes
  {
    int words_per_row = k_size / 4;
    int rows[] = {0, 32, 33};
    for (int ri = 0; ri < 3 && ri < (m_size > 32 ? 3 : 1); ri++) {
      int row = rows[ri];
      tfp_printf("[DUMP] r%d:", row);
      for (int b = 0; b < 16 && b < k_size; b++) {
        int idx = row * k_size + b;
        uint8_t hb = ((uint8_t *)z)[idx];
        tfp_printf(" %x", hb);
      }
      tfp_printf("\n");
      tfp_printf("[GOLD] r%d:", row);
      for (int b = 0; b < 16 && b < k_size; b++) {
        int idx = row * k_size + b;
        uint8_t gb = ((uint8_t *)golden_mx)[idx];
        tfp_printf(" %x", gb);
      }
      tfp_printf("\n");
    }
  }
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
