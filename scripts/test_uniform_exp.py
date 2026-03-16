#!/usr/bin/env python3
"""Force all exponents to 0x77 and regenerate golden to test exponent streaming hypothesis."""
import sys, os, re
import shutil

# Paths
SW_INC = 'sw/inc'
MX_DIR = 'golden-model/MX'

def force_uniform_exponents(filename, uniform_val=0x77):
    """Replace all exponent values in a C header with a uniform value."""
    with open(filename, 'r') as f:
        text = f.read()

    # Replace each hex value with uniform
    def replace_hex(m):
        return f'0x{uniform_val:02x}{uniform_val:02x}{uniform_val:02x}{uniform_val:02x}'

    text = re.sub(r'0x[0-9a-fA-F]{8}', replace_hex, text)

    with open(filename, 'w') as f:
        f.write(text)
    print(f"  Forced all exponents to 0x{uniform_val:02x} in {filename}")

def force_uniform_exp_txt(filename, uniform_val=0x77):
    """Replace all exponent values in a .txt file with a uniform value."""
    with open(filename, 'r') as f:
        lines = f.readlines()

    new_lines = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('//'):
            new_lines.append(line + '\n')
            continue
        # Each line has hex values like "77 77 78 77..."
        # Replace all with uniform
        parts = line.split()
        new_parts = [f'{uniform_val:02x}' for _ in parts]
        new_lines.append(' '.join(new_parts) + '\n')

    with open(filename, 'w') as f:
        f.writelines(new_lines)
    print(f"  Forced all exponents to 0x{uniform_val:02x} in {filename}")

# Backup originals
for f in ['x_exp_mx.h', 'w_exp_mx.h']:
    src = os.path.join(SW_INC, f)
    dst = src + '.bak'
    if not os.path.exists(dst):
        shutil.copy2(src, dst)
        print(f"Backed up {src} -> {dst}")

for f in ['mx_x_exp.txt', 'mx_w_exp.txt']:
    src = os.path.join(MX_DIR, f)
    dst = src + '.bak'
    if not os.path.exists(dst):
        shutil.copy2(src, dst)
        print(f"Backed up {src} -> {dst}")

# Force uniform exponents
force_uniform_exponents(os.path.join(SW_INC, 'x_exp_mx.h'))
force_uniform_exponents(os.path.join(SW_INC, 'w_exp_mx.h'))
force_uniform_exp_txt(os.path.join(MX_DIR, 'mx_x_exp.txt'))
force_uniform_exp_txt(os.path.join(MX_DIR, 'mx_w_exp.txt'))

print("\nDone! Now regenerate golden and rebuild:")
print("  make -C golden-model/MX ... (or just re-run gen_mx_golden.py)")
print("  make sw-build MX_ENABLE=1 MX_SKIP_FP16=1 M=96 N=64 K=64 target=vsim")
