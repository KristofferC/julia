# This file is a part of Julia. License is MIT: http://julialang.org/license

using Base.Test

# Check that non-floats are correctly promoted
@test_approx_eq [1 0 0; 0 1 0]\[1,1] [1;1;0]

# Test specialized inverses for n = 1,2,3
let
    srand(1234)
    for n = 1:3
        A = rand(n,n)
        @test_approx_eq inv(A) inv(lufact(A))
    end
end
