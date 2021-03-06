using MAT
using Optim
# import AutodiffModule_parallel

n_core = 23
if nworkers() < n_core
    addprocs(n_core-nworkers(); exeflags="--check-bounds=yes")
end
@assert nprocs() > n_core
@assert nworkers() >= n_core

println(workers())

@everywhere include("AutodiffModule_parallel.jl")
@everywhere using AutodiffModule_parallel
@everywhere using ForwardDiff

@everywhere const dt = 0.02;


function ComputeLL(LLs::SharedArray{Float64,1}, params::Vector, ratdata, ntrials::Int)
    LL = 0.

    @sync @parallel for i in 1:ntrials
        RightClickTimes, LeftClickTimes, maxT, rat_choice = AutodiffModule_parallel.trialdata(ratdata, i)
        Nsteps = Int(ceil(maxT/dt))

        LLs[i] = AutodiffModule_parallel.logLike(params, RightClickTimes, LeftClickTimes, Nsteps, rat_choice)
    end

    LL = -sum(LLs)
    return LL 
end

function ComputeGrad_par{T}(params::Vector{T}, ratdata, ntrials::Int)
    LL        = 0.
    LLgrad    = zeros(T,length(params))
    
    function WrapperLL{T}(params::Vector{T})
        LL  = 0.
        LLs = SharedArray(eltype(params), ntrials)#zeros(eltype(params),ntrials)

        @sync @parallel for i in 1:ntrials
            RightClickTimes, LeftClickTimes, maxT, rat_choice = AutodiffModule_parallel.trialdata(ratdata, i)
            Nsteps = Int(ceil(maxT/dt))
            LLs[i] = AutodiffModule_parallel.logLike(params, RightClickTimes, LeftClickTimes, Nsteps, rat_choice)
        end
        LL = -sum(LLs)
        return LL
    end

    result =  GradientResult(params)
    
    ForwardDiff.gradient!(result, WrapperLL, params);
    
    LL     = ForwardDiff.value(result)
    LLgrad = ForwardDiff.gradient(result)
    return LL, LLgrad
end

function ComputeHess_par{T}(params::Vector{T}, ratdata, ntrials::Int)
    LL        = 0.
    LLgrad    = zeros(T,length(params))
    LLhess    = zeros(T,length(params),length(params))
    
    function WrapperLL{T}(params::Vector{T})
        LL  = 0.
        LLs = SharedArray(eltype(params), ntrials)#zeros(eltype(params),ntrials)

        @sync @parallel for i in 1:ntrials
            RightClickTimes, LeftClickTimes, maxT, rat_choice = AutodiffModule_parallel.trialdata(ratdata, i)
            Nsteps = Int(ceil(maxT/dt))
            LLs[i] = AutodiffModule_parallel.logLike(params, RightClickTimes, LeftClickTimes, Nsteps, rat_choice)
        end
        LL = -sum(LLs)
        return LL
    end

    result =  HessianResult(params)
    
    ForwardDiff.hessian!(result, WrapperLL, params);
    
    LL     = ForwardDiff.value(result)
    LLgrad = ForwardDiff.gradient(result)
    LLhess = ForwardDiff.hessian(result)
    return LL, LLgrad, LLhess
end


function Likely_all_trials{T}(LL::AbstractArray{T,1},params::Vector, ratdata, ntrials::Int)     
    for i in 1:ntrials
        RightClickTimes, LeftClickTimes, maxT, rat_choice = AutodiffModule_parallel.trialdata(ratdata, i)
        Nsteps = Int(ceil(maxT/dt))

        LL[i] = AutodiffModule_parallel.logLike(params, RightClickTimes, LeftClickTimes, Nsteps, rat_choice)
    end
end


