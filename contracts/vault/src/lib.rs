// Vault Contract — T1.1 (ETA: August 2026)
//
// USDC entry point. Accepts deposits, mints agUSD 1:1, manages
// the two-step FIFO withdrawal queue (request_withdrawal → claim_withdrawal).
// Queries Oracle Adapter for NAV. Routes capital via Allocation Engine.
//
// Status: in development
