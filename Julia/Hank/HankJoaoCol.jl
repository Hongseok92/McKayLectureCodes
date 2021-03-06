using LinearAlgebra
using Parameters
using IterativeSolvers
using FastGaussQuadrature
using ForwardDiff
#using Calculus
using Plots
using Arpack
include("support.jl")
################################### Model types #########################

struct MarketParameters{T <: Real}
    β::T
    γ::T
    ρz::T
    σz::T
    ρξ::T
    σξ::T
    ζ::T
    ψ::T
    μ::T
    μϵ::T
    θ::T
    ω::T
    ubar::T
    δ::T
    Mbar::T
    wbar::T
    B::T
    ben::T
    amin::T
    Penalty::T
end

mutable struct AggVars{T <: Real,S <: Real,D <: Real}
    R::T
    M::T
    w::T
    Earnings::Array{S,1}
    EmpTrans::Array{D,2}
end

struct HankModel{T <: Real,I <: Integer}
    params::MarketParameters{T}
    aGrid::Array{T,1}
    aGridl::Array{T,1}
    na::I
    dGrid::Array{T,1}
    nd::I
    ns::I
end

function Prices(R,M,Z,u,ulag,params::MarketParameters)
    @unpack δ,Mbar,wbar,ψ,ben,B,ζ = params
    w = wbar * (M/Mbar)^ζ
    Y = Z*(1.0-u)
    H = (1.0-u) - (1.0 - δ)*(1.0-ulag)
    d = (Y-ψ*M*H)/(1.0-u) - w
    τ = ((R-1.0)*B + ben*u)/(w+d)/(1.0-u)
    EmpInc = (1.0-τ)*(w+d)
    Earnings = vcat(ben,EmpInc)
    EmpTrans = vcat(hcat(1.0-M,δ*(1.0-M)),hcat(M,1.0-δ*(1.0-M)))
    @assert sum(EmpTrans[:,1]) == 1.0
    @assert sum(EmpTrans[:,2]) == 1.0

    return AggVars(R,M,w,Earnings,EmpTrans)
end

uPrime(c,γ) = c^(-γ)
uPrimeInv(up,γ) = up^(-1.0/γ)

function Hank(
    R::T,
    β::T = 0.988,
    γ::T = 2.00,
    ρz::T = 0.95,
    σz::T = 1.0,
    ρξ::T = 0.9,
    σξ::T = 1.0,
    ζ::T = 0.8,
    ψ::T = 0.1,
    μ::T = 1.2,
    θ::T = 0.75,
    ω::T = 1.5,
    ubar::T = 0.06,
    δ::T = 0.15,
    B::T = 1.0,
    amin::T = 1e-10,
    amax::T = 200.0,
    na::I = 201,
    nd::I = 201,
    Penalty::T = 1000000000.0) where{T <: Real,I <: Integer}

    #############Params
    μϵ = μ/(μ-1.0)
    Mbar = (1.0-ubar)*δ/(ubar+δ*(1.0-ubar))
    wbar = 1.0/μ - δ*ψ*Mbar
    ben = wbar*0.5
    params = MarketParameters(β,γ,ρz,σz,ρξ,σξ,ζ,ψ,μ,μϵ,θ,ω,ubar,δ,Mbar,wbar,B,ben,amin,Penalty)
    AggVars = Prices(R,Mbar,1.0,ubar,ubar,params)
    @unpack R,M,w,Earnings,EmpTrans = AggVars
    ################## Collocation pieces
    function grid_fun(a_min,a_max,na, pexp)
        x = range(a_min,step=0.5,length=na)
        grid = a_min .+ (a_max-a_min)*(x.^pexp/maximum(x.^pexp))
        return grid
    end
    aGrid = grid_fun(amin,amax,na,6.0)
    #Collocation = ReiterCollocation(aGrid,aSize)

    ################### Distribution pieces
    #dGrid = collect(range(aGrid[1],stop = 10.0,length = nd))
    dGrid = aGrid
    #Distribution = ReiterDistribution(dSize,dGrid)
    ns = length(Earnings)
    #MarkovChain = ReiterMarkovChain(Earnings,sSize,[1;2],EmpTrans)

    ################### Final model pieces
    Guess = zeros(na*ns)
    for (si,earn) in enumerate(Earnings)
        for (ki,k) in enumerate(aGrid) 
            n = (si-1)*na + ki
            ap = R*β*k + earn - 0.001*k
            Guess[n] = ap
        end
    end
    GuessMatrix = reshape(Guess,na,ns)
    
    return HankModel(params,aGrid,vcat(aGrid,aGrid),na,dGrid,nd,ns),Guess,AggVars
