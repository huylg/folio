# TeX → Unicode symbol table

Lifted from `MathFormatter.prettify` before the HTML renderer was deleted. It is the one
genuinely reusable asset from that file: a starting point for the native math renderer's symbol
table, which will need to grow to roughly 140 entries with atom classes attached.

```swift
let symbols: [(String, String)] = [
            ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"), ("\\epsilon", "ε"),
            ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"), ("\\sigma", "σ"),
            ("\\phi", "φ"), ("\\omega", "ω"), ("\\Delta", "Δ"), ("\\Sigma", "Σ"), ("\\Omega", "Ω"),
            ("\\times", "×"), ("\\cdot", "·"), ("\\pm", "±"), ("\\leq", "≤"), ("\\geq", "≥"),
            ("\\neq", "≠"), ("\\approx", "≈"), ("\\infty", "∞"), ("\\sum", "∑"), ("\\prod", "∏"),
            ("\\int", "∫"), ("\\partial", "∂"), ("\\nabla", "∇"), ("\\sqrt", "√"), ("\\in", "∈"),
            ("\\subset", "⊂"), ("\\subseteq", "⊆"), ("\\cup", "∪"), ("\\cap", "∩"), ("\\to", "→"),
            ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"), ("\\odot", "⊙"),
            ("\\top", "ᵀ"), ("\\|", "‖"), ("\\,", " "), ("\\;", " "), ("\\!", ""), ("\\ ", " "),
        ]
```