function main()

    ratname = readline(STDIN)#<- $echo $ratname | julia t3.jl  #"B069"
    ratname = ratname[1:end-1]    
    # ratname = "B069"

    # data import
    mpath = "/mnt/bucket/people/amyoon/Data/PBupsModel_rawdata/"
    # mpath = "/Users/msyoon/Desktop/Princeton/Brodylab/Data/bing/"
    ratdata = matread(*(mpath,"chrono_",ratname,"_rawdata.mat"))

    println("rawdata of ", ratname, " imported" )

    saveto_filename = *("parhess_julia_out_",ratname,".mat")

    # number of trials
    ntrials = Int(ratdata["total_trials"])

    # Parameters
    sigma_a = rand()*4.; sigma_s = rand()*4.; sigma_i = rand()*30.; 
    lam = randn(); B = rand()*20.+5.; bias = randn(); 
    phi = rand()*1.19+0.01; tau_phi = 0.695*rand()+0.005; lapse = rand();

    # sigma_a = 1.; sigma_s = 0.1; sigma_i = 0.2; 
    # lam = -0.0005; B = 6.1; bias = 0.1; 
    # phi = 0.3; tau_phi = 0.1; lapse = 0.05*2;
    # params = [sigma_a, sigma_s, sigma_i, lam, B, bias, phi, tau_phi, lapse]
    # params = [1.9270,  3.7212,  13.4133, -0.7529, 7.3259, 0.6795, 0.6854, 0.6083,  0.5803]

    l = [0.,   0.,   0., -5., 5., -5., 0.01, 0.005, 0.]
    u = [200., 200., 30., 5., 25., 5., 1.2,  0.7,   1.]

    # @code_warntype SumLikey(params, ratdata, ntrials)


    function LL_f(params::Vector)
        LLs = SharedArray(Float64, ntrials)
        return ComputeLL(LLs, params, ratdata["rawdata"], ntrials)
    end

    function LL_g!{T}(params::Vector{T}, grads::Vector{T})
        LL, LLgrad = ComputeGrad_par(params, ratdata["rawdata"], ntrials)
        for i=1:length(params)
            grads[i] = LLgrad[i]
        end
    end

    function LL_fg!(params::Vector, grads)
        LL, LLgrad = ComputeGrad_par(params, ratdata["rawdata"], ntrials)
        for i=1:length(params)
            grads[i] = LLgrad[i]
        end
        return LL
    end

    d4 = DifferentiableFunction(LL_f,
                                LL_g!,
                                LL_fg!)

    tic()
    history = optimize(d4, params, l, u, Fminbox(); 
             optimizer = GradientDescent, optimizer_o = OptimizationOptions(g_tol = 1e-12,
                                                                            x_tol = 1e-10,
                                                                            f_tol = 1e-6,
                                                                            iterations = 200,
                                                                            store_trace = true,
                                                                            ))
    fit_time = toc()
    println(history.minimum)
    println(history)

    ## do a single functional evaluation at best fit parameters and save likely for each trial
    likely_all = zeros(typeof(sigma_i),ntrials)
    x_bf = history.minimum
    Likely_all_trials(likely_all, x_bf, ratdata["rawdata"], ntrials)
    LL, LLgrad, LLhess = ComputeHess_par(x_bf, ratdata["rawdata"], ntrials)

    matwrite(saveto_filename, Dict([("ratname",ratname),
                                    ("x_init",params),
                                    ("trials",ntrials),
                                    ("history",history),
                                    ("f",history.f_minimum), 
                                    ("x_converged",history.x_converged),
                                    ("f_converged",history.f_converged),
                                    ("g_converged",history.g_converged),                                    
                                    ("fit_time",fit_time),
                                    ("x_bf",history.minimum),
                                    ("myfval", history.f_minimum),
                                    ("hessian", LLhess),
                                    ("likely",likely_all)
                                    ]))
     # hessian?
     LL, LLgrad, LLhess = ComputeHess_par(x_bf, ratdata["rawdata"], ntrials)
end

# @code_warntype main()
@time main()
# Profile.print()
# Profile.clear_malloc_data() 

