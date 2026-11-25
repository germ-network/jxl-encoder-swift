---
'@germ-network/jxl-encoder-swift': patch
---

Give each DC group its own AC histogram set when a frame has more than eight AC groups, matching libjxl's streaming layout.