end

function Residual(
    pol::AbstractArray,
    HankModel::HankModel,
    AggVars::AggVars,
    Penalty)
    
    @unpack params,aGrid,na,ns = HankModel
    @unpack β,γ,Penalty = params
    @unpack R,M,w,Earnings,EmpTrans = AggVars
    nx = na*ns
    
    dResidual = zeros(eltype(pol),nx,nx)
    Residual = zeros(eltype(pol),nx)
    np = 0    
    for (s,earn) in enumerate(Earnings)
        for (n,a) in enumerate(aGrid)
            s1 = (s-1)*na + n
            #@show ϵ
            #Policy functions
            ap = pol[s1]

            #penalty function
            pen = Penalty*min(ap,0.0)^2
            dpen = 2*Penalty*min(ap,0.0)
            c = R*a + earn - ap

            #preferences
            uc = c^(-γ)
            ucc = -γ*c^(-γ-1.0)
            ∂c∂ai = -1.0

            np = searchsortedlast(aGrid,ap)

            ##Adjust indices if assets fall out of bounds
            (np > 0 && np < na) ? np = np : 
                (np == na) ? np = na-1 : 
                    np = 1 

            ap1,ap2 = aGrid[np],aGrid[np+1]
            basisp1 = (ap2 - ap)/(ap2 - ap1)
            basisp2 = (ap - ap1)/(ap2 - ap1)

            ####### Store derivatives###############
            dbasisp1 = -1.0/(ap2 - ap1)
            dbasisp2 = -dbasisp1                

            tsai = 0.0
            sum1 = 0.0
            for (sp,earnp) in enumerate(Earnings)
                sp1 = (sp-1)*na + np
                sp2 = (sp-1)*na + np + 1

                #Policy functions
                app = pol[sp1]*basisp1 + pol[sp2]*basisp2
                cp = R*ap + earnp - app
                ucp = cp^(-γ)
                uccp = -γ*cp^(-γ-1.0)

                #Need ∂cp∂ai and ∂cp∂aj
                ∂ap∂ai = pol[sp1]*dbasisp1 + pol[sp2]*dbasisp2
                ∂cp∂ai = R - ∂ap∂ai
                ∂cp∂aj = -1.0

                sum1 += β*(EmpTrans[sp,s]*R*ucp + pen)

                #summing derivatives with respect to θs_i associated with c(s)
                tsai += β*(EmpTrans[sp,s]*R*uccp*∂cp∂ai + dpen)
                tsaj = β*EmpTrans[sp,s]*R*uccp*∂cp∂aj

                dResidual[s1,sp1] += tsaj * basisp1
                dResidual[s1,sp2] += tsaj * basisp2
            end
            ##add the LHS and RHS of euler for each s wrt to θi
            dres = tsai - ucc*∂c∂ai
            
            dResidual[s1,s1] += dres

            res = sum1 - uc
            Residual[s1] += res
        end
    end 
    Residual,dResidual 
end

function SolveCollocation(
    guess::AbstractArray,
    HankModel::HankModel,
    AggVars::AggVars{T},
    Penalty::T,
    maxn::Int64 = 500,
    tol = 1e-11
) where{T <: Real,I <: Integer}

    pol = guess
    #Newton Iteration
    for i = 1:maxn
        Res,dRes = Residual(pol,HankModel,AggVars,Penalty)
        step = - dRes \ Res
        if norm(step) > 1.0
            pol += 1.0/20.0*step
        else
            pol += 1.0/1.0*step
        end
        #@show LinearAlgebra.norm(step)
        if LinearAlgebra.norm(step) < tol
            println("Individual problem converged in ",i," steps")
            return pol
            break
        end
    end
        
    #return 
    return println("Individual problem Did not converge")
end


function StationaryDistribution(T,HankModel)
    @unpack ns,nd = HankModel 
    λ, x = powm!(T, rand(ns*nd), maxiter = 100000,tol = 1e-15)
    @show λ
    return x/sum(x)
end

