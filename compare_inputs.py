#!/usr/bin/env python3
import struct

# Read FP16 baseline data
fp16_x = []
with open('inc/x_input.h', 'r') as f:
    for line in f:
        if line.startswith('0x'):
            vals = [int(v.strip(','), 16) for v in line.split() if v.startswith('0x')]
            fp16_x.extend(vals)

fp16_w = []
with open('inc/w_input.h', 'r') as f:
    for line in f:
        if line.startswith('0x'):
            vals = [int(v.strip(','), 16) for v in line.split() if v.startswith('0x')]
            fp16_w.extend(vals)

# Read MX data (this is MX-encoded, not raw FP16)
mx_x = []
with open('inc/x_input_mx.h', 'r') as f:
    for line in f:
        if '0x' in line and not line.strip().startswith('/*') and not line.strip().startswith('uint16_t'):
            vals = [int(v.strip(','), 16) for v in line.split() if v.startswith('0x')]
            mx_x.extend(vals)

mx_w = []
with open('inc/w_input_mx.h', 'r') as f:
    for line in f:
        if '0x' in line and not line.strip().startswith('/*') and not line.strip().startswith('uint16_t'):
            vals = [int(v.strip(','), 16) for v in line.split() if v.startswith('0x')]
            mx_w.extend(vals)

print('='*80)
print('INPUT DATA COMPARISON: FP16 Baseline vs MX Mode')
print('='*80)
print(f'\nFP16 baseline X size: {len(fp16_x)} values')
print(f'FP16 baseline W size: {len(fp16_w)} values')
print(f'\nMX X size: {len(mx_x)} values (MX-encoded format)')
print(f'MX W size: {len(mx_w)} values (MX-encoded format)')

print(f'\nFirst 10 FP16 X values: {[hex(v) for v in fp16_x[:10]]}')
print(f'First 10 MX X values:   {[hex(v) for v in mx_x[:10]]}')

print('\n' + '='*80)
print('KEY INSIGHT:')
print('='*80)
print('MX format is block-encoded with shared exponents.')
print('Each MX block contains:')
print('  - Multiple mantissa values packed together')
print('  - One shared exponent per block')
print('')
print('The MX data is ~50% the size of FP16 data because:')
print(f'  FP16: {len(fp16_x)} × 16 bits = {len(fp16_x)*16} bits')
print(f'  MX:   {len(mx_x)} × 16 bits = {len(mx_x)*16} bits')
print('')
print('To verify if inputs match, you need to:')
print('  1. Decode MX format back to FP16')
print('  2. Compare decoded values with FP16 baseline')
print('')
print('The golden model script that can do this comparison:')
print('  ./golden-model/compare_mx_golden_models.py')
