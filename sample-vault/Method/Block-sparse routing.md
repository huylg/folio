---
title: Block-sparse routing
tags: [attention, efficiency]
---

# Block-sparse routing

Routing happens once per layer. The routing mask M_θ is the only learned component, so the kernel drops into an existing stack without retraining.

## Notes

- Budget is expressed in key blocks, not tokens
- The mask transfers across model scales (see reviewer replies)
