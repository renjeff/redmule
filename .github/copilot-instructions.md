# RedMulE Codebase Instructions for AI Coding Agents

## Project Overview
RedMulE (Reduced-Precision Matrix Multiplication Engine) is an open-source hardware accelerator for GEMM operations supporting FP16 and FP8 formats. It's a parametric 2D array of Computing Elements (CEs) based on the HWPE template, designed for flexible low-precision linear algebra acceleration.

## Key Architecture Patterns

### Core Hardware Components
- **Engine**: Parametric 2D array of CEs controlled via `rtl/redmule_pkg.sv` parameters:
  - `ARRAY_HEIGHT` (default: 4) - number of PEs per row
  - `ARRAY_WIDTH` (default: 12, max = ARRAY_HEIGHT × PIPE_REGS)
  - `PIPE_REGS` (default: 3) - pipeline stages per CE
  - `FPFORMAT` - internal precision (always FP16, configurable at top-level)
  
- **Data Path**: Input/Output casting modules allow FP8↔FP16 conversion:
  - `redmule_castin.sv` - FP8 to FP16 conversion on input
  - `redmule_castout.sv` - FP16 to FP8 conversion on output
  - Enables larger intermediate precision for accuracy

- **Memory Buffers**: Separate buffers for X, W, Z matrices with single-port SRAMs:
  - `x_buffer/` - input matrix X (with padding support)
  - `w_buffer/` - weight matrix W
  - `z_buffer/` - output/accumulation matrix Z

- **Control Subsystem**: 
  - `redmule_ctrl.sv` - hwpe-ctrl based memory-mapped register interface (base 0x00100000)
  - `redmule_scheduler.sv` - operation orchestration
  - `redmule_inst_decoder.sv` - instruction decoding for XIF interface

### Supported GEMM Operations
All follow pattern `Z = (X op1 W) op2 Z`:
- `gemm`: Z = (X × W) + Z
- `addmax`, `addmin`: Z = max/min((X + W), Z)
- `mulmax`, `mulmin`: Z = max/min((X × W), Z)
- `maxmin`, `minmax`: Z = min/max(max/min(X, W), Z)

Operations selected via `MACFG` register [12:10] and runtime configuration.

### Integration Modes

1. **Memory-Mapped (UseXif=0)**: Default configuration
   - CV32E40P controller core + address decoder
   - Configuration via direct memory-mapped writes to register file
   - Registers at base 0x00100000, address space 0x100B

2. **Tensor Co-processor (UseXif=1)**: ISA extension mode
   - CV32E40X core with eXtension Interface (XIF)
   - Custom ISA instructions (mcnfig, marith) embedded in firmware
   - No memory-mapped interface needed

## MX Format Support

### Overview
MX (Microscaling Formats) enables sub-byte precision with per-block scaling for efficient low-precision matrix operations. RedMulE supports multiple MX variants parameterized by exponent/mantissa bit-widths.

### Supported Format Variants
Defined in `golden-model/MX/gen_mx_vectors.py`:

| Format | Exp Bits | Mantissa Bits | Bitwidth | Bias | Use Case |
|--------|----------|---------------|----------|------|----------|
| MXFP8_E5M2 | 5 | 2 | 8 | 15 | High dynamic range |
| MXFP8_E4M3 | 4 | 3 | 8 | 7 | Balanced precision |
| MXFP6_E3M2 | 3 | 2 | 6 | 3 | Memory efficient |
| MXFP6_E2M3 | 2 | 3 | 6 | 1 | Precision focused |
| MXFP4_E2M1 | 2 | 1 | 4 | 1 | Extreme compression |

### Hardware Integration

**Encoder/Decoder Pipeline**:
- `redmule_mx_encoder.sv` - Converts FP16 blocks to MX format with per-block exponent
  - Input: 256-bit data (FP16 elements)
  - Output: MX-formatted data + shared exponent metadata
- `redmule_mx_decoder.sv` - Converts MX format back to FP16 for computation
  - Input: MX-formatted blocks
  - Output: Expanded FP16 elements

**Data Path Integration**:
```
TCDM → MX_Decoder → FP16 → Engine (FMA/FNCOMP) → FP16 → MX_Encoder → TCDM
```

Encoder/decoder can be chained with existing cast modules or replace them entirely depending on configuration.

### Test Vector Generation

Generate test vectors for any MX variant:
```bash
cd golden-model/MX
python3 gen_mx_vectors.py mxfp8_e4m3  # Generates mx_encoder_vectors_mxfp8_e4m3.txt
                                       # and mx_decoder_vectors_mxfp8_e4m3.txt
```

Testbenches reference vectors at runtime:
- `rtl/tb_redmule_mx_decoder.sv` - Parameter: `VECTOR_FILE` (defaults to mxfp8_e4m3)
- `rtl/tb_redmule_mx_encoder.sv` - Same pattern

Vector format: One value per line in decimal or hex, readable by `$readmemh()` in Verilog.

### Configuration Registers for MX Mode

When using MX formats, the `ARITH` register gains additional fields:
- **[15:13]**: Input/Output format selection (use MX variant index)
- **[12:10]**: Operation selection (standard GEMM op codes)
- Custom bits for encoder/decoder bypass or chaining mode

Check firmware configuration in `sw/redmule.c` for XIF/memory-mapped MX instruction encoding.

### Verification Workflow

1. Generate golden model output:
   ```bash
   make -C golden-model mx_format_test M=32 N=32 K=32 mx_fmt=mxfp8_e4m3
   ```

2. Create RTL testbench with format-specific vectors

3. Run simulation and compare block exponents + mantissa values

