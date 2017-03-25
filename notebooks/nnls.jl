module nnls

function construct_householder!(u::AbstractVector, up)
    m = length(u)
    if m <= 1
        return up
    end
    
    cl = maximum(abs, u)
    @assert cl > 0
    clinv = 1 / cl
    sm = sum(x -> (x * clinv)^2, u)
    cl *= sqrt(sm)
    if u[1] > 0
        cl = -cl
    end
    up = u[1] - cl
    u[1] = cl
    
    return up
end

function apply_householder!{T}(u::AbstractVector{T}, up::T, c::AbstractVector{T})
    m = length(u)
    if m <= 1
        return
    end
        
    cl = abs(u[1])
    @assert cl > 0
    b = up * u[1]
    if b >= 0
        return
    end
    b = 1 / b
    # i2 = 1 - m + lpivot - 1
    # incr = 1
    # i2 = lpivot
    # i3 = lpivot + 1
    # i4 = lpivot + 1

    sm = c[1] * up
    for i in 2:m
        sm += c[i] * u[i]
    end
    if sm != 0
        sm *= b
        c[1] += sm * up
        for i in 2:m
            c[i] += sm * u[i]
        end
    end
end

function orthogonal_rotmat(a, b)
    if abs(a) > abs(b)
        xr = b / a
        yr = sqrt(1 + xr^2)
        c = (1 / yr) * sign(a)
        s = c * xr
        sig = abs(a) * yr
    elseif b != 0
        xr = a / b
        yr = sqrt(1 + xr^2)
        s = (1 / yr) * sign(b)
        c = s * xr
        sig = abs(b) * yr
    else
        sig = 0
        c = 0
        s = 1
    end
    return c, s, sig
end

immutable NNLSWorkspace{T}
    x::Vector{T}
    w::Vector{T}
    zz::Vector{T}
    idx::Vector{Cint}
    rnorm::Ref{T}
    mode::Ref{Cint}
end

function NNLSWorkspace{T}(::Type{T}, m::Integer, n::Integer)
    NNLSWorkspace{T}(zeros(T, n),
                     zeros(T, n),
                     zeros(T, m),
                     zeros(Cint, n),
                     zero(T),
                     0)
end

