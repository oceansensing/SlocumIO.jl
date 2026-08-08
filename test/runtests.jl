using Test
using Dates
using SHA
using SlocumIO
using SlocumIO: bswap_int16, bswap_float32, bswap_float64,
                   decode_state_bytes!, detect_byte_order,
                   parse_sensor_list, parse_fileopen_time,
                   is_valid_nmea, is_lat_param,
                   candidate_cachedirs, default_cachedir,
                   read_file_header, find_cache_file,
                   _slocum_sort_key, sort_slocum!,
                   paired_extension, paired_filename, glob_files,
                   find_paired_file, read_sensor_value, read_cache_file

# ── Test-fixture location ─────────────────────────────────────────────────────
#
# Real glider files live in `test/data/` by default.  Point SLOCUMIO_TEST_DATA
# at another directory to validate against your own archive; it must contain
# the data files plus a `cache/` subdirectory and a `fingerprints.json`.

const DATA_DIR  = get(ENV, "SLOCUMIO_TEST_DATA", joinpath(@__DIR__, "data"))
const CACHE_DIR = joinpath(DATA_DIR, "cache")
const FP_PATH   = joinpath(DATA_DIR, "fingerprints.json")
const ENG_FILE  = "electa-2025-120-1-113.sbd"
const SCI_FILE  = "electa-2025-120-1-141.tbd"

const HAS_REFERENCE = isfile(FP_PATH) &&
                      isfile(joinpath(DATA_DIR, ENG_FILE)) &&
                      isfile(joinpath(DATA_DIR, SCI_FILE)) &&
                      isdir(CACHE_DIR)

HAS_REFERENCE || @info """
    Real-file tests SKIPPED: no fixture found at $DATA_DIR.
    Set SLOCUMIO_TEST_DATA to a directory containing the data files, a
    cache/ subdirectory, and fingerprints.json. Unit tests still run.
    """

"""First 16 hex chars of the SHA-256 over the raw float64 bytes — the same
byte-level fingerprint `tools/julia_reference.py` emits."""
sha16(v::Vector{Float64}) = bytes2hex(sha256(reinterpret(UInt8, v)))[1:16]

@testset "SlocumIO.jl" begin

# ── Unit tests (no I/O) ──────────────────────────────────────────────────────

@testset "NMEA conversion" begin
    @test nmea_to_decimal(5312.345) ≈ 53.20575 atol=1e-10
    @test nmea_to_decimal(-5312.345) ≈ -53.20575 atol=1e-10
    @test nmea_to_decimal(0.0) == 0.0
    @test nmea_to_decimal(5300.0) ≈ 53.0 atol=1e-10
    @test isnan(nmea_to_decimal(NaN))
end

@testset "NMEA validation" begin
    @test is_valid_nmea(5312.345, true) == true
    @test is_valid_nmea(12045.678, false) == true
    @test is_valid_nmea(9100.0, true) == false        # > 90° lat
    @test is_valid_nmea(18100.0, false) == false      # > 180° lon
    # The dbdreader bug fix: minutes ≥ 60 is invalid
    @test is_valid_nmea(5360.0, true) == false
    @test is_valid_nmea(5359.9999, true) == true
    @test is_valid_nmea(NaN, true) == false
    @test is_valid_nmea(Inf, false) == false
end

@testset "Lat/lon param detection" begin
    @test is_latlon_param("m_lat") == true
    @test is_latlon_param("m_gps_lon") == true
    @test is_latlon_param("m_depth") == false
    @test is_lat_param("m_lat") == true
    @test is_lat_param("m_lon") == false
end

@testset "File type classification" begin
    @test is_science_file("test.ebd") == true
    @test is_science_file("test.tbd") == true
    @test is_science_file("test.dbd") == false
    @test is_science_file("test.sbd") == false
    @test is_science_file("test.EBD") == true        # case-insensitive
    @test is_compressed("test.dcd") == true
    @test is_compressed("test.ecd") == true
    @test is_compressed("test.dbd") == false
end

