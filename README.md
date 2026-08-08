# SlocumIO.jl

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.21345329.svg)](https://doi.org/10.5281/zenodo.21345329)

A pure-Julia reader for Slocum ocean glider binary data files (`.dbd`, `.sbd`, `.mbd`, `.ebd`, `.tbd`, `.nbd`) and their LZ4-compressed variants (`.dcd`, `.scd`, `.mcd`, `.ecd`, `.tcd`, `.ncd`).

This is a ground-up Julia translation of the Python [`dbdreader`](https://github.com/smerckel/dbdreader) package by Lucas Merckelbach (Helmholtz-Zentrum Hereon), addressing the architectural issues, bugs, and design shortcomings identified in a critical evaluation of that codebase (see [`docs/evaluation.pdf`](docs/evaluation.pdf)). As a derivative of dbdreader it is licensed **GPL-3.0-or-later**, matching upstream (see Licensing below).

## Status

Every test run reads real glider files and compares SHA-256 fingerprints of the decoded float64
arrays byte-for-byte. See [Validation](#validation) for exactly what is checked against what.

## Quick start

```julia
using SlocumIO

# Single file
dbd = open_dbd("00010010.dbd"; cachedir="/path/to/cache")
ts = get_data(dbd, "m_depth")               # TimeSeries with .time and .value

# Synchronize multiple parameters onto a common time base
t, hdg, pitch, roll = get_sync(dbd, "m_heading", "m_pitch", "m_roll")

# Multiple files at once
m = MultiDBD(pattern="data/*.dbd"; cachedir="/path/to/cache",
             complement_files=true)         # auto-add matching .ebd/.tbd
all_depth = get_data(m, "m_depth")
t, T, C, P = get_sync(m, "sci_water_temp", "sci_water_cond", "sci_water_pressure")
```

### Split-directory layouts

When engineering and science files are archived in separate directories (common
when DBDs come off the dockserver and EBDs arrive separately via SFMC), use
`eng_dir` and `sci_dir`:

```julia
m = MultiDBD(eng_dir  = "/data/from-glider",
             sci_dir  = "/data/from-science",
             cachedir = "/data/cache")

# Optional patterns to restrict file types within each directory
m = MultiDBD(eng_dir     = "/data/from-glider",
             sci_dir     = "/data/from-science",
             eng_pattern = "*.[dD][bB][dD]",   # only DBDs
             sci_pattern = "*.[eE][bB][dD]",   # only EBDs
             cachedir    = "/data/cache")

# Enforce "every file has a pair": drop files whose sibling is missing
m = MultiDBD(eng_dir = "/data/from-glider",
             sci_dir = "/data/from-science",
             cachedir = "/data/cache",
             complemented_files_only = true)
```

The `eng_dir`/`sci_dir` keywords combine with `filenames` and `pattern`
additively — they're not mutually exclusive. Files are classified as eng or
sci by extension at open time, regardless of which directory they came from.

## What this fixes vs `dbdreader`

| Issue | `dbdreader` (Python + C) | `SlocumIO.jl` |
|-------|--------------------------|------------------|
| Build dependency | C compiler + headers required | Pure Julia, zero non-Julia deps |
| Error handling | `exit(1)` in C on read failure | Julia exceptions, recoverable |
| NaN encoding | `1e9` sentinel + `isclose` check | Direct IEEE `NaN` |
| NMEA validation | Degree bounds only | Degrees + **minutes < 60** |
| Locale | Global `setlocale` mutation at import | No locale dependency |
| Cache directory | `mkdir` side-effect at import | Explicit, opt-in |
| Thread safety | C `static` variables in reader | Fully thread-safe |
| `scipy` dependency | Required for `interp1d` | Built-in linear + heading interp |
| Dead code | ~200 lines of unused Python reader | None |
| Stale `fp` handle | Created at construction, used much later | Opened per call, closed cleanly |

## File format reference (validated empirically)

After the ASCII header, the binary section consists of:

```
17-byte known-cycle preamble (used for endianness detection)
  ─ 's' (0x73)
  ─ 1 byte int8 tag (arbitrary)
  ─ uint16 0x1234 (endianness marker)
  ─ float32 123.456
  ─ float64 123456789.12345
  ─ 'd' (0x64)

Per data cycle:
  ─ state_bytes_per_cycle state bytes (2 bits/sensor, MSB first per byte)
  ─ chunk of sensor values (sum of bytesizes for UPDATED sensors, in cycle order)
  ─ 1 separator byte   ← between cycles only; absent after the last one
```

State value encoding: `0 = NOTSET`, `1 = SAME` (use last value), `2 = UPDATED` (read new value).

The single most easily-overlooked detail in porting this format is the **1-byte separator between cycles** (implicit in the C extension's `fp_current += chunksize + 1`).

The second-most easily overlooked detail is that this separator **delimits cycles rather than
terminating them**. A file ends `state_bytes | chunk`, with the last chunk's final byte being the
last byte of the file — there is no trailing separator. A reader that requires `chunk + separator`
to fit before accepting a cycle silently discards the last complete cycle of *every* file. Both
fixture files exhibit this (`chunk_end == filesize` exactly), and the regression test
`"Real-file: final cycle is not dropped"` pins the behaviour.

## Sensor list (cache) file format

```
s:  F|T   full_idx   active_pos   bytesize   name   unit
```

- The cache file lists every sensor in the file's full namespace (one line per sensor).
- `active_pos == -1` means the sensor is not in this cycle.
- The cycle layout is **dense in `active_pos`**: positions are contiguous from `0` to `sensors_per_cycle-1`.

## Cache file discovery

Cache files (`.cac` plain, `.ccc` LZ4-compressed) are located by their CRC, in this order:

1. The `cachedir` keyword argument passed to `open_dbd`/`MultiDBD`.
2. `./cache` relative to the current working directory.
3. `<datafile_dir>/cache`.
4. `<datafile_dir>` itself.
5. The platform-default directory ([`default_cachedir()`](src/cache.jl)).

Both the lowercase and uppercase spellings of the CRC basename are tried in each
directory, since dockserver case is inconsistent and that matters on
case-sensitive filesystems. If no matching cache is found, the error message
lists every directory that was searched.

## API

| Function | Purpose |
|----------|---------|
| `open_dbd(path; cachedir)`             | Open one file, parse header, locate cache. |
| `MultiDBD(; filenames, pattern, ...)`  | Open a set of files. |
| `get_data(dbd_or_multi, params...)`    | Read parameters; per-parameter time bases. |
| `get_sync(dbd_or_multi, params...)`    | Read + linearly interpolate onto first param's time base. |
| `parameter_names(dbd_or_multi)`        | List available parameters. |
| `has_parameter(dbd_or_multi, name)`    | Membership check. |
| `linear_interp(t, t_src, v_src)`       | Linear interpolation, NaN outside source range. |
| `heading_interp(t, t_src, v_src)`      | Wrap-correct interp for compass headings. |
| `nmea_to_decimal(x)`                   | NMEA `DDDMM.MMMM` → decimal degrees. |
| `is_valid_nmea(x, is_latitude)`        | Strict validation including minutes < 60. |
| `default_cachedir()`                   | Platform default cache directory (does not create it). |
| `decompress_glider_file(path)`         | LZ4 decompress an entire compressed glider file to memory. |

## Validation

Two distinct things, with different provenance — worth keeping separate.

**1. Continuous (runs on every `Pkg.test()`).** A real fixture is committed to
[`test/data/`](test/data): one `.sbd` and one `.tbd` from `electa`, MARACOOS deployment 2025-05,
with their sensor-list caches and one LZ4-compressed `.ccc` cache. Twelve `(file, parameter)`
combinations are checked, comparing **SHA-256 over the raw float64 bytes** of both the value and
time arrays — byte-level equality, not just matching `n`/`min`/`max`. The expected fingerprints in
`test/data/fingerprints.json` are produced by [`tools/julia_reference.py`](tools/julia_reference.py),
an independent pure-Python implementation of the same algorithm, so agreement is a genuine
cross-implementation check. It is *not* a dbdreader comparison.

To validate against your own archive instead:

```bash
SLOCUMIO_TEST_DATA=/path/to/your/files julia --project=. -e 'using Pkg; Pkg.test()'
```

The directory needs the data files, a `cache/` subdirectory, and a `fingerprints.json` — generate
one with `python3 tools/julia_reference.py /path/to/your/files -o /path/to/your/files/fingerprints.json`.

**2. Historical dbdreader comparison.** Earlier development compared 45 `(file, parameter)`
combinations against `dbdreader`'s output across two gliders (`electa` 2024-07-21, `sylvia`
2024-09-30) and all five readable file types (DBD, SBD, MBD, EBD, TBD); all matched exactly. Those
fingerprints are preserved in
[`test/reference_fingerprints.json`](test/reference_fingerprints.json) as a record. **They are not
executed by the test suite** — the source files are not redistributable here, so the comparison
cannot be re-run from this repository. Treat it as a documented past result rather than a
continuously verified property.

## Installation

```julia
] add https://github.com/oceansensing/SlocumIO.jl
```

For development:

```julia
] dev /path/to/SlocumIO.jl
```

## Licensing and provenance

SlocumIO.jl is a Julia translation of
[`dbdreader`](https://github.com/smerckel/dbdreader) by Lucas Merckelbach
(Helmholtz-Zentrum Hereon), which is licensed GPL-3.0-or-later. As a derivative
work, SlocumIO.jl is likewise distributed under the
**GNU General Public License v3.0 or later** (see [LICENSE](LICENSE)).
The byte-for-byte validation against `dbdreader`'s output
(`test/reference_fingerprints.json`, `tools/julia_reference.py`) is original to
this package. If you use SlocumIO.jl in published work, please also credit
`dbdreader` (the `CITATION.cff` carries it as a reference). Note the GPL applies to this reader only: packages that consume
its *output tables* (e.g. GliderADCP.jl's `slocum_nav`) are not derivatives and
carry their own licenses.
