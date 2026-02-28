# Amax 计算方式详解

## 1. HC 单层操作

一个 Transformer block 有 2 个 HC 模块（hc_attn 和 hc_mlp）。

### 状态

模型维护 4 个并行 stream，每个 stream 维度为 C（=2048）。  
状态表示为 `x[s, d]`，s=0..3 是 stream 索引，d=0..C-1 是特征维度。

### Width Connection（宽度连接）

对输入 `x_old[4, C]` 做两件事：

**a) 计算 4×4 的 H_res 矩阵（per-token，input-dependent）：**

```
H_res[s, t] = scale * tanh(RMSNorm(x_old[s]) @ W[t]) + bias[s, t]
                       ↑ 动态部分（依赖输入）              ↑ 静态部分（可学习）

scale 初始化为 0.01，是可学习标量
bias 的 residual 部分初始化为 4×4 单位矩阵
```

所以训练初期，H_res ≈ 单位矩阵 + 0.01 * 小扰动。

**b) 混合 stream：**

```
x_mixed[t] = H_res[0,t]*x_old[0] + H_res[1,t]*x_old[1] + H_res[2,t]*x_old[2] + H_res[3,t]*x_old[3]
```

即：新 stream t = 所有旧 stream 的加权和，权重由 H_res 的第 t 列决定。

同时计算 branch 输入：`z = H_pre[0]*x_old[0] + H_pre[1]*x_old[1] + ...`

### Branch（分支计算）

branch_output = Attention(z) 或 MLP(z)

### Depth Connection（深度连接）

```
x_new[t] = x_mixed[t] + beta[t] * branch_output
```

最终效果：

```
x_new = H_res @ x_old + beta * F(H_pre @ x_old)
         ↑ 残差混合        ↑ 分支贡献（类似传统 residual connection 的 F(x) 部分）
```

---

## 2. H_res 矩阵格式

在我们的代码中，H_res 用 **[from, to]** 格式存储：

```
H_res[s, t] = 从 stream s 到 stream t 的权重
```

实际混合操作：`x_new[t] = Σ_s H_res[s, t] * x_old[s]`

用标准矩阵乘法写：`x_new = H_res^T @ x_old`

所以代码的 H_res 和论文的 M（标准左乘矩阵）互为转置：**M = H_res^T**

---

## 3. Amax 连乘

### 捕获

在 forward pass 中，每个 HC 模块存储它的 4×4 H_res 矩阵。  
32 层 × 2 HC/层 = 64 个 H_res 矩阵。  
每个矩阵是 per-token 的，形状 `(batch, seq_len, 4, 4)`。

### 连乘

```
composite = H_res_0 @ H_res_1 @ H_res_2 @ ... @ H_res_63
```

这是 batch matrix multiply，对每个 token 独立计算。

对应论文的 composite mapping（左乘格式）：

```
M_composite = composite^T = (H_res_0 @ H_res_1 @ ... @ H_res_63)^T
```

信号从第 0 层传到第 63 层：

```
x_63 = M_63 @ M_62 @ ... @ M_0 @ x_0
     = (H_res_0 @ H_res_1 @ ... @ H_res_63)^T @ x_0
     = composite^T @ x_0
```

### Forward Amax

论文定义：M_composite 的 **最大绝对行和**。

```
forward_amax = max_i |Σ_j M[i, j]|
```

衡量：前向传播中，哪个输出 stream 接收到的信号总和最大。

因为 M = composite^T，所以：

```
Σ_j M[i, j] = Σ_j composite[j, i] = composite 第 i 列的和
```

代码：

```python
composite.sum(dim=-2)  # 沿 from 维度（dim=-2）求和 = 每列的和
.abs().max(dim=-1)     # 取绝对值后取最大
.values.mean()         # 对所有 token 取平均
```

### Backward Amax

论文定义：M_composite 的 **最大绝对列和**。

```
backward_amax = max_j |Σ_i M[i, j]|
```

衡量：反向传播中（梯度走 M^T），哪个输入 stream 的梯度被放大最多。

因为 M = composite^T，所以：

```
Σ_i M[i, j] = Σ_i composite[j, i] = composite 第 j 行的和
```

代码：

```python
composite.sum(dim=-1)  # 沿 to 维度（dim=-1）求和 = 每行的和
.abs().max(dim=-1)     # 取绝对值后取最大
.values.mean()         # 对所有 token 取平均
```

### Amax Max

```
amax_max = max(forward_amax, backward_amax)
```

---

## 4. 数值示例

训练初期（step 0）：
- 每个 H_res ≈ 单位矩阵
- composite ≈ 单位矩阵
- forward_amax ≈ 1.0, backward_amax ≈ 1.0

训练中期（step 2500）：
- 每个 H_res 开始偏离单位矩阵
- 64 个矩阵连乘，偏差被指数放大
- amax 开始增长

训练后期（step 5000）：
- 我们观测到 forward_amax ≈ 100,000x, backward_amax ≈ 350,000x
- Taylor 观测到 max_amax ≈ 10,924x
- DeepSeek 27B 观测到 max_amax ≈ 3,000x

---

## 5. 与 Taylor / DeepSeek 的差异

我们的 Amax 比 Taylor 高约 32 倍。已排除的原因：

| 因素 | 状态 |
|------|------|
| HC 数量（2 per block） | 一致，论文明确说 2 |
| expansion rate n=4 | 一致 |
| gating factor init α=0.01 | 一致 |
| learning_rate=1e-4 | 一致 |
| 数据集 C4 | 一致 |
| Amax 公式 | 与论文一致 |
| forward/backward 方向 | 与论文一致 |

未确认的差异：

| 因素 | 说明 |
|------|------|
| HC 代码实现 | 我们用 lucidrains 库，Taylor 用自己的代码 |
| 模型架构 | 我们用 nanoGPT（GPT-2），Taylor 用自定义 GPT |
| Norm 位置/类型 | 可能不同 |
| 初始化方式 | 可能不同 |
| H_res 的 dynamic 部分行为 | 可能不同 |
