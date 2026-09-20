### What’s New in RLengine 4.0 (Compared to RLengine 3.0)

While RLengine 3.0 introduced the **3,000,000 particle target**, version 4.0 is a low-level architectural rewrite designed to make that 3M target run at **smooth, stable frame rates** without micro-stutters or CPU bottlenecks.

#### 1. Memory Architecture Transformation (AoS $\rightarrow$ SoA)

* **RLengine 3.0 (Array of Structures):** Stored particle attributes together in contiguous struct elements ($x, y, z, vx, vy, vz, \dots$). Iterating through 3 million complex structures caused constant CPU L1/L2 cache misses.
* **RLengine 4.0 (Structure of Arrays):** Splits data into separate, contiguous `float` arrays (`buf_x`, `buf_y`, `buf_z`, etc.). When updating positions, the CPU loads only the raw position data into the cache, enabling LuaJIT auto-vectorization and SIMD-like execution.

#### 2. Elimination of GC Micro-Stutters

* **RLengine 3.0:** High memory throughput at 3M particles periodically triggered Lua garbage collector sweeps, leading to small frame spikes under heavy physics interaction.
* **RLengine 4.0:** Uses raw `ByteData` memory pointers with zero allocations inside the update/render loops, completely isolating the simulation from the Garbage Collector.

#### 3. Pointer Arithmetic & Pre-Baked Look-Up Tables

* **Direct Pointer Offsets:** Writes transformed vertex coordinates directly into mapped mesh buffers using raw C pointer arithmetic (`vPtr + i`) without struct copying.
* **$O(1)$ Color LUT:** Replaces dynamic per-particle palette calculations with a pre-baked $8 \times 256$ 3D byte array (`uint8_t[8][256][4]`).

---

### Feature & Performance Comparison: 3.0 vs 4.0

| Feature / Metric | RLengine 3.0 | RLengine 4.0 Ultra-Kernel |
| --- | --- | --- |
| **Max Particle Limit** | 3,000,000 | 3,000,000 |
| **Performance at 3M Particles** | Heavy CPU load / Frame drops | **High & Stable FPS (Cache-Optimized)** |
| **Data Layout** | Array of Structures (AoS) | **Structure of Arrays (SoA)** |
| **Garbage Collector Impact** | Occasional GC sweeps / spikes | **Zero GC pressure in update loop** |
| **Color Rendering** | Dynamic runtime math | **Pre-calculated 3D LUT** |
| **Vertex Processing** | Struct copies / FFI writes | **Raw C pointer arithmetic (`vPtr + i`)** |
| **Physics & FX Features** | 8 Shapes, 6 Forces, Attractors | **100% Preserved & Accelerated** |
