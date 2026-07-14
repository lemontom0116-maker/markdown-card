export const previewMarkdown = String.raw`###### RESEARCH NOTE / 014

# Self-Attention

Self-attention is a mechanism that allows a sequence to attend to its own elements to compute contextualized representations.

- Captures long-range dependencies without recurrence.
- Enables parallel computation across sequence positions.
- Forms the core building block of Transformer models.

---

\`\`\`python
def self_attention(X):
    Q = X @ W_Q   # (n, d_k)
    K = X @ W_K   # (n, d_k)
    V = X @ W_V   # (n, d_v)
    scores = (Q @ K.T) / sqrt(d_k)
    weights = softmax(scores, axis=-1)
    return weights @ V
\`\`\`

$$
\operatorname{Attention}(Q,K,V)=\operatorname{softmax}\left(\frac{QK^\mathsf{T}}{\sqrt{d_k}}\right)V
$$

---

> Note: Positional information must be added separately (e.g., positional encoding).`;
