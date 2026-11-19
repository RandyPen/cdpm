# Scallop Move dependency

The Move sources come from [Scallop's public repository at commit 334e93a](https://github.com/scallop-io/sui-lending-protocol/tree/334e93a1232a1d9417466080ae24491be3f7b27c/contracts). The public manifests point to lending v19 and X v1. The local manifests pin the current lending package and the X version listed in its Sui mainnet linkage.

| Package | Original package ID | Published package ID |
| --- | --- | --- |
| Lending v20 | `0xefe8b36d5b2e43728cc323298626b83177803521d195cfb11e15b910e892fddf` | `0x560a9732944dbed51a46036558e452431c25392765e7e3da02506bc6a226c825` |
| X v2 | `0x779b5c547976899f5474f3a5bc0db36ddf4697ad7e5a901db0415c2281d28162` | `0x53c23bd7342c87d16ac7da8327bee0b139298bd0323bc3238f313fd31c6c5d61` |

CDPM compiles against the public source interface. The on-chain signatures for `mint::mint` and `redeem::redeem` match between v19 and v20. The [Move Registry record](https://www.moveregistry.com/package/lending@scallop/core) tracks the lending deployment.
