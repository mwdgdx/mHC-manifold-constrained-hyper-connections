# C4 with HC (4 streams, 32 layers, ~1.7B params)
# Reproduces Taylor Kolasinski's mHC Part 2 experiment (HC only)
#
# Usage (8x GPU):
#   torchrun --standalone --nproc_per_node=8 train.py config/train_c4_hc_1.7B.py gradient_accumulation_steps=8
#   torchrun --standalone --nproc_per_node=8 train.py config/train_c4_hc_1.7B.py gradient_accumulation_steps=8 seed=123

out_dir = "out-c4-hc-1.7B"
wandb_run_name = "hc-1.7B-d32"
wandb_project = "mhc-part2"

dataset = "c4"

# model — 32 layers, ~1.73B params (matching Taylor Part 2)
block_size = 1024
n_layer = 32
n_head = 32
n_embd = 2048
dropout = 0.0
bias = False

# training — Taylor uses batch_size=8 per GPU for 32-layer 1.7B
# With 8 GPUs, grad_accum=8 gets divided by 8 → 1 per GPU
# Effective: 8 × 8 × 1024 = 65,536 tokens/step
batch_size = 8
gradient_accumulation_steps = 8
max_iters = 5000
eval_interval = 250
log_interval = 10
eval_iters = 50

# optimizer — Taylor Part 2: lr=1e-4
learning_rate = 1e-4
weight_decay = 0.1
beta1 = 0.9
beta2 = 0.95
grad_clip = 1.0

# lr schedule — Taylor uses 500 warmup steps
warmup_iters = 500
lr_decay_iters = 5000
min_lr = 1e-5

# dtype
dtype = "bfloat16"

# wandb / logging
wandb_log = True
wandb_log_amax = True

# hyper-connections: HC enabled (4 streams, unconstrained)
hc_num_streams = 4
hc_num_fracs = 1
hc_disable = False
mhc = False
