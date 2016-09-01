# This file is a part of Julia. License is MIT: http://julialang.org/license

module Read

import ...LibGit2, ..Cache, ..Reqs, ...Pkg.PkgError, ..Dir
using ..Types

metapkgpath(s::AbstractString) = joinpath(uppercase(string(s[1])), s * ".versions")

url(pkg::AbstractString) = chomp(readline(joinpath(Dir.path("METADATA"), metapkgpath(pkg))))

# Should only be called when cache is guaranteed to be updated
sha1(pkg::AbstractString, ver::VersionNumber) = PKG_AVAILABLE_CACHE.pkgs[pkg][ver].sha1

type AvailableCache
    sha::String
    pkgs::Dict{String, Dict{VersionNumber, Available}}
end

PKG_AVAILABLE_CACHE = AvailableCache("", Dict{String, Dict{VersionNumber, Available}}())

function read_version{T <: AbstractString}(s::Vector{T}, i::Int)
    version = s[i]; i += 1
    i += 1 # skip "-----" under the version
    sha = s[i]; i += 1
    requires = String[]
    while i <= length(s) && !isempty(s[i])
        push!(requires, s[i]); i += 1
    end
    i += 1 # skip the empty string
    return version, sha, requires, i
end


function read_package!(pkgs, lines::Vector, pkg_name::AbstractString)
    i = 3 # Skip url + empty line
    isempty(lines[i]) && return # TODO: Package is without a version
    while i <= length(lines)
        ver, sha, requires, i = read_version(lines, i)
        haskey(pkgs, pkg_name) || (pkgs[pkg_name] = Dict{VersionNumber,Available}())
        z = Reqs.parse(requires)
        q = Available(sha, z)
        pkgs[pkg_name][VersionNumber(ver)] = q
    end
end

function available(names)
    pkgs = Dict{String,Dict{VersionNumber,Available}}()
    cd("METADATA") do
        for pkg in names
            path = metapkgpath(pkg)
            !isfile(path) && continue
            read_package!(pkgs, split(readstring(path), '\n'), pkg)
        end
    end
    return pkgs
end

available(pkg::AbstractString) = get(available([pkg]),pkg,Dict{VersionNumber,Available}())


# Uses cached data if not outdated
function available(cache::AvailableCache = PKG_AVAILABLE_CACHE)
    function get_pkgs()
        names = String[]
        cd("METADATA") do
            for firstletterpath in filter(x->isdir(x) && !startswith(x, '.'), readdir())
                append!(names, map(x -> split(x, ".versions")[1], readdir(firstletterpath)))
            end
        end
        return names
    end
    # Not a git repo so just bail on using cache
    #!(".git" in names) && error("METADATA must be a git repo")
    return with(LibGit2.GitRepo("METADATA")) do repo
        with(LibGit2.head(repo)) do head
            sha = string(Base.LibGit2.Oid(head))
            with(LibGit2.GitStatus(repo)) do status
                # Only use cache if nothing funky is going on, this should be true in the majority of cases
                if length(status) == 0
                    # Sha does not match, update the cache with the new pkgs
                    if cache.sha != sha
                        cache.pkgs = available(get_pkgs())
                        cache.sha = sha
                    end
                    return cache.pkgs
                end
                return available(get_pkgs())
            end
        end
    end
end

function latest()
    pkgs_all = available()
    pkgs = Dict{String,Available}()
    for (pkg, v) in pkgs_all
        isempty(pkg) && continue
        ver = maximum(keys(v))
        pkgs[pkg] = v[ver]
    end
    return pkgs
end

isinstalled(pkg::AbstractString) =
    pkg != "METADATA" && pkg != "REQUIRE" && pkg[1] != '.' && isdir(pkg)

function isfixed(pkg::AbstractString, prepo::LibGit2.GitRepo, avail::Dict=available(pkg))
    isinstalled(pkg) || throw(PkgError("$pkg is not an installed package."))
    isfile("METADATA", metapkgpath(pkg)) || return true
    ispath(pkg, ".git") || return true

    LibGit2.isdirty(prepo) && return true
    LibGit2.isattached(prepo) && return true
    LibGit2.need_update(prepo)
    LibGit2.iszero(LibGit2.revparseid(prepo, "HEAD:REQUIRE")) && isfile(pkg,"REQUIRE") && return true

    head = string(LibGit2.head_oid(prepo))
    for (ver,info) in avail
        head == info.sha1 && return false
    end

    cache = Cache.path(pkg)
    cache_has_head = if isdir(cache)
        crepo = LibGit2.GitRepo(cache)
        LibGit2.iscommit(head, crepo)
    else
        false
    end
    res = true
    try
        for (ver,info) in avail
            if cache_has_head && LibGit2.iscommit(info.sha1, crepo)
                if LibGit2.is_ancestor_of(head, info.sha1, crepo)
                    res = false
                    break
                end
            elseif LibGit2.iscommit(info.sha1, prepo)
                if LibGit2.is_ancestor_of(head, info.sha1, prepo)
                    res = false
                    break
                end
            else
                Base.warn_once("unknown $pkg commit $(info.sha1[1:8]), metadata may be ahead of package cache")
            end
        end
    finally
        cache_has_head && LibGit2.finalize(crepo)
    end
    return res
end