function nnls!{T}(work::NNLSWorkspace{T}, A::Matrix{T}, b::Vector{T}, itermax=(3 * size(A, 2)))
    x = work.x
    w = work.w
    zz = work.zz
    idx = work.idx
    const factor = 0.01
    work.mode[] = 1
    
    m, n = size(A)
    @assert size(b) == (m,)
    @assert size(x) == (n,)
    @assert size(w) == (n,)
    @assert size(zz) == (m,)
    @assert size(idx) == (n,)
    
    iter = 0
    x .= 0
    idx .= 1:n
    
    izmax = 0
    iz2 = n
    iz1 = 1
    iz = 0
    j = 0
    nsetp = 0
    npp1 = 1
    up = zero(T)

    terminated = false
    
    # ******  MAIN LOOP BEGINS HERE  ******
    while true
        # println("jl main loop")
        # QUIT IF ALL COEFFICIENTS ARE ALREADY IN THE SOLUTION.
        # OR IF M COLS OF A HAVE BEEN TRIANGULARIZED. 
        if (iz1 > iz2 || nsetp >= m)
            terminated = true
            break
        end
        
        # COMPUTE COMPONENTS OF THE DUAL (NEGATIVE GRADIENT) VECTOR W().
        for iz in iz1:iz2
            j = idx[iz]
            sm = 0
            for l in npp1:m
                sm += A[l, j] * b[l]
            end
            w[j] = sm
        end
        
        # FIND LARGEST POSITIVE W(J).
        while true
            wmax = 0
            for iz in iz1:iz2
                j = idx[iz]
                if w[j] > wmax
                    wmax = w[j]
                    izmax = iz
                end
            end
            
            # IF WMAX .LE. 0. GO TO TERMINATION.
            # THIS INDICATES SATISFACTION OF THE KUHN-TUCKER CONDITIONS.
            if wmax <= 0
                terminated = true
                break
            end
            
            iz = izmax
            j = idx[iz]
            
            # THE SIGN OF W(J) IS OK FOR J TO BE MOVED TO SET P.
            # BEGIN THE TRANSFORMATION AND CHECK NEW DIAGONAL ELEMENT TO AVOID
            # NEAR LINEAR DEPENDENCE.
            Asave = A[npp1, j]
            up = construct_householder!(@view(A[npp1:end, j]), up)
            unorm = 0
            if nsetp != 0
                for l in 1:nsetp
                    unorm += A[l, j]^2
                end
            end
            unorm = sqrt(unorm)

            if ((unorm + abs(A[npp1, j]) * factor) - unorm) > 0 
                # COL J IS SUFFICIENTLY INDEPENDENT.  COPY B INTO ZZ, UPDATE ZZ
                # AND SOLVE FOR ZTEST ( = PROPOSED NEW VALUE FOR X(J) ).   
                # println("copying b into zz")
                zz .= b
                apply_householder!(@view(A[npp1:end, j]), up, @view(zz[npp1:end]))
                # print("after h12: ")
                ztest = zz[npp1] / A[npp1, j]

                # SEE IF ZTEST IS POSITIVE  
                if ztest > 0
                    break
                end
            end

            # REJECT J AS A CANDIDATE TO BE MOVED FROM SET Z TO SET P.  
            # RESTORE A(NPP1,J), SET W(J)=0., AND LOOP BACK TO TEST DUAL
            # COEFFS AGAIN.
            A[npp1, j] = Asave
            w[j] = 0
        end
        if terminated
            break
        end

        # THE INDEX  J=INDEX(IZ)  HAS BEEN SELECTED TO BE MOVED FROM
        # SET Z TO SET P.    UPDATE B,  UPDATE INDICES,  APPLY HOUSEHOLDER  
        # TRANSFORMATIONS TO COLS IN NEW SET Z,  ZERO SUBDIAGONAL ELTS IN   
        # COL J,  SET W(J)=0. 

        b .= zz

        idx[iz] = idx[iz1]
        idx[iz1] = j
        iz1 += 1
        nsetp = npp1
        npp1 += 1

        if iz1 <= iz2
            for jz in iz1:iz2
                jj = idx[jz]
                apply_householder!(@view(A[nsetp:end, j]), up, @view(A[nsetp:end, jj]))
            end
        end

        if nsetp != m
            for l in npp1:m
                A[l, j] = 0
            end
        end

        w[j] = 0

        # SOLVE THE TRIANGULAR SYSTEM.   
        # STORE THE SOLUTION TEMPORARILY IN ZZ().
        jj = solve_triangular_system(zz, A, idx, nsetp, jj)

        # ******  SECONDARY LOOP BEGINS HERE ******  
        # 
        # ITERATION COUNTER.   

        while true
            # println("jl secondary loop")
            iter += 1
            if iter > itermax
                work.mode[] = 3
                terminated = true
                println("NNLS quitting on iteration count")
                break
            end

            # SEE IF ALL NEW CONSTRAINED COEFFS ARE FEASIBLE. 
            # IF NOT COMPUTE ALPHA.    
            alpha = 2.0
            for ip in 1:nsetp
                l = idx[ip]
                if zz[ip] <= 0
                    t = -x[l] / (zz[ip] - x[l])
                    if alpha > t
                        alpha = t
                        jj = ip
                    end
                end
            end

            # IF ALL NEW CONSTRAINED COEFFS ARE FEASIBLE THEN ALPHA WILL
            # STILL = 2.    IF SO EXIT FROM SECONDARY LOOP TO MAIN LOOP.
            if alpha == 2
                break
            end

            # OTHERWISE USE ALPHA WHICH WILL BE BETWEEN 0 AND 1 TO
            # INTERPOLATE BETWEEN THE OLD X AND THE NEW ZZ.
            for ip in 1:nsetp
                l = idx[ip]
                x[l] = x[l] + alpha * (zz[ip] - x[l])
            end

            # MODIFY A AND B AND THE INDEX ARRAYS TO MOVE COEFFICIENT I
            # FROM SET P TO SET Z.
            i = idx[jj]

            while true
                x[i] = 0

                if jj != nsetp
                    jj += 1
                    for j in jj:nsetp
                        ii = idx[j]
                        idx[j - 1] = ii
                        cc, ss, sig = orthogonal_rotmat(A[j - 1, ii], A[j, ii])
                        A[j - 1, ii] = sig
                        A[j, ii] = 0
                        for l in 1:n
                            if l != ii
                                # Apply procedure G2 (CC,SS,A(J-1,L),A(J,L))
                                temp = A[j - 1, l]
                                A[j - 1, l] = cc * temp + ss * A[j, l]
                                A[j, l] = -ss * temp + cc * A[j, l]
                            end
                        end

                        # Apply procedure G2 (CC,SS,B(J-1),B(J))  
                        temp = b[j - 1]
                        b[j - 1] = cc * temp + ss * b[j]
                        b[j] = -ss * temp + cc * b[j]
                    end
                end

                npp1 = nsetp
                nsetp = nsetp - 1
                iz1 = iz1 - 1
                idx[iz1] = i

                # SEE IF THE REMAINING COEFFS IN SET P ARE FEASIBLE.  THEY SHOULD
                # BE BECAUSE OF THE WAY ALPHA WAS DETERMINED.
                # IF ANY ARE INFEASIBLE IT IS DUE TO ROUND-OFF ERROR.  ANY   
                # THAT ARE NONPOSITIVE WILL BE SET TO ZERO   
                # AND MOVED FROM SET P TO SET Z. 
                allfeasible = true
                for jj in 1:nsetp
                    i = idx[jj]
                    if x[i] <= 0
                        allfeasible = false
                        break
                    end
                end
                if allfeasible
                    break
                end
            end

            # COPY B( ) INTO ZZ( ).  THEN SOLVE AGAIN AND LOOP BACK.
            zz .= b
            jj = solve_triangular_system(zz, A, idx, nsetp, jj)
        end
        if terminated
            break
        end
        # ******  END OF SECONDARY LOOP  ******

        for ip in 1:nsetp
            i = idx[ip]
            x[i] = zz[ip]
        end
        # ALL NEW COEFFS ARE POSITIVE.  LOOP BACK TO BEGINNING.
    end

    # ******  END OF MAIN LOOP  ******   
    # COME TO HERE FOR TERMINATION. 
    # COMPUTE THE NORM OF THE FINAL RESIDUAL VECTOR.

    @assert terminated
    sm = 0
    if npp1 <= m
        for i in npp1:m
            sm += b[i]^2
        end
    else
        for j in 1:n
            w[j] = 0
        end
    end
    work.rnorm[] = sqrt(sm)
