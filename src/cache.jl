"""
Cache directory management for Slocum sensor-list cache files (`.cac`).

Unlike `dbdreader.py` (which mutates global state at module import and creates
directories as a side effect), this module is explicit and side-effect-free
at import time.  Cache directories are created only when actually needed.
"""

"""
    default_cachedir() -> String

Platform-appropriate default cache directory path.  Does NOT create it.

- Linux: `~/.local/share/SlocumIO/cache`
- macOS: `~/Library/Caches/SlocumIO`
- Windows: `%LOCALAPPDATA%\\SlocumIO\\cache`
- Other: `~/.SlocumIO/cache`
"""
function default_cachedir()::String
    home = homedir()
    if Sys.islinux()
        return joinpath(home, ".local", "share", "SlocumIO", "cache")
    elseif Sys.isapple()
        return joinpath(home, "Library", "Caches", "SlocumIO")
    elseif Sys.iswindows()
        appdata = get(ENV, "LOCALAPPDATA", joinpath(home, "AppData", "Local"))
        return joinpath(appdata, "SlocumIO", "cache")
    else
        return joinpath(home, ".SlocumIO", "cache")
    end
end

"""
    candidate_cachedirs(user, data_filename=nothing) -> Vector{String}

Build the list of cache directories to search, in priority order:

1. User-provided directory (if any)
2. `./cache` relative to the current working directory
3. `cache` next to the data file (only when `data_filename` is given)
4. The data file's own directory (only when `data_filename` is given)
5. The platform default directory ([`default_cachedir`](@ref))

The first directory that contains the requested `.cac`/`.ccc` file wins.

`data_filename` is part of this function rather than being appended by the
caller so that the returned list is exactly what gets searched — error
messages built from it therefore name every directory that was tried.
"""
function candidate_cachedirs(user::Union{Nothing,AbstractString},
                             data_filename::Union{Nothing,AbstractString}=nothing)::Vector{String}
    dirs = String[]
    if user !== nothing
        push!(dirs, String(user))
    end
    push!(dirs, joinpath(pwd(), "cache"))
    if data_filename !== nothing
        d = dirname(abspath(String(data_filename)))
        push!(dirs, joinpath(d, "cache"))
        push!(dirs, d)
    end
    push!(dirs, default_cachedir())
    return unique!(dirs)
end

"""
    find_cache_file(crc, cachedir, data_filename=nothing) -> Union{String,Nothing}

Search for a cache file `<crc>.cac` (or its compressed form `<crc>.ccc`) in
the directories returned by [`candidate_cachedirs`](@ref).  Returns the
resolved path, or `nothing` if it is not found anywhere.

Both the lowercase and uppercase spellings of the CRC basename are tried:
Slocum CRCs are hex and the dockserver's case is not consistent, which
matters on case-sensitive filesystems.
"""
function find_cache_file(crc::AbstractString,
                        cachedir::Union{Nothing,AbstractString}=nothing,
                        data_filename::Union{Nothing,AbstractString}=nothing)::Union{String,Nothing}
    stems = unique!([lowercase(crc), uppercase(crc)])
    for dir in candidate_cachedirs(cachedir, data_filename)
        for stem in stems, ext in (".cac", ".ccc", ".CAC", ".CCC")
            p = joinpath(dir, stem * ext)
            isfile(p) && return p
        end
    end
    return nothing
end