function ispinned(pkg::AbstractString)
    ispath(pkg,".git") || return false
    LibGit2.with(LibGit2.GitRepo, pkg) do repo
        return ispinned(repo)
    end
end

function ispinned(prepo::LibGit2.GitRepo)
    LibGit2.isattached(prepo) || return false
    br = LibGit2.branch(prepo)
    # note: regex is based on the naming scheme used in Entry.pin()
    return ismatch(r"^pinned\.[0-9a-f]{8}\.tmp$", br)
end

function installed_version(pkg::AbstractString, prepo::LibGit2.GitRepo, avail::Dict=available(pkg))
    ispath(pkg,".git") || return typemin(VersionNumber)

    # get package repo head hash
    local head
    try
        head = string(LibGit2.head_oid(prepo))
    catch ex
        # refs/heads/master does not exist
        if isa(ex,LibGit2.GitError) &&
            ex.code == LibGit2.Error.EUNBORNBRANCH
            head = ""
        else
            rethrow(ex)
        end
    end
    isempty(head) && return typemin(VersionNumber)

    vers = collect(keys(filter((ver,info)->info.sha1==head, avail)))
    !isempty(vers) && return maximum(vers)

    cache = Cache.path(pkg)
    cache_has_head = if isdir(cache)
        crepo = LibGit2.GitRepo(cache)
        LibGit2.iscommit(head, crepo)
    else
        false
    end
    ancestors = VersionNumber[]
    descendants = VersionNumber[]
    try
        for (ver,info) in avail
            sha1 = info.sha1
            base = if cache_has_head && LibGit2.iscommit(sha1, crepo)
                LibGit2.merge_base(crepo, head, sha1)
            elseif LibGit2.iscommit(sha1, prepo)
                LibGit2.merge_base(prepo, head, sha1)
            else
                Base.warn_once("unknown $pkg commit $(sha1[1:8]), metadata may be ahead of package cache")
                continue
            end
            string(base) == sha1 && push!(ancestors,ver)
            string(base) == head && push!(descendants,ver)
        end
    finally
        cache_has_head && LibGit2.finalize(crepo)
    end
    both = sort!(intersect(ancestors,descendants))
    isempty(both) || warn("$pkg: some versions are both ancestors and descendants of head: $both")
    if !isempty(descendants)
        v = minimum(descendants)
        return VersionNumber(v.major, v.minor, v.patch, ("",), ())
    elseif !isempty(ancestors)
        v = maximum(ancestors)
        return VersionNumber(v.major, v.minor, v.patch, (), ("",))
    else
        return typemin(VersionNumber)
    end
end

function requires_path(pkg::AbstractString, avail::Dict=available(pkg))
    pkgreq = joinpath(pkg,"REQUIRE")
    ispath(pkg,".git") || return pkgreq
    repo = LibGit2.GitRepo(pkg)
    head = LibGit2.with(LibGit2.GitRepo, pkg) do repo
        LibGit2.isdirty(repo, "REQUIRE") && return pkgreq
        LibGit2.need_update(repo)
        LibGit2.iszero(LibGit2.revparseid(repo, "HEAD:REQUIRE")) && isfile(pkgreq) && return pkgreq
        string(LibGit2.head_oid(repo))
    end
    for (ver,info) in avail
        if head == info.sha1
            return joinpath("METADATA", pkg, "versions", string(ver), "requires")
        end
    end
    return pkgreq
end

requires_list(pkg::AbstractString, avail::Dict=available(pkg)) =
    collect(keys(Reqs.parse(requires_path(pkg,avail))))

requires_dict(pkg::AbstractString, avail::Dict=available(pkg)) =
    Reqs.parse(requires_path(pkg,avail))

function installed(avail::Dict=available())
    pkgs = Dict{String,Tuple{VersionNumber,Bool}}()
    for pkg in readdir()
        isinstalled(pkg) || continue
        ap = get(avail,pkg,Dict{VersionNumber,Available}())
        if ispath(pkg,".git")
            LibGit2.with(LibGit2.GitRepo, pkg) do repo
                ver = installed_version(pkg, repo, ap)
                fixed = isfixed(pkg, repo, ap)
                pkgs[pkg] = (ver, fixed)
            end
        else
            pkgs[pkg] = (typemin(VersionNumber), true)
        end
    end
    return pkgs
end

function fixed(avail::Dict=available(), inst::Dict=installed(avail), dont_update::Set{String}=Set{String}(),
    julia_version::VersionNumber=VERSION)
    pkgs = Dict{String,Fixed}()
    for (pkg,(ver,fix)) in inst
        (fix || pkg in dont_update) || continue
        ap = get(avail,pkg,Dict{VersionNumber,Available}())
        pkgs[pkg] = Fixed(ver,requires_dict(pkg,ap))
    end
    pkgs["julia"] = Fixed(julia_version)
    return pkgs
end

function free(inst::Dict=installed(), dont_update::Set{String}=Set{String}())
    pkgs = Dict{String,VersionNumber}()
    for (pkg,(ver,fix)) in inst
        (fix || pkg in dont_update) && continue
        pkgs[pkg] = ver
    end
    return pkgs
end

function issue_url(pkg::AbstractString)
    ispath(pkg,".git") || return ""
    m = match(LibGit2.GITHUB_REGEX, url(pkg))
    m === nothing && return ""
    return "https://github.com/" * m.captures[1] * "/issues"
end

end # module