end

function solve_triangular_system(zz, A, idx, nsetp, jj)
    for l in 1:nsetp
        ip = nsetp + 1 - l
        if (l != 1)
            for ii in 1:ip
                zz[ii] -= A[ii, jj] * zz[ip + 1]
            end
        end
        jj = idx[ip]
        zz[ip] /= A[ip, jj]
    end
    return jj
end

    
function h1_reference!(u::DenseVector)
    mode = 1
    lpivot = 1
    l1 = 2
    m = length(u)
    iue = 1
    up = Ref{Cdouble}()
    c = Vector{Cdouble}()
    ice = 1
    icv = 1
    ncv = 0
    ccall((:h12_, "nnls.dylib"), Void,
    (Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}, 
    Ref{Cdouble}, Ref{Cint}, Ref{Cdouble}, 
    Ref{Cdouble}, Ref{Cint}, Ref{Cint}, Ref{Cint}),
    mode, lpivot, l1, m, 
    u, iue, up, 
    c, ice, icv, ncv)
    return up[]
end

function h2_reference!{T}(u::DenseVector{T}, up::T, c::DenseVector{T})
    mode = 2
    lpivot = 1
    l1 = 2
    m = length(u)
    @assert length(c) == m
    iue = 1
    ice = 1
    icv = m
    ncv = 1
    ccall((:h12_, "nnls.dylib"), Void,
    (Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}, 
    Ref{Cdouble}, Ref{Cint}, Ref{Cdouble}, 
    Ref{Cdouble}, Ref{Cint}, Ref{Cint}, Ref{Cint}),
    mode, lpivot, l1, m, 
    u, iue, up, 
    c, ice, icv, ncv)
