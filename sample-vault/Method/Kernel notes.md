---
title: Kernel notes
tags: [efficiency, reviewed]
---

# Kernel notes

## Dispatch

The mask is built once per layer:

```python
mask = build_routing_mask(q, k, budget=128)
```

## Memory layout

Key blocks are kept in HBM-contiguous tiles so a routed gather stays coalesced.

| Tile | Bytes | Residency |
| --- | ---: | --- |
| Q | 16,384 | registers |
| K | 65,536 | shared |
| V | 65,536 | shared |
