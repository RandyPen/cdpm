# Error Reference

| Error | Cause | Solution |
|-------|-------|----------|
| `EPriceIsZero` | Price parameter is 0 | Validate price before calculation |
| `ELiquidityOverflow` | Result exceeds u128 max | Reduce input amounts |
| `InvalidBinId` | Bin ID out of valid range | Check with `findMinMaxBinId()` |
| `LiquiditySupplyIsZero` | Attempting to remove from empty bin | Check liquidity before removal |
| `InvalidDeltaLiquidity` | Removing more than available | Validate against total liquidity |