@testset "Eng↔Sci file pairing" begin
    @test paired_extension(".dbd") == ".ebd"
    @test paired_extension(".ebd") == ".dbd"
    @test paired_extension(".sbd") == ".tbd"
    @test paired_extension(".tbd") == ".sbd"
    @test paired_filename("/a/b/glider-2024-1-0-0.dbd") == "/a/b/glider-2024-1-0-0.ebd"
end

@testset "Slocum filename sorting" begin
    files = [
        "glider-2024-100-1-9.dbd",
        "glider-2024-100-1-10.dbd",
        "glider-2024-100-1-2.dbd",
        "glider-2024-100-2-0.dbd",
        "glider-2024-99-7-0.dbd",
    ]
    sort_slocum!(files)
    @test files == [
        "glider-2024-99-7-0.dbd",
        "glider-2024-100-1-2.dbd",
        "glider-2024-100-1-9.dbd",
        "glider-2024-100-1-10.dbd",
        "glider-2024-100-2-0.dbd",
    ]
end

@testset "Linear interpolation" begin
    t_src = [1.0, 2.0, 3.0, 4.0, 5.0]
    v_src = [10.0, 20.0, 30.0, 40.0, 50.0]

    # Exact points
    @test linear_interp([1.0, 3.0, 5.0], t_src, v_src) ≈ [10.0, 30.0, 50.0]
    # Midpoints
    @test linear_interp([1.5, 2.5, 3.5], t_src, v_src) ≈ [15.0, 25.0, 35.0]
    # Out of bounds → NaN
    result = linear_interp([0.0, 6.0], t_src, v_src)
    @test all(isnan, result)
    # Empty source
    @test all(isnan, linear_interp([1.0], Float64[], Float64[]))
end

@testset "Heading interpolation" begin
    # Wrap around 0/2π: 350° → 10°, midpoint should be ~0°
    t_src = [0.0, 1.0]
    v_src = [350.0 * π/180, 10.0 * π/180]
    result = heading_interp([0.5], t_src, v_src)
    # midpoint should be near 0 (or 2π); not 180°
    angle_diff = min(abs(result[1]), abs(result[1] - 2π))
    @test angle_diff < 0.1
end

@testset "Byte-swap helpers" begin
    @test bswap_int16(Int16(0x1234)) == Int16(0x3412)
    @test bswap_float32(Float32(1.0)) != Float32(1.0)
    @test bswap_float32(bswap_float32(Float32(1.0))) == Float32(1.0)
    @test bswap_float64(bswap_float64(1.0)) == 1.0
end

@testset "State byte decoding" begin
    # 0xAA = 10101010 = [2,2,2,2] = all UPDATED
    states = Vector{UInt8}(undef, 8)
    decode_state_bytes!(states, IOBuffer([0xAA, 0xAA]), 2, 8)
    @test all(==(SlocumIO.UPDATED), states)
    # 0x00 = all NOTSET, 0x55 = [1,1,1,1] = all SAME
    decode_state_bytes!(states, IOBuffer([0x00, 0x55]), 2, 8)
    @test states[1:4] == fill(SlocumIO.NOTSET, 4)
    @test states[5:8] == fill(SlocumIO.SAME, 4)
end

@testset "fileopen_time parsing" begin
    t = parse_fileopen_time("Sun_Jul_21_23:00:36_2024")
    @test t ≈ 1721602836.0 atol=2.0
    @test isnan(parse_fileopen_time("garbage"))
    @test isnan(parse_fileopen_time("Sun_Xyz_21_23:00:36_2024"))  # bad month
end

@testset "LZ4 block decoder" begin
    # Trivial: 4 literal bytes, no match
    # token=0x40 (lit_len=4, match_len=0), then 4 literal bytes
    @test SlocumIO.lz4_decompress_block(UInt8[0x40, 0x48, 0x65, 0x6C, 0x6F]) == UInt8[0x48, 0x65, 0x6C, 0x6F]
end