function TransMat(
    pol::AbstractArray,
    AggVars::AggVars{T},
    HankModel::HankModel,
    tmat::AbstractArray) where{T <: Real}
    
    @unpack params,aGrid,na,dGrid,nd,ns = HankModel
    @unpack EmpTrans = AggVars
    nx = na*ns
    
    nf = ns*nd
    pol = reshape(pol,na,ns)

    ##initialize
    #pdf1 = zeros(eltype(pol),nf)
    #Qa = zeros(eltype(pol),nf,nf)

    for s=1:ns
        for (i,x) in enumerate(dGrid)            
            ######
            # find each k in dist grid in nodes to use FEM solution
            ######
            n = searchsortedlast(aGrid,x)
            (n > 0 && n < na) ? n = n : 
                (n == na) ? n = na-1 : 
                    n = 1 
            x1,x2 = aGrid[n],aGrid[n+1]
            basis1 = (x2 - x)/(x2 - x1)
            basis2 = (x - x1)/(x2 - x1)
            ap  = basis1*pol[n,s] + basis2*pol[n+1,s]            
            
            ######
            # Find in dist grid where policy function is
            ######            
            n = searchsortedlast(dGrid,ap)
            #if n == 0
            #    n=1
            #end
            aph_id,apl_id = n + 1, n
            if n > 0 && n < nd
                aph,apl = dGrid[n+1],dGrid[n]
                ω = 1.0 - (ap - apl)/(aph - apl)
            end
            
            
            ######            
            for si = 1:ns
                aa = (s-1)*nd + i
                ss = (si-1)*nd + n
                if n > 0 && n < nd                    
                    tmat[ss+1,aa] = EmpTrans[si,s]*(1.0 - ω)
                    tmat[ss,aa]  = EmpTrans[si,s]*ω
                elseif n == 0
                    ω = 1.0
                    tmat[ss+1,aa] = EmpTrans[si,s]*ω
                else
                    ω = 1.0
                    tmat[ss,aa] = EmpTrans[si,s]*ω
                end
            end
        end
    end
    
    tmat
end

function equilibrium(
    initialpol::AbstractArray,
    HankModel::HankModel{T,I},
    initialR::T,
    tol = 1e-10,maxn = 100) where{T <: Real,I <: Integer}

    @unpack params,aGrid,na,dGrid,nd,ns = HankModel
    @unpack B,ubar,Mbar,Penalty = params

    #Create matrices to store policies
    cpol = zeros(T,nd,ns)
    lpol = zeros(T,nd,ns)
    appol = zeros(T,nd,ns)

    AssetDistribution = zeros(nd*ns)
    tmat = zeros(eltype(initialpol),(na*ns,na*ns))
    EA = 0.0
    
    ###Start Bisection
    K = 0.0
    R = initialR
    Aggs = Prices(R,Mbar,1.0,ubar,ubar,params)
    pol = initialpol
    uir,lir = 1.02, 1.0001
    print("Iterate on aggregate assets")
    for kit = 1:maxn
        Aggs = Prices(R,Mbar,1.0,ubar,ubar,params) ##steady state
        pol = SolveCollocation(pol,HankModel,Aggs,Penalty)

        #Transition matrix
        tmat .= 0.0
        Qa = TransMat(pol,Aggs,HankModel,tmat)

        #Stationary transition
        λ, x = powm!(Qa, rand(ns*nd), maxiter = 10000,tol = 1e-15)

        #Get aggregate capital
        x = x/sum(x)
        EA = dot(vcat(dGrid,dGrid),x)
        
        if (EA > B)
            uir = min(uir,R)
            R = 1.0/2.0*(uir + lir)
        else
            lir = max(lir,R)
            R = 1.0/2.0*(uir + lir)
        end
        if abs(EA - B) < 1e-11
            println("Markets clear!")
            println("Interest rate: ",R," ","Bonds: ",EA)
            @unpack R,M,w,Earnings,EmpTrans = Aggs
            polm = reshape(pol,na,ns)
            cpol = R*hcat(aGrid,aGrid) .+ repeat(reshape(Earnings,(1,ns)),outer=[na,1]) - polm  
            return pol,polm,EA,R,x,reshape(x,nd,ns),cpol,Aggs
            break
        end
    end
    
    return println("Markets did not clear")
end

