# Nano Banana Visual Prompts For Prediction-Market Routing Post

These prompts are designed for one-shot concept generation with Gemini image models.
The goal is not polished product art. The goal is austere, technically legible blog visuals
that feel at home in a computer-science essay about market structure.

## Global Style Guide

Use this style guidance with every prompt:

- white or near-white background
- sparse palette: charcoal lines, muted blue, muted terracotta, very light gray only
- flat vector-like forms, low-poly geometry, no glossy rendering
- thin strokes, plenty of whitespace, minimal shading
- technical notebook / research-blog aesthetic, not startup marketing
- readable labels only if the model can render them cleanly; otherwise leave space for labels to be added later in SVG
- slight hand-drawn warmth is okay, but diagrams should still feel precise
- if humans appear, use tiny stick figures only
- composition should look like something from a Vitalik-style technical blog post: simple, direct, slightly eccentric, intellectually playful, and visually restrained

## Prompt 1: Hypergraph Overview

Create a clean computer-science diagram showing why prediction-market routing is not just pathfinding.

Scene:
- one collateral node on the left labeled conceptually as collateral
- five outcome nodes arranged in a semicircle or arc on the right
- several ordinary pairwise edges from collateral to individual outcomes, drawn as simple straight thin lines
- one hyperedge touching collateral and all five outcomes at once, drawn as a faceted polygon hull or low-poly envelope, clearly distinct from ordinary edges
- include a tiny stick figure trader near the bottom looking at the topology

Design intent:
- the viewer should immediately understand that pairwise swap edges are different from one basket operation that touches many assets at once
- avoid UI cards, dashboards, and network-monitoring aesthetics
- avoid neon colors, gradients, glossy 3D, and photorealism
- keep the geometry elegant and minimal, closer to a graph-theory textbook figure than a product illustration

Composition:
- wide landscape ratio
- lots of whitespace
- strong visual contrast between the thin pairwise lines and the larger low-poly hyperedge hull
- if any labels are included, keep them tiny and monospace-like

## Prompt 2: Synthetic YES Route

Create a minimal explanatory diagram for a binary prediction market showing a synthetic route to acquire YES.

Scene:
- small stick figure trader on the far left
- a simple left-to-right flow with three conceptual steps:
- step 1: spend one unit of collateral and mint a complete set
- step 2: separate into YES and NO tokens
- step 3: sell the unwanted NO token for cash, leaving YES in hand
- at the bottom or side, show the key arithmetic visually: direct YES costs 0.62, synthetic YES costs 1.00 minus 0.45 equals 0.55

Design intent:
- emphasize the insight, not the transaction UI
- this should look like a whiteboard derivation made visual
- the arithmetic comparison should be the emotional center of the graphic
- show clearly that the synthetic route is cheaper than the direct route

Style:
- thin lines, flat token circles or low-poly token shapes
- no panels, no glossy buttons, no faux app interface
- use one muted accent color to highlight the better synthetic route
- allow a little personality in the stick figure, but keep it tiny and spare

Composition:
- wide landscape ratio
- continuous flow, not three separate boxes
- one strong comparison area with 0.62 visually dominated by 0.55

## Prompt 3: Price Discovery Router

Create a sparse systems-and-math diagram showing how a global optimizer coordinates many local trading venues using internal prices.

Scene:
- several venue nodes around the perimeter: a few ordinary AMM venues and one split/merge venue
- in the center, a simple mathematical object representing the internal price vector, such as [Pc, P1, P2, ... , PN]
- arrows from the central price vector out to venues labeled conceptually as "prices"
- arrows returning from venues back toward the center labeled conceptually as "best local trade"
- the whole composition should read as an iterative loop rather than a hub-and-spoke dashboard

Design intent:
- express "replace route enumeration with price discovery"
- make it feel like a market mechanism diagram, not software architecture
- keep the venues simple and abstract, almost like operators in a graph
- the center should feel like a coordinating mathematical object, not a control tower

Style:
- white background
- mostly line art with a few muted fills
- very restrained use of color
- no rounded application cards, no icons that look like SaaS feature badges

Composition:
- circular or oval layout is fine
- keep the arrows legible and rhythmic
- leave enough whitespace that the loop is visually obvious at a glance

## Prompt 4: Split/Merge Oracle

Create a minimal technical illustration of the split/merge oracle for a prediction market.

Scene:
- a very simple balance-beam or low-poly scale
- one side represents the sum of outcome prices
- the other side represents the collateral price
- show the three cases visually:
- outcomes heavier than collateral means mint
- balanced means no structural trade
- collateral heavier than outcomes means merge
- optionally include tiny symbolic text like sum(outcomes) > collateral, equals, less than, but only if it can be rendered clearly

Design intent:
- make the oracle feel almost embarrassingly simple
- the viewer should instantly understand that one scalar comparison determines the structural trade direction
- keep it austere, almost theorem-sketch-like

Style:
- simple beam, triangle fulcrum, geometric weights
- very little decoration
- muted blue on one side and muted terracotta on the other is enough
- if text is unreliable, rely on geometry instead

Composition:
- landscape ratio
- large central beam
- highly legible silhouette even when scaled down inside a blog post

## Prompt 5: One-Shot Contact Sheet

Create a single 2x2 contact sheet containing four related diagrams for a technical blog post about prediction-market routing.

Top left:
- graph versus hypergraph topology with one collateral node, five outcome nodes, pairwise edges, and one faceted hyperedge hull

Top right:
- binary synthetic YES route with a stick figure trader, mint complete set, sell NO, keep YES, and a visible 0.62 versus 0.55 comparison

Bottom left:
- price-discovery loop with central internal price vector and multiple local venues sending back best local trades

Bottom right:
- split/merge oracle as a simple balance beam comparing sum of outcome prices to collateral price

Global constraints:
- all four panels must share one coherent visual language
- white background, thin strokes, low-poly geometry, muted academic palette
- technical blog style, not app marketing, not comic book, not photorealistic
- enough whitespace that each panel can later be traced or translated into SVG
- avoid dense text; prefer shapes that communicate the idea even without words
