# third_party —— 外部开源 RTL（vendored）

本目录是**原样拷入的第三方开源 RTL**，用于 SoC 总线加宽到 64 位。不做任何本地修改；
需要适配的地方一律写在 `soc/rtl/` 下我们自己的 wrapper 里，不动这里的文件。

## 溯源

| 包 | 版本 | commit | 日期 | 来源 |
|---|---|---|---|---|
| `axi` | v0.39.9 | `a256a3b86394fedf19e361047fccfdd7f6ef83e4` | 2025-11-21 | https://github.com/pulp-platform/axi |
| `common_verification` | v0.2.5 | `fb1885f48ea46164a10568aeff51884389f67ae3` | — | https://github.com/pulp-platform/common_verification |

**`common_cells` 曾在此目录、后被删除**（commit `654d691`，82 个文件）：仓库里本来就有一份
`soc/rtl/ip/open-la500/fpu/cvfpu/common_cells`，两份并存会撞 `cf_math_pkg` 等包名。实测 cvfpu
那份更新（1.38+ 的写法），故删掉这里的 v1.37.0、把五处引用统一指向 cvfpu 那份。
删后 26/26 等价性 + DC + Vivado 综合 + SoC token md5 全过。
`axi` 的依赖因此由 cvfpu 那份 `common_cells` 满足，不再由本目录提供。

许可：Solderpad Hardware License v0.51（基于 Apache-2.0），各包内 `LICENSE` 为准。

版本一致性：`axi/Bender.yml` 声明的依赖为 `common_cells 1.37.0` / `common_verification 0.2.5`；
`common_verification` 版本一致，`common_cells` 见上方说明（用 cvfpu 那份更新的替代）。

> 注意：`fsa_llm_sv` 的 `axi` 虽然 `VERSION` 写着 0.39.9，实际是更新的 master（多出
> `axi_demux_id_counters.sv`，那是后来从 `axi_demux.sv` 拆出来的，且另有 17 个文件不同）。
> **本目录用的是 v0.39.9 tag 原版，不要拿那份的 filelist 直接套。**

## 只拷了什么

每个包只拷 `src/` `include/` 以及 `Bender.yml` / `src_files.yml` / `LICENSE` / `README.md` / `VERSION`，
未拷 `test/` `doc/` `scripts/` `.github/` 等。共 187 个文件、约 2.0MB。

## 用到的模块

- **`axi_xbar`** —— 全连接 crossbar，替换原 `soc/rtl/ip/Bus_interconnects/AxiCrossbar_2x8.v`
  （SpinalHDL v1.10.1 生成物，仓库内无 `.scala` 源）。位宽是 `axi_pkg::xbar_cfg_t` 的参数，
  32→64 只改一个数。
- **`axi_dw_converter`** —— 位宽转换（内部按方向选 `axi_dw_upsizer` / `axi_dw_downsizer`）。
  CPU 主口固定 32 位（`core_top` 里 `rdata`/`wdata` 写死 `[31:0]`，无参数），而 `axi_xbar` 要求
  全端口同宽，所以 CPU 侧必须有一个升宽器。
- **`axi_test.sv`** + `common_verification` —— 仿真用 VIP，**只进 tb filelist，不进综合**。

## 编译顺序

见 `scripts/pulp_axi_rtl_filelist.f`（可综合部分）与 `scripts/pulp_axi_vip_filelist.f`（仿真专用）。
axi 的顺序取自本版本 `Bender.yml` 的 level 0→6 分组（同 level 内按字母序），**不是照抄别处的 filelist**。

## 升级注意

若要换版本：重新按 tag clone、整目录替换、更新上表的 commit，然后**必须重跑第 1 步的三条工具链判据**
（VCS 编译 / Vivado 2023.1 综合 / DC）与性能定标——PULP 的 SV 写法较重（struct / interface / typedef），
不同版本对工具的要求可能不同。