function F(X_L::AbstractArray,
           X::AbstractArray,
           X_P::AbstractArray,
           epsilon::AbstractArray,
           HankModel::HankModel,pos)
    
    @unpack params,na,ns,nd,dGrid = HankModel  

    m = na*ns
    md = nd*ns
    pol_L,D_L,Agg_L = X_L[1:m],X_L[m+1:m+md-1],X_L[m+md:end]
    pol,D,Agg = X[1:m],X[m+1:m+md-1],X[m+md:end]
    pol_P,D_P,Agg_P = X_P[1:m],X_P[m+1:m+md-1],X_P[m+md:end]

    u_L, R_L, i_L, M_L, pi_L, pA_L, pB_L, Z_L, ξ_L = Agg_L
    u, R, i, M, pi, pA, pB, Z, ξ = Agg
    u_P, R_P, i_P, M_P, pi_P, pA_P, pB_P, Z_P, ξ_P = Agg_P
    
    D_L = vcat(1.0-sum(D_L),D_L)
    D   = vcat(1.0-sum(D),D)
    D_P = vcat(1.0-sum(D_P),D_P)
    
    Price = Prices(R,M,Z,u,u_L,params)
    Price_P = Prices(R_P,M_P,Z_P,u_P,u,params)
    
    #Need matrices that pass through intermediate functions to have the same type as the
    #argument of the derivative that will be a dual number when using forward diff. In other words,
    #when taking derivative with respect to X_P, EE, his, his_rhs must have the same type as X_P
    if pos == 1 
        EE = zeros(eltype(X_L),ns*na)
        his = zeros(eltype(X_L),ns*nd)
        tmat = zeros(eltype(X_L),(ns*na,ns*na))
    elseif pos == 2
        EE = zeros(eltype(X),ns*na)
        his = zeros(eltype(X),ns*nd)
        tmat = zeros(eltype(X),(ns*na,ns*na))
    else
        EE = zeros(eltype(X_P),ns*na)
        his = zeros(eltype(X_P),ns*nd)
        tmat = zeros(eltype(X_P),(ns*na,ns*na))
    end
    agg_root = AggResidual(D,u,u_L,Price.R,i_L,i,M,M_P,pi,pi_P,pA,pB,pA_P,pB_P,Z_L,Z,ξ_L,ξ,epsilon,HankModel)
    dist_root = WealthResidual(pol_L,D_L,D,Price,HankModel,tmat,his) ###Price issue
    euler_root = EulerResidual(Price,Price_P,pol,pol_P,HankModel,EE)
    
    return vcat(euler_root,dist_root,agg_root)
end




function AggResidual(D::AbstractArray,u,u_L,R,i_L,i,M,M_P,pi,pi_P,pA,pB,pA_P,pB_P,Z_L,Z,ξ_L,ξ,
                     epsilon::AbstractArray,HankModel::HankModel)

    @unpack params,dGrid = HankModel
    @unpack β,γ,ρz,σz,ρξ,σξ,ζ,ψ,μ,μϵ,θ,ω,ubar,δ,Mbar,wbar,B,ben,amin = params
    ϵz,ϵξ = epsilon
    #@show D[1:30]
    AggAssets = dot(D,vcat(dGrid,dGrid))
    Y = Z*(1.0-u)
    H = 1.0-u - (1.0-δ)*(1.0-u_L)
    marg_cost = (wbar * (M/Mbar)^ζ + ψ*M - (1.0-δ)*ψ*M_P)/Z
    AggEqs = vcat(
        AggAssets - B, #bond market clearing
        1.0 + i - R_ss * pi^ω * ξ, #mon pol rule #notice Rstar here is fixed and defined as a global
        R - (1.0 + i_L)/pi, 
        M - (1.0-u-(1.0-δ)*(1.0-u_L))/(u_L + δ*(1.0-u_L)), #3 labor market 
        pi - θ^(1.0/(1.0-μϵ))*(1.0-(1.0-θ)*(pA/pB)^(1.0-μϵ))^(1.0/(μϵ-1.0)), #4 inflation
        -pA + μ*Y*marg_cost + θ*pi_P^μϵ*pA_P/R, #aux inflation equ 1
        -pB + Y + θ*pi_P^(μϵ-1.0)*pB_P/R, #aux inflation equ 2
        log(Z) - ρz*log(Z_L) - σz*ϵz, #TFP evol
        log(ξ) - ρξ*log(ξ_L) - σξ*ϵξ #Mon shock
    ) 
    
    return AggEqs
end

function WealthResidual(pol::AbstractArray,
                        Dist_L::AbstractArray,
                        Dist::AbstractArray,
                        Agg::AggVars,
                        HankModel::HankModel,
                        tmat::AbstractArray,
                        his::AbstractArray)

    
    Qa = TransMat(pol,Agg,HankModel,tmat)
    for i in eachindex(his)
        his[i] = Dist[i] - dot(Qa[i,:],Dist_L)
    end

    return his[2:end]
end



