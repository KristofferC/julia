# This file is a part of Julia. License is MIT: https://julialang.org/license

for file in readlines(joinpath(@__DIR__, "tests")
    include(file * ".jl")
end
