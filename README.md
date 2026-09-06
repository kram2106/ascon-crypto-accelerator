# ASCON-128a Lightweight Cryptographic Accelerator with RISC-V SoC Integration

A hardware cryptographic accelerator implementing the NIST-standardized ASCON authenticated encryption algorithm (SP 800-232), integrated as a memory-mapped peripheral into a RISC-V (PicoRV32) System-on-Chip, and carried through a complete 90nm ASIC physical design flow using Cadence EDA tools.

> Built as part of a B.Tech ECE final-year project at VIT Chennai, under the guidance of Dr. Jean Jenifer Nesam J.

---

## Why this project

Most academic ASCON implementations stop at "the algorithm works in simulation." This project goes further by taking the ASCON accelerator through a complete ASIC implementation flow, including synthesis and physical layout, resulting in a design that is DRC-clean and timing-clean. The accelerator was also integrated into a processor-driven SoC at the RTL level and functionally verified through simulation, demonstrating both the physical realization of the ASCON hardware and its integration within a processor-based system.

**Key numbers:**

| Metric              | Value              |
|----------------------|--------------------|
| Technology node      | 90nm CMOS (gpdk90) |
| Max frequency         | 250 MHz            |
| Throughput            | 711.11 Mbps        |
| Core area              | 98,008.71 µm²      |
| Gate count             | 25.899 kGE         |
| Total power             | 17.554 mW         |
| Energy efficiency        | 40.51 Gbits/J    |
| Post-route timing slack   | +0.013 ns       |
| DRC / connectivity violations | 0           |
| LEC (RTL vs. gate-level)   | PASS            |

---