function EulerResidual(
    Agg::AggVars,
    Agg_P::AggVars,
    pol::AbstractArray,
    pol_P::AbstractArray,
    HankModel::HankModel,
    EE::AbstractArray)
    
    @unpack params,aGrid,na,ns = HankModel
    @unpack β,γ,Penalty = params

    R,Earnings,EmpTrans = Agg.R,Agg.Earnings,Agg.EmpTrans
    R_P,Earnings_P,EmpTrans_P = Agg_P.R, Agg_P.Earnings, Agg_P.EmpTrans

    ##########################################################
    # For the pieces from FEM
    ##########################################################
    #@show R
    #@show R_P
    #@show Earnings
    #@show Earnings_P
    #@show EmpTrans
    #@show EmpTrans_P
    for (s,earn) in enumerate(Earnings)
        for i=1:na
            a = aGrid[i]
            
            s1 = (s-1)*na + i
            ap = pol[s1]
            
            pen = Penalty*min(ap,0.0)^2
            c = R*a + earn - ap
            uc = c^(-γ)
            
            np = searchsortedlast(aGrid,ap)
            ##Adjust indices if assets fall out of bounds
            (np > 0 && np < na) ? np = np : 
                (np == na) ? np = na-1 : 
                    np = 1 
            
            ap1,ap2 = aGrid[np],aGrid[np+1]
            basisp1 = (ap2 - ap)/(ap2 - ap1)
            basisp2 = (ap - ap1)/(ap2 - ap1)
            

            ee_rhs = 0.0
            for (sp,earnp) in enumerate(Earnings_P)
                sp1 = (sp-1)*na + np
                sp2 = (sp-1)*na + np + 1
                
                #Policy
                app = pol_P[sp1]*basisp1 + pol_P[sp2]*basisp2

                cp = R_P*ap + earnp - app
                ucp = cp^(-γ)
                #uccp = -γ*cp^(-γ - 1.0)

                ###Euler RHS
                ee_rhs += β*(EmpTrans_P[sp,s]*R_P*ucp + pen)  
            end

            res = uc - ee_rhs
            EE[s1] = res 
        end
    end 

    return EE
end

function lininterp(x,x1,sizex,derivs=true)
    n = searchsortedlast(x,x1)

    #extend linear interpolation and assign edge indices
    (n > 0 && n < sizex) ? nothing : 
        (n == sizex) ? n = sizex-1 : 
             n = 1 

    xl,xh = x[n],x[n+1]
    basis1 = (xh - x1)/(xh - xl)
    basis2 = (x1 - xl)/(xh - xl)

    if derivs
        dbasis1 =  -1.0/(xh-xl) 
        return basis1,basis2,n,dbasis1
    else
        return basis1,basis2,n
    end
end


function EulerError(
    Agg::AggVars,
    Agg_P::AggVars,
    pol::AbstractArray,
    pol_P::AbstractArray,
    HankModel::HankModel,
    EE::AbstractArray,
    Grid::AbstractArray)
    
    @unpack params,aGrid,na,ns = HankModel
    @unpack β,γ,Penalty = params

    R,Earnings,EmpTrans = Agg.R,Agg.Earnings,Agg.EmpTrans
    R_P,Earnings_P,EmpTrans_P = Agg_P.R, Agg_P.Earnings, Agg_P.EmpTrans

    for (s,earn) in enumerate(Earnings)
        for (i,a) in enumerate(Grid)

            #find basis for policy
            basis1,basis2,n = lininterp(aGrid,a,na,false)
            
            s1 = (s-1)*na + n
            s2 = (s-1)*na + n+1
            ap = basis1*pol[s1] + basis2*pol[s2]            

            pen = Penalty*min(ap,0.0)^2
            c = R*a + earn - ap
            uc = c^(-γ)
            
            #New policy basis functions
            basisp1,basisp2,np = lininterp(aGrid,ap,na,false)             

            ee_rhs = 0.0
            for (sp,earnp) in enumerate(Earnings_P)
                sp1 = (sp-1)*na + np
                sp2 = (sp-1)*na + np + 1
                
                #Policy
                app = pol_P[sp1]*basisp1 + pol_P[sp2]*basisp2

                cp = R_P*ap + earnp - app
                ucp = cp^(-γ)
                #uccp = -γ*cp^(-γ - 1.0)

                ###Euler RHS
                ee_rhs += β*(EmpTrans_P[sp,s]*R_P*ucp + pen)  
            end

            res = uc - ee_rhs
            EE[(s-1)*length(Grid)+i] = res 
        end
    end 

    return EE
end


