function Soln = ecLQR_fg_cross(param, xN,  A_list, B_list, C_list, D_list, G_list, r_list, h_list, S_list)
%ECLQR_FG solve LQR with equality constraint using factor graph
% It uses the general input output structure:
% Inputs:
%  -- param   a struct contains all necessary parameters
%  -- xN      The final target that state must reach at N
%  -- A_list B_list lists of system dynamics 
%  -- C_list, D_list, G_list, r_list, h_list lists of constraints 
% Outputs:
%  -- Soln 


%1. necessary variables
N = param.N;
nx = param.nx;
nu = param.nu;
ncxu = param.ncxu;
ncx = param.ncx;

Cxu = param.Cxu;
Cx  = param.Cx;
Q = param.Q;
Qf = param.Qf;
R = param.R;


% 2. construct factor graph
prior_noise = gtsam.noiseModel.Constrained.All(nx);
dynamics_noise = gtsam.noiseModel.Constrained.All(nx);
control_noise = gtsam.noiseModel.Constrained.All(nu);

constraint_x_noise = gtsam.noiseModel.Constrained.All(ncx);
constraint_xu_noise = gtsam.noiseModel.Constrained.All(ncxu);
% constraint_x_noise = gtsam.noiseModel.Gaussian.SqrtInformation(sqrt(6999*eye(ncx)));
% constraint_xu_noise = gtsam.noiseModel.Gaussian.SqrtInformation(sqrt(6999*eye(ncxu)));

graph = gtsam.GaussianFactorGraph();

% Create the keys corresponding to unknown variables in the factor graph
X = [];  % N+1
U = [];  % N
for i=1:N
  X = [X gtsam.symbol('x', i)];
  U = [U gtsam.symbol('u', i)];
end
X = [X gtsam.symbol('x', N+1)];

% set initial state as prior
graph.add(X(1), eye(nx), param.x0, prior_noise);

% Add dynamics constraint as ternary factor
% A.x1 + B.u1 - I.x2 = 0
for i=1:N
  graph.add(X(i), A_list(:,:,i), U(i), B_list(:,:,i), X(i+1), -eye(nx), zeros(nx,1), dynamics_noise);
end

% add cross time constraint
for S = S_list
    S = S{1};
    args = {};
    for xi = 1:length(S.xn)
        args{end+1} = X(S.xn(xi));
        args{end+1} = S.xmat(:, :, xi);
    end
    for ui = 1:length(S.un)
        args{end+1} = U(S.un(ui));
        args{end+1} = S.umat(:, :, ui);
    end
    assert (length(args) >= 2 && length(args) <= 6,...
            'GTSAM matlab api does not currently support the n-ary constructor of Jacobian Factor');
    graph.add(args{:}, S.rhs, constraint_xu_noise);
end

% for i=19:20:N-20   
    
%     graph.add(X(i), [0 0; 0 1], X(i+20), [0 0; 0 -1], [0; -0.5]+zeros(nx,1), constraint_xu_noise);
% %     graph.add(X(i+10), [0 0; 0 1], X(i+20), [0 0; 0 -1], zeros(nx,1), constraint_xu_noise);
% %     graph.add(X(i), [0,1], zeros(1), constraint_x_noise);
    
% end


% noises 
q_noise = gtsam.noiseModel.Gaussian.Information(Q);
r_noise = gtsam.noiseModel.Gaussian.Information(R);
qf_noise = gtsam.noiseModel.Gaussian.Information(Qf);

% state and control cost
if isa(q_noise, 'gtsam.noiseModel.Diagonal') &&...
   isa(r_noise, 'gtsam.noiseModel.Diagonal')
    for i=1:N
        graph.add(X(i), eye(nx), zeros(nx,1), q_noise);
        graph.add(U(i), eye(nu), zeros(nu,1), r_noise);
    end
else
    for i=1:N
        graph.add(gtsam.HessianFactor(X(i), zeros(nx, 1), inv(Q)));
        graph.add(gtsam.HessianFactor(U(i), zeros(nu, 1), inv(R)));
    end
end
% set final state as cost
graph.add(X(N+1), eye(nx), xN, qf_noise);

% set ordering as N+1...1
ordering = gtsam.Ordering();
ordering.push_back(X(N+1));
for i = N:-1:1
    ordering.push_back(X(i));
    ordering.push_back(U(i));
end

% solve
result = graph.optimize(ordering);

Soln(N).t = 0;
Soln(N).u = zeros(nu,1);
Soln(N).x = zeros(nu,1);

% extract K matrices
Soln(N+1).K = zeros(nx,nu);
Soln(N+1).k = zeros(1,nu);
% no variable elimination to get K list yet

ordering = gtsam.Ordering();
for idx = N:-1:1
    ordering.push_back(X(idx+1));
    ordering.push_back(U(idx));
    [b,~] = graph.eliminatePartialSequential(ordering);
    R = b.back().R;
    Soln(idx).K = R \ b.back().S();
    Soln(idx).k = R \ b.back().d;
    % cross-timestep constraints break Markov property, so u(n) is dependent upon multiple x(ns)
    % store x(ns) in Soln.nset
    kv = b.back().keys();  % KeyVector
    Soln(idx).nset = zeros(kv.size-1, 1, 'uint64');
    for ki = 1:kv.size-1
        Soln(idx).nset(ki) = gtsam.symbolIndex(kv.at(ki)); % note: kv is 0 indexed
    end
end



for idx=1:N
    i = idx;
    Soln(i).u = result.at(U(i));
    Soln(i).x = result.at(X(i));
    % check: u = -K.x + k
    Kerr = abs((-Soln(i).K * reshape([Soln(Soln(i).nset).x], [], 1)...
                + Soln(i).k) - Soln(i).u);
    assert(all(Kerr < 1e-6, 'all'),...
           'Incorrect K matrix calculation in Factor graph');
    if (~all(Kerr < 1e-9, 'all'))
        fprintf('Warning: numerical instability issues likely encountered\n');
    end
end
Soln(N+1).x = result.at(X(N+1));

end