@testset "Cache directory resolution" begin
    @test !isempty(default_cachedir())
    cands = candidate_cachedirs("/foo/bar")
    @test "/foo/bar" in cands
    @test default_cachedir() in cands
    # Documented order: user dir, ./cache, <datadir>/cache, <datadir>, platform default.
    # Derive the expected data directory the same way the implementation does
    # rather than hardcoding a POSIX literal — abspath normalises separators,
    # so "/data/glider" becomes "\\data\\glider" on Windows.
    datafile = joinpath("/data", "glider", "00010000.dbd")
    datadir  = dirname(abspath(datafile))
    with_data = candidate_cachedirs("/foo/bar", datafile)
    @test with_data[1] == "/foo/bar"
    @test with_data[2] == joinpath(pwd(), "cache")
    @test with_data[3] == joinpath(datadir, "cache")
    @test with_data[4] == datadir
    @test with_data[end] == default_cachedir()   # platform default is LAST
end

@testset "TimeSeries iteration" begin
    ts = TimeSeries([1.0, 2.0, 3.0], [10.0, 20.0, 30.0])
    @test length(ts) == 3
    @test !isempty(ts)
    @test collect(ts) == [(1.0, 10.0), (2.0, 20.0), (3.0, 30.0)]
end

# ── Regression tests: one per bug fixed ──────────────────────────────────────

@testset "regression: asctime pads single-digit day (fileopen_time)" begin
    # Slocum writes C asctime, which space-pads days 1-9. After the dockserver
    # maps spaces to underscores that leaves an EMPTY field:
    #   "Fri_May__2_11:57:20_2025" -> ["Fri","May","","2","11:57:20","2025"]
    # Splitting with keepempty=true made every such file parse as NaN.
    t1 = parse_fileopen_time("Fri_May__2_11:57:20_2025")
    @test !isnan(t1)
    @test Dates.unix2datetime(t1) == Dates.DateTime(2025, 5, 2, 11, 57, 20)
    t2 = parse_fileopen_time("Thu_May__8_04:22:10_2025")
    @test Dates.unix2datetime(t2) == Dates.DateTime(2025, 5, 8, 4, 22, 10)
    # Two-digit days must keep working
    @test Dates.unix2datetime(parse_fileopen_time("Sun_Jul_21_23:00:36_2024")) ==
          Dates.DateTime(2024, 7, 21, 23, 0, 36)
end

@testset "regression: sort key survives wide mission/segment fields" begin
    # Packing into one integer gave the segment only 3 digits, so segment>=1000
    # overflowed into the mission field and produced identical keys.
    @test _slocum_sort_key("gl-2024-100-1-0.dbd") != _slocum_sort_key("gl-2024-100-0-1000.dbd")
    f = ["gl-2024-100-1-999.dbd", "gl-2024-100-1-1000.dbd",
         "gl-2024-100-2-0.dbd",   "gl-2024-100-1-1001.dbd"]
    sort_slocum!(f)
    @test f == ["gl-2024-100-1-999.dbd", "gl-2024-100-1-1000.dbd",
                "gl-2024-100-1-1001.dbd", "gl-2024-100-2-0.dbd"]
    # mission >= 100 must not bleed into the day-of-year field
    g = ["gl-2024-101-0-0.dbd", "gl-2024-100-100-0.dbd"]
    sort_slocum!(g)
    @test g == ["gl-2024-100-100-0.dbd", "gl-2024-101-0-0.dbd"]
end

@testset "regression: find_paired_file handles bare relative names" begin
    # dirname("a.dbd") == "" and isdir("") is false, so the file's own
    # directory used to be skipped entirely.
    mktempdir() do dir
        cd(dir) do
            touch("00010000.dbd"); touch("00010000.ebd")
            p = find_paired_file("00010000.dbd")
            @test p !== nothing
            @test basename(p) == "00010000.ebd"
        end
    end
end

@testset "regression: glob escapes regex metacharacters" begin
    mktempdir() do dir
        for n in ("a+b.dbd", "aab.dbd", "ab.dbd"); touch(joinpath(dir, n)); end
        # '+' used to be a regex quantifier: matched aab/ab, missed the literal.
        @test basename.(glob_files(joinpath(dir, "a+b.dbd"))) == ["a+b.dbd"]
        @test sort(basename.(glob_files(joinpath(dir, "a*.dbd")))) ==
              ["a+b.dbd", "aab.dbd", "ab.dbd"]
        # character classes must still work
        touch(joinpath(dir, "x.sbd")); touch(joinpath(dir, "x.tbd"))
        @test sort(basename.(glob_files(joinpath(dir, "*.[sStT][bB][dD]")))) ==
              ["x.sbd", "x.tbd"]
    end