end

function g1_reference(a, b)
    c = Ref{Float64}()
    s = Ref{Float64}()
    sig = Ref{Float64}()
    ccall((:g1_, "nnls.dylib"), Void, 
    (Ref{Float64}, Ref{Float64}, Ref{Float64}, Ref{Float64}, Ref{Float64}), 
    a, b, c, s, sig)
    return c[], s[], sig[]
end

function nnls_reference!(work::NNLSWorkspace{Cdouble}, A::DenseMatrix{Cdouble}, b::DenseVector{Cdouble})
    m, n = size(A)
    @assert length(work.x) == n
    @assert length(work.w) == n
    mda = m
    ccall((:nnls_, "nnls.dylib"), Void,
          (Ref{Cdouble}, Ref{Cint}, Ref{Cint}, Ref{Cint}, # A, mda, m, n
           Ref{Cdouble}, # b
           Ref{Cdouble}, # x
           Ref{Cdouble}, # rnorm
           Ref{Cdouble}, # w
           Ref{Cdouble}, # zz
           Ref{Cint},    # idx
           Ref{Cint}),    # mode
          A, mda, m, n,
          b, 
          work.x,
          work.rnorm,
          work.w,
          work.zz,
          work.idx,
          work.mode)
    if work.mode[] == 2
        error("nnls.f exited with dimension error")
    end
end

using Base.Test

@testset "construct_householder!" begin
    for i in 1:10000
        u = randn(rand(3:10))
        
        u1 = copy(u)
        up1 = construct_householder!(u1, 0)
        
        u2 = copy(u)
        up2 = h1_reference!(u2)
        @test up1 == up2
        @test u1 == u2
    end
end

@testset "apply_householder!" begin
    for i in 1:1000
        u = randn(rand(3:10))
        c = randn(length(u))
        
        u1 = copy(u)
        c1 = copy(c)
        up1 = construct_householder!(u1, 0)
        apply_householder!(u1, up1, c1)
        
        u2 = copy(u)
        c2 = copy(c)
        up2 = h1_reference!(u2)
        h2_reference!(u2, up2, c2)
        
        @test up1 == up2
        @test u1 == u2
        @test c1 == c2
    end
end

@testset "orthogonal_rotmat" begin
    for i in 1:1000
        a = randn()
        b = randn()
        @test orthogonal_rotmat(a, b) == g1_reference(a, b)
    end
end

@testset "nnls" begin
    srand(1)
    for i in 1:1000
        m = rand(20:100)
        n = rand(20:100)
        A = randn(m, n)
        b = randn(m)

        A1 = copy(A)
        b1 = copy(b)
        work1 = NNLSWorkspace(Float64, m, n)
        nnls!(work1, A1, b1)

        A2 = copy(A)
        b2 = copy(b)
        work2 = NNLSWorkspace(Float64, m, n)
        nnls_reference!(work2, A2, b2)

        @test work1.x == work2.x
        @test A1 == A2
        @test b1 == b2
        @test work1.w == work2.w
        @test work1.zz == work2.zz
        @test work1.idx == work2.idx
        @test work1.rnorm[] == work2.rnorm[]
        @test work1.mode[] == work2.mode[]
    end
end

end