4. Validate encoder/decoder round-trip: FP16 → MX → FP16 should match within tolerance

### Special Considerations

- **Block Alignment**: MX operates on 256-bit blocks (NUM_ELEMS=32 FP8 elements). Ensure matrix dimensions are block-aligned.
- **Exponent Sharing**: Per-block exponent metadata overhead increases with smaller block sizes; tune accordingly.
- **Format Mixing**: Can chain MX encoder on output with standard FP8 cast for hybrid precision pipelines.
- **Saturation/Rounding**: Mantissa truncation in encoder can introduce accuracy loss—always verify against golden model output.

## Critical Developer Workflows

### Building & Compilation
Uses **Bender** dependency manager. Key makefiles:
- `Makefile` - top-level build (targets: `verilator`, `modelsim`)
- `bender_common.mk`, `bender_sim.mk`, `bender_synth.mk` - tool-specific rules

```bash
# RTL synthesis
make synth

# Simulation (default verilator)
make gui=0 P_STALL=0.0 UseXif=0  # Memory-mapped
make gui=0 UseXif=1              # XIF co-processor mode
```

### Golden Model Generation
Python-based reference implementation for verification:
```bash
cd golden-model && source setup-py.sh && cd ..
make -C golden-model clean minmax M=96 N=64 K=64 fp_fmt=FP8 SW=$(pwd)/inc
```
Generates matrices in `.txt` and header files. FP formats: FP16, FP8.

### Simulation & Testing
- **Testbench**: `target/sim/src/redmule_tb.sv` - instantiates synthetic memories + Core Complex
- **Parametric stalling**: `PROB_STALL` parameter for data memory contention simulation
- **Traces**: CV32E40P/CV32E40X execution traces with `-D CV32*_TRACE_EXECUTION`
- **Test vectors**: MX format test vectors in `golden-model/MX/mx_*_vectors_*.txt`

### Software/Firmware Development
- **Language**: RISC-V C with inline assembly for custom instructions
- **HAL layer**: `sw/hal_redmule.h` - register access macros and functions
- **Architecture defs**: `sw/archi_redmule.h` - register offsets and memory layout
- **Configuration flow** (from `sw/redmule.c`):
  1. Set X, W, Z addresses and matrix dimensions (M, N, K)
  2. Write configuration registers (MCFG0, MCFG1, ARITH)
  3. Issue trigger command
  4. Poll status or wait for interrupt

## Project-Specific Conventions

### File Organization Patterns
- **RTL modules**: Inherit from HWPE template - use `hwpe_ctrl_intf_periph`, `hci_core_intf`, `hwpe_stream_intf_tcdm`
- **Config package**: All parameters centralized in `rtl/redmule_pkg.sv` - import as `redmule_pkg::*`
- **Golden model**: Separate Python scripts per operation (gemm.py, addmax.py, etc.) under `golden-model/{FP16,FP8}/`
- **Test data**: Header files auto-generated from golden model, placed in `sw/inc/`

### Register Interface Convention
Registers use hwpe-ctrl 32-bit word addressing:
- Control registers: 0x00-0x14 (TRIGGER, ACQUIRE, STATUS, etc.)
- Job registers: 0x40+ (X_ADDR, W_ADDR, Z_ADDR, MCFG0, MCFG1, ARITH)
- ECC counters: Separate offset space (see `REDMULE_ECC_REG_OFFS`)

Matrix config register packing:
- `MCFG0`: [31:16] K size, [15:0] M size
- `MCFG1`: [31:0] N size
- `ARITH`: [12:10] op selection, [9:7] I/O format, custom bits for xif mode

### Dependencies
- **HWPE infrastructure**: hwpe-ctrl, hwpe-stream packages (PULP ecosystem)
- **Floating-point**: Transprecision FP Unit (fpnew) - supports F16, F8, F32
- **RISC-V cores**: CV32E40P (default) or CV32E40X (XIF variant)
- **Packaging**: Bender manifests pinned to specific revisions

### Documentation Locations
- Architecture diagrams: `doc/redmule_overview.png`, `doc/RedmuleSubsystem-CoreComplex.png`
- Register layouts: `sw/archi_redmule.h` (ASCII tables)
- API: `sw/hal_redmule.h`, `sw/inc/golden.h`
- Test parameters: `scripts/regression-list.sh` (M, N, K combinations)

## Cross-Component Data Flows
1. **Control path**: Firmware → hwpe-ctrl interface → register file → scheduler
2. **Data path**: TCDM memory → input buffers → cast-in → engine → FMA/FNCOMP array → cast-out → output buffer → TCDM
3. **Synchronization**: hwpe-ctrl triggers via acquire/trigger, status polling for completion
4. **Verification loop**: Golden model (Python) → test vectors (txt) → RTL simulation → C firmware validation

## Quick Reference Commands
```bash
# Setup Python environment
cd golden-model && source setup-py.sh

# Generate GEMM FP16 test data
make -C golden-model gemm M=16 N=16 K=16 fp_fmt=FP16 SW=$(pwd)/inc

# Compile RTL for simulation
bender script verilator

# Run with GUI (requires license)
make gui=1 target=modelsim UseXif=0
```

## Common Pitfalls
- **Parameter consistency**: Changes to `redmule_pkg.sv` parameters must propagate through Bender build system
- **Matrix dimensions**: M×N × N×K → M×K; must be multiples of ARRAY_HEIGHT for efficiency
- **Precision conversions**: FP8 cast modules introduce saturation/rounding - verify against golden model
- **XIF mode complexity**: Custom instruction encoding differs from memory-mapped - check CV32E40X XIF spec