end

@testset "regression: state buffer is cleared between cycles" begin
    # `states` is reused across cycles and only 4*nsb entries get written, so
    # without an explicit clear the tail held the PREVIOUS cycle's states.
    states = Vector{UInt8}(undef, 8)
    fill!(states, 0xFF)                       # simulate stale prior content
    decode_state_bytes!(states, IOBuffer([0xAA]), 1, 8)   # only 4 sensors covered
    @test states[1:4] == fill(SlocumIO.UPDATED, 4)
    @test states[5:8] == fill(SlocumIO.NOTSET, 4)
end

@testset "regression: interp_fn Dict is keyed by input-series index" begin
    # The key indexes `series`, NOT the returned tuple: series[2] comes back
    # as out[3]. The docs previously showed Dict(3 => heading_interp) for a
    # 2-parameter call, which silently matched nothing.
    marker(t, ts, vs) = fill(-999.0, length(t))
    s = [TimeSeries([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]),
         TimeSeries([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]),
         TimeSeries([1.0, 2.0, 3.0], [100.0, 200.0, 300.0])]
    out = SlocumIO.get_sync(s; interp_fn = Dict(2 => marker))
    @test out[3] == fill(-999.0, 3)      # series[2] -> out[3], customised
    @test out[4] ≈ [100.0, 200.0, 300.0] # series[3] -> out[4], default interp
    # A key past the end is ignored rather than erroring.
    out2 = SlocumIO.get_sync(s; interp_fn = Dict(9 => marker))
    @test !any(==(-999.0), out2[3])
end

@testset "regression: linear_interp needs an ascending base" begin
    # Documents the precondition that MultiDBD.get_data now guarantees by
    # sorting its eng+sci merge: an unsorted base silently extrapolates.
    t_src = [1.0, 2.0, 3.0, 4.0, 5.0]
    v_src = [0.0, 1.0, 4.0, 9.0, 16.0]        # non-linear, so errors show
    @test linear_interp([1.5, 2.5, 4.5], t_src, v_src) ≈ [0.5, 2.5, 12.5]
end

# ── Integration tests against real glider files ──────────────────────────────

