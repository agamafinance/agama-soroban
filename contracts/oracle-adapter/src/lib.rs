// Oracle Adapter Contract — T2.2 (ETA: October 2026)
//
// Multi-source NAV pipeline:
//   - Reflector feeds: XLM/USD and USDC/USD (1h staleness, 2% deviation bound)
//   - Custom reporter: private credit NAV (7d staleness, 5% deviation bound)
//   - Etherfuse API: Stablebond pricing (48h staleness, deterministic)
//
// Validates caller authorization, timestamp freshness, and deviation bounds.
// Vault calls get_nav(); reverts with OracleStale if feed is expired.
//
// Status: in development
