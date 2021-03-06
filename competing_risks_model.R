library(plyr)
library(survival)
library(methods)
library(MASS)
library(survival)
library(abind)
library(mvtnorm)
library(Rcpp)
library(statmod)
library(rootSolve)
library(doParallel)
source("utils.R")

#Compile and import c code
sourceCpp("comp_risk.cpp", verbose=TRUE)
N_P = 20
CompetingRisksModel = setRefClass('CompetingRisksModel',
                                  fields = list(                                
                                      event_specific_models = "list",
				      omega_hat = "matrix",
				      omega_varcov_hat = "matrix",
				      N = "numeric",
				      N_CLUESTERS_SIZE = "numeric",
				      N_FAILURE_TYPES = "numeric"
                                    )
                                  )
# MAIN API:
CompetingRisksModel$methods(

  # This function runs the EM algotihem.
  # It expects 
  # t - a [n_clusters,n_cluster_size] matrix of observed failure times
  # delta - a [n_clusters,n_cluster_size,n_failures] array of indicates if specific failture was observed.
  # X - a [n_clusters,n_cluster_size,n_covariates] array of covarites.
  # W - optional [n_clusters] array of weights.
  # A - optional [n_clusters,n_cluster_size] matrix indicating if the specific memmber exists in the cluster. This allows handling missing memmbers. 
  # tol - optional convergance threshold.
  # MAX_ITR optional maximum number of iteration in attempt to reach convergance. 
  fit = function(t, 
                 delta, 
                 X,  
                 W=NULL,
		 A=NULL,
		 tol=10^-3,
		 MAX_ITR=150,ncore=1) {
	registerDoParallel(cores=ncore)
	N <<- dim(delta)[1]
	N_CLUESTERS_SIZE <<- dim(delta)[2]
	N_FAILURE_TYPES <<- dim(delta)[3]
	if (is.null(W)) {
		W = rep(1,N)
	}

	if (is.null(A)) {
		A = matrix(rep(1,N*N_CLUESTERS_SIZE),ncol=N_CLUESTERS_SIZE)
	}
	delta_sums = apply(delta,3,rowSums)
	conv=1
	omega_hat <<- matrix(rep(1,N*N_FAILURE_TYPES),ncol=N_FAILURE_TYPES)
	beta_hat = matrix(rep(0,N_CLUESTERS_SIZE*N_FAILURE_TYPES),ncol=N_FAILURE_TYPES) 
	omega_varcov_hat <<-  matrix(c(1,0,0,0,1,0,0,0,1),ncol=3)
	k=0
	while (conv > tol) {
		if(k > MAX_ITR) {
			print("Did not converge")
			stopImplicitCluster()
			return
		}
		old_beta_hat = beta_hat
		old_omega_varcov_hat = omega_varcov_hat
		omega_hat_old = omega_hat
		
		cox_step(t,X,omega_hat,W,A)
		beta_Z = get_beta_Z(X)
		hazared_at_event = get_hazerd_at_event(t,delta,X,A,W)
		gh = mgauss.hermite(N_P,rep(0,N_FAILURE_TYPES),omega_varcov_hat)
		omega_varcov_hat_tmp = E_phase_C(delta_sums,gh$points,gh$weights,flatten_array(hazared_at_event),flatten_array(beta_Z))
		gh = mgauss.hermite(N_P,rep(0,N_FAILURE_TYPES),omega_varcov_hat)
		omega_hat <<- omega_expectation_C(delta_sums,gh$points,gh$weights,flatten_array(hazared_at_event),flatten_array(beta_Z))
		omega_varcov_hat <<- omega_varcov_hat_tmp
		conv = sum(abs(old_beta_hat - beta_hat)) + sum(abs(old_omega_varcov_hat - omega_varcov_hat))
		k = k + 1
		print(conv)
		print(k)
	}
	stopImplicitCluster()
  },

  cox_step = function(t,X,O,W,A) {
		ret = list()
		Q_res <- foreach (i=1:N_CLUESTERS_SIZE)  %dopar% {
			ret = list()
			for (j in seq(1,N_FAILURE_TYPES)) {
				relevent_samples = A[,i] == 1
				W_relevent = W[relevent_samples]
				df = data.frame(X[relevent_samples,i,])
				
				rv = log(O[relevent_samples,j])
				srv = Surv(t[relevent_samples,i],delta[relevent_samples,i,j])
				res.cox <- coxph(srv ~ . + offset(rv), data = df, weights=W_relevent)
				ret[[j]] = res.cox
			}
			return(ret)
		}
		for (i in seq(1,N_CLUESTERS_SIZE)) {
			event_specific_models[[i]] <<- Q_res[[i]]
			
		}
		return(ret)
  },

get_beta_Z = function(X) {
	ret = array(rep(0,N*N_CLUESTERS_SIZE*N_FAILURE_TYPES),c(N,N_CLUESTERS_SIZE,N_FAILURE_TYPES))
	for (i in seq(1,N_FAILURE_TYPES)) {
		for (j in seq(1,N_CLUESTERS_SIZE)) {
			ret[,j,i] = as.matrix(X[,j,]) %*% coef(event_specific_models[[j]][[i]])
		}
	}
	return(ret)
},
get_hazerd_at_event = function(T,D,X,A,W) {
	ret = array(rep(0,N*N_CLUESTERS_SIZE*N_FAILURE_TYPES),c(N,N_CLUESTERS_SIZE,N_FAILURE_TYPES))
	for (i in seq(1,N_FAILURE_TYPES)) {
		for (j in seq(1,N_CLUESTERS_SIZE)) {
			relevent_samples = A[,j] == 1
			W_ans = W[relevent_samples]
			res.cox <- event_specific_models[[j]][[i]]
			coef = res.cox$coefficients
			coef[is.na(coef)] = 0
			fit.obj<-coxph.detail(res.cox)
			clam<-cumsum(fit.obj$hazard[] / as.numeric(exp(t(colSums(matrix(X[relevent_samples,i,])*W_ans) / sum(W_ans)) %*% coef)))
			clam1<-c(0,clam)
			stf = stepfun(fit.obj$time,clam1)				
			ret[,j,i] = stf(T[,j])
		}
	}
	return(ret)
}
)
