RLengine 4.0 is a complete low-level architectural rewrite of the engine's core simulation kernel, transitioning from standard Lua/FFI object-oriented structures to a hardware-oriented, SIMD-friendly **Structure of Arrays (SoA)** memory layout.

---

## 1. Architectural Overhaul: SoA vs. AoS

* **RLengine 3.x (Array of Structures - AoS):** Particle data was stored as contiguous structs or nested tables containing all properties per particle (`{x, y, z, vx, vy, vz, ...}`). This caused CPU cache misses when iterating through single attributes across millions of elements.
* **RLengine 4.0 (Structure of Arrays - SoA):** Data is split into isolated, contiguous single-type buffers (`buf_x`, `buf_y`, `buf_z`, `buf_vx`, etc.). When updating positions or velocities, the CPU cache loads only the exact float arrays needed, maximizing L1/L2 cache hit rates and allowing LuaJIT to auto-vectorize loops.

---

## 2. Zero-GC Allocation & Raw Pointer Arithmetic

* **Zero Garbage Collection Pressure:** All buffers are pre-allocated using raw memory via `love.data.newByteData` and cast directly to native C pointers (`ffi.cast("float*", ...)`). Lua's garbage collector remains virtually idle during runtime.
* **Direct Vertex Pointer Mutation:** Instead of generating temporary Lua tables or struct instances to update the rendering mesh, RLengine 4.0 calculates offsets using raw C pointer arithmetic (`vPtr + i`). It writes directly to mapped mesh byte buffers in a single pass.

---

## 3. Pre-Baked Color Look-Up Tables (LUT)

* **RLengine 3.x:** Evaluated dynamic mathematical palette functions and color-space conversions per particle inside the main simulation loop every frame.
* **RLengine 4.0:** Pre-computes all 8 color palettes into an ultra-fast 3D byte array (`uint8_t[8][256][4]`) during initialization. Color mapping during particle updates requires only an $O(1)$ fast integer index lookup based on particle speed.

---

## 4. Scalability & Throughput

* **Particle Capacity:** Scales from $\approx 300,000$ particles in version 3.x up to **3,000,000+** real-time particles in 4.0 while maintaining high frame rates.
* **SIMD-Optimized Math:** Localized math operations (using local micro-caches like `m_sin`, `m_cos`, `m_sqrt`) minimize FFI boundary overhead within LuaJIT's trace compiler.

---

## Feature Comparison Matrix

| Feature | RLengine 3.5 | RLengine 4.0 Ultra-Kernel |
| --- | --- | --- |
| **Data Layout** | Array of Structures (AoS) | Structure of Arrays (SoA) |
| **Memory Allocation** | Lua Tables / FFI Struct Arrays | Raw `ByteData` & Direct C Pointers |
| **Garbage Collection (GC)** | Low-to-Moderate spikes | Zero GC during runtime |
| **Color Evaluation** | Dynamic per-frame functions | 8x256 Pre-calculated LUT |
| **Max Particle Target** | ~300,000 | **3,000,000+** |
| **Procedural Shapes** | 8 Shapes | 8 Shapes (Preserved) |
| **Force Fields** | 6 Vector Fields | 6 Vector Fields (Preserved) |
| **Physics Features** | Attractors, Shockwaves | Attractors, Shockwaves (Preserved) |
| **Camera & PostFX** | Orbit/WASD, Chromatic Aberration | Orbit/WASD, Chromatic Aberration (Preserved) |
