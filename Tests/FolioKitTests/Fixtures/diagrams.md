# Diagrams

A left-to-right flowchart.

```mermaid
flowchart LR
    A[Read] --> B[Parse]
    B --> C[Render]
```

A top-down flowchart with mixed shapes and labelled edges.

```mermaid
flowchart TD
    Start[Start] --> Check{Cached?}
    Check -->|yes| Serve([Serve])
    Check -->|no| Fetch[[Fetch]]
    Fetch --> Store[(Store)]
    Store --> Serve
```

A state machine.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Working : start
    Working --> Idle
    Working --> [*] : stop
```

A kind Folio does not draw.

```mermaid
sequenceDiagram
    Alice->>Bob: Hello
```

Malformed, and must fall back rather than draw something wrong.

```mermaid
flowchart LR
    ]]] --> [[[
```

An ordinary code fence, as a control.

```python
def route(x):
    return x
```
