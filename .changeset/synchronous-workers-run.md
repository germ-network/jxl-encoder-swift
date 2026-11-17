---
'@germ-network/jxl-encoder-swift': patch
---

Add synchronous pixel encoding with bounded worker scheduling through the optional Dispatch product. Runner APIs require iOS 18 or macOS 15; existing serial and async calls remain available, and eligible JPEG recompression stays serial.
