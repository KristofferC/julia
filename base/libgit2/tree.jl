# This file is a part of Julia. License is MIT: http://julialang.org/license

"""
Traverse the entries in a tree and its subtrees in post or pre order.

Function parameter should have following signature:

    (Cstring, Ptr{Void}, Ptr{Void}) -> Cint
"""
function treewalk(f::Function, tree::GitTree, payload=Any[], post::Bool = false)
    cbf = cfunction(f, Cint, (Cstring, Ptr{Void}, Ptr{Void}))
    cbf_payload = Ref{typeof(payload)}(payload)
    @check ccall((:git_tree_walk, :libgit2), Cint,
                  (Ptr{Void}, Cint, Ptr{Void}, Ptr{Void}),
                   tree.ptr, post, cbf, cbf_payload)
    return cbf_payload
end

function filename(te::GitTreeEntry)
    str = ccall((:git_tree_entry_name, :libgit2), Cstring, (Ptr{Void},), te.ptr)
    str != C_NULL && return unsafe_string(str)
    return nothing
end

"Returns UNIX file attributes, as a `Cint`, of a tree entry."
function Base.Filesystem.filemode(te::GitTreeEntry)
    return ccall((:git_tree_entry_filemode, :libgit2), Cint, (Ptr{Void},), te.ptr)
end

isdir(tree_entry::GitTreeEntry) = filemode(tree_entry) == Int(LibGit2.Consts.FILEMODE_TREE)
function isfile(tree_entry::GitTreeEntry)
    mode  = LibGit2.filemode(tree_entry)
    return mode == Int(LibGit2.Consts.FILEMODE_BLOB) || mode == Int(LibGit2.Consts.FILEMODE_BLOB_EXECUTABLE)
end

function object(repo::GitRepo, te::GitTreeEntry)
    obj_ptr_ptr = Ref{Ptr{Void}}(C_NULL)
    @check ccall((:git_tree_entry_to_object, :libgit2), Cint,
                  (Ptr{Ptr{Void}}, Ptr{Void}, Ref{Void}),
                   obj_ptr_ptr, repo.ptr, te.ptr)
    return GitAnyObject(obj_ptr_ptr[])
end

"""Lookup a tree entry by its file name.

This returns a `GitTreeEntry` that is owned by the `GitTree`.
You don't have to free it, but you must not use it after the `GitTree` is released.
"""
function lookup(tree::GitTree, fname::AbstractString)
    res = ccall((:git_tree_entry_byname, :libgit2), Ptr{Void},
                (Ref{Void}, Cstring), tree.ptr, fname)
    res == C_NULL && return Nullable{GitTreeEntry}()
    return Nullable(GitTreeEntry(res))
end

"""Lookup a tree entry by its index number.

This returns a `GitTreeEntry` that is owned by the `GitTree`.
You don't have to free it, but you must not use it after the `GitTree` is released.
"""
function lookup(tree::GitTree, idx::Integer)
    res = ccall((:git_tree_entry_byindex, :libgit2), Ptr{Void},
                (Ref{Void}, Cint), tree.ptr, idx)
    res == C_NULL && return Nullable{GitTreeEntry}()
    return Nullable(GitTreeEntry(res))
end

function Base.getindex(tree::GitTree, v::Union{String, Integer})
    tree_entity = isa(v, String) ? lookup(tree, v) : lookup(tree, v - 1)
    isnull(tree_entity) && throw(BoundsError(tree, (v,)))
    return Base.get(tree_entity)
end


"""Get the number of entries in the tree."""
function Base.length(tree::GitTree)
    ccall((:git_tree_entrycount, :libgit2), Cint, (Ptr{Void},), tree.ptr)
end

Base.start(b::GitTree) = 1
Base.done(b::GitTree, state) = state > length(b)
Base.next(b::GitTree, state) = b[state], state+1
