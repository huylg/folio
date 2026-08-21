---
title: Complexity proof
tags: [attention, to-cite]
---

# Complexity proof

## Lemma 3

Sparsity of the routing mask bounds the number of loaded key blocks by B, giving O(nB) work per head.

$$
W(n) \leq n \cdot B \cdot d
$$
