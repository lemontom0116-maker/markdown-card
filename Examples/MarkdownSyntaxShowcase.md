# Markdown Syntax Showcase

This card exercises the Markdown, GFM, KaTeX, and renderer-plugin features supported by Easy Card. This deliberately long sentence wraps naturally inside a narrow Sticky Note so automatic wrapping can be compared with the following paragraph.

This paragraph starts after Enter and should use exactly the same baseline spacing as the wrapped line above.\
This line uses a Markdown hard break and should keep the same body line height too.

## Inline formatting

**Bold**, *italic*, ***bold italic***, ~~strikethrough~~, `inline code`, an escaped \*asterisk\*, and a [safe external link](https://example.com).

### Blockquote

> Easy Card keeps quotes in the same continuous canvas.
>
> > Nested quotes remain editable and serialize back to Markdown.

#### Lists

- Unordered item
- Nested structures
  - Nested bullet
  - Another nested bullet

1. First ordered item
2. Second ordered item
   1. Nested ordered item

##### Tasks

- [ ] Unfinished task
- [x] Completed task uses a lighter text color

###### Small metadata heading

---

## GFM table

| Feature | Input | Result |
| --- | --- | --- |
| Bold | `**text**` | **text** |
| Task | `- [x] done` | Completed state |
| Formula | `$E=mc^2$` | Inline KaTeX |

## Fenced code with language

```python
from dataclasses import dataclass

@dataclass
class Card:
    title: str
    pinned: bool = True

print(Card("Markdown Syntax Showcase"))
```

```swift
struct Layout {
    let width: Double
    let minimumHeight: Double
    let maximumHeight: Double
}
```

## Mathematics

Inline formula: $E = mc^2$.

$$
\operatorname{Attention}(Q,K,V)
= \operatorname{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right)V
$$

## YouTube plugin node

[![YouTube video](https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg)](https://www.youtube.com/watch?v=dQw4w9WgXcQ)

## Safe degradation

Remote images remain visible as a restricted placeholder instead of loading inside the WebView:

![Remote image](https://example.com/markdown-card.png)

Local file image URLs are preserved as visible source and never read:

![Local image](file:///tmp/private-image.png)

Raw HTML is displayed as source rather than creating executable DOM:

<script>alert("This must never execute")</script>

<img src="file:///tmp/private-image.png" onerror="alert('blocked')">
