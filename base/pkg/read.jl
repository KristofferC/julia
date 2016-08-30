# This file is a part of Julia. License is MIT: http://julialang.org/license

module Read

import ...LibGit2, ..Cache, ..Reqs, ...Pkg.PkgError, ..Dir
using ..Types

readstrip(path...) = strip(readstring(joinpath(path...)))

url(pkg::AbstractString) = readstrip(Dir.path("METADATA"), pkg, "url")
sha1(pkg::AbstractString, ver::VersionNumber) = readstrip(Dir.path("METADATA"), pkg, "versions", string(ver), "sha1")

using Base.Pkg.Types
import Base.Pkg.Reqs
import Base.LibGit2: GitRepo, GitTree, GitBlob, filename, peel, object, content, head

# Adds the `Available` entries to `pkg` for the package in the `pacakage_tree` for each version
function add_available!(pkgs::Dict, package_tree::GitTree, repo::GitRepo)
    pkg_name = filename(package_tree)
    for package_dir_entry in package_tree
        !isdir(package_dir_entry) && continue # probably the url file so skip
        filename(package_dir_entry) != "versions" && continue  # skip non "versions" folders
        # Loop over the folders in "version" now
        for ver in peel(GitTree, object(repo, package_dir_entry))
            ver_name = filename(ver)
            !ismatch(Base.VERSION_REGEX, ver_name) && continue
            sha_str = ""
            requires_str = ""
            for ver_file in peel(GitTree, object(repo, ver))
                !isfile(ver_file) && continue
                ver_file_name = filename(ver_file)
                blob = peel(GitBlob, object(repo, ver_file))
                if ver_file_name == "requires"
                     requires_str = unsafe_string(convert(Cstring, content(blob)))
                elseif ver_file_name == "sha1"
                    sha_str = unsafe_string(convert(Cstring, content(blob)))
                end
            end
            haskey(pkgs, pkg_name) || (pkgs[pkg_name] = Dict{VersionNumber,Available}())
            pkgs[pkg_name][convert(VersionNumber, ver_name)] =
                Available(strip(sha_str), Reqs.parse(split(requires_str, '\n')))
        end
    end
end

function available(repo::GitRepo = GitRepo("METADATA"))
    tree = peel(GitTree, head(repo))
    pkgs = Dict{String,Dict{VersionNumber,Available}}()
    for pkg in tree # Package folders
        !isdir(pkg) && continue
        pkg_name = filename(pkg)
        startswith(pkg_name, '.') && continue
        add_available!(pkgs, peel(GitTree, object(repo, pkg)), repo)
    end
    return pkgs
end

function available(pkg::AbstractString)
    repo = GitRepo("METADATA")
    tree = peel(GitTree, head(repo))
    tree_entry = lookup(tree, pkg)
    pkg_avail = Dict{VersionNumber,Available}()
    (isnull(tree_entry) || !LibGit2.isdir(tree_entry)) && return pkg_avail
    add_available!(peel(GitTree, object(repo, pkg_avail)))
    return pkg_avail
end

function latest(names=readdir("METADATA"))
    pkgs = Dict{String,Available}()
    for pkg in names
        isfile("METADATA", pkg, "url") || continue
        versdir = joinpath("METADATA", pkg, "versions")
        isdir(versdir) || continue
        pkgversions = VersionNumber[]
        for ver in readdir(versdir)
            ismatch(Base.VERSION_REGEX, ver) || continue
            isfile(versdir, ver, "sha1") || continue
            push!(pkgversions, convert(VersionNumber,ver))
        end
        isempty(pkgversions) && continue
        ver = string(maximum(pkgversions))
        pkgs[pkg] = Available(
                readchomp(joinpath(versdir,ver,"sha1")),
                Reqs.parse(joinpath(versdir,ver,"requires"))
            )
    end
    return pkgs
end

isinstalled(pkg::AbstractString) =
    pkg != "METADATA" && pkg != "REQUIRE" && pkg[1] != '.' && isdir(pkg)

function isfixed(pkg::AbstractString, prepo::LibGit2.GitRepo, avail::Dict=available(pkg))
    isinstalled(pkg) || throw(PkgError("$pkg is not an installed package."))
    isfile("METADATA", pkg, "url") || return true
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
