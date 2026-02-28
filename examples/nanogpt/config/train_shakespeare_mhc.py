# TinyShakespeare char-level with mHC (4 streams, depth 24)
# Reproduces Taylor Kolasinski's mHC Part 1 experiment
# ~11M params, matching his depth-24 configuration
#
# Usage:
#   python train.py config/train_shakespeare_mhc.py
#   python train.py config/train_shakespeare_mhc.py seed=123
#   python train.py config/train_shakespeare_mhc.py seed=456

out_dir = "out-shakespeare-mhc"
wandb_run_name = "shakespeare-mhc-d24"
wandb_project = "mhc-shakespeare"

dataset = "shakespeare_char"

# model — matches Taylor's depth-24 config (~11M params)
block_size = 256
n_layer = 24
n_head = 6
n_embd = 192
dropout = 0.0
bias = False

batch_size = 64
gradient_accumulation_steps = 1
max_iters = 5000
eval_interval = 250
log_interval = 10
eval_iters = 100

# optimizer — matches Taylor: AdamW, β1=0.9, β2=0.95, wd=0.1
learning_rate = 1e-3
weight_decay = 0.1
beta1 = 0.9
beta2 = 0.95
grad_clip = 1.0

# lr schedule — cosine decay
warmup_iters = 200
lr_decay_iters = 5000
min_lr = 1e-4

# dtype
dtype = "bfloat16"

# wandb / logging
wandb_log = True
wandb_log_amax = True

# hyper-connections: mHC enabled (4 streams, Sinkhorn constrained)
hc_num_streams = 4
hc_num_fracs = 1
hc_disable = False
mhc = True
sinkhorn_iters = 20
sinkhorn_tau = 0.05
mhc_h_res_proj = "sinkhorn"
ns_steps = 5
ns_eps = 1e-7
ns_coeffs = (3.0, -3.2, 1.2)
