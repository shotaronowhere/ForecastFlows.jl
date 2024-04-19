# Algorithm

Please see our paper [Convex Network Flows](https://arxiv.org/abs/2404.00765)[^1]
for full algorithmic details. This section provides a very brief high-level
sketch.

`ConvexFlows` solves problems of the form
```math
\begin{array}{ll}
\text{maximize}     & U(y) + \sum_{i=1}^m V_i(x_i) \\
\text{subject to}   & y = \sum_{i=1}^m A_i x_i \\
&& x_i \in T_i
\end{array}
```
where $f$ and $g$ are assumed to be convex.


## References
[^1]: Diamandis, T., Angeris, G., & Edelman, A. (2024). [Convex Network Flows.](https://arxiv.org/abs/2404.00765) arXiv preprint arXiv:2404.00765.