if HAS_REFERENCE
    using JSON

    eng_path = joinpath(DATA_DIR, ENG_FILE)
    sci_path = joinpath(DATA_DIR, SCI_FILE)

    @testset "Real-file: header parsing" begin
        eng = open_dbd(eng_path; cachedir=CACHE_DIR)
        @test eng.header.encoding_ver == 5
        @test eng.header.sensors_per_cycle == 64
        @test eng.header.state_bytes_per_cycle == 16
        @test eng.header.sensor_list_crc == "0f682cb2"
        @test eng.header.sensor_list_factored == 1
        @test eng.header.total_num_sensors == 2709
        @test eng.header.mission_name == "electash.mi"
        @test length(eng.sensors) == 64
        @test eng.time_var_name == "m_present_time"
        @test has_parameter(eng, "m_depth")
        @test has_parameter(eng, "m_gps_lat")
        @test !has_parameter(eng, "bogus_sensor_name")
        # full namespace is retained alongside the active cycle sensors
        @test length(eng.all_sensor_names) == 2709
        @test "m_depth" in eng.all_sensor_names

        sci = open_dbd(sci_path; cachedir=CACHE_DIR)
        @test sci.header.sensors_per_cycle == 14
        @test sci.header.state_bytes_per_cycle == 4
        @test sci.time_var_name == "sci_m_present_time"
        @test has_parameter(sci, "sci_water_temp")

        # fileopen_time must parse (these files use asctime's padded day)
        @test !isnan(parse_fileopen_time(eng.header.fileopen_time))
        @test !isnan(parse_fileopen_time(sci.header.fileopen_time))
    end

    @testset "Real-file: SHA-256 fingerprints" begin
        ref = JSON.parsefile(FP_PATH)
        cases = [
            (ENG_FILE, ["m_present_time", "m_depth", "m_gps_lat", "m_gps_lon",
                        "m_heading", "m_pitch", "m_roll", "m_battery"]),
            (SCI_FILE, ["sci_m_present_time", "sci_water_temp",
                        "sci_water_cond", "sci_water_pressure"]),
        ]
        for (fname, params) in cases
            dbd = open_dbd(joinpath(DATA_DIR, fname); cachedir=CACHE_DIR)
            # Raw values: the fingerprints are over undecorated reader output.
            r = get_data(dbd, params...; decimal_latlon=false, discard_bad_latlon=false)
            r isa TimeSeries && (r = [r])
            file_ref = ref[fname]["params"]
            for (i, p) in pairs(params)
                expect = file_ref[p]["value"]
                @test length(r[i]) == expect["n"]
                # Byte-level equality, not just min/max agreement.
                @test sha16(r[i].value) == expect["sha256"]
                @test sha16(r[i].time)  == file_ref[p]["time"]["sha256"]
                if expect["n"] > 0
                    finite = filter(isfinite, r[i].value)
                    if !isempty(finite)
                        @test minimum(finite) ≈ expect["min"] rtol=1e-9
                        @test maximum(finite) ≈ expect["max"] rtol=1e-9
                    end
                end
            end
        end
    end

    @testset "Real-file: final cycle is not dropped" begin
        # The separator byte delimits cycles rather than terminating them, so
        # a file ends `state_bytes | chunk` with no trailing separator.
        # Demanding the separator discarded the last complete cycle of EVERY
        # file. Verify the reader consumes the file right up to its last byte.
        dbd = open_dbd(sci_path; cachedir=CACHE_DIR)
        ts = get_data(dbd, "sci_water_temp")
        @test length(ts) == 871          # 870 before the fix
        tt = get_data(dbd, "sci_m_present_time")
        @test length(tt) == 967
    end

    @testset "Real-file: NMEA conversion" begin
        dbd = open_dbd(eng_path; cachedir=CACHE_DIR)
        raw = get_data(dbd, "m_gps_lat"; decimal_latlon=false, discard_bad_latlon=false)
        @test length(raw) == 25
        @test all(v -> 3800 < v < 3900, raw.value)      # NMEA degrees×100
        dec = get_data(dbd, "m_gps_lat")
        @test all(v -> 38 < v < 39, dec.value)          # decimal degrees
        # 3841.174 -> 38 + 41.174/60
        @test minimum(dec.value) ≈ 38.68623 atol=1e-4
    end

    @testset "Real-file: get_sync" begin
        dbd = open_dbd(eng_path; cachedir=CACHE_DIR)
        t, dep, hdg = get_sync(dbd, "m_depth", "m_heading")
        @test length(t) == length(dep) == length(hdg)
        @test issorted(t)
        @test any(isfinite, hdg)
    end

    @testset "Real-file: MultiDBD across eng + sci" begin
        m = MultiDBD(filenames=[eng_path, sci_path]; cachedir=CACHE_DIR)
        @test nfiles(m) == 2
        @test length(m.files_eng) == 1
        @test length(m.files_sci) == 1
        @test "m_depth" in parameter_names(m, :eng)
        @test "sci_water_temp" in parameter_names(m, :sci)
        @test has_parameter(m, "m_depth")
        @test has_parameter(m, "sci_water_temp")
        # time_range is populated (it silently wasn't, before the asctime fix)
        tmin, tmax = m.time_range
        @test isfinite(tmin) && isfinite(tmax)
        @test tmin <= tmax

        ts = get_data(m, "sci_water_temp")
        @test length(ts) == 871
        t, temp, pres = get_sync(m, "sci_water_temp", "sci_water_pressure")
        @test length(t) == length(temp) == length(pres)
        @test sum(isfinite, pres) > 0
    end

    @testset "Real-file: mission filtering is case-insensitive" begin
        @test nfiles(MultiDBD(filenames=[eng_path]; cachedir=CACHE_DIR,
                              missions=["ELECTASH.MI"])) == 1
        @test nfiles(MultiDBD(filenames=[eng_path]; cachedir=CACHE_DIR,
                              missions=["electash.mi"])) == 1
        # a banned mission excludes everything -> constructor errors
        @test_throws ErrorException MultiDBD(filenames=[eng_path]; cachedir=CACHE_DIR,
                                            banned_missions=["ELECTASH.MI"])
    end

    @testset "Real-file: split eng_dir/sci_dir layout" begin
        # Build a realistic split-directory archive from the fixture. The files
        # are renamed to share a stem so eng<->sci pairing can be exercised;
        # the cache is located by the CRC in the header, which renaming
        # does not affect.
        mktempdir() do root
            eng_dir = joinpath(root, "from-glider")
            sci_dir = joinpath(root, "from-science")
            mkpath(eng_dir); mkpath(sci_dir)
            cp(eng_path, joinpath(eng_dir, "glider-2025-120-1-1.sbd"))
            cp(sci_path, joinpath(sci_dir, "glider-2025-120-1-1.tbd"))

            m = MultiDBD(eng_dir=eng_dir, sci_dir=sci_dir, cachedir=CACHE_DIR)
            @test length(m.files_eng) == 1
            @test length(m.files_sci) == 1

            # eng_dir alone sees only the engineering file
            m = MultiDBD(eng_dir=eng_dir, cachedir=CACHE_DIR)
            @test length(m.files_eng) == 1
            @test length(m.files_sci) == 0

            # the sibling is findable across directories
            p = find_paired_file(joinpath(eng_dir, "glider-2025-120-1-1.sbd"), [sci_dir])
            @test p == joinpath(sci_dir, "glider-2025-120-1-1.tbd")

            # complement_files pulls the sci partner in from the other directory
            m = MultiDBD(filenames=[joinpath(eng_dir, "glider-2025-120-1-1.sbd")],
                         sci_dir=sci_dir, cachedir=CACHE_DIR, complement_files=true)
            @test length(m.files_eng) == 1
            @test length(m.files_sci) == 1

            # cross-source sync from separate directories
            m = MultiDBD(eng_dir=eng_dir, sci_dir=sci_dir, cachedir=CACHE_DIR)
            t, temp, depth = get_sync(m, "sci_water_temp", "m_depth")
            @test length(t) == length(temp) == length(depth)
            @test issorted(t)
        end
    end

    @testset "Real-file: LZ4-compressed .ccc cache" begin
        ccc = filter(f -> endswith(f, ".ccc"), readdir(CACHE_DIR, join=true))
        if isempty(ccc)
            @info "no .ccc fixture present; skipping compressed-cache test"
        else
            text = read_cache_file(first(ccc))
            @test !isempty(text)
            lines = split(text, '\n'; keepempty=false)
            @test length(lines) > 10
            @test startswith(first(lines), "s:")
            # It must parse as a real sensor list.
            sensors, all_names = parse_sensor_list(text, length(lines))
            @test !isempty(sensors)
            @test length(all_names) == length(lines)
        end
    end

    @testset "Real-file: cache lookup falls back to the data directory" begin
        # With no cachedir given, the cache next to the data file must be found
        # (documented step 3), and the error must name every directory tried.
        mktempdir() do dir
            cp(eng_path, joinpath(dir, ENG_FILE))
            mkpath(joinpath(dir, "cache"))
            cp(joinpath(CACHE_DIR, "0f682cb2.cac"), joinpath(dir, "cache", "0f682cb2.cac"))
            dbd = open_dbd(joinpath(dir, ENG_FILE))       # no cachedir kwarg
            @test length(dbd.sensors) == 64
        end
        mktempdir() do dir
            cp(eng_path, joinpath(dir, ENG_FILE))          # no cache anywhere
            err = try
                open_dbd(joinpath(dir, ENG_FILE); cachedir=joinpath(dir, "nope"))
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("0f682cb2", err)
            @test occursin(joinpath(dir, "nope"), err)     # user dir listed
            @test occursin(dir, err)                       # data dir listed too
        end
    end
end

end  # outer testset

println("\nAll tests passed",
        HAS_REFERENCE ? " (including real-file validation)." :
                        " (unit-only — no fixture found).